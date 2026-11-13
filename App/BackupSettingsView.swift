// Explicit local backup export and biometric restore confirmation.

import Foundation
import LocalAuthentication
import SwiftUI
import UniformTypeIdentifiers

@MainActor struct BackupSettingsView: View {
    var canRestore: () -> Bool = { true }
    var onRestore: () -> Void = {}

    @State private var choosingFile = false
    @State private var creatingBackup = false
    @State private var review: ArchiveSelection?
    @State private var share: DiagnosticsExport?
    @State private var exportURL: URL?
    @State private var failure: String?
    @State private var didRestore = false

    var body: some View {
        Form {
            Section("Sikkerhedskopi") {
                FadedDetailText("Gem almindelige chats, noter, bots, indstillinger, videojob i kø og dit modelvalg.")
                FadedDetailText("ZIP-filen indeholder personligt indhold. Gem den et sted, du stoler på. Privat Studio, adgangsnøgler og downloadede modeller følger ikke med.")
                FadedDetailText("En kopi med videojob indeholder deres lokale PC-adresser, så de kan vises det rigtige sted.")
                FadedPrimaryButton(creatingBackup ? "Opretter backup…" : "Opret backup", icon: "square.and.arrow.up") {
                    failure = nil
                    creatingBackup = true
                }
                .disabled(creatingBackup)
                if creatingBackup { ProgressView("Pakker dine lokale data…") }
            }
            Section("Gendan") {
                FadedDetailText("Vælg en ZIP-fil fra FadedAI, og beslut, om den skal flettes ind eller erstatte de valgte data på telefonen.")
                FadedSecondaryButton("Vælg backupfil", icon: "folder") {
                    failure = nil
                    choosingFile = true
                }
                .disabled(creatingBackup)
            }
            if let failure {
                Section { FadedToast(failure, tone: .error) }
            }
        }
        .scrollContentBackground(.hidden)
        .background { FadedBackground() }
        .navigationTitle("Backup og gendan")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: creatingBackup) { createBackupIfRequested() }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.zip], onCompletion: selectBackup)
        .sheet(item: $share, onDismiss: removeTemporaryExport) { item in
            DiagnosticsShareSheet(url: item.url)
        }
        .sheet(item: $review, onDismiss: finishReview) { archive in
            NavigationStack {
                BackupRestoreReview(archive: archive, canRestore: canRestore) { didRestore = true }
            }
        }
    }

    private func createBackupIfRequested() {
        guard creatingBackup else { return }
        defer { creatingBackup = false }
        do {
            try Task.checkCancellation()
            let url = try BackupService.shared.createBackup()
            exportURL = url
            if Task.isCancelled { removeTemporaryExport(); return }
            share = DiagnosticsExport(url: url)
        } catch is CancellationError {
            return
        } catch {
            AppDiagnostics.record(error)
            failure = backupError(error, fallback: "Kunne ikke oprette backup. Tjek lagerpladsen, og prøv igen.")
        }
    }

    private func selectBackup(_ result: Result<URL, Error>) {
        do {
            review = ArchiveSelection(url: try result.get())
        } catch {
            if (error as? CocoaError)?.code == .userCancelled { return }
            AppDiagnostics.record(error)
            failure = "Kunne ikke åbne filen. Prøv at vælge ZIP-filen igen."
        }
    }

    private func removeTemporaryExport() {
        guard let exportURL else { return }
        self.exportURL = nil
        do { try FileManager.default.removeItem(at: exportURL) }
        catch { AppDiagnostics.record(error) }
    }

    private func finishReview() {
        guard didRestore else { return }
        didRestore = false
        onRestore()
    }
}

private struct ArchiveSelection: Identifiable {
    let id = UUID()
    let url: URL
}

@MainActor private struct BackupRestoreReview: View {
    private enum Choice: String, CaseIterable {
        case merge = "Flet"
        case replace = "Erstat"

        var detail: String {
            switch self {
            case .merge: "Tilføjer data fra kopien. Hvis en samtale, bot eller et job allerede findes, beholdes udgaven på telefonen."
            case .replace: "Kopiens chats, noter, bots, indstillinger, videojob i kø og modelvalg erstatter de tilsvarende data på telefonen."
            }
        }
    }

    let archive: ArchiveSelection
    let canRestore: () -> Bool
    let onRestored: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var choice: Choice = .merge
    @State private var confirmReplace = false
    @State private var authentication: LAContext?
    @State private var failure: String?
    @State private var restored = false

