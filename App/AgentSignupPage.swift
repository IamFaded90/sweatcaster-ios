import SwiftUI
import WebKit

@MainActor struct AgentSignupPage: View {
    let url: URL
    let address: String
    let name: String
    @Binding var verificationURL: URL?
    let openInbox: () -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var page = AgentSignupBrowser()

    static func siteURL(_ value: String) -> URL? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        let candidate = text.contains("://") ? text : "https://" + text
        guard let parts = URLComponents(string: candidate), parts.scheme?.lowercased() == "https",
              let host = parts.host, host.contains("."), parts.user == nil, parts.password == nil else { return nil }
        return parts.url
    }

    static func link(in prompt: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let matches = detector.matches(in: prompt, range: NSRange(prompt.startIndex..., in: prompt))
        guard matches.count == 1, let range = Range(matches[0].range, in: prompt) else { return nil }
        return siteURL(String(prompt[range]))
    }

    static func links(in mail: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        var links: [URL] = []
        for match in detector.matches(in: mail, range: NSRange(mail.startIndex..., in: mail)) {
            guard let url = match.url, url.scheme?.lowercased() == "https", siteURL(url.absoluteString) != nil,
                  !links.contains(url) else { continue }
            links.append(url)
            if links.count == 8 { break }
        }
        return links
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Text(page.host ?? url.host ?? "").font(.headline).textSelection(.enabled)
                Text(address).font(.footnote).textSelection(.enabled)
                SignupWebView(page: page, url: url, address: address)
                if let notice = page.notice {
                    Text(notice).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal).accessibilityAddTraits(.updatesFrequently)
                }
                HStack {
                    Button("Agentpost", systemImage: "envelope", action: openInbox)
                    Spacer()
                    Button("Tilmeld \(name)") { page.apply(submit: true) }
                        .buttonStyle(.borderedProminent).disabled(!page.canSubmit)
                }
                .padding(.horizontal).padding(.bottom, 8)
            }
            .navigationTitle("Tilmelding")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Luk") { dismiss() } }
        }
        .onChange(of: verificationURL) { _, destination in
            if let destination {
                page.webView?.load(URLRequest(url: destination))
                verificationURL = nil
            }
        }
    }
}

@MainActor private final class AgentSignupBrowser: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var host: String?
    @Published var notice: String?
    @Published var canSubmit = false
    private(set) var webView: WKWebView?
    private var start: URL?
    private var email = ""

    func open(url: URL, address: String) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = self
        web.allowsBackForwardNavigationGestures = true
        webView = web
        start = url
        email = address
        web.load(URLRequest(url: url))
        return web
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url?.scheme?.lowercased() == "https" ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        canSubmit = false
        notice = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        host = webView.url?.host
        if let host = host?.lowercased(), host == "instagram.com" || host.hasSuffix(".instagram.com") {
            canSubmit = false
            notice = "Opret kontoen hos Instagram. Du kan kopiere agentens adresse øverst."
            return
        }
        guard let start, let current = webView.url, current.scheme == start.scheme,
              current.host?.lowercased() == start.host?.lowercased(), (current.port ?? 443) == (start.port ?? 443) else {
            notice = "Siden har skiftet adresse. Fortsæt i formularen."
            return
        }
        canSubmit = true
        apply(submit: false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        canSubmit = false
        notice = "Siden kunne ikke åbnes. Tjek linket og forbindelsen."
    }

    func apply(submit: Bool) {
        guard let webView, let start, let activeURL = webView.url, canSubmit else { return }
        canSubmit = false
        webView.callAsyncJavaScript(Self.fillForm, arguments: ["address": email, "start": start.absoluteString,
                                    "submitForm": submit], in: nil, contentWorld: .defaultClient) { [weak self] result in
            guard let self, webView.url == activeURL, !webView.isLoading else { return }
            switch result {
            case .success(let value):
                let sent = value as? String == "submitted"
                self.canSubmit = !sent
                switch value as? String {
                case "filled": self.notice = "Agentens adresse er udfyldt."
                case "submitted": self.notice = "Tilmeldingen er sendt til siden. Se sidens svar."
                case "required": self.notice = "Udfyld de felter, siden mangler, og fortsæt i formularen."
                default: self.notice = "Åbn sidens tilmeldingsformular. Du kan kopiere agentens adresse øverst."
                }
            case .failure:
                self.canSubmit = true
                self.notice = "Brug sidens formular til at fortsætte."
            }
        }
    }

    // Use only the displayed site's form and its own sign-up button.
    static let fillForm = #"""
    if (location.origin !== new URL(start).origin) return "manual";
    const visible = element => element.getClientRects().length > 0;
    const fields = Array.from(document.querySelectorAll('input[type="email"], input[autocomplete="email"]'))
        .filter(field => visible(field) && !field.disabled && !field.readOnly && field.form);
    if (fields.length !== 1) return "manual";
    const field = fields[0], form = field.form;
    const buttons = Array.from(form.elements).filter(button =>
        button.type === "submit" && visible(button) &&
        /^(?:sign up|subscribe|register|create (?:(?:an?|my) )?account|tilmeld(?: dig| mig)?|abonnér|opret (?:en )?(?:konto|bruger))$/i
            .test((button.innerText || button.value || "").trim()));
    if (buttons.length !== 1 || (field.value && field.value !== address)) return "manual";
    const target = buttons[0].getAttribute("formaction") || form.getAttribute("action") || location.href;
    if (new URL(target, document.baseURI).origin !== location.origin) return "manual";
    if (!field.value) {
        Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set.call(field, address);
        field.dispatchEvent(new Event("input", {bubbles:true}));
        field.dispatchEvent(new Event("change", {bubbles:true}));
    }
    if (!submitForm) return "filled";
    if (buttons[0].disabled || !form.reportValidity() || field.value !== address) return "required";
    form.requestSubmit(buttons[0]);
    return "submitted";
    """#
}

private struct SignupWebView: UIViewRepresentable {
    let page: AgentSignupBrowser
    let url: URL
    let address: String

    func makeUIView(context: Context) -> WKWebView { page.open(url: url, address: address) }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
