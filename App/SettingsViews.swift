// Viser indstillinger, noter, forbindelsestest og eksport af fejllog.

import SwiftUI
import UIKit

struct FadedNotesSheet: View {
    let onClose: () -> Void
    @State private var unsavedNotes: String?

    var body: some View {
        NavigationStack {
            TextEditor(text: Binding(get: { unsavedNotes ?? MigratedAppData.shared.notes }, set: saveNotes))
                .font(FadedTypography.body)
                .scrollContentBackground(.hidden)
                .padding(FadedSpacing.edge)
                .background(FadedBackground())
                .accessibilityLabel("Dine noter")
                .navigationTitle("Noter")
                .toolbar { Button("Luk", action: onClose) }
                .safeAreaInset(edge: .bottom) {
                    if unsavedNotes != nil { Text("Noten kunne ikke gemmes.").font(.footnote).padding() }
                }
        }
    }

    private func saveNotes(_ text: String) {
        do { try MigratedAppData.shared.saveNotes(text); unsavedNotes = nil }
        catch { AppDiagnostics.record(error); unsavedNotes = text }
    }
}

private struct VideoCleanupSettings: View {
    let prunePreviews: () -> String
    let hideFinishedJobs: () -> Int
    @State private var previewNotice: String?
    @State private var jobsNotice: String?
    @State private var confirmHideJobs = false

    var body: some View {
        Button("Ryd previews over 24 timer") { previewNotice = prunePreviews() }
        if let previewNotice { FadedDetailText(previewNotice) }
        Button("Skjul afsluttede jobs på denne telefon", role: .destructive) { confirmHideJobs = true }
            .confirmationDialog("Skjul afsluttede jobs på denne telefon?", isPresented: $confirmHideJobs) {
                Button("Skjul afsluttede jobs", role: .destructive) {
                    let count = hideFinishedJobs()
                    jobsNotice = count == 0 ? "Der er ingen afsluttede jobs at skjule."
                        : count == 1 ? "Ét afsluttet job er skjult." : "\(count) afsluttede jobs er skjult."
                }
            } message: {
                Text("Videoer og jobhistorik bliver liggende på PC’en.")
            }
        if let jobsNotice { FadedDetailText(jobsNotice) }
    }
}

