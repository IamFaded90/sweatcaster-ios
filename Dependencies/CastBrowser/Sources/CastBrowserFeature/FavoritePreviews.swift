import SwiftUI
import WebKit
import CryptoKit

// One hidden browser renders favorite previews sequentially. Images are cached
// on this iPhone; no screenshot or browsing history is sent to another service.
@MainActor
final class FavoritePreviewStore: NSObject, ObservableObject, @preconcurrency WKNavigationDelegate {
    static let shared = FavoritePreviewStore()
    @Published private(set) var images: [String: UIImage] = [:]

    private var pending: [String] = []
    private var requested = Set<String>()
    private var current: String?
    private var webView: WKWebView?

    func request(_ address: String) {
        guard let url = URL(string: address),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        if let cached = UIImage(contentsOfFile: cacheURL(for: address).path) {
            images[address] = cached
            return
        }
        guard requested.insert(address).inserted else { return }
        pending.append(address)
        startNext()
    }

    private func startNext() {
        guard current == nil, !pending.isEmpty else { return }
        let address = pending.removeFirst()
        guard let url = URL(string: address) else { startNext(); return }
        current = address

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 360, height: 640),
                             configuration: config)
        view.navigationDelegate = self
        view.isOpaque = false
        webView = view
        view.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))

        // A broken website must not block screenshots for the other favorites.
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self, weak view] in
            guard let self, let view, self.current == address, self.webView === view else { return }
            self.finish()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let address = current, self.webView === webView else { return }
        // Let the first visible images settle before capturing the page.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak webView] in
            guard let self, let webView, self.current == address, self.webView === webView else { return }
            let options = WKSnapshotConfiguration()
            options.rect = CGRect(x: 0, y: 0, width: 360, height: 210)
            webView.takeSnapshot(with: options) { [weak self] image, _ in
                Task { @MainActor in
                    guard let self, self.current == address else { return }
                    if let image, let data = image.jpegData(compressionQuality: 0.72) {
                        try? FileManager.default.createDirectory(
                            at: self.cacheDirectory, withIntermediateDirectories: true)
                        try? data.write(to: self.cacheURL(for: address), options: .atomic)
                        self.images[address] = image
                    }
                    self.finish()
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if self.webView === webView { finish() }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if self.webView === webView { finish() }
    }

    private func finish() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        current = nil
        startNext()
    }

    private var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FavoritePreviews", isDirectory: true)
    }

    private func cacheURL(for address: String) -> URL {
        let digest = SHA256.hash(data: Data(address.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent(digest + ".jpg")
    }
}
