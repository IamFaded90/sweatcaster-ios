// Drafts a bot-owned workflow on the phone for the user to edit and save.

import Foundation
import SwiftUI

@MainActor struct TeamTeachTask: View {
    let review: (TeamBotNotebookStore.Skill) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.fadedPalette) private var palette
    @Environment(\.scenePhase) private var phase
    @AppStorage(AppStorageKeys.phoneModel) private var model = "apple"
    @State private var description = ""
    @State private var status: String?
    @State private var task: Task<Void, Never>?

    private struct Draft: Decodable {
        let title: String
        let steps: [String]
    }

    private var goal: String { description.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var modelID: String { PhoneModels.effectiveModelID(model) }
    private var ready: Bool { PhoneModels.isReady(modelID) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FadedSpacing.section) {
                    Text("Fortæl botten, hvordan du vil have en opgave løst. Du gennemgår trinnene og vælger selv, om de skal gemmes.")
                        .font(.subheadline).foregroundStyle(palette.secondary)
                    TextField("Beskriv opgaven og dine trin", text: $description, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(4...8).frame(minHeight: 44)
                        .disabled(task != nil)
                    if let status { Text(status).font(.footnote).accessibilityAddTraits(.updatesFrequently) }
                    if !ready { Text("Vælg en klar telefonmodel under Lokale modeller.").font(.footnote) }
                    if goal.unicodeScalars.count > 2_000 { Text("Brug højst 2.000 tegn.").font(.footnote) }
                    if let task {
                        FadedPrimaryButton("Stop", icon: "stop.fill") { task.cancel() }
                    } else {
                        FadedPrimaryButton("Lav udkast på telefonen", icon: "list.number") { create() }
                            .disabled(!ready || !(1...2_000).contains(goal.unicodeScalars.count))
                    }
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(FadedSpacing.edge).frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background { FadedBackground() }
            .foregroundStyle(palette.text)
            .navigationTitle("Lær botten en opgave")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Luk") { dismiss() } }
            .onDisappear { task?.cancel() }
            .onChange(of: phase) { _, next in if next == .background { task?.cancel() } }
        }
    }

    private func create() {
        let input = goal
        let activeModel = modelID
        guard task == nil, ready, (1...2_000).contains(input.unicodeScalars.count) else { return }
        status = "Telefonen skriver et udkast…"
        task = Task {
            defer { task = nil }
            do {
                var response = ""
                try await PhoneModels.reply(modelID: activeModel, prompt: input, instructions: """
                    Gør brugerens forklaring til en kort arbejdsgang på brugerens sprog.
                    Returnér kun et gyldigt JSON-objekt som {"title":"Kort titel","steps":["Trin 1","Trin 2"]}.
                    Skriv højst seks konkrete trin. Bevar brugerens rækkefølge og begrænsninger.
                    """) { response = $0 }
                try Task.checkCancellation()
                let draft = try JSONDecoder().decode(Draft.self, from: ModelJSON.payload(response))
                let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let steps = draft.steps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard (1...80).contains(title.unicodeScalars.count), !title.contains("\0"),
                      (1...12).contains(steps.count),
                      steps.allSatisfy({ (1...500).contains($0.unicodeScalars.count) && !$0.contains("\0") }) else {
                    throw TeamBotNotebookStore.Failure.invalid
                }
                review(.init(id: UUID(), title: title, steps: steps, sop: nil))
                dismiss()
            } catch {
                if Task.isCancelled || error is CancellationError { status = "Udkastet blev stoppet." }
                else {
                    AppDiagnostics.record(error)
                    status = "Telefonen kunne ikke lave et brugbart udkast. Forkort beskrivelsen, eller opret færdigheden manuelt."
                }
            }
        }
    }
}
