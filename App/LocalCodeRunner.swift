import SwiftUI
import WebKit

@MainActor final class LocalCodeRunner: NSObject, ObservableObject, WKNavigationDelegate {
    @Published private(set) var ready = false
    private(set) var web: WKWebView
    override init() {
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: .zero, configuration: configuration)
        super.init(); web.navigationDelegate = self; web.loadHTMLString(LocalCode.page, baseURL: URL(string: "https://fadedai.invalid"))
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready = true }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { ready = false; web.loadHTMLString(LocalCode.page, baseURL: URL(string: "https://fadedai.invalid")) }
    func stop() {
        web.evaluateJavaScript("window.cancelRun?.(); window.cancelLinux?.()", completionHandler: nil)
    }
    func execute(_ recipe: LocalCode.Recipe, input: String) async throws -> String {
        guard ready, recipe.code.utf8.count <= 8_000, input.utf8.count <= 160_000 else { throw LocalCode.Failure.invalid }
        return try await withTaskCancellationHandler {
            let value = try await web.callAsyncJavaScript("return await window.runCode(code, input)", arguments: ["code": recipe.code, "input": input], in: nil, contentWorld: .page)
            try Task.checkCancellation()
            guard let raw = value as? String else { throw LocalCode.Failure.invalid }; return try LocalCode.output(raw)
        } onCancel: { Task { @MainActor in self.stop() } }
    }
}

struct LocalCodeHost: UIViewRepresentable {
    let runner: LocalCodeRunner
    func makeUIView(context: Context) -> WKWebView { runner.web }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
