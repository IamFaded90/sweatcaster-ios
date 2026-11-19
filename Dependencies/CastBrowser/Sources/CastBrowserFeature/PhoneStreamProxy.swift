import Foundation
import Network
import Darwin

struct HLSFormats {
    let audioSegmentFormat: Int?
    let videoSegmentFormat: Int?
}

/// Serves media back to Chromecast over the home Wi-Fi while fetching it from the
/// same URLs and session as the embedded browser. HLS playlists are rewritten so
/// manifests, keys and segments are fetched through this phone-local endpoint.
final class PhoneStreamProxy {
    static let shared = PhoneStreamProxy()

    private let queue = DispatchQueue(label: "webcast.phone-stream-proxy")
    private var listener: NWListener?
    private var hostAddress: String?
    private var listenPort: UInt16?
    private var cookies: [HTTPCookie] = []
    private var userAgent = "Mozilla/5.0"
    private var referer = ""
    private var capturedHeadersByURL: [String: [String: String]] = [:]
    private var requestSequence: UInt64 = 0
    private let playlistLock = NSLock()
    private let routeLock = NSLock()
    private var mediaRoutes: [String: URL] = [:]
    private var routeTokens: [URL: String] = [:]
    private var routeOrder: [String] = []
    private var audioPlaylistURLs = Set<String>()
    private var videoPlaylistURLs = Set<String>()
    var onActivity: ((String) -> Void)?

    private init() {}

    private func useBrowserSession(_ cookies: [HTTPCookie], userAgent: String?, referer: String?,
                                   headers: [String: [String: String]]) {
        self.cookies = cookies
        self.userAgent = userAgent.flatMap { $0.isEmpty ? nil : $0 } ?? "Mozilla/5.0"
        self.referer = referer ?? ""
        capturedHeadersByURL = headers
    }

    func inspectDirect(_ url: URL, isHLS: Bool, cookies: [HTTPCookie], userAgent: String?,
                       referer: String?, headers: [String: [String: String]], completion: @escaping (HLSFormats?) -> Void) {
        queue.async {
            self.useBrowserSession(cookies, userAgent: userAgent, referer: referer, headers: headers)
            if isHLS { self.inspectHLS(url, completion: completion) }
            else { completion(nil) }
        }
    }