    var body: some View {
        Form {
            if restored {
                Section {
                    FadedToast("Backupen er gendannet.", tone: .success)
                    FadedDetailText("Gennemgå dine gendannede videojob. Opret et nyt job, hvis det skal køres igen.")
                    FadedPrimaryButton("Fortsæt", icon: "checkmark") { dismiss() }
                }
            } else {
                Section("Valgt backup") {
                    Text(verbatim: String(archive.url.lastPathComponent.prefix(160))).textSelection(.enabled)
                }
                Section("Vælg gendannelse") {
                    Picker("Metode", selection: $choice) {
                        ForEach(Choice.allCases, id: \.self) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    FadedDetailText(choice.detail)
                    FadedDetailText("Gendannede videojob sendes aldrig automatisk. Gennemgå dem, før du opretter et nyt job.")
                    if choice == .replace {
                        FadedDetailText("Gem en kopi af telefonens nuværende data først, hvis du vil kunne vende tilbage.")
                    }
                }
                .disabled(authentication != nil)
                Section {
                    if let failure { FadedToast(failure, tone: .error) }
                    if authentication != nil { ProgressView("Venter på godkendelse…") }
                    FadedPrimaryButton("Gendan backup", icon: "faceid") {
                        if choice == .replace { confirmReplace = true }
                        else { authenticateAndRestore() }
                    }
                    .disabled(authentication != nil)
                    FadedDetailText("Gendannelse kræver Face ID eller Touch ID.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background { FadedBackground() }
        .navigationTitle("Gendan backup")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(restored ? "Luk" : "Annuller") { dismiss() }.disabled(authentication != nil)
            }
        }
        .interactiveDismissDisabled(authentication != nil)
        .confirmationDialog("Erstat de valgte lokale data?", isPresented: $confirmReplace, titleVisibility: .visible) {
            Button("Erstat og godkend", role: .destructive, action: authenticateAndRestore)
            Button("Annuller", role: .cancel) {}
        } message: {
            Text("De tilsvarende data på telefonen erstattes af kopiens indhold. Godkend med Face ID eller Touch ID for at fortsætte.")
        }
        .onChange(of: phase) { _, current in
            if current == .background { cancelAuthentication() }
        }
        .onDisappear(perform: cancelAuthentication)
    }

    private func authenticateAndRestore() {
        guard authentication == nil, !restored else { return }
        failure = nil
        let context = LAContext()
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &policyError) else {
            if let policyError { AppDiagnostics.record(policyError) }
            failure = authenticationError(policyError)
            return
        }
        let selectedChoice = choice
        authentication = context
        Task {
            defer {
                if authentication === context { authentication = nil }
                context.invalidate()
            }
            do {
                let accepted = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                                                 localizedReason: "Godkend gendannelse af dine lokale data")
                guard authentication === context, phase != .background else { return }
                guard accepted else {
                    failure = "Gendannelsen blev ikke godkendt. Prøv igen, når du er klar."
                    return
                }
            } catch {
                guard authentication === context else { return }
                AppDiagnostics.record(error)
                failure = authenticationError(error)
                return
            }
            do {
                guard canRestore() else {
                    failure = "En PC-opgave er stadig i gang på telefonen. Vent et øjeblik, og prøv igen."
                    return
                }
                let url = archive.url
                let input = try await Task.detached(priority: .userInitiated) {
                    try BackupService.readArchive(from: url)
                }.value
                guard authentication === context, phase != .background else { return }
                guard canRestore() else {
                    failure = "En PC-opgave er stadig i gang på telefonen. Vent et øjeblik, og prøv igen."
                    return
                }
                switch selectedChoice {
                case .merge: try BackupService.shared.restoreBackup(archive: input, mode: .merge)
                case .replace: try BackupService.shared.restoreBackup(archive: input, mode: .replace)
                }
                restored = true
                onRestored()
            } catch {
                AppDiagnostics.record(error)
                failure = backupError(error, fallback: "Gendannelsen kunne ikke gennemføres. Tjek lagerpladsen, eller vælg en anden FadedAI-backup.")
            }
        }
    }

    private func cancelAuthentication() {
        guard let context = authentication else { return }
        authentication = nil
        context.invalidate()
    }

    private func authenticationError(_ error: Error?) -> String {
        switch (error as? LAError)?.code {
        case .biometryLockout:
            "Lås telefonen op med din kode for at genaktivere Face ID eller Touch ID. Prøv derefter igen."
        case .biometryNotAvailable, .biometryNotEnrolled:
            "Aktivér Face ID eller Touch ID i iPhones indstillinger for at gendanne."
        default:
            "Gendannelsen blev ikke godkendt. Prøv igen, når du er klar."
        }
    }
}

private func backupError(_ error: Error, fallback: String) -> String {
    (error as? BackupService.Failure)?.errorDescription ?? (error as? BackupArchive.Failure)?.errorDescription ?? fallback
}
