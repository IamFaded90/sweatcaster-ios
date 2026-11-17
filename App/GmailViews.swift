import Foundation
import LocalAuthentication
import SwiftUI
import UIKit

@MainActor struct GmailDraftView: View {
    let api: LiveAPI
    @Environment(\.dismiss) private var dismiss
    @State private var recipient = ""
    @State private var subject = ""
    @State private var message: String
    @State private var confirmation = false
    @State private var sending = false
    @State private var sent = false
    @State private var notice: String?
    @State private var identifier = UUID()

    init(api: LiveAPI, draft: String = "") {
        self.api = api
        _message = State(initialValue: String(draft.prefix(8_000)))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FadedSpacing.m) {
                    FadedCard(accent: FadedBrand.pc) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Fra din Gmail").font(.headline)
                            TextField("Til", text: $recipient)
                                .textContentType(.emailAddress).keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            Divider()
                            TextField("Emne", text: $subject)
                            Divider()
                            Text("Besked").font(.caption).foregroundStyle(.secondary)
                            TextEditor(text: $message)
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 160)
                                .accessibilityLabel("Besked")
                        }
                        .disabled(sending || sent)
                    }
                    if let notice { FadedDetailText(notice) }
                    if sending { ProgressView("Sender via Gmail…") }
                    if !sent {
                        FadedPrimaryButton("Gennemse og send", icon: "paperplane") { confirmation = true }
                            .disabled(sending || !valid)
                    }
                }
                .padding(FadedSpacing.edge).frame(maxWidth: 640).frame(maxWidth: .infinity)
            }
            .background { FadedBackground() }
            .navigationTitle("Gmail-kladde")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(sent ? "Færdig" : "Luk") { dismiss() }.disabled(sending) }
            }
            .confirmationDialog("Send fra din Gmail?", isPresented: $confirmation, titleVisibility: .visible) {
                Button("Bekræft og send") { Task { await send() } }
                Button("Behold kladden", role: .cancel) {}
            } message: {
                Text("Til \(recipient)\nEmne: \(subject)")
            }
        }
        .interactiveDismissDisabled(sending)
        .privacySensitive()
    }

    private var valid: Bool {
        recipient.contains("@") && !recipient.contains(",") && !recipient.contains(";") &&
            (1...200).contains(subject.trimmingCharacters(in: .whitespacesAndNewlines).count) &&
            (1...8_000).contains(message.trimmingCharacters(in: .whitespacesAndNewlines).count)
    }

    private func send() async {
        guard !sending, !sent, valid else { return }
        sending = true
        defer { sending = false }
        let context = LAContext()
        defer { context.invalidate() }
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                   localizedReason: "Godkend afsendelsen fra din Gmail.") else { return }
        } catch {
            notice = "Afsendelsen blev afbrudt."
            return
        }
        do {
            struct Receipt: Decodable { let sent: Bool }
            let request = ["id": identifier.uuidString, "recipient": recipient.trimmingCharacters(in: .whitespacesAndNewlines),
                           "subject": subject, "body": message]
            let receipt: Receipt = try await api.moduleJSON("composio/gmail/send", upload: JSONEncoder().encode(request), timeout: 100)
            guard receipt.sent else { throw APIError.malformed }
            sent = true
            notice = "Mailen er sendt."
        } catch {
            if case APIError.http(_, let error) = error, let message = error?.message { notice = message }
            else { notice = "Kunne ikke bekræfte afsendelsen. Tjek Sendt i Gmail før et nyt forsøg." }
        }
    }
}

@MainActor struct GmailReadView: View {
    let api: LiveAPI
    let onUse: ((String) -> Bool)?
    @State private var query = ""
    @State private var messages: [BotMailMessages.Message] = []
    @State private var selected: BotMailMessages.Message?
    @State private var preview: String?
    @State private var previewIssue: String?
    @State private var notice: String?
    @State private var loading = false
    @State private var draft = false
    @State private var folder = MailFolder.inbox
    @State private var refreshID = UUID()
    @State private var activeSearch: UUID?

