// Læser tekst og genkender motiver i et valgt foto på telefonen.

import Foundation
import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import Vision

extension LumiChatImageRequest {
    // A single attachment can be either a question about a photo or an edit of it.
    static func requestedWithPhoto(_ text: String) -> Self? {
        if let image = parse(text) { return image }
        let danish = #"^(?:lumi[,! ]+)?(?:(?:kan|vil|kunne|gider) du (?:lige )?(?:ændre|redigere|fjerne|erstatte|udskifte|skifte|tilføje|gøre)|ændr|redigér|rediger|fjern|erstat|udskift|skift|tilføj|gør)\s+\S"#
        let english = #"^(?:please |(?:can|could|would) you )?(?:edit|replace|remove|add|change|turn|make(?!\s+(?:out|sense\b)))\s+\S"#
        let options: String.CompareOptions = [.regularExpression, .caseInsensitive]
        guard text.range(of: danish, options: options) != nil || text.range(of: english, options: options) != nil else { return nil }
        return Self(prompt: text, isSelfPortrait: false)
    }
}

struct LocalImageAnalysisView: View {
    let data: Data
    let onChooseNote: ((String) -> Void)?
    let api: LiveAPI?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.fadedPalette) private var palette
    @State private var attempt = 0
    @State private var state: AnalysisState = .loading
    @State private var prompt = ""
    @State private var pcModel: V2Models.Entry?
    @State private var pcNotice: String?
    @State private var pcLookupAttempt = 0
    @State private var analysis: Task<Void, Never>?
    @State private var source: String?
    @State private var answer = ""
    @State private var analysisNotice: String?

    init(data: Data, onChooseNote: ((String) -> Void)?, api: LiveAPI? = nil, initialPrompt: String = "") {
        self.data = data
        self.onChooseNote = onChooseNote
        self.api = api
        _prompt = State(initialValue: initialPrompt)
    }

    private enum AnalysisState {
        case loading
        case result(LocalImageText.Result)
        case failure(AppErrorPresentation)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FadedSpacing.section) {
                    ocrCard
                    modelCard
                }.padding(FadedSpacing.edge)
            }
            .background { FadedBackground() }
            .foregroundStyle(palette.text)
            .navigationTitle("Analysér billede")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Luk") { dismiss() } } }
        }
        .task(id: attempt) {
            state = .loading
            do {
                let result = try await LocalImageText.read(data)
                try Task.checkCancellation()
                state = .result(result)
            } catch is CancellationError {
                return
            } catch {
                AppDiagnostics.record(error)
                state = .failure(AppErrorPresentation(error, title: "Telefonen kunne ikke læse billedet."))
            }
        }
        .task(id: "\(api?.queueTargetID ?? ""):\(pcLookupAttempt)") { await findPCModel() }
        .onChange(of: api?.queueTargetID) { _, _ in
            if source == "PC" { analysis?.cancel() }
        }
        .onDisappear { analysis?.cancel() }
    }

    private var ocrCard: some View {
        FadedCard(accent: palette.green) {
            VStack(alignment: .leading, spacing: FadedSpacing.action) {
                FadedSectionHeader("Billedtekst på telefonen")
                switch state {
                case .loading:
                    ProgressView("Undersøger billedet…")
                case .result(let result):
                    if !result.labels.isEmpty {
                        FadedSectionHeader("Mulige motiver")
                        Text(result.labels.joined(separator: ", "))
                    }
                    if !result.text.isEmpty {
                        Text(result.text).textSelection(.enabled)
                        attachButton("Vedhæft tekstuddrag", text: result.text)
                    } else if result.labels.isEmpty {
                        Text("Jeg fandt ingen tydelige motiver eller læsbar tekst. Prøv et skarpere billede.")
                    }
                case .failure(let failure):
                    Text(failure.title)
                    FadedSecondaryButton(failure.fixAction.title, icon: "arrow.clockwise") { attempt += 1 }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var localVisionModel: ModelRouter.Selection? {
        let ids = PhoneModels.readyVisionModelIDs
        let candidates = ids.map { id in
            ModelRouter.candidate(id: id, name: PhoneModels.catalog.first { $0.id == id }?.name ?? "Telefonmodel",
                                  location: .phone, ready: true, capabilities: PhoneModels.routingCapabilities(for: id))
        }
        return ModelRouter.choose(text: prompt, hasImage: true, candidates: candidates)
    }

    private var modelCard: some View {
        let phoneModel = localVisionModel
        let promptTooLong = prompt.unicodeScalars.count > 2_000
        return FadedCard {
            VStack(alignment: .leading, spacing: FadedSpacing.action) {
                FadedSectionHeader("Spørg om billedet")
                if phoneModel != nil || pcModel != nil {
                    TextField("Spørgsmål til billedet (valgfrit)", text: $prompt, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(1...3).frame(minHeight: 44)
                        .disabled(analysis != nil)
                    if promptTooLong { FadedDetailText("Skriv højst 2.000 tegn.") }
                }
                if let phoneModel {
                    FadedPrimaryButton("Analysér på telefonen", icon: "iphone") { analyzeOnPhone(phoneModel.candidate) }
                        .disabled(analysis != nil || promptTooLong)
                    FadedDetailText("Auto-valgt: \(phoneModel.candidate.name) – \(phoneModel.reason)")
                } else {
                    FadedDetailText("Telefonen har ingen klar AI-model til billeder. Billedtekst virker stadig.")
                }
                if let pcModel {
                    FadedSecondaryButton("Analysér på PC", icon: "desktopcomputer") { analyzeOnPC(pcModel) }
                        .disabled(analysis != nil || promptTooLong)
                    FadedDetailText("\(pcModel.label) · Billedet sendes til din PC.")
                } else if let pcNotice {
                    FadedDetailText(pcNotice)
                    FadedSecondaryButton("Tjek PC igen", icon: "arrow.clockwise") { pcLookupAttempt += 1 }
                }
                if analysis != nil {
                    ProgressView(source == "PC" ? "PC’en analyserer…" : "Telefonen analyserer…")
                    FadedSecondaryButton("Stop", icon: "stop.fill") { analysis?.cancel() }
                }
                if let analysisNotice { FadedDetailText(analysisNotice) }
                if !answer.isEmpty, let source {
                    FadedSectionHeader("Svar fra \(source)")
                    Text(answer).textSelection(.enabled)
                    attachButton("Vedhæft svaruddrag", text: answer)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func attachButton(_ label: String, text: String) -> some View {
        if let onChooseNote {
            FadedSecondaryButton(label, icon: "note.text") {
                onChooseNote(String(text.unicodeScalars.prefix(600)))
                dismiss()
            }
        }
    }

    private func findPCModel() async {
        pcModel = nil
        pcNotice = nil
        guard let api else { return }
        do {
            let catalog = try await api.v2Models()
            try Task.checkCancellation()
            pcModel = PCModelSelection.preferredVision(in: catalog)
            if pcModel == nil { pcNotice = "PC’en meldte ingen installeret model til billedanalyse." }
        } catch {
            guard !Task.isCancelled else { return }
            AppDiagnostics.record(error)
            pcNotice = "PC’ens billedmodel kunne ikke kontrolleres."
        }
    }

    private func analyzeOnPhone(_ model: ModelRouter.Candidate) {
        runModel(source: "Telefon") { prompt in
            let image = try LocalImageText.checkedImage(data)
            return try await PhoneModels.analyzeImage(modelID: model.id, image: image, prompt: prompt)
        }
    }

    private func analyzeOnPC(_ model: V2Models.Entry) {
        guard let api, pcModel?.id == model.id else { return }
        runModel(source: "PC") { prompt in
            // The picker supplies bounded JPEG data. Verify dimensions before any request.
            _ = try LocalImageText.checkedImage(data)
            let buffer = PCVisionText()
            try await api.v2DescribeImage(data, prompt: prompt, model: model) { event in
                if event.type == .text { await buffer.append(event.content) }
            }
            return api.redactChat(buffer.text, complete: buffer.hasSpace)
        }
    }

    private func runModel(source: String, work: @escaping @MainActor (String) async throws -> String) {
        let question = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard analysis == nil, question.unicodeScalars.count <= 2_000 else { return }
        let request = question.isEmpty ? "Beskriv billedet kort på dansk." : question
        self.source = source
        answer = ""
        analysisNotice = nil
        analysis = Task { @MainActor in
            defer { analysis = nil }
            do {
                let response = try await work(request)
                try Task.checkCancellation()
                answer = String(response.unicodeScalars.prefix(12_000)).trimmingCharacters(in: .whitespacesAndNewlines)
                if answer.isEmpty { analysisNotice = "Modellen gav intet svar." }
            } catch {
                if Task.isCancelled || error is CancellationError {
                    analysisNotice = "Analysen blev stoppet."
                } else {
                    AppDiagnostics.record(error)
                    let device = source == "PC" ? "PC’en" : "Telefonen"
                    analysisNotice = pcBusyMessage(error) ?? "\(device) kunne ikke analysere billedet. Prøv igen."
                }
            }
        }
    }
}

@MainActor private final class PCVisionText {
    private(set) var text = ""
    private var remaining = 12_000
    var hasSpace: Bool { remaining > 0 }

    func append(_ delta: String) {
        let part = delta.unicodeScalars.prefix(remaining)
        text += String(part)
        remaining -= part.count
    }
}

private enum LocalImageText {
    private enum Failure: Error { case unsupportedImage }

    struct Result: Sendable {
        let text: String
        let labels: [String]
    }

    static func checkedImage(_ data: Data) throws -> CGImage {
        guard !data.isEmpty, data.count <= 2_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = metadata[kCGImagePropertyPixelWidth as String] as? Int,
              let height = metadata[kCGImagePropertyPixelHeight as String] as? Int,
              (1...2_048).contains(width), (1...2_048).contains(height), width * height <= 2_000_000,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure.unsupportedImage }
        return image
    }

    static func read(_ data: Data) async throws -> Result {
        let work = Task.detached(priority: .userInitiated) {
            guard !data.isEmpty, data.count <= 2_000_000 else { throw Failure.unsupportedImage }
            try Task.checkCancellation()
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .accurate
            textRequest.automaticallyDetectsLanguage = true
            let imageRequest = VNClassifyImageRequest()
            try VNImageRequestHandler(data: data, options: [:]).perform([textRequest, imageRequest])
            try Task.checkCancellation()
            let text = textRequest.results?.prefix(80).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n") ?? ""
            let labels = imageRequest.results?.filter { $0.confidence >= 0.4 }.prefix(3).map(\.identifier) ?? []
            return Result(text: String(text.unicodeScalars.prefix(4_000)), labels: labels)
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }
}

struct ChatPhotoPreview: View {
    let data: Data

    var body: some View {
        if let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFit()
                .frame(maxWidth: 230, maxHeight: 190)
                .clipShape(.rect(cornerRadius: 12))
                .accessibilityLabel("Vedhæftet foto")
        }
    }
}

struct ChatPhotoPicker: View {
    @Binding var photo: Data?
    @Binding var loading: Bool
    let onError: (String) -> Void
    var addTitle = "Vedhæft foto"
    var replaceTitle = "Skift foto"
    @State private var selection: PhotosPickerItem?

    var body: some View {
        HStack(spacing: 8) {
            if let photo { ChatPhotoPreview(data: photo).frame(maxWidth: 64, maxHeight: 54) }
            PhotosPicker(selection: $selection, matching: .images) {
                Label(photo == nil ? addTitle : replaceTitle, systemImage: "photo")
                    .frame(minHeight: 44)
            }
            if photo != nil || selection != nil {
                Button("Fjern foto", systemImage: "xmark.circle") {
                    selection = nil
                    photo = nil
                    loading = false
                }
                    .labelStyle(.iconOnly).frame(width: 44, height: 44)
            }
            if selection != nil { ProgressView() }
        }
        .font(.subheadline)
        .task(id: selection) {
            guard let item = selection else { return }
            loading = true
            defer {
                if selection == item {
                    loading = false
                    selection = nil
                }
            }
            do {
                guard let input = try await item.loadTransferable(type: StudioPhotoInput.self),
                      !input.data.isEmpty else { throw APIError.input }
                try Task.checkCancellation()
                guard selection == item else { return }
                photo = input.data
            } catch {
                if !Task.isCancelled, selection == item { onError("Fotoet kunne ikke åbnes. Prøv et andet foto.") }
            }
        }
    }
}

@MainActor enum AgentChatPhotoReply {
    struct Result {
        let text: String
        let source: String
        let model: String
    }

    static func answer(_ data: Data, question: String, agent: String, language: String, pc: LiveAPI?) async throws -> Result {
        let image = try LocalImageText.checkedImage(data)
        let instruction = language == "en-US"
            ? "You are \(agent). Answer in English and distinguish what is visible from guesses."
            : "Du er \(agent). Svar på dansk og skeln mellem det, du ser, og hvad du gætter."
        let prompt = instruction + "\n" + question
        if let pc {
            let catalog = try await pc.v2Models()
            if let model = PCModelSelection.preferredVision(in: catalog) {
                let buffer = PCVisionText()
                try await pc.v2DescribeImage(data, prompt: prompt, model: model) { event in
                    if event.type == .text { await buffer.append(event.content) }
                }
                let text = pc.redactChat(buffer.text, complete: buffer.hasSpace)
                return try result(text, source: "PC", model: model.label)
            }
        }
        if let id = PhoneModels.readyVisionModelIDs.first {
            let text = try await PhoneModels.analyzeImage(modelID: id, image: image, prompt: prompt)
            return try result(text, source: "iPhone", model: PhoneModels.textModelName(id))
        }
        let local = try await LocalImageText.read(data)
        let values = [local.text.isEmpty ? nil : "Tekst på billedet: " + local.text,
                      local.labels.isEmpty ? nil : "Mulige motiver: " + local.labels.joined(separator: ", ")]
            .compactMap { $0 }
        let detail = values.isEmpty ? "Jeg fandt ingen tydelig tekst eller genkendelige motiver." : values.joined(separator: "\n")
        return Result(text: detail + "\n\nAktivér en model til billedanalyse for at stille spørgsmål om fotoet.",
                      source: "iPhone", model: "Billedtekst")
    }

    private static func result(_ text: String, source: String, model: String) throws -> Result {
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { throw PhoneModelError.emptyResponse }
        return Result(text: reply, source: source, model: model)
    }
}
