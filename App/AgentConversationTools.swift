import Foundation
import LocalAuthentication
import SwiftUI
import UIKit

@MainActor enum ChatScreenWake {
    private static var active = Set<UUID>()
    private static var userPreference = false

    static func setUserPreference(_ value: Bool) {
        userPreference = value
        update()
    }

    static func hold(_ id: UUID, whileReplying replying: Bool) {
        if replying { active.insert(id) }
        else { active.remove(id) }
        update()
    }

    private static func update() {
        UIApplication.shared.isIdleTimerDisabled = userPreference || !active.isEmpty
    }
}

extension AgentPhoneChat {
    func shouldCheckGmail(_ message: String) -> Bool {
        keepHistory && !web && nextDocument == nil && AgentGmailCheck.matches(message)
    }

    func startGmailCheck(_ message: String) {
        guard gmailCheck?.isChecking != true else { return }
        if handsFree { stopVoice() }
        composerFocused = false
        appleDictation.stop()
        if cleanDraft == message { draft = "" }
        notice = nil
        gmailCheck = .init(prompt: message, afterTurn: turns.last?.id)
    }

    func gmailCard(_ request: AgentGmailCheck.Request) -> some View {
        AgentGmailCheck(request: request, bot: bot, api: api).id(request.id)
    }
}

@MainActor struct AgentGmailCheck: View {
    @Observable @MainActor final class Request {
        let id = UUID()
        let prompt: String
        let afterTurn: UUID?
        private(set) var state: MailAppointmentState?
        private(set) var status = "Tjekker Gmail…"
        private(set) var isChecking = false
        private var started = false

        init(prompt: String, afterTurn: UUID?) {
            self.prompt = prompt
            self.afterTurn = afterTurn
        }

        func run(bot: VillageBot, api: LiveAPI?) async {
            guard !started else { return }
            started = true
            guard let api else {
                status = "Forbind FadedAI til PC’en for at tjekke Gmail."
                return
            }
            isChecking = true
            defer { isChecking = false }
            do {
                let initial = try await api.mailAppointments(bot.id)
                guard initial.enabled else {
                    status = initial.otherBot ? "En anden agent står for aftalesøgningen."
                        : "Slå aftalesøgning til for \(bot.name) i Gmail-aftaler."
                    return
                }
                _ = try await api.scanMailAppointments(bot.id)
                for _ in 0..<12 {
                    try await Task.sleep(for: .seconds(3))
                    let latest = try await api.mailAppointments(bot.id)
                    guard latest.enabled else {
                        status = "Aftalesøgningen er ikke længere slået til for \(bot.name)."
                        return
                    }
                    if let checked = latest.checked, checked > (initial.checked ?? 0) {
                        state = latest
                        status = latest.notice ?? (latest.appointments.isEmpty
                            ? "Ingen kommende aftaler i det seneste opslag." : "Seneste fund fra Gmail")
                        return
                    }
                }
                status = "Søgningen er sat i gang på PC’en. Se dens status i Gmail-aftaler."
            } catch is CancellationError {
                status = "Se status for aftalesøgningen i Gmail-aftaler."
            } catch {
                if case APIError.http(_, let problem) = error, let message = problem?.message { status = message }
                else { status = AppErrorPresentation(error).title }
            }
        }
    }

    let request: Request
    let bot: VillageBot
    let api: LiveAPI?
    @State private var showReview = false

