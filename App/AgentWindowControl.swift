import SwiftUI
import UIKit

@MainActor struct AgentWindowControl: View {
    let api: LiveAPI
    let token: String
    let botName: String
    var initialGoal = ""
    var onResult: (String) -> Void = { _ in }

    struct Control: Decodable, Identifiable {
        let id: String
        let role: String
        let name: String
    }
    struct Observation: Decodable {
        let title: String
        let jpeg: Data?
        let labels: [String]
        let controls: [Control]
    }
    struct Step: Decodable {
        let type: String
        let title: String
        let message: String?
        let evidence: String?
    }
    struct Reply: Decodable {
        let job: String
        let observation: Observation?
        let message: String?
        let state: String?
        let running: Bool?
        let proposal: String?
        let step: Step?
        let count: Int?
        let goal: String?
    }

    @State private var goal = ""
    @State private var text = ""
    @State private var job: String?
    @State private var result: Reply?
    @State private var busy = false
    @State private var working = false
    @State private var stopped = false
    @State private var message: String?
    @State private var request: Task<Void, Never>?
    @State private var polling: Task<Void, Never>?
    @State private var directTouch = false
    @State private var lastReceipt: String?
    @Environment(\.scenePhase) private var phase
    @Environment(\.fadedPalette) private var palette

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let observation = result?.observation {
                    Text(observation.title).font(.headline)
                    if let data = observation.jpeg, let image = UIImage(data: data) {
                        GeometryReader { geometry in
                            Image(uiImage: image).resizable().scaledToFit()
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .contentShape(Rectangle())
                                .gesture(SpatialTapGesture().onEnded { value in
                                    guard directTouch, !busy, !working, !stopped else { return }
                                    input(.click(x: Double(value.location.x / geometry.size.width),
                                                 y: Double(value.location.y / geometry.size.height)))
                                })
                        }
                        .aspectRatio(image.size.width / image.size.height, contentMode: .fit)
                        .accessibilityLabel("Aktuelt PC-vindue")
                    }
                    if let step = result?.step {
                        Text(step.title).font(.subheadline.bold())
                        if let evidence = step.evidence, !evidence.isEmpty {
                            Text("Set i vinduet · " + evidence).font(.footnote).foregroundStyle(palette.secondary)
                        }
                    }
                    if let count = result?.count { Text("Udførte trin · \(count)").font(.caption) }
                    if working { ProgressView(botName + " arbejder på PC’en…") }
                    if let message = message ?? result?.message { Text(message).font(.callout) }
                    if !stopped {
                        taskControls
                        DisclosureGroup("Styr vinduet selv") {
                            directControls(observation)
                        }.disabled(working || busy)
                    } else {
                        FadedSecondaryButton("Åbn en ny PC-opgave", icon: "arrow.clockwise") { connect() }
                    }
                } else if busy {
                    ProgressView("Henter PC-vinduet…")
                } else {
                    if let message { Text(message) }
                    FadedSecondaryButton("Prøv igen", icon: "arrow.clockwise") { connect() }
                }
            }.padding(FadedSpacing.edge)
        }
        .background { FadedBackground() }
        .navigationTitle("Arbejd på PC’en")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Stop", systemImage: "stop.fill") { stop() }.disabled(job == nil || stopped)
            }
        }
        .task { goal = initialGoal; connect() }
        .onChange(of: phase) { _, next in
            if next == .active, job != nil { startPolling() }
            else { polling?.cancel() }
        }
        .onDisappear { request?.cancel(); polling?.cancel() }
        .privacySensitive()
    }

    private var taskControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Hvad skal \(botName) gøre i vinduet?", text: $goal, axis: .vertical)
                .lineLimit(2...5).padding(12).fadedGlassSurface()
                .disabled(working || busy)
            FadedPrimaryButton("Udfør opgaven", icon: "cursorarrow.click") {
                call("run", data: ["job": job ?? "", "goal": goal]) { reply in
                    working = reply.running == true
                    startPolling()
                }
            }.disabled(busy || working || goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || goal.count > 1000)
            FadedSecondaryButton("Vis næste trin først", icon: "list.bullet.rectangle") {
                call("plan", data: ["job": job ?? "", "goal": goal]) { _ in }
            }.disabled(busy || working || goal.isEmpty || goal.count > 1000)
            if let proposal = result?.proposal, let step = result?.step, !["done", "ask"].contains(step.type) {
                FadedSecondaryButton("Udfør dette trin", icon: "play.fill") {
                    call("step", data: ["job": job ?? "", "proposal": proposal]) { _ in }
                }.disabled(busy || working)
            }
            Text("Agenten kontrollerer vinduet efter hvert trin. Du kan følge med her og trykke Stop.")
                .font(.footnote).foregroundStyle(palette.secondary)
        }
    }

    private func directControls(_ observation: Observation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Tryk på billedet for at klikke", isOn: $directTouch)
            HStack {
                Button("Rul op") { input(.scroll(2)) }
                Button("Rul ned") { input(.scroll(-2)) }
                Button("Enter") { input(.key("enter")) }
                Button("Tab") { input(.key("tab")) }
            }.buttonStyle(.bordered)
            TextField("Skriv i det aktive felt", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
            Button("Skriv på PC’en", systemImage: "keyboard") { input(.type(text)) }
                .disabled(text.isEmpty || text.count > 1000)
            ForEach(observation.controls.prefix(35)) { control in
                if !control.name.isEmpty {
                    if control.role == "Edit" || control.role == "ComboBox" {
                        Button("Skriv i " + control.name) { input(.type(text, target: control.id)) }
                            .disabled(text.isEmpty || text.count > 1000)
                    } else {
                        Button(control.name) { input(.target(control.id)) }
                    }
                }
            }
            Button("Hent nyt billede", systemImage: "arrow.clockwise") { update() }
        }.padding(.vertical, 8)
    }

    private func connect() {
        guard !busy else { return }
        stopped = false
        call("session", data: ["token": token, "goal": goal]) { reply in
            job = reply.job
            working = reply.running == true
            if working, let currentGoal = reply.goal { goal = currentGoal }
            if working { startPolling() }
        }
    }

    private func update() {
        guard let job else { return }
        call("refresh", data: ["job": job]) { _ in }
    }

    private func input(_ action: Input) {
        guard let job else { return }
        call("input", data: Direct(job: job, action: action)) { _ in text = "" }
    }

    private func call<T: Encodable>(_ path: String, data: T, complete: @escaping (Reply) -> Void) {
        guard !busy else { return }
        busy = true
        message = nil
        request = Task {
            defer { busy = false }
            do {
                let body = try JSONEncoder().encode(data)
                let reply: Reply = try await api.moduleJSON("window-help/" + path, upload: body, timeout: 125)
                try Task.checkCancellation()
                result = reply
                if path != "session" { emitReceipt(reply) }
                complete(reply)
            } catch is CancellationError { return }
            catch { message = AgentPCFeedback.message(error, fallback: "PC’en kunne ikke udføre trinnet.") }
        }
    }

    private func startPolling() {
        polling?.cancel()
        guard let job else { return }
        polling = Task {
            repeat {
                do {
                    let reply: Reply = try await api.moduleJSON("window-help/jobs/" + job, timeout: 8)
                    try Task.checkCancellation()
                    result = reply
                    emitReceipt(reply)
                    working = reply.running == true
                    stopped = reply.state == "stopped"
                    if !working { return }
                    try await Task.sleep(for: .seconds(2))
                } catch is CancellationError { return }
                catch { message = "Forbindelsen blev afbrudt. Opgaven kan stadig køre på PC’en."; return }
            } while !Task.isCancelled
        }
    }

    private func stop() {
        guard let job else { return }
        request?.cancel()
        polling?.cancel()
        busy = false
        Task {
            do {
                let body = try JSONEncoder().encode(["job": job])
                let reply: Reply = try await api.moduleJSON("window-help/stop", upload: body, timeout: 10)
                result = reply; working = false; stopped = true
                emitReceipt(reply)
            } catch { message = "PC’en har ikke bekræftet Stop. Kontrollér forbindelsen, og prøv igen." }
        }
    }

    private func emitReceipt(_ reply: Reply) {
        guard let state = reply.state, ["completed", "needsInput", "stopped", "failed"].contains(state) else { return }
        let identifier = reply.job + state + (reply.message ?? "") + String(reply.count ?? 0)
        guard identifier != lastReceipt else { return }
        lastReceipt = identifier
        let status: String
        switch state {
        case "completed": status = "PC-opgaven er udført og kontrolleret."
        case "needsInput": status = "PC-opgaven afventer dig."
        case "stopped": status = "Stop er registreret på PC’en."
        default: status = "PC-opgaven blev afbrudt."
        }
        var receipt = status
        if let actualGoal = reply.goal, !actualGoal.isEmpty { receipt += "\nOpgaven var “" + String(actualGoal.prefix(240)) + "”." }
        if let message = reply.message, !message.isEmpty { receipt += "\n" + message }
        if state == "completed", let evidence = reply.step?.evidence, !evidence.isEmpty {
            receipt += "\nKontrollen i vinduet viste “" + evidence + "”."
        }
        onResult(receipt)
    }

    private struct Direct: Encodable { let job: String; let action: Input }
    private struct Input: Encodable {
        let type: String
        var target: String? = nil
        var text: String? = nil
        var key: String? = nil
        var x: Double? = nil
        var y: Double? = nil
        var amount: Int? = nil
        static func click(x: Double, y: Double) -> Self { .init(type: "click", x: x, y: y) }
        static func target(_ id: String) -> Self { .init(type: "click", target: id) }
        static func scroll(_ amount: Int) -> Self { .init(type: "scroll", amount: amount) }
        static func key(_ key: String) -> Self { .init(type: "key", key: key) }
        static func type(_ text: String, target: String? = nil) -> Self { .init(type: "type", target: target, text: text) }
    }
}

enum AgentPCFeedback {
    static func message(_ error: Error, fallback: String) -> String {
        if case .http(_, let problem)? = error as? APIError, let problem { return problem.message }
        return (error as? APIError)?.title ?? fallback
    }
}
