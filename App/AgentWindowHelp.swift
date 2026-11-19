import SwiftUI
import UIKit

enum AgentWindowIntent {
    static func matches(_ prompt: String) -> Bool {
        let text = prompt.lowercased()
        let patterns = [
            #"\b(?:se|kig|kikke|kigge|tjek|tjekke|vis|læs|læse|del)(?:\s+(?:lige|på|til|mig|hvad|der|står|er|sker)){0,6}\s+(?:min|mit|dette|det|den|et)\s+(?:pc[ -]?)?(?:skærm|vindue)\b"#,
            #"\b(?:vis|åbn|start)\s+skærmhjælp\b"#,
            #"\b(?:look at|check|read|see|inspect)\s+(?:my|this)\s+(?:screen|window)\b"#
        ]
        for pattern in patterns {
            guard let match = text.range(of: pattern, options: .regularExpression) else { continue }
            let preceding = String(text[..<match.lowerBound].suffix(36))
            if preceding.range(of: #"\b(?:ikke|aldrig|never|don't|do not|lad være med at)\s+(?:lige\s+)?$"#,
                               options: .regularExpression) == nil { return true }
        }
        return false
    }
}

private struct WindowChoice: Decodable, Identifiable {
    let id: String
    let title: String
}

private struct WindowObservation: Decodable {
    let title: String
    let summary: String
    let reading: String?
    let labels: [String]
    let approval: String?
    let jpeg: Data?
}

struct AgentWindowHelp: View {
    let api: LiveAPI?
    let botName: String
    let prompt: String
    var onResult: (String) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var windows: [WindowChoice] = []
    @State private var choice: WindowChoice?
    @State private var observation: WindowObservation?
    @State private var message: String?
    @State private var operation: Task<Void, Never>?
    @State private var busy = false
    @State private var confirmRestore = false
    @State private var approved = false
    @State private var followup = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let observation, let choice {
                        Text(observation.title).font(.headline)
                        if let api {
                            NavigationLink {
                                AgentWindowControl(api: api, token: choice.id, botName: botName,
                                                   initialGoal: prompt, onResult: onResult)
                            } label: { Label("Arbejd i dette PC-vindue", systemImage: "cursorarrow.click") }
                                .buttonStyle(FadedButtonStyle(kind: .primary))
                        }
                        Text(observation.summary)
                        if let data = observation.jpeg, let image = UIImage(data: data) {
                            Image(uiImage: image).resizable().scaledToFit()
                                .accessibilityLabel("Nyt billede af \(observation.title)")
                        }
                        if let reading = observation.reading { Text(reading) }
                        if !observation.labels.isEmpty {
                            Text("Tekst fra vinduet").font(.headline)
                            ForEach(Array(observation.labels.enumerated()), id: \.offset) { _, label in Text(verbatim: label) }
                        }
                        if observation.approval != nil && !approved {
                            FadedPrimaryButton("Gendan vinduet", icon: "macwindow") { confirmRestore = true }
                        }
                        TextField("Spørg om dette vindue", text: $followup, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                        if !followup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            FadedSecondaryButton("Spørg \(botName)", icon: "text.bubble") {
                                inspect(choice, question: followup)
                            }
                        }
                        FadedSecondaryButton("Tjek vinduet igen", icon: "arrow.clockwise") { inspect(choice) }
                        FadedSecondaryButton("Vælg et andet vindue", icon: "rectangle.on.rectangle") { refresh() }
                    } else if api == nil {
                        Text("Forbind din iPhone til FadedAI på PC’en for at bruge skærmhjælp.")
                    } else {
                        Text("Hvilket vindue må \(botName) se?").font(.headline)
                        Text("Tryk på et vindue for at dele ét øjebliksbillede. Det vises kun her og analyseres på din PC.")
                            .foregroundStyle(.secondary)
                        ForEach(windows) { window in
                            FadedSecondaryButton(window.title, icon: "macwindow") { inspect(window) }
                        }
                        FadedSecondaryButton("Hent vinduer fra PC’en", icon: "arrow.clockwise") { refresh() }
                    }
                    if busy { ProgressView("Arbejder på PC’en …") }
                    if let message { Text(message).accessibilityLabel(message) }
                }
                .disabled(busy)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("Skærmhjælp")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Luk") { dismiss() } } }
            .confirmationDialog("Gendan det valgte vindue på PC’en?", isPresented: $confirmRestore) {
                if let choice, let approval = observation?.approval {
                    Button("Ja, gendan vinduet") { restore(choice, approval: approval) }
                }
                Button("Annuller", role: .cancel) {}
            }
        }
        .privacySensitive()
        .onAppear { if api != nil { refresh() } }
        .onDisappear { clear() }
        .onChange(of: phase) { _, newPhase in
            if newPhase != .active {
                operation?.cancel()
                operation = nil
                busy = false
            }
        }
    }

    private func clear() {
        operation?.cancel()
        operation = nil
        windows = []
        observation = nil
        choice = nil
        message = nil
        approved = false
        followup = ""
        confirmRestore = false
        busy = false
    }

    private func run(_ action: @escaping @MainActor (LiveAPI) async throws -> Void) {
        guard let api, !busy else { return }
        busy = true
        message = nil
        operation = Task { @MainActor in
            defer { if !Task.isCancelled { busy = false } }
            do {
                try await action(api)
            } catch {
                guard !Task.isCancelled else { return }
                if case .http(404, _)? = error as? APIError {
                    message = "Opdatér FadedAI på PC’en for at bruge skærmhjælp."
                } else if case .http(409, let problem)? = error as? APIError {
                    message = problem?.message ?? "Vælg vinduet igen."
                } else {
                    message = (error as? APIError)?.title ?? "PC’en kunne ikke læse vinduet. Prøv igen."
                }
            }
        }
    }

    private func refresh() {
        choice = nil
        observation = nil
        windows = []
        followup = ""
        run { api in
            struct Response: Decodable { let windows: [WindowChoice] }
            let reply: Response = try await api.moduleJSON("window-help/windows")
            try Task.checkCancellation()
            windows = reply.windows
            if windows.isEmpty { message = "Åbn et vindue på din Windows-PC, og hent listen igen." }
        }
    }

    private func inspect(_ window: WindowChoice, question: String? = nil) {
        choice = window
        observation = nil
        approved = false
        run { api in
            let body = try JSONEncoder().encode(["token": window.id, "question": String((question ?? prompt).prefix(500))])
            let reply: WindowObservation = try await api.moduleJSON("window-help/inspect", upload: body, timeout: 65)
            try Task.checkCancellation()
            observation = reply
        }
    }

    private func restore(_ window: WindowChoice, approval: String) {
        run { api in
            struct Receipt: Decodable { let message: String }
            approved = true
            let body = try JSONEncoder().encode(["token": window.id, "approval": approval])
            let result: Receipt = try await api.moduleJSON("window-help/restore", upload: body)
            try Task.checkCancellation()
            message = result.message
        }
    }
}
