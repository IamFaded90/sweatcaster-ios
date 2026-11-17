import AVFAudio
import Foundation
import SwiftUI
import WebKit

private final class CastMediaMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var browser: BrowserController?

    init(browser: BrowserController) { self.browser = browser }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        browser?.userContentController(controller, didReceive: message)
    }
}

final class BrowserController: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {
    @Published var address = "https://fmhy.net/video"
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published private(set) var adBlockingEnabled = false
    @Published private(set) var settingAdBlocking = false
    @Published private(set) var adBlockingNotice: String?
    var onVideo: ((VideoCandidate) -> Void)?
    var onPageStarted: (() -> Void)?
    var onPageLoaded: ((URL?, String?) -> Void)?
    let webView: WKWebView
    private var playingVideoFrame: WKFrameInfo?
    private static let adBlockingKey = "castbrowser.adBlocking"
    private var adRules: WKContentRuleList?
    private var pendingNavigation: URLRequest?
    private let capturedHeadersLock = NSLock()
    private var capturedMediaHeaders: [String: [String: String]] = [:]

    override init() {
        let controller = WKUserContentController()
        let script = """
        (() => {
          const send = (raw, mime, title, duration, poster, subtitles, direct=true) => {
            try {
              const url = new URL(raw, document.baseURI);
              if (!['http:', 'https:'].includes(url.protocol)) return;
              window.webkit.messageHandlers.videoFound.postMessage({url:url.href,mime:mime||'',title:title||document.title||'Video',pageTitle:document.title||url.hostname,pageURL:location.href,duration:Number.isFinite(duration)?duration:0,poster:poster?new URL(poster,document.baseURI).href:null,subtitles:subtitles||[],direct});
            } catch (_) {}
          };
          const scan = () => {
            document.querySelectorAll('video').forEach(v => {
              const subs = [...v.querySelectorAll('track[kind="subtitles"],track[kind="captions"]')].map(t => ({url:new URL(t.src,document.baseURI).href,name:t.label||t.srclang||'Undertekster',language:t.srclang||'',mime:t.type||'text/vtt'}));
              const sources = [...v.querySelectorAll('source')];
              const current = v.currentSrc || v.src;
              if (current) send(current, v.currentType||'', v.getAttribute('title')||document.title||'Video', v.duration, v.poster, subs, !current.startsWith('blob:'));
              sources.forEach(s => send(s.src,s.type,document.title,v.duration,v.poster,subs,true));
            });
            performance.getEntriesByType('resource').forEach(e => {
              if (/\\.(mp4|webm|m3u8|mpd)(?:[?#]|$)/i.test(e.name)) send(e.name,'',document.title,0,null,[],true);
            });
            document.querySelectorAll('iframe[src]').forEach(f => {
              if (/youtube|vimeo|player|embed/i.test(f.src)) send(f.src,'',f.title||'Indlejret afspiller',0,null,[],false);
            });
          };
          scan();
          new MutationObserver(scan).observe(document.documentElement,{childList:true,subtree:true,attributes:true,attributeFilter:['src']});
          document.addEventListener('loadedmetadata',scan,true);
          document.addEventListener('playing', event => {
            if (event.target instanceof HTMLVideoElement) {
              window.webkit.messageHandlers.videoFound.postMessage({messageType:'playingVideo'});
            }
          }, true);
          setInterval(scan,2500);
        })();
        """
        let captureScript = """
        (() => {
          const postMedia = (raw, mime, body='') => {
            try {
              const url = new URL(raw, document.baseURI);
              if (!['http:', 'https:'].includes(url.protocol)) return;
              const type = (mime || '').toLowerCase();
              const looksLikeMedia = /\\.(m3u8|mpd|mp4|webm)(?:[?#]|$)/i.test(url.href);
              const isManifest = /mpegurl|dash\\+xml/i.test(type) || /\\.(m3u8|mpd)(?:[?#]|$)/i.test(url.href);
              if (!looksLikeMedia && !isManifest) return;
              const isMaster = /#EXT-X-STREAM-INF/i.test(body);
              const hasAudio = /#EXT-X-MEDIA\\s*:\\s*TYPE=AUDIO/i.test(body) || /CODECS="[^"]*(mp4a|ac-3|ec-3|opus)/i.test(body);
              window.webkit.messageHandlers.videoFound.postMessage({url:url.href,mime:mime||'',title:document.title||'Video',pageTitle:document.title||url.hostname,pageURL:location.href,duration:0,poster:null,subtitles:[],direct:true,isHLSMaster:isMaster,hasAudioTrack:hasAudio});
            } catch (_) {}
          };
          const mediaRequest = (raw, mime='') => {
            try {
              const url = new URL(raw, document.baseURI);
              return /\\.(m3u8|mpd|mp4|webm|m4s|ts|aac|ac3|eac3|mp3)(?:[?#]|$)/i.test(url.href) ||
                /^(audio|video)\\//i.test(mime) || /mpegurl|dash\\+xml/i.test(mime);
            } catch (_) { return false; }
          };
          const requestHeadersFromFetch = args => {
            try {
              const request = args[0];
              const inputHeaders = (args[1] && args[1].headers) ||
                ((typeof Request !== 'undefined' && request instanceof Request) ? request.headers : {});
              return Object.fromEntries(new Headers(inputHeaders || {}).entries());
            } catch (_) { return {}; }
          };
          const sendRequestHeaders = (raw, headers, mime='') => {
            try {
              if (!mediaRequest(raw, mime)) return;
              const url = new URL(raw, document.baseURI);
              const clean = {};
              for (const [name, value] of Object.entries(headers || {})) {
                if (name.toLowerCase() !== 'cookie') clean[name] = value;
              }
              if (Object.keys(clean).length) {
                window.webkit.messageHandlers.videoFound.postMessage({messageType:'requestHeaders',url:url.href,headers:clean});
              }
            } catch (_) {}
          };
          const originalFetch = window.fetch;
          if (typeof originalFetch === 'function') {
            window.fetch = async function(...args) {
              const request = args[0];
              const url = typeof request === 'string' ? request : (request.url || request.href);
              const headers = requestHeadersFromFetch(args);
              const response = await originalFetch.apply(this, args);
              try {
                const mime = response.headers.get('content-type') || '';
                sendRequestHeaders(url, headers, mime);
                if (/mpegurl/i.test(mime) || /\\.m3u8(?:[?#]|$)/i.test(url)) {
                  response.clone().text().then(body => postMedia(url, mime, body));
                } else postMedia(url, mime);
              } catch (_) {}
              return response;
            };
          }
          const originalSetRequestHeader = XMLHttpRequest.prototype.setRequestHeader;
          XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
            this.__castRequestHeaders = this.__castRequestHeaders || {};
            this.__castRequestHeaders[name] = value;
            return originalSetRequestHeader.call(this, name, value);
          };
          const originalOpen = XMLHttpRequest.prototype.open;
          XMLHttpRequest.prototype.open = function(method, url, ...rest) {
            this.__castMediaUrl = url;
            this.__castRequestHeaders = {};
            this.addEventListener('load', () => {
              try {
                const mime = this.getResponseHeader('content-type') || '';
                sendRequestHeaders(this.__castMediaUrl, this.__castRequestHeaders, mime);
                if (/mpegurl/i.test(mime) || /\\.m3u8(?:[?#]|$)/i.test(this.__castMediaUrl)) {
                  const body = (this.responseType === '' || this.responseType === 'text') ? (this.responseText || '') : '';
                  postMedia(this.__castMediaUrl, mime, body);
                } else postMedia(this.__castMediaUrl, mime);
              } catch (_) {}
            });
            return originalOpen.call(this, method, url, ...rest);
          };
        })();
        """
        controller.addUserScript(WKUserScript(source: captureScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: castWebsiteProfile)
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        controller.add(CastMediaMessageHandler(browser: self), name: "videoFound")
        webView.navigationDelegate = self
        if UserDefaults.standard.bool(forKey: Self.adBlockingKey) {
            configureAdBlocking(true, showReloadHint: false)
        }
    }

    func setAdBlocking(_ enabled: Bool) {
        configureAdBlocking(enabled, showReloadHint: true)
    }

    private func configureAdBlocking(_ enabled: Bool, showReloadHint: Bool) {
        guard !settingAdBlocking, enabled != adBlockingEnabled else { return }
        let controller = webView.configuration.userContentController
        adBlockingNotice = nil
        if enabled, adRules == nil {
            settingAdBlocking = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    guard let url = Bundle.module.url(forResource: "AdBlockingRules", withExtension: "json") else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    let rules = try String(contentsOf: url, encoding: .utf8)
                    self.adRules = try await WKContentRuleListStore.default().compileContentRuleList(
                        forIdentifier: "FadedAI.CastBrowser.Ads.v1", encodedContentRuleList: rules)
                    self.settingAdBlocking = false
                    self.configureAdBlocking(true, showReloadHint: showReloadHint)
                } catch {
                    self.settingAdBlocking = false
                    self.adBlockingNotice = "Reklameblokering kunne ikke startes."
                }
                if let request = self.pendingNavigation {
                    self.pendingNavigation = nil
                    self.webView.load(request)
                }
            }
            return
        }
        guard let adRules else { return }
        if enabled { controller.add(adRules) }
        else { controller.remove(adRules) }
        adBlockingEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.adBlockingKey)
        if showReloadHint, webView.url != nil {
            adBlockingNotice = "Genindlæs siden, når det passer dig."
        }
    }

    func startPictureInPicture() async -> Bool {
        guard await webView.requestMediaPlaybackState() == .playing else { return false }
        let audio = AVAudioSession.sharedInstance()
        let previousCategory = audio.category
        let previousMode = audio.mode
        let previousOptions = audio.categoryOptions
        try? audio.setCategory(.playback, mode: .moviePlayback)
        let frame = playingVideoFrame
        if let frame, !frame.isMainFrame, await startPictureInPicture(in: frame) { return true }
        if await startPictureInPicture(in: nil) { return true }
        if audio.category == .playback && audio.mode == .moviePlayback {
            try? audio.setCategory(previousCategory, mode: previousMode, options: previousOptions)
        }
        return false
    }

    private func startPictureInPicture(in frame: WKFrameInfo?) async -> Bool {
        let script = """
        const video = Array.from(document.querySelectorAll('video')).find(element =>
          !element.paused && !element.ended && !element.disablePictureInPicture &&
          element.webkitSupportsPresentationMode?.('picture-in-picture'));
        if (!video) return false;
        if (video.webkitPresentationMode === 'picture-in-picture') return true;
        return await new Promise(resolve => {
          const finish = () => {
            clearTimeout(timeout);
            video.removeEventListener('webkitpresentationmodechanged', finish);
            resolve(video.webkitPresentationMode === 'picture-in-picture');
          };
          const timeout = setTimeout(finish, 800);
          video.addEventListener('webkitpresentationmodechanged', finish);
          try { video.webkitSetPresentationMode('picture-in-picture'); }
          catch (_) { finish(); }
        });
        """
        let result = try? await webView.callAsyncJavaScript(script, arguments: [:], in: frame, contentWorld: .defaultClient)
        return (result as? Bool) == true
    }

    func captureBrowserSession(completion: @escaping ([HTTPCookie], String?, [String: [String: String]]) -> Void) {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { completion(cookies, nil, [:]); return }
            self.webView.evaluateJavaScript("navigator.userAgent") { value, _ in
                completion(cookies, value as? String, self.snapshotCapturedMediaHeaders())
            }
        }
    }

    private func snapshotCapturedMediaHeaders() -> [String: [String: String]] {
        capturedHeadersLock.lock()
        defer { capturedHeadersLock.unlock() }
        return capturedMediaHeaders
    }

    func load(_ raw: String) {
        guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        address = url.absoluteString
        let request = URLRequest(url: url)
        if settingAdBlocking { pendingNavigation = request }
        else { webView.load(request) }
    }
    func goBack() { if webView.canGoBack { webView.goBack() } }
    func goForward() { if webView.canGoForward { webView.goForward() } }
    func reload() { webView.reload() }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        if adRules != nil { adBlockingNotice = nil }
        playingVideoFrame = nil
        syncNavigation(webView)
        onPageStarted?()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        syncNavigation(webView)
        onPageLoaded?(webView.url, webView.title)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { isLoading = false }
    private func syncNavigation(_ webView: WKWebView) {
        address = webView.url?.absoluteString ?? address
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let data = message.body as? [String: Any] else { return }
        if data["messageType"] as? String == "playingVideo" {
            playingVideoFrame = message.frameInfo
            return
        }
        guard let url = data["url"] as? String else { return }
        if data["messageType"] as? String == "requestHeaders", let headers = data["headers"] as? [String: String], !headers.isEmpty {
            capturedHeadersLock.lock()
            capturedMediaHeaders[url] = headers
            if capturedMediaHeaders.count > 160, let oldestKey = capturedMediaHeaders.keys.first { capturedMediaHeaders.removeValue(forKey: oldestKey) }
            capturedHeadersLock.unlock()
            return
        }
        let mime = data["mime"] as? String ?? ""
        let isDirect = data["direct"] as? Bool ?? true
        let subtitles = (data["subtitles"] as? [[String: String]] ?? []).map {
            SubtitleCandidate(url: $0["url"] ?? "", name: $0["name"] ?? "Undertekster", language: $0["language"] ?? "", mime: $0["mime"] ?? "text/vtt")
        }
        let candidate = VideoCandidate(url: url, mime: mime.isEmpty ? Self.mime(for: url) : mime,
                                       title: data["title"] as? String ?? "Video",
                                       pageTitle: data["pageTitle"] as? String ?? "Website",
                                       pageURL: data["pageURL"] as? String ?? "",
                                       poster: data["poster"] as? String,
                                       duration: data["duration"] as? Double ?? 0,
                                       isDirect: isDirect, subtitles: subtitles,
                                       isHLSMaster: data["isHLSMaster"] as? Bool,
                                       hasAudioTrack: data["hasAudioTrack"] as? Bool)
        DispatchQueue.main.async { self.onVideo?(candidate) }
    }
    private static func mime(for raw: String) -> String {
        let path = URL(string: raw)?.path.lowercased() ?? ""
        if path.hasSuffix(".m3u8") { return "application/vnd.apple.mpegurl" }
        if path.hasSuffix(".mpd") { return "application/dash+xml" }
        if path.hasSuffix(".webm") { return "video/webm" }
        return "video/mp4"
    }
}

struct WebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) { }
}
