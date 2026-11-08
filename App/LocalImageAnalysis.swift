// Læser tekst og genkender motiver i et valgt foto på telefonen.

import Foundation
import SwiftUI
import Vision

struct LocalImageAnalysisView: View {
    let data: Data
    let onChooseNote: ((String) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.fadedPalette) private var palette
    @State private var attempt = 0
    @State private var state: AnalysisState = .loading

    private enum AnalysisState {
        case loading
        case result(LocalImageText.Result)
        case failure(AppErrorPresentation)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                FadedCard(accent: palette.green) {
                    VStack(alignment: .leading, spacing: FadedSpacing.action) {
                        Text("Billedet analyseres på telefonen.").foregroundStyle(palette.secondary)
                        switch state {
                        case .loading:
                            ProgressView("Undersøger billedet…")
                        case .result(let result):
                            if !result.labels.isEmpty {
                                FadedSectionHeader("Mulige motiver")
                                Text(result.labels.joined(separator: ", "))
                            }
                            if !result.text.isEmpty {
                                FadedSectionHeader("Tekst i billedet")
                                Text(result.text).textSelection(.enabled)
                                if let onChooseNote {
                                    FadedSecondaryButton("Vedhæft tekstuddrag", icon: "note.text") {
                                        onChooseNote(String(result.text.unicodeScalars.prefix(600)))
                                        dismiss()
                                    }
                                }
                            } else if result.labels.isEmpty {
                                Text("Jeg fandt ingen tydelige motiver eller læsbar tekst. Prøv et skarpere billede.")
                            }
                        case .failure(let failure):
                            Text(failure.title)
                            FadedSecondaryButton(failure.fixAction.title, icon: "arrow.clockwise") { attempt += 1 }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(FadedSpacing.edge)
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
    }
}

private enum LocalImageText {
    private enum Failure: Error { case unsupportedImage }

    struct Result: Sendable {
        let text: String
        let labels: [String]
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
