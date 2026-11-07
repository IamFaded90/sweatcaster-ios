import CoreML
import CoreMLLLM
import Foundation
import FoundationModels
import SwiftUI
import UniformTypeIdentifiers

enum PhoneModelError: Error {
    case unavailable, invalidBundle, emptyResponse
}

enum PhoneModels {
    struct Entry: Identifiable {
        let model: ModelDownloader.ModelInfo
        let memory: String
        var id: String { model.id }
    }

    static func hasDownloadSpace(bytes: Int64) -> Bool {
        let values = try? URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return (values?.volumeAvailableCapacityForImportantUsage ?? 0) >= bytes
    }

    static var catalog: [Entry] {
        [
            .init(model: .lfm2_5_350m, memory: "Lavere hukommelsesforbrug"),
            .init(model: .qwen35_08b, memory: "Mellem hukommelsesforbrug"),
            .init(model: .gemma4e2b, memory: "Højt hukommelsesforbrug")
        ]
    }

    static var appleAvailable: Bool {
        if #available(iOS 26.0, *), case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static var importedFolder: URL {
        URL.applicationSupportDirectory.appending(path: "ImportedPhoneModels", directoryHint: .isDirectory)
    }

    static func installedDirectory(_ id: String) -> URL? {
        if id == "imported" {
            let config = importedFolder.appending(path: "model_config.json")
            return FileManager.default.fileExists(atPath: config.path) ? importedFolder : nil
        }
        guard let entry = catalog.first(where: { $0.id == id }) else { return nil }
        return ModelDownloader.shared.localModelURL(for: entry.model)?.deletingLastPathComponent()
    }

    static func prefersPC(_ message: String, previousCharacters: Int) -> Bool {
        if message.count + previousCharacters > 3_000 || message.count > 1_200 { return true }
        let text = message.lowercased()
        return ["video", "klip", "render", "researcher", "søg på", "søg efter", "websøg",
                "seneste nyt", "min pc", "på pc", "file explorer", "agent-hub"].contains { text.contains($0) }
    }

    @MainActor static func reply(modelID: String, prompt: String, update: (String) -> Void) async throws {
        var answer = ""
        if modelID == "apple" {
            guard #available(iOS 26.0, *), appleAvailable else { throw PhoneModelError.unavailable }
            let session = LanguageModelSession(instructions: "Svar kort på brugerens sprog. Du har kun adgang til teksten i chatten.")
            for try await snapshot in session.streamResponse(to: prompt) {
                try Task.checkCancellation()
                answer = snapshot.content
                update(answer)
            }
        } else {
            guard let folder = installedDirectory(modelID) else { throw PhoneModelError.unavailable }
            let model = try await CoreMLLLM.load(from: folder, computeUnits: .cpuAndNeuralEngine)
            try Task.checkCancellation()
            for await token in try await model.stream(prompt, maxTokens: 384) {
                try Task.checkCancellation()
                answer += token
                update(answer)
            }
        }
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PhoneModelError.emptyResponse
        }
    }

    static func importFolder(_ source: URL) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let files = FileManager.default
        guard files.fileExists(atPath: source.appending(path: "model_config.json").path),
              files.fileExists(atPath: source.appending(path: "hf_model/tokenizer.json").path),
              let contents = try? files.contentsOfDirectory(at: source, includingPropertiesForKeys: nil),
              contents.contains(where: { ["mlpackage", "mlmodelc"].contains($0.pathExtension) })
        else { throw PhoneModelError.invalidBundle }
        let parent = importedFolder.deletingLastPathComponent()
        try files.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? files.removeItem(at: staging) }
        try files.copyItem(at: source, to: staging)
        var modelDirectory = staging
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try modelDirectory.setResourceValues(values)
        if files.fileExists(atPath: importedFolder.path) {
            _ = try files.replaceItemAt(importedFolder, withItemAt: staging)
        } else {
            try files.moveItem(at: staging, to: importedFolder)
        }
    }
}

struct PhoneModelsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("phone.model") private var selected = "apple"
    @State private var downloadID: String?
    @State private var importing = false
    @State private var working = false
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Standard") {
                    Button { selected = "apple" } label: {
                        modelLabel("Apple Foundation Models", id: "apple")
                    }
                    Text(PhoneModels.appleAvailable ? "Klar på denne telefon."
                         : "Kræver iOS 26 og en aktiv, kompatibel Apple Intelligence-model.")
                        .font(.caption)
                }
                Section("Core ML-modeller") {
                    Text("Størrelser er cirka. RAM afhænger af telefonen og længden af chatten.")
                        .font(.caption)
                    ForEach(PhoneModels.catalog) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.model.name).font(.headline)
                            Text("\(entry.model.size) · \(entry.memory)").font(.caption)
                            if PhoneModels.installedDirectory(entry.id) != nil {
                                Button { selected = entry.id } label: { modelLabel("Brug modellen", id: entry.id) }
                            } else if downloadID == entry.id {
                                let progress = min(1, max(0, ModelDownloader.shared.progress))
                                ProgressView(value: progress) {
                                    Text("Henter modellen · \(progress.formatted(.percent.precision(.fractionLength(0))))")
                                }
                            } else {
                                Button("Download") { download(entry) }
                                    .disabled(downloadID != nil || working)
                            }
                        }
                    }
                }
                Section("Importér fra Filer") {
                    Text("Gem modellen via AirDrop eller en filserver i Filer. Pak ZIP-filen ud, og vælg hele Core ML-modelmappen.")
                        .font(.caption)
                    Button("Vælg modelmappe") { importing = true }.disabled(working || downloadID != nil)
                    if working { ProgressView("Importerer model…") }
                    if PhoneModels.installedDirectory("imported") != nil {
                        Button { selected = "imported" } label: { modelLabel("Brug importeret model", id: "imported") }
                    }
                }
                if let notice { Text(notice) }
            }
            .navigationTitle("Lokale modeller")
            .toolbar { Button("Luk") { dismiss() }.disabled(working || downloadID != nil) }
            .interactiveDismissDisabled(working || downloadID != nil)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { importModel(url) }
            }
        }
    }

    private func modelLabel(_ title: String, id: String) -> some View {
        Label(title, systemImage: selected == id ? "checkmark.circle.fill" : "circle")
            .accessibilityValue(selected == id ? "Valgt" : "Ikke valgt")
    }

    private func download(_ entry: PhoneModels.Entry) {
        let reserves: [String: Int64] = ["lfm2.5-350m": 1_200_000_000, "qwen3.5-0.8b": 1_800_000_000, "gemma4-e2b": 7_000_000_000]
        guard PhoneModels.hasDownloadSpace(bytes: reserves[entry.id] ?? 2_000_000_000) else {
            notice = "Der er ikke plads nok til modellen. Frigør plads, og prøv igen."
            return
        }
        downloadID = entry.id
        notice = nil
        Task {
            defer { downloadID = nil }
            do {
                _ = try await ModelDownloader.shared.download(entry.model)
                selected = entry.id
                notice = "Modellen er hentet og valgt."
            } catch { notice = "Modellen kunne ikke hentes. Tjek internet og ledig plads, og prøv igen." }
        }
    }

    private func importModel(_ url: URL) {
        working = true
        notice = nil
        Task {
            defer { working = false }
            do {
                try await Task.detached(priority: .userInitiated) { try PhoneModels.importFolder(url) }.value
                selected = "imported"
                notice = "Modellen er importeret og valgt."
            } catch {
                notice = "Importen mislykkedes. Vælg en udpakket Core ML-modelmappe med konfiguration og tokenizer."
            }
        }
    }
}