    nonisolated static func matches(_ message: String) -> Bool {
        let words = message.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let pattern = #"^(?:har jeg (?:nye |kommende |nogle )*aftaler|(?:tjek|søg efter|find) (?:mine |efter |nye |kommende )*aftaler) (?:i|fra) (?:min )?gmail[?.!]*$"#
        return words.range(of: pattern, options: .regularExpression) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AgentChatBubble(user: true, title: "Dig", pc: false) {
                Text(request.prompt).textSelection(.enabled)
            }
            AgentChatBubble(user: false, title: "\(bot.name) · Gmail", pc: true) {
                if request.isChecking { ProgressView(request.status) }
                else { Text(request.status) }
                if let state = request.state, state.notice == nil {
                    ForEach(Array(state.appointments.prefix(5))) { appointment in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(appointment.title).font(.headline)
                            if let date = appointment.date {
                                Text(date.formatted(date: .abbreviated, time: .shortened)).font(.subheadline)
                            }
                            if !appointment.canApply {
                                Text(appointment.revisionStatus == "cancelled" ? "Aflyst" : "Flyttet").font(.caption)
                            }
                        }
                        .textSelection(.enabled)
                    }
                }
                if api != nil {
                    Button("Åbn Gmail-aftaler", systemImage: "calendar.badge.envelope") { showReview = true }
                        .frame(minHeight: 44)
                }
            }
        }
        .privacySensitive()
        .sheet(isPresented: $showReview) {
            if let api { AgentGmailReview(api: api, bot: bot) }
        }
    }
}

@MainActor private struct AgentGmailReview: View {
    let api: LiveAPI
    let bot: VillageBot
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            MailAppointmentsView(api: api, bot: bot)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Luk") { dismiss() } } }
        }
    }
}

struct AgentReplyCard: Codable, Sendable {
    let title: String
    let items: [String]

    static func decode(_ reply: String) -> Self? {
        let data = ModelJSON.payload(reply)
        guard data.count <= 8_000,
              let card = try? JSONDecoder().decode(Self.self, from: data),
              (1...120).contains(card.title.count), (1...8).contains(card.items.count),
              card.items.allSatisfy({ (1...450).contains($0.count) }) else { return nil }
        return card
    }

    var plainText: String { ([title] + items.map { "• " + $0 }).joined(separator: "\n") }
}

enum AgentLocalTool {
    struct Request: Decodable {
        let tool: String
        let input: String
    }

    static let instructions = """
        Du har to lokale værktøjer, calculator og date. Når et spørgsmål kræver dem,
        kan du først svare med kun JSON, f.eks. {"tool":"calculator","input":"859*0.17"}
        eller {"tool":"date","input":"14"} for dato om 14 dage, og 0 for dato og klokkeslæt nu.
        Brug et fortegn for dage før i dag. Brug ellers almindelig tekst.
        """

    static func answer(_ reply: String, now: Date = .now, calendar: Calendar = .current) -> String? {
        let data = ModelJSON.payload(reply)
        guard data.count <= 240,
              let request = try? JSONDecoder().decode(Request.self, from: data) else { return nil }
        switch request.tool {
        case "calculator":
            guard let value = calculate(request.input) else { return "Regnestykket kunne ikke beregnes." }
            return "Lommeregnerens resultat: " + value.formatted(.number.precision(.fractionLength(0...10)))
        case "date":
            guard let days = Int(request.input), (-3_650...3_650).contains(days),
                  let date = calendar.date(byAdding: .day, value: days, to: now) else { return "Datoen kunne ikke beregnes." }
            return "Dato og klokkeslæt på iPhone: " + date.formatted(date: .complete, time: days == 0 ? .shortened : .omitted)
        default:
            return nil
        }
    }

    static func calculate(_ raw: String) -> Double? {
        let normalized = raw.replacingOccurrences(of: ",", with: ".")
        guard (1...120).contains(normalized.utf8.count) else { return nil }
        var parser = Expression(chars: Array(normalized.filter { !$0.isWhitespace }))
        guard let result = parser.expression(), parser.index == parser.chars.count, result.isFinite else { return nil }
        return result
    }

    private struct Expression {
        let chars: [Character]
        var index = 0
        var next: Character? { index < chars.count ? chars[index] : nil }

