import SwiftUI

@MainActor struct AgentMailboxSetup: View {
    let api: LiveAPI
    let bot: VillageBot
    let state: BotMailboxState
    let onChange: (BotMailboxState) -> Void

    private enum Operation: Equatable { case enroll, verify, resend, create }
    @State private var operation: Operation?
    @State private var email = ""
    @State private var code = ""
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if state.verificationRequired == true {
                Text("Indtast de seks cifre, som AgentMail har sendt til din e-mail.")
                TextField("Engangskode", text: $code)
                    .keyboardType(.numberPad).textContentType(.oneTimeCode)
                Button("Bekræft koden") { operation = .verify }
                    .disabled(code.utf8.count != 6 || !code.utf8.allSatisfy { (48...57).contains($0) })
                Button("Send en ny kode") { operation = .resend }
            } else if state.verificationElsewhere == true {
                FadedDetailText("Bekræft koden hos den agent, hvor du startede opsætningen. Derefter kan du oprette denne postkasse.")
            } else if state.configured {
                Button("Opret postkasse til " + bot.name, systemImage: "envelope.badge.person.crop") {
                    operation = .create
                }
            } else {
                FadedDetailText("AgentMail giver \(bot.name) en selvstændig adresse og indbakke. Indtast din e-mail for at modtage en engangskode til opsætningen.")
                TextField("Din e-mail til bekræftelse", text: $email)
                    .keyboardType(.emailAddress).textContentType(.emailAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Send bekræftelseskode til mig") { operation = .enroll }
                    .disabled(!email.contains("@"))
            }
            if operation != nil { ProgressView() }
            if let notice { Text(notice).font(.callout) }
        }
        .disabled(operation != nil)
        .task(id: operation) {
            guard let requested = operation else { return }
            notice = nil
            defer { if !Task.isCancelled { operation = nil } }
            do {
                let updated: BotMailboxState
                switch requested {
                case .enroll:
                    updated = try await api.enrollAgentMail(bot.id, email: email.trimmingCharacters(in: .whitespacesAndNewlines))
                case .verify:
                    updated = try await api.verifyAgentMail(bot.id, code: code)
                case .resend:
                    updated = try await api.resendAgentMailCode(bot.id)
                case .create:
                    updated = try await api.botMailbox(bot.id, createFor: bot.name)
                }
                try Task.checkCancellation()
                if requested == .enroll { email = "" }
                if requested == .verify { code = "" }
                if requested == .resend { notice = "Der er sendt en ny kode." }
                onChange(updated)
            } catch {
                if !Task.isCancelled {
                    if case APIError.http(_, let problem) = error, let detail = problem?.message, !detail.isEmpty {
                        notice = detail
                    } else {
                        notice = AppErrorPresentation(error).title
                    }
                }
            }
        }
    }
}