    func prepare(cookies: [HTTPCookie], userAgent: String?, referer: String?, capturedHeadersByURL: [String: [String: String]] = [:], completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async {
            self.routeLock.withLock {
                self.mediaRoutes.removeAll()
                self.routeTokens.removeAll()
                self.routeOrder.removeAll()
            }
            self.useBrowserSession(cookies, userAgent: userAgent, referer: referer, headers: capturedHeadersByURL)
            if let host = self.hostAddress, let port = self.listenPort {
                completion(.success(URL(string: "http://\(host):\(port)/")!))
                return
            }
            do {
                let listener = try NWListener(using: .tcp, on: .any)
                self.listener = listener
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard let port = listener.port?.rawValue, let host = self.wifiIPv4() else {
                            completion(.failure(ProxyError.noWiFiAddress)); return
                        }
                        self.hostAddress = host
                        self.listenPort = port
                        completion(.success(URL(string: "http://\(host):\(port)/")!))
                    case .failed(let error): completion(.failure(error))
                    default: break
                    }
                }
                listener.start(queue: self.queue)
            } catch { completion(.failure(error)) }
        }
    }

    func proxiedURL(for upstream: URL) -> URL? {
        guard let host = hostAddress, let port = listenPort,
              let result = URL(string: localURL(for: upstream)) else { return nil }
        return result
    }

    /// Inspect the master and its referenced audio/video playlists so Cast
    /// receives segment formats that match this stream instead of guesses.
    func inspectHLS(_ url: URL, usingBrowserSession: Bool = true, completion: @escaping (HLSFormats?) -> Void) {
        fetchPlaylistText(url, usingBrowserSession: usingBrowserSession) { [weak self] masterText, finalURL in
            guard let self, let masterText, let finalURL else { completion(nil); return }
            let lines = masterText.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let audioLine = lines.first { $0.hasPrefix("#EXT-X-MEDIA:") && $0.localizedCaseInsensitiveContains("TYPE=AUDIO") }
            let audioURL = audioLine.flatMap { self.uriAttribute(in: $0) }.flatMap { URL(string: $0, relativeTo: finalURL)?.absoluteURL }
            let videoURL: URL? = {
                for (index, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF:") {
                    if let next = lines.dropFirst(index + 1).first(where: { !$0.isEmpty && !$0.hasPrefix("#") }) {
                        return URL(string: next, relativeTo: finalURL)?.absoluteURL
                    }
                }
                return nil
            }()

            self.playlistLock.lock()
            if let audioURL { self.audioPlaylistURLs.insert(audioURL.absoluteString) }
            if let videoURL { self.videoPlaylistURLs.insert(videoURL.absoluteString) }
            self.playlistLock.unlock()

            guard audioURL != nil || videoURL != nil else {
                completion(HLSFormats(audioSegmentFormat: nil, videoSegmentFormat: self.videoFormat(in: masterText)))
                return
            }
            let group = DispatchGroup()
            var audioFormat: Int?
            var videoFormat: Int?
            if let audioURL {
                group.enter()
                self.fetchPlaylistText(audioURL, usingBrowserSession: usingBrowserSession) { text, _ in
                    self.queue.async {
                        if let text { audioFormat = self.audioFormat(in: text) }
                        group.leave()
                    }
                }
            }
            if let videoURL {
                group.enter()
                self.fetchPlaylistText(videoURL, usingBrowserSession: usingBrowserSession) { text, _ in
                    self.queue.async {
                        if let text { videoFormat = self.videoFormat(in: text) }
                        group.leave()
                    }
                }
            }
            group.notify(queue: self.queue) {
                completion(HLSFormats(audioSegmentFormat: audioFormat, videoSegmentFormat: videoFormat))
            }
        }
    }

    /// Snapshot the existing proxy context on its serial queue. Never log header values.
    func diagnosticRequest(for url: URL) async -> URLRequest? {
        await withCheckedContinuation { continuation in
            queue.async {
                guard !self.referer.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
                request.setValue(self.userAgent, forHTTPHeaderField: "User-Agent")
                request.setValue("*/*", forHTTPHeaderField: "Accept")
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                let pageReferer = self.referer.isEmpty ? url.absoluteString : self.referer
                request.setValue(pageReferer, forHTTPHeaderField: "Referer")
                if let page = URL(string: pageReferer), let scheme = page.scheme, let host = page.host {
                    request.setValue("\(scheme)://\(host)" + (page.port.map { ":\($0)" } ?? ""), forHTTPHeaderField: "Origin")
                }
                let cookie = self.cookieHeader(for: url)
                if !cookie.isEmpty { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
                self.applyCapturedHeaders(to: &request, for: url)
                continuation.resume(returning: request)
            }
        }
    }

    private func fetchPlaylistText(_ url: URL, usingBrowserSession: Bool, completion: @escaping (String?, URL?) -> Void) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.httpShouldHandleCookies = false
        if usingBrowserSession {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            let pageReferer = referer.isEmpty ? url.absoluteString : referer
            request.setValue(pageReferer, forHTTPHeaderField: "Referer")
            if let page = URL(string: pageReferer), let scheme = page.scheme, let host = page.host {
                request.setValue("\(scheme)://\(host)" + (page.port.map { ":\($0)" } ?? ""), forHTTPHeaderField: "Origin")
            }
            let cookie = cookieHeader(for: url)
            if !cookie.isEmpty { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
            applyCapturedHeaders(to: &request, for: url)
        }
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard error == nil, let response = response as? HTTPURLResponse,
                  (200...299).contains(response.statusCode), let data,
                  let text = String(data: data, encoding: .utf8), text.hasPrefix("#EXTM3U") else {
                completion(nil, nil)
                return
            }
            completion(text, response.url ?? url)
        }.resume()
    }

    private func uriAttribute(in line: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"URI="([^"]+)""#),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[range])
    }

    private func hasFMP4Segments(_ text: String) -> Bool {
        // EXT-X-MAP identifies an initialization section; resource extensions can be misleading.
        text.localizedCaseInsensitiveContains("#EXT-X-MAP:") ||
            segmentExtensions(in: text).contains(where: { $0 == "m4s" || $0 == "mp4" })
    }

    private func isFMP4Data(_ data: Data) -> Bool {
        guard data.count >= 8 else { return false }
        let boxType = String(data: data[4..<8], encoding: .ascii)?.lowercased()
        return ["ftyp", "styp", "moof", "mdat", "sidx"].contains(boxType ?? "")
    }

    private func audioFormat(in text: String) -> Int? {
        if hasFMP4Segments(text) { return 7 } // GCKHLSSegmentFormatFMP4
        let extensions = segmentExtensions(in: text)
        if extensions.contains("ts") { return 5 } // TS_AAC
        if extensions.contains("aac") { return 1 }
        if extensions.contains("ac3") { return 2 }
        if extensions.contains("ec3") || extensions.contains("eac3") { return 6 }
        if extensions.contains("mp3") { return 3 }
        return nil
    }

    private func videoFormat(in text: String) -> Int? {
        if hasFMP4Segments(text) { return 2 } // MPEG-4 fragmented video
        if segmentExtensions(in: text).contains("ts") { return 1 }
        return nil
    }

    private func segmentExtensions(in text: String) -> Set<String> {
        Set(text.components(separatedBy: .newlines)
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .compactMap { URL(string: $0)?.pathExtension.lowercased() })
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHeaders(connection, accumulated: Data())
    }

    private func receiveHeaders(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var bytes = accumulated
            if let data { bytes.append(data) }
            if let range = bytes.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = bytes[..<range.lowerBound]
                guard let header = String(data: headerData, encoding: .utf8) else { self.reply(connection, status: 400, body: Data("Bad request".utf8)); return }
                self.handle(header, connection: connection)
            } else if complete || error != nil || bytes.count > 131072 {
                self.reply(connection, status: 400, body: Data("Bad request".utf8))
            } else {
                self.receiveHeaders(connection, accumulated: bytes)
            }
        }
    }

    private func handle(_ rawHeader: String, connection: NWConnection) {
        let lines = rawHeader.components(separatedBy: "\r\n")
        guard let first = lines.first, let path = first.split(separator: " ").dropFirst().first else {
            reply(connection, status: 400, body: Data("Bad request".utf8)); return
        }
        let parts = path.split(separator: "/")
        guard parts.count == 2, parts[0] == "stream",
              let mediaURL = routeLock.withLock({ mediaRoutes[String(parts[1])] }),
              first.hasPrefix("GET ") || first.hasPrefix("HEAD ") || first.hasPrefix("OPTIONS ") else {
            reply(connection, status: 404, body: Data("Media URL not found".utf8))
            return
        }
        if first.hasPrefix("OPTIONS ") {
            reply(connection, status: 204, headers: [("Access-Control-Allow-Origin", "*"), ("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS"), ("Access-Control-Allow-Headers", "Range, Content-Type, Accept, If-Range"), ("Content-Length", "0"), ("Connection", "close")], body: Data())
            return
        }
        let headers = Dictionary(lines.dropFirst().compactMap { line -> (String, String)? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (String(line[..<colon]).lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }, uniquingKeysWith: { _, newest in newest })
        let mediaKind = requestKind(for: mediaURL)
        let incomingMethod = first.hasPrefix("HEAD ") ? "HEAD" : "GET"
        let incomingIsHead = incomingMethod == "HEAD"
        requestSequence &+= 1
        let requestID = requestSequence
        let safeURL = "\(mediaURL.host ?? "ukendt-host")\(mediaURL.path)"
        onActivity?("req#\(requestID) \(incomingMethod) \(safeURL) — henter fra videokilden…")
        var request = URLRequest(url: mediaURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        // Fetch GET even for a downstream HEAD, so the body can be sniffed.
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let pageReferer = referer.isEmpty ? mediaURL.absoluteString : referer
        request.setValue(pageReferer, forHTTPHeaderField: "Referer")
        if let page = URL(string: pageReferer), let scheme = page.scheme, let host = page.host {
            let origin = "\(scheme)://\(host)" + (page.port.map { ":\($0)" } ?? "")
            request.setValue(origin, forHTTPHeaderField: "Origin")
        }
        let cookies = cookieHeader(for: mediaURL)
        if !cookies.isEmpty { request.setValue(cookies, forHTTPHeaderField: "Cookie") }
        applyCapturedHeaders(to: &request, for: mediaURL)
        if !incomingIsHead {
            if let range = headers["range"] { request.setValue(range, forHTTPHeaderField: "Range") }
            if let ifRange = headers["if-range"] { request.setValue(ifRange, forHTTPHeaderField: "If-Range") }
        }

        let upstreamRequest = request
        @Sendable func fetch(retriesRemaining: Int) {
            URLSession.shared.dataTask(with: upstreamRequest) { [weak self] data, response, error in
                guard let self else { connection.cancel(); return }
                if retriesRemaining > 0,
                   error != nil || (response as? HTTPURLResponse).map({ (500...599).contains($0.statusCode) }) == true {
                    self.onActivity?("req#\(requestID) \(incomingMethod) \(safeURL); upstream=\((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "ukendt"); result=upstream-error; sent=afventer; prøver igen om 1 s")
                    self.queue.asyncAfter(deadline: .now() + 1) { fetch(retriesRemaining: retriesRemaining - 1) }
                    return
                }
                guard let response = response as? HTTPURLResponse, let data, error == nil else {
                    let message = error?.localizedDescription ?? "Intet HTTP-svar fra websitet"
                    self.onActivity?("req#\(requestID) \(incomingMethod) \(safeURL) -> upstream GET fejlede: \(message); sent=502")
                    self.reply(connection, status: 502, body: Data("Upstream media request failed".utf8)); return
                }
                let upstreamType = response.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
                let sniff = String(data: data.prefix(256), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let isPlaylist = mediaURL.path.lowercased().hasSuffix(".m3u8") || upstreamType.lowercased().contains("mpegurl") || sniff.hasPrefix("#EXTM3U")
                let isFMP4 = !isPlaylist && self.isFMP4Data(data)
                let declaredLength = response.value(forHTTPHeaderField: "Content-Length") ?? "unknown"
                let actualLength = data.count
                let firstBytes = data.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
                let result = isPlaylist ? "playlist" : (isFMP4 ? "fMP4" : (actualLength < 8 ? "body-too-short" : "not-fMP4"))
                let contentType = isPlaylist ? "application/x-mpegurl" : (isFMP4 ? "video/mp4" : upstreamType)
                let details = isPlaylist ? self.playlistDetails(data) : nil
                let suffix = details.map { "; \($0)" } ?? ""
                let responseURL = response.url ?? mediaURL
                let responseHost = responseURL.host ?? "ukendt host"
                let responseExtension = responseURL.pathExtension.isEmpty ? "no-ext" : responseURL.pathExtension.lowercased()
                let typeCorrection = isFMP4 ? "; upstream=\(upstreamType)" : ""
                let requestLog = "req#\(requestID) \(incomingMethod) \(safeURL) -> HTTP \(response.statusCode); upstream=\(upstreamType); declared=\(declaredLength); body=\(actualLength); magic=\(firstBytes); result=\(result); sent=\(contentType)\(typeCorrection); final=\(responseHost) (.\(responseExtension))\(suffix)"
                if !isPlaylist && (actualLength < 8 || (upstreamType.lowercased().hasPrefix("image/png") && !isFMP4)) {
                    self.onActivity?("\(requestLog); rejected=502")
                    self.reply(connection, status: 502, body: Data("Unrecognized or empty HLS media segment".utf8))
                    return
                }
                self.onActivity?(requestLog)
                let responseBody = isPlaylist ? self.rewritePlaylist(data, baseURL: response.url ?? mediaURL) : data
                var responseHeaders: [(String, String)] = [
                    ("Content-Type", contentType),
                    ("Content-Length", String(responseBody.count)),
                    ("Connection", "close"),
                    ("Access-Control-Allow-Origin", "*"),
                    ("Access-Control-Allow-Headers", "Range, Content-Type, Accept"),
                    ("Accept-Ranges", "bytes")
                ]
                for name in ["Content-Range", "Cache-Control", "Last-Modified", "ETag"] {
                    if let value = response.value(forHTTPHeaderField: name) { responseHeaders.append((name, value)) }
                }
                let clientBody = incomingIsHead ? Data() : responseBody
                self.reply(connection, status: response.statusCode, headers: responseHeaders, body: clientBody)
            }.resume()
        }
        fetch(retriesRemaining: 1)
    }

    private func requestKind(for url: URL) -> String {
        playlistLock.lock()
        let isAudio = audioPlaylistURLs.contains(url.absoluteString)
        let isVideo = videoPlaylistURLs.contains(url.absoluteString)
        playlistLock.unlock()
        if isAudio { return "Lydliste" }
        if isVideo { return "Videoliste" }
        if url.pathExtension.lowercased() == "m3u8" { return "HLS-liste" }
        return "Segment"
    }

    private func playlistDetails(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix("#EXTM3U") else { return nil }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let variants = lines.filter { $0.hasPrefix("#EXT-X-STREAM-INF:") }.count
        let audioTracks = lines.filter { $0.hasPrefix("#EXT-X-MEDIA:") && $0.localizedCaseInsensitiveContains("TYPE=AUDIO") }.count
        let segmentExtensions = Set(lines.filter { !$0.isEmpty && !$0.hasPrefix("#") }.compactMap { URL(string: $0)?.pathExtension.lowercased() })
        if variants > 0 { return "hovedliste: \(variants) videovarianter, \(audioTracks) lydspor" }
        if !segmentExtensions.isEmpty { return "segmentformat: \(segmentExtensions.sorted().joined(separator: ", "))" }
        return "HLS-playliste modtaget"
    }

    private func rewritePlaylist(_ data: Data, baseURL: URL) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        let lines = text.components(separatedBy: .newlines).map { line -> String in
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
            if line.hasPrefix("#") {
                guard let regex = try? NSRegularExpression(pattern: #"URI="([^"]+)""#) else { return line }
                let ns = line as NSString
                let matches = regex.matches(in: line, range: NSRange(location: 0, length: ns.length)).reversed()
                var updated = line
                for match in matches where match.numberOfRanges > 1 {
                    let range = match.range(at: 1)
                    let raw = ns.substring(with: range)
                    if let absolute = URL(string: raw, relativeTo: baseURL)?.absoluteURL {
                        updated = (updated as NSString).replacingCharacters(in: range, with: localURL(for: absolute))
                    }
                }
                return updated
            }
            guard let absolute = URL(string: line.trimmingCharacters(in: .whitespaces), relativeTo: baseURL)?.absoluteURL else { return line }
            return localURL(for: absolute)
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    private func localURL(for url: URL) -> String {
        let base = "http://\(hostAddress ?? "127.0.0.1"):\(listenPort ?? 0)/stream/"
        guard let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              url.host != nil, url.user == nil, url.password == nil else { return base + "unavailable" }
        let token = routeLock.withLock {
            if let existing = routeTokens[url] { return existing }
            if routeOrder.count >= 8_192, let oldest = routeOrder.first,
               let removed = mediaRoutes.removeValue(forKey: oldest) {
                routeOrder.removeFirst()
                routeTokens.removeValue(forKey: removed)
            }
            let token = UUID().uuidString.lowercased()
            routeTokens[url] = token
            mediaRoutes[token] = url
            routeOrder.append(token)
            return token
        }
        return base + token
    }

    private func applyCapturedHeaders(to request: inout URLRequest, for url: URL) {
        let exact = capturedHeadersByURL[url.absoluteString]
        let sameHost = exact == nil ? capturedHeadersByURL.first(where: {
            URL(string: $0.key)?.host?.caseInsensitiveCompare(url.host ?? "") == .orderedSame
        })?.value : nil
        let headers = exact ?? sameHost ?? [:]
        let blocked: Set<String> = ["cookie", "host", "content-length", "connection", "transfer-encoding", "accept-encoding", "range", "if-range"]
        for (name, value) in headers {
            let key = name.lowercased()
            guard !blocked.contains(key), !value.contains("\\r"), !value.contains("\\n") else { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    private func cookieHeader(for url: URL) -> String {
        guard let host = url.host?.lowercased() else { return "" }
        let path = url.path.isEmpty ? "/" : url.path
        return cookies.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let matchesHost = host == domain || host.hasSuffix("." + domain)
            let matchesPath = path == cookie.path || path.hasPrefix(cookie.path.hasSuffix("/") ? cookie.path : cookie.path + "/")
            let secureOK = !cookie.isSecure || url.scheme?.lowercased() == "https"
            let notExpired = cookie.expiresDate.map { $0 > Date() } ?? true
            return matchesHost && matchesPath && secureOK && notExpired
        }.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    private func reply(_ connection: NWConnection, status: Int, body: Data) {
        reply(connection, status: status, headers: [("Content-Type", "text/plain; charset=utf-8"), ("Content-Length", String(body.count)), ("Connection", "close")], body: body)
    }

    private func reply(_ connection: NWConnection, status: Int, headers: [(String, String)], body: Data) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 204: reason = "No Content"
        case 206: reason = "Partial Content"
        case 400: reason = "Bad Request"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 416: reason = "Range Not Satisfiable"
        case 502: reason = "Bad Gateway"
        default: reason = "Response"
        }
        let headerText = "HTTP/1.1 \(status) \(reason)\r\n" + headers.map { "\($0.0): \($0.1)\r\n" }.joined() + "\r\n"
        var data = Data(headerText.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func wifiIPv4() -> String? {
        var addressList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addressList) == 0, let first = addressList else { return nil }
        defer { freeifaddrs(addressList) }
        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = item.pointee
            guard String(cString: interface.ifa_name) == "en0", let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let socketAddress = UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr_in.self).pointee
            guard inet_ntop(AF_INET, [socketAddress.sin_addr], &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let value = String(cString: buffer)
            if !value.hasPrefix("127.") { return value }
        }
        return nil
    }

    private enum ProxyError: LocalizedError {
        case noWiFiAddress
        var errorDescription: String? { "Telefonens Wi‑Fi-adresse blev ikke fundet. Kontrollér lokalnetværksadgang." }
    }
}