    private enum MailFolder: String, CaseIterable, Identifiable {
        case inbox = "Indbakke", unread = "Ulæst", sent = "Sendt"
        var id: Self { self }
        var query: String {
            switch self {
            case .inbox: "in:inbox"
            case .unread: "in:inbox is:unread"
            case .sent: "in:sent"
            }
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: FadedSpacing.s) {
                FadedCard(accent: FadedBrand.pc) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            ComposioLogo(slug: "gmail")
                            Text("Din Gmail").font(.headline)
                        }
                        Picker("Postkasse", selection: $folder) {
                            ForEach(MailFolder.allCases) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented)
                        HStack {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("Søg i \(folder.rawValue.lowercased())", text: $query)
                                .submitLabel(.search).onSubmit { refreshID = UUID() }
                            Button("Søg", systemImage: "arrow.right.circle.fill") { refreshID = UUID() }
                                .labelStyle(.iconOnly).frame(width: 44, height: 44)
                        }
                        .padding(.leading, 12).fadedGlassSurface()
                    }
                }
                if loading && messages.isEmpty { ProgressView("Læser Gmail…").padding(12) }
                if let notice { FadedEmptyState(icon: "tray", title: folder.rawValue, detail: notice) }
                ForEach(messages) { item in
                    Button {
                        preview = nil
                        previewIssue = nil
                        selected = item
                    } label: { mailRow(item) }
                    .buttonStyle(.plain)
                }
            }
            .padding(FadedSpacing.edge).frame(maxWidth: 640).frame(maxWidth: .infinity)
        }
        .background { FadedBackground() }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Gmail")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Skriv mail", systemImage: "square.and.pencil") { draft = true }
            }
        }
        .privacySensitive()
        .onChange(of: folder) { _, _ in
            messages = []
            notice = nil
            refreshID = UUID()
        }
        .task(id: refreshID) { await search() }
        .refreshable { await search() }
        .sheet(isPresented: $draft) { GmailDraftView(api: api) }
        .sheet(item: $selected) { item in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: FadedSpacing.m) {
                        mailRow(item)
                    if let preview {
                        FadedCard {
                            Text(preview).font(.body).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let onUse, !preview.isEmpty {
                            FadedPrimaryButton("Brug i denne opgave", icon: "paperclip") {
                                let excerpt = preview.utf8.count > 8_000
                                    ? String(decoding: preview.utf8.prefix(7_997), as: UTF8.self)
                                    : preview
                                if onUse(excerpt) { selected = nil }
                            }
                            if preview.utf8.count > 8_000 {
                                Text("Kun starten af den lange mail følger med opgaven.").foregroundStyle(.secondary)
                            }
                        }
                    } else if let previewIssue {
                        Text(previewIssue).foregroundStyle(.secondary)
                    } else { ProgressView("Læser mailen…") }
                    }
                    .padding(FadedSpacing.edge).frame(maxWidth: 640).frame(maxWidth: .infinity)
                }
                .background { FadedBackground() }
                .navigationTitle("Læs mail")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Luk") { selected = nil } } }
                .task(id: item.id) {
                    do {
                        let result: BotMailContent = try await api.moduleJSON("composio/gmail/message/\(Server.segment(item.id))", timeout: 75)
                        guard !Task.isCancelled else { return }
                        if result.text.isEmpty { previewIssue = "Mailen indeholder ingen læsbar tekst." }
                        else { preview = result.text }
                    } catch {
                        guard !Task.isCancelled else { return }
                        previewIssue = "Kunne ikke læse mailen."
                    }
                }
                .privacySensitive()
            }
        }
    }

    private func mailRow(_ item: BotMailMessages.Message) -> some View {
        FadedCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "envelope")
                    .foregroundStyle(FadedBrand.pc)
                    .frame(width: 38, height: 38).fadedGlassSurface()
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.subject.isEmpty ? "Uden emne" : item.subject).font(.subheadline.weight(.semibold))
                    Text(item.sender).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                if let time = Double(item.timestamp), time.isFinite, (1...4_200_000_000_000).contains(time) {
                    let date = Date(timeIntervalSince1970: time > 10_000_000_000 ? time / 1_000 : time)
                    Text(date, format: .dateTime.day().month(.abbreviated))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func search() async {
        loading = true
        notice = nil
        let requestedFolder = folder
        let request = UUID()
        activeSearch = request
        defer { if activeSearch == request { loading = false } }
        let prefix = requestedFolder.query + " "
        let expression = prefix + String(query.prefix(160 - prefix.count))
        do {
            let data: BotMailMessages = try await api.moduleJSON("composio/gmail/messages", timeout: 75,
                query: [URLQueryItem(name: "q", value: expression)])
            guard !Task.isCancelled, activeSearch == request, folder == requestedFolder else { return }
            messages = data.messages
            if messages.isEmpty { notice = "Ingen mails fundet." }
        } catch {
            guard !Task.isCancelled, activeSearch == request, folder == requestedFolder else { return }
            if case APIError.http(_, let error) = error { notice = error?.message }
            if notice == nil { notice = "Kunne ikke åbne Gmail fra PC’en." }
        }
    }
}
