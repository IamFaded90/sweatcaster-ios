import Foundation
import SafariServices
import SwiftUI
import WebKit

struct CodeAddOnWebFiles: Decodable, Sendable {
    struct File: Decodable, Sendable {
        let path: String
        let data: Data
    }
    let files: [File]

    func stage(in folder: URL) throws -> URL {
        let manager = FileManager.default
        let supported = Set(["html", "htm", "css", "js", "mjs", "json", "png", "jpg", "jpeg", "gif",
                             "webp", "svg", "ico", "woff", "woff2", "ttf", "txt", "wasm", "mp3", "ogg"])
        guard (1...250).contains(files.count), files.contains(where: { $0.path == "index.html" }),
              files.reduce(0, { $0 + $1.data.count }) <= 6_000_000 else { throw APIError.malformed }
        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
            var seen = Set<String>()
            for file in files {
                let parts = file.path.split(separator: "/", omittingEmptySubsequences: false)
                guard file.path.utf8.count <= 240, (1...10).contains(parts.count),
                      parts.allSatisfy({ $0.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,95}$"#, options: .regularExpression) != nil }),
                      seen.insert(file.path.lowercased()).inserted,
                      supported.contains((file.path as NSString).pathExtension.lowercased()) else { throw APIError.malformed }
                let url = parts.reduce(folder) { $0.appending(path: String($1)) }
                var contents = file.data
                if ["html", "htm"].contains(url.pathExtension.lowercased()) {
                    guard let html = String(data: contents, encoding: .utf8) else { throw APIError.malformed }
                    contents = Data((Self.localHTML + html).utf8)
                }
                try LocalFileStore.writeBytes(contents, to: url, within: folder)
            }
            return folder.resolvingSymlinksInPath()
        } catch {
            try? manager.removeItem(at: folder)
            throw error
        }
    }

    private static let localHTML = """
    <!doctype html>
    <meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src file: data: blob:; script-src file: 'unsafe-inline'; style-src file: 'unsafe-inline'; connect-src 'none'; frame-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'">

    """
}

struct PublishedAddOnBrowser: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

@MainActor struct CodeAddOnWebScreen: View {
    let api: LiveAPI
    let item: CodeAddOn
    @State private var workspace: URL?
    @State private var filter: WKContentRuleList?
    @State private var notice: String?
    @State private var attempt = 0

    var body: some View {
        Group {
            if let workspace, let filter {
                CodeAddOnLocalBrowser(root: workspace, filter: filter)
            } else if let notice {
                FadedEmptyState(icon: "doc.badge.xmark", title: "Webpakken kunne ikke åbnes", detail: notice,
                                actionTitle: "Prøv igen") { attempt += 1 }
            } else {
                ProgressView("Henter webpakken fra PC’en…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { FadedBackground() }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: attempt) { await load() }
        .onDisappear {
            if let workspace { try? FileManager.default.removeItem(at: workspace) }
            workspace = nil
            filter = nil
        }
    }

    private func load() async {
        notice = nil
        do {
            let files = try await api.codeAddOnWebFiles(item.id)
            let rules = try await Self.localRules()
            try Task.checkCancellation()
            let folder = FileManager.default.temporaryDirectory
                .appending(path: StudioScratch.prefix + UUID().uuidString, directoryHint: .isDirectory)
            let prepared = try await Task.detached(priority: .utility) { try files.stage(in: folder) }.value
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: prepared)
                return
            }
            filter = rules
            workspace = prepared
        } catch let APIError.http(status, _) where status == 404 {
            guard !Task.isCancelled else { return }
            notice = "Tilføjelsen er fjernet eller skal installeres igen."
        } catch {
            guard !Task.isCancelled else { return }
            notice = "Tjek, at PC’en er forbundet, og at projektet er en færdig webpakke."
        }
    }

    private static func localRules() async throws -> WKContentRuleList {
        let store: WKContentRuleListStore? = WKContentRuleListStore.default()
        guard let store else { throw APIError.malformed }
        let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}}]"#
        return try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(forIdentifier: "FadedAIOfflineWeb", encodedContentRuleList: rules) { list, error in
                if let list { continuation.resume(returning: list) }
                else { continuation.resume(throwing: error ?? APIError.malformed) }
            }
        }
    }
}

private struct CodeAddOnLocalBrowser: UIViewRepresentable {
    let root: URL
    let filter: WKContentRuleList

    func makeCoordinator() -> Coordinator { Coordinator(root: root) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(filter)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.loadFileURL(root.appending(path: "index.html"), allowingReadAccessTo: root)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let root: URL

        init(root: URL) { self.root = root }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let target = action.request.url, action.targetFrame?.isMainFrame == true, target.isFileURL,
                  target.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