        mutating func expression() -> Double? {
            guard var result = term() else { return nil }
            while let op = next, op == "+" || op == "-" {
                index += 1
                guard let value = term() else { return nil }
                result = op == "+" ? result + value : result - value
            }
            return result
        }

        mutating func term() -> Double? {
            guard var result = factor() else { return nil }
            while let op = next, op == "*" || op == "/" {
                index += 1
                guard let value = factor(), op != "/" || value != 0 else { return nil }
                result = op == "*" ? result * value : result / value
            }
            return result
        }

        mutating func factor() -> Double? {
            let sign = next == "-" ? -1.0 : 1.0
            if sign < 0 { index += 1 }
            let value: Double
            if next == "(" {
                index += 1
                guard let contained = expression(), next == ")" else { return nil }
                index += 1
                value = contained
            } else {
                let start = index
                while let char = next, char.isASCII && (char.isNumber || char == ".") { index += 1 }
                guard start < index, let number = Double(String(chars[start..<index])) else { return nil }
                value = number
            }
            if next == "%" { index += 1; return sign * value / 100 }
            return sign * value
        }
    }
}

struct AgentWebSources: Decodable, Sendable {
    struct Source: Codable, Sendable, Identifiable {
        let title: String
        let url: URL
        let readPage: Bool
        var id: URL { url }

        var isWeb: Bool {
            ["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.host != nil && url.user == nil && url.password == nil
        }
    }
    let context: String
    let sources: [Source]
}

@MainActor struct AgentPCToolsView: View {
    let api: LiveAPI
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    AgentPCImageView(api: api)
                } label: { Label("Lav billede", systemImage: "photo") }
                NavigationLink {
                    PCVideoGenerationView(api: api, initialPrompt: "")
                } label: { Label("Lav video", systemImage: "film") }
                NavigationLink {
                    BatchReviewView(api: api)
                } label: { Label("Kodeforslag", systemImage: "curlybraces") }
            }
            .navigationTitle("Agentens PC-værktøjer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Luk") { dismiss() } } }
        }
    }
}

@MainActor private struct AgentPCImageView: View {
    let api: LiveAPI
    @State private var prompt = ""
    @State private var image: UIImage?
    @State private var running: Task<Void, Never>?
    @State private var notice: String?
    private var description: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FadedSpacing.m) {
                FadedDetailText("Din beskrivelse sendes til den parrede PC, når du trykker Lav billede.")
                TextField("Beskriv billedet", text: $prompt, axis: .vertical)
                    .lineLimit(3...6)
                    .disabled(running != nil)
                FadedPrimaryButton("Lav billede", icon: "wand.and.stars", action: generate)
                    .disabled(running != nil || !(1...1_000).contains(description.count))
                if running != nil { ProgressView("PC’en genererer billedet…") }
                if let notice { FadedDetailText(notice) }
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                        .clipShape(.rect(cornerRadius: FadedRadius.medium))
                        .accessibilityLabel("Genereret billede")
                    Button("Slet billedvisning", systemImage: "trash", role: .destructive) {
                        self.image = nil
                    }
                    .frame(minHeight: 44)
                    .disabled(running != nil)
                }
            }
            .padding(FadedSpacing.edge)
            .frame(maxWidth: 580)
            .frame(maxWidth: .infinity)
        }
        .background { FadedBackground() }
        .navigationTitle("Lav billede på PC")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { running?.cancel() }
    }

    private func generate() {
        let input = description
        guard running == nil, (1...1_000).contains(input.count) else { return }
        notice = nil
        running = Task {
            defer { running = nil }
            do {
                let data = try await api.v2GenerateImage(prompt: input)
                try Task.checkCancellation()
                guard let generated = UIImage(data: data) else { throw APIError.malformed }
                image = generated
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                if case APIError.http(_, let problem) = error, let message = problem?.message { notice = message }
                else { notice = "Billedet kunne ikke laves. Tjek PC-forbindelsen og billedmodellen." }
            }
        }
    }
}
