import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor final class FadedShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let items = (extensionContext?.inputItems ?? []).compactMap { $0 as? NSExtensionItem }
        let controller = UIHostingController(rootView: FadedShareContent(
            items: items,
            close: { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
        ))
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        controller.didMove(toParent: self)
        preferredContentSize = CGSize(width: 390, height: 300)
    }
}

@MainActor private struct FadedShareContent: View {
    let items: [NSExtensionItem]
    let close: () -> Void
    @State private var working = false
    @State private var saved = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Del til FadedAI", systemImage: "bubble.left.and.bubble.right")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            if saved {
                Label("Klar til chat", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                Text("Åbn FadedAI for at bruge det delte indhold i chatten.")
                    .foregroundStyle(.secondary)
            } else if let problem {
                Text(problem).foregroundStyle(.secondary)
            } else {
                Text("Læg det delte indhold klar til din næste chat.").foregroundStyle(.secondary)
            }
            if working { ProgressView("Gør indholdet klar…") }
            HStack {
                Button(saved ? "Færdig" : "Luk", action: close)
                    .buttonStyle(.bordered)
                    .disabled(working)
                Spacer()
                if !saved {
                    Button("Læg klar til chat") {
                        Task { await save() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(working)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(uiColor: .systemBackground))
    }

    private func save() async {
        guard !working, !saved else { return }
        working = true
        problem = nil
        defer { working = false }
        do {
            try await ShareInbox.save(items)
            saved = true
        } catch let issue as ShareInbox.Failure {
            problem = issue.message
        } catch {
            problem = "Delingen kunne ikke gemmes. Prøv igen."
        }
    }
}

private enum ShareInbox {
    private static let maxAttachmentSize = 10 * 1_024 * 1_024

    enum Failure: Error {
        case unavailable, unsupported, severalItems, tooLarge

        var message: String {
            switch self {
            case .unavailable: "Delt indhold er ikke tilgængeligt med denne installation af FadedAI."
            case .unsupported: "Vælg et billede, en PDF, en webadresse eller markeret tekst."
            case .severalItems: "Del ét billede eller én PDF ad gangen."
            case .tooLarge: "Filen er større end 10 MB. Del en mindre fil."
            }
        }
    }

    private enum Kind: String, Codable { case text, url, pdf, image }

    private struct Item: Codable {
        let id: UUID
        let kind: Kind
        let title: String
        let value: String?
        let filename: String?
    }

    @MainActor static func save(_ items: [NSExtensionItem]) async throws {
        let manager = FileManager.default
        guard let root = FadedSharedContainer.url else {
            throw Failure.unavailable
        }
        let (item, attachment) = try await load(items)
        try Task.checkCancellation()
        var inbox = root.appendingPathComponent("ShareInbox", isDirectory: true)
        try manager.createDirectory(at: inbox, withIntermediateDirectories: true)
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try? inbox.setResourceValues(resources)

        let staging = inbox.appendingPathComponent(".\(item.id.uuidString).partial", isDirectory: true)
        let destination = inbox.appendingPathComponent(item.id.uuidString, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        if let attachment, let name = item.filename {
            try attachment.write(to: staging.appendingPathComponent(name), options: [.atomic, .completeFileProtection])
        }
        try JSONEncoder().encode(item).write(to: staging.appendingPathComponent("item.json"),
                                            options: [.atomic, .completeFileProtection])
        try manager.moveItem(at: staging, to: destination)
    }

    @MainActor private static func load(_ items: [NSExtensionItem]) async throws -> (Item, Data?) {
        let providers = items.flatMap { $0.attachments ?? [] }
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }),
           let url = try? await readWebURL(provider) {
            return (Item(id: UUID(), kind: .url, title: url.host ?? "Webside",
                         value: url.absoluteString, filename: nil), nil)
        }
        let files = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) || $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }
        guard files.count <= 1 else { throw Failure.severalItems }
        if let provider = files.first {
            let kind: Kind = provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) ? .pdf : .image
            let type = kind == .pdf ? UTType.pdf : imageType(for: provider)
            let data = try await readFile(provider, type: type.identifier)
            let suffix = type.preferredFilenameExtension ?? "jpg"
            let fallback = kind == .pdf ? "Delt PDF" : "Delt billede"
            let title = provider.suggestedName.map { String($0.prefix(160)) } ?? fallback
            return (Item(id: UUID(), kind: kind, title: title, value: nil, filename: "attachment.\(suffix)"), data)
        }
        var text: String?
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) {
            text = try? await readText(provider)
        }
        text = text ?? items.lazy.compactMap { $0.attributedContentText?.string }.first
        guard let text else { throw Failure.unsupported }
        let value = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(8_000))
        guard !value.isEmpty else { throw Failure.unsupported }
        return (Item(id: UUID(), kind: .text, title: "Delt tekst", value: value, filename: nil), nil)
    }

    private static func imageType(for provider: NSItemProvider) -> UTType {
        provider.registeredTypeIdentifiers.compactMap { UTType($0) }
            .first { $0.conforms(to: .image) && $0.preferredFilenameExtension != nil } ?? .image
    }

    private static func readWebURL(_ provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, error in
                if let error { continuation.resume(throwing: error); return }
                let url = (item as? URL) ?? (item as? String).flatMap { URL(string: $0) }
                guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
                      url.user == nil, url.password == nil, url.absoluteString.utf8.count <= 4_096 else {
                    continuation.resume(throwing: Failure.unsupported)
                    return
                }
                continuation.resume(returning: url)
            }
        }
    }

    private static func readText(_ provider: NSItemProvider) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, error in
                if let error { continuation.resume(throwing: error); return }
                guard let text = (item as? String) ?? (item as? NSAttributedString)?.string else {
                    continuation.resume(throwing: Failure.unsupported)
                    return
                }
                continuation.resume(returning: text)
            }
        }
    }

    private static func readFile(_ provider: NSItemProvider, type: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                // This URL is valid only during the provider's callback.
                do {
                    if let error { throw error }
                    guard let url else { throw Failure.unsupported }
                    let file = try FileHandle(forReadingFrom: url)
                    defer { try? file.close() }
                    guard let data = try file.read(upToCount: maxAttachmentSize + 1), !data.isEmpty else {
                        throw Failure.unsupported
                    }
                    guard data.count <= maxAttachmentSize else { throw Failure.tooLarge }
                    continuation.resume(returning: data)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