extension Home {
    private var connectionIndicator: some View {
        let latency = model.latencyMs
        let color = latencyColor(latency)
        return HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
            Label("\(model.activeProfile.route) · \(model.connected ? "Forbundet" : "Ikke forbundet")",
                  systemImage: model.connected ? "checkmark.circle" : "exclamationmark.circle")
            if let latency { Text("\(latency) ms").foregroundStyle(.secondary) }
        }.font(.subheadline)
    }

    var settingsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FadedSpacing.section) {
                    ForEach(SettingsCategory.allCases, id: \.self) { category in
                        NavigationLink { settingsPage(category) } label: { settingsRow(category) }
                            .buttonStyle(.plain)
                    }
                }.padding(FadedSpacing.edge)
            }
            .background(FadedBackground())
            .navigationTitle("Indstillinger")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Luk") { showSettings = false } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(palette.background)
    }

    func latencyColor(_ milliseconds: Int?) -> Color {
        guard let milliseconds else { return palette.coral }
        if milliseconds < 50 { return palette.green }
        return milliseconds <= 200 ? .yellow : palette.coral
    }

    private func settingsRow(_ category: SettingsCategory) -> some View {
        let accent: Color = switch category {
        case .connection: palette.cyan
        case .models: palette.purple
        case .appearance: palette.lime
        case .diagnostics: palette.secondary
        }
        return FadedCard {
            HStack(spacing: 12) {
                Image(systemName: category.icon).foregroundStyle(FadedColors.deep)
                    .frame(width: 34, height: 34).background(accent, in: Circle()).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    FadedSectionLabel(category.rawValue)
                    Text(category.detail).font(.subheadline).foregroundStyle(palette.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(palette.secondary).accessibilityHidden(true)
            }
        }
    }

    private func settingsPage(_ category: SettingsCategory) -> some View {
        Form {
            switch category {
            case .connection:
                connectionIndicator
                pingSetting
                Button("Skift forbindelse") { closeSettings(for: .login) }.disabled(switchDisabled)
                NavigationLink("Forbindelser") { ConnectionsView() }
                Toggle("Vis forbindelsesbanner", isOn: $showConnectionBanner)
                Toggle("Opdatér ved faneskift", isOn: $autoRefreshTabs)
            case .models:
                Button("Lokale modeller (iPhone)") { closeSettings(for: .models) }
                NavigationLink("PC-modeller (RTX 3070)") { PCModelsView(api: studioAPI) }
                Toggle("Vælg automatisk model", isOn: $autoModelRouter)
                Text("Automatisk modelvalg bruger Telefon og PC. Grok vælges manuelt.")
                    .font(.caption).foregroundStyle(palette.secondary)
                Button("Privat Studio") { closeSettings(for: .privateChat) }
                Button("Mine bots") { closeSettings(for: .bots) }
                Button("Code Bot og Agent Workspace") { closeSettings(for: .code) }
                CloudModelSettings()
            case .appearance:
                appearanceSettings
                Section("Chat og lyd") {
                    Toggle("Vis værktøjsstatus", isOn: $showChatTools)
                    Toggle("Læs chatsvar op", isOn: $readChatAloud)
                    Toggle("Haptisk feedback", isOn: $appHaptics)
                    Text("Vælg stemme i chatten eller på din bots profil.").font(.callout).foregroundStyle(palette.secondary)
                }
            case .diagnostics:
                pingSetting
                ResourceMonitor()
                Section("Notifikationer") { JobNotificationSettings() }
                Toggle("Liveaktivitet på låseskærmen", isOn: $liveActivityEnabled)
                Button("Eksportér fejllog", systemImage: "square.and.arrow.up") { closeSettings(for: .export) }
                Toggle("Gem genererede billeder i Fotos", isOn: $saveImagesToPhotos)
                Toggle("Bekræft før video startes", isOn: $confirmVideoStart)
                VideoCleanupSettings(prunePreviews: prunePreviews) {
                    let previousCount = hiddenJobs.count
                    hiddenJobs.formUnion(model.jobs.filter { !$0.status.active }.map(\.id))
                    return hiddenJobs.count - previousCount
                }
                NukeLocalDataButton()
            }
        }
        .scrollContentBackground(.hidden)
        .background(FadedBackground())
        .navigationTitle(category.rawValue)
    }

    @ViewBuilder private var pingSetting: some View {
        Button(pinging ? "Tester PC…" : "Ping PC", systemImage: "network") {
            Task {
                pinging = true
                defer { pinging = false }
                pingResult = await model.ping()
            }
        }.disabled(pinging)
        if let pingResult { Text(pingResult).font(.caption).foregroundStyle(.secondary) }
    }

    private func closeSettings(for destination: SettingsFollowup) {
        settingsFollowup = destination
        showSettings = false
    }

    func openSettingsFollowup() {
        guard let destination = settingsFollowup else { return }
        settingsFollowup = nil
        switch destination {
        case .login: showLogin = true
        case .models: showPhoneModels = true
        case .privateChat: openStudio(.chat)
        case .bots: showBots = true
        case .code: searchCodePath = nil; showCodeWorkspace = true
        case .export: exportDiagnostics()
        }
    }

    @ViewBuilder private var appearanceSettings: some View {
        Picker("Lys og mørke", selection: $appearanceMode) {
            ForEach(FadedAppearance.allCases, id: \.self) { mode in Text(mode.rawValue).tag(mode) }
        }
        Picker("Tema", selection: $theme) {
            ForEach(FadedTheme.allCases) { choice in Text(choice.rawValue).tag(choice) }
        }
        textSizeSetting
        Picker("Skrift", selection: $font) {
            ForEach(["Standard", "Afrundet", "Monospace"], id: \.self) { Text($0) }
        }
        Toggle("Bevægelse i baggrunden", isOn: $motion)
        Toggle("Ekstra rolig bevægelse", isOn: $calmMotion)
        Toggle("Husk seneste fane", isOn: $rememberLastSpace)
        Toggle("Hold skærmen vågen", isOn: $keepScreenAwake)
        Toggle("Kompakte klipkort", isOn: $compactClipCards)
        Toggle("Vis kliplængde", isOn: $showClipDurations)
        Toggle("Vis jobdetaljer", isOn: $showJobDetails)
    }

    private var textSizeSetting: some View {
        let slider = Slider<Text, EmptyView>(value: $textScale, in: 0.0...5.0, step: 1.0,
                                             label: { Text("Tekststørrelse") })
        return slider
            .accessibilityLabel("Tekststørrelse i appen")
            .sensoryFeedback(.selection, trigger: textScale) { (old: Double, new: Double) in
                appHaptics && old != new && (new == 0 || new == 5)
            }
    }

    func exportDiagnostics() {
        let selected = UserDefaults.standard.string(forKey: PhoneModels.selectionKey) ?? "apple"
        let name = PhoneModels.catalog.first(where: { $0.id == selected })?.name
            ?? (selected == "imported" ? "Importeret model" : "Apple Foundation Models")
        do {
            diagnosticsExport = DiagnosticsExport(url: try AppDiagnostics.export(phoneModel: name,
                                                                                 pcConnected: model.connected && !model.isDemo))
        }
        catch { AppDiagnostics.record(error); diagnosticsError = true }
    }
}
