import MediaGenerationKit
import SwiftUI
import UniformTypeIdentifiers

struct OfflineStudio: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("offline.studio.enabled") private var enabled = false
    @AppStorage("phone.model") private var textModel = "apple"
    @AppStorage("offline.studio.lora") private var loraName = ""
    @State private var showModels = false
    @State private var importLoRA = false
    @State private var prompt = ""
    @State private var answer = ""
    @State private var status = ""
    @State private var imageURL: URL?
    @State private var task: Task<Void, Never>?
    @State private var imageModel = "sd_v1.5_f16.ckpt"
    @State private var useLoRA = false

    var body: some View {
        NavigationStack {
            Form {
                Toggle("Aktivér lokal tilstand", isOn: $enabled).disabled(task != nil)
                Text("Tekst og billeder behandles på telefonen. Download af modeller kræver internet.")
                    .font(.caption)
                if enabled {
                    textSection
                    imageSection
                }
                if !status.isEmpty { Text(status).accessibilityAddTraits(.updatesFrequently) }
                if task != nil {
                    Button("Stop") { task?.cancel() }.frame(minHeight: 48)
                }
            }
            .navigationTitle("NSFW / Uncensored")
            .toolbar { Button("Luk") { dismiss() } }
            .sheet(isPresented: $showModels) { PhoneModelsView() }
            .fileImporter(isPresented: $importLoRA, allowedContentTypes: [.data]) { result in
                if case .success(let url) = result { loadLoRA(url) }
            }
            .onDisappear { task?.cancel() }
        }
    }

    private var textSection: some View {
        Section("Lokal tekst") {
            Button("Download eller importér tekstmodel") { showModels = true }
                .frame(minHeight: 48).disabled(task != nil)
            Text(textReady ? "Core ML-modellen er klar." : "Vælg en downloadet eller importeret Core ML-model.")
            Text("Modellens egne svargrænser afhænger af de valgte vægte. Apple Foundation Models bruges ikke her.")
                .font(.caption)
            TextField("Din prompt", text: $prompt, axis: .vertical).lineLimit(2...6)
            Button("Svar på telefonen") {
                let message = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                answer = ""
                run("Telefonen tænker…") {
                    try await PhoneModels.reply(modelID: textModel, prompt: message) { answer = $0 }
                    status = "Tekstsvar klar."
                }
            }.frame(minHeight: 48).disabled(!textReady || !hasPrompt || task != nil)
            if !answer.isEmpty { Text(answer).textSelection(.enabled) }
        }
    }

    private var imageSection: some View {
        Section("Lokale billeder") {
            Picker("Billedmodel", selection: $imageModel) {
                Text("Stable Diffusion 1.5").tag("sd_v1.5_f16.ckpt")
                Text("FLUX.2 Klein 4B").tag("flux_2_klein_4b_q8p.ckpt")
            }.disabled(task != nil)
            Text(imageReady ? "Billedmodellen er fundet på telefonen." : "Billedmodellen skal hentes først.")
            Button("Download billedmodel") {
                let selected = imageModel
                run("Henter billedmodel…") {
                    _ = try await MediaGenerationEnvironment.default.ensure(selected)
                    status = "Billedmodel hentet."
                }
            }.frame(minHeight: 48).disabled(task != nil)
            Button("Importér LoRA fra Filer") { importLoRA = true }
                .frame(minHeight: 48).disabled(task != nil)
            if !loraName.isEmpty {
                Toggle("Brug importeret LoRA", isOn: $useLoRA).disabled(task != nil)
                Text("Vælg en LoRA, der passer til billedmodellen.").font(.caption)
            }
            Button("Generér billede på telefonen") { generateImage() }
                .frame(minHeight: 48).disabled(!imageReady || !hasPrompt || task != nil)
            if let imageURL, let preview = UIImage(contentsOfFile: imageURL.path) {
                Image(uiImage: preview).resizable().scaledToFit()
                    .accessibilityLabel("Lokalt genereret billede")
                ShareLink(item: imageURL) { Label("Del billede", systemImage: "square.and.arrow.up") }
            }
        }
    }

    private var hasPrompt: Bool { !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var textReady: Bool { textModel != "apple" && PhoneModels.installedDirectory(textModel) != nil }
    private var imageReady: Bool {
        (try? MediaGenerationEnvironment.default.inspectModel(imageModel, offline: true))?.isDownloaded == true
    }

    private func generateImage() {
        let selected = imageModel
        let message = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let lora = useLoRA ? loraName : ""
        run("Genererer billede på telefonen…") {
            var pipeline = try await MediaGenerationPipeline.fromPretrained(selected, backend: .local)
            pipeline.configuration.width = 512
            pipeline.configuration.height = 512
            if !lora.isEmpty {
                pipeline.configuration.loras = [.init(file: lora, weight: 1, mode: .base)]
            }
            let results = try await pipeline.generate(prompt: message)
            try Task.checkCancellation()
            guard let result = results.first else { throw PhoneModelError.emptyResponse }
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
            try result.write(to: destination, type: .png)
            if let imageURL { try? FileManager.default.removeItem(at: imageURL) }
            imageURL = destination
            status = "Billede klar."
        }
    }

    private func loadLoRA(_ source: URL) {
        guard source.pathExtension.lowercased() == "safetensors",
              let directory = MediaGenerationEnvironment.default.externalUrls.first else {
            status = "Vælg en LoRA-fil i .safetensors-format."
            return
        }
        let name = "fadedai-\(UUID().uuidString)_lora_f16.ckpt"
        let destination = directory.appendingPathComponent(name)
        run("Importerer LoRA…") {
            try await Task.detached(priority: .userInitiated) {
                let scoped = source.startAccessingSecurityScopedResource()
                defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                var importer = LoRAImporter(file: source)
                try importer.import(to: destination)
            }.value
            try Task.checkCancellation()
            if !loraName.isEmpty { try? FileManager.default.removeItem(at: directory.appendingPathComponent(loraName)) }
            loraName = name
            useLoRA = true
            status = "LoRA importeret."
        }
    }

    private func run(_ message: String, work: @escaping @MainActor () async throws -> Void) {
        guard enabled, task == nil else { return }
        status = message
        task = Task {
            defer { task = nil }
            do { try await work() }
            catch is CancellationError { status = "Stoppet." }
            catch { status = "Opgaven mislykkedes. Tjek model, ledig plads og hukommelse." }
        }
    }
}
