// CPU-only offline end-to-end fixture: FADEDAI_RANGE_TESTS is mandatory.
// The fixture serves verified local model byte ranges through URLProtocol.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class VerifiedModelFixture: URLProtocol {
    private static let lock = NSLock()
    private static var paused = true
    private static var entered = false
    private static var requests = 0
    private let stateLock = NSLock()
    private var stopped = false

    static func snapshot() -> (Bool, Int) { lock.lock(); defer { lock.unlock() }; return (entered, requests) }
    static func resume() { lock.lock(); paused = false; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { stateLock.lock(); stopped = true; stateLock.unlock() }
    override func startLoading() {
        do {
            guard let url = request.url, let text = request.value(forHTTPHeaderField: "Range"), text.hasPrefix("bytes=") else {
                throw URLError(.badURL)
            }
            let pair = text.dropFirst(6).split(separator: "-")
            guard pair.count == 2, let start = Int64(pair[0]), let end = Int64(pair[1]), end >= start else {
                throw URLError(.badServerResponse)
            }
            let vae = url.path.contains("/vae/")
            let name = vae ? "vae" : "tokenizer"
            let rangeStart: Int64 = vae ? 168_868_700 : 4_577_761_208
            let total: Int64 = vae ? 337_431_388 : 4_787_825_604
            let etag = vae ? "\"e8d754cd5cb69cf864a2d44a61b39bf61354ebac7fc70680bbfdb8ed49b1bc8b\""
                           : "\"077d06c5a16c9f9ff327389b66b0dd355fe3b8f7ad2777ef6767cbd9022d2a7c\""
            guard request.value(forHTTPHeaderField: "If-Range") == etag else { throw URLError(.badServerResponse) }
            let isHeader = start == 0
            let file = URL(fileURLWithPath: "/work/\(name)-\(isHeader ? "header" : "range")")
            let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
            try input.seek(toOffset: UInt64(isHeader ? start : start - rangeStart))
            guard let bytes = try input.read(upToCount: Int(end - start + 1)), bytes.count == Int(end - start + 1) else {
                throw URLError(.cannotDecodeContentData)
            }
            Self.lock.lock(); Self.requests += 1; Self.entered = true; let wait = Self.paused; Self.lock.unlock()
            let response = HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1",
                                           headerFields: ["ETag": etag, "Content-Range": "bytes \(start)-\(end)/\(total)"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if wait { Thread.sleep(forTimeInterval: 1) }
            stateLock.lock(); let wasStopped = stopped; stateLock.unlock()
            if !wasStopped { client?.urlProtocol(self, didLoad: bytes); client?.urlProtocolDidFinishLoading(self) }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

@main
private struct PhoneSongReferenceEndToEndChecks {
    static func main() async throws {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fatalError("No app support directory")
        }
        let base = support.appendingPathComponent("FadedAI/OfflineSongs", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let sentinel = base.appendingPathComponent("existing-text-model.keep")
        try Data("preserve".utf8).write(to: sentinel, options: .withoutOverwriting)
        let models = PhoneSongReferenceModels.shared
        await models.setFixtureProtocolClasses([VerifiedModelFixture.self])
        let cancelled = Task { try await models.prepare(at: base) { _ in } }
        var entered = false
        for _ in 0..<200 {
            if VerifiedModelFixture.snapshot().0 { entered = true; break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard entered else { cancelled.cancel(); fatalError("Fixture did not start") }
        await models.cancel()
        do { try await cancelled.value; fatalError("Cancelled preparation completed") }
        catch is CancellationError { }
        switch await models.status(at: base) { case .notInstalled: break; default: fatalError("Cancelled install became ready") }
        VerifiedModelFixture.resume()
        try await models.prepare(at: base) { _ in }
        switch await models.status(at: base) { case .ready: break; default: fatalError("Prepared weights not ready") }
        let directory = try await models.preparedDirectory(at: base)
        for name in ["ace_vae_encoder_f16.safetensors", "ace_audio_tokenizer_bf16.safetensors"] {
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) else {
                fatalError("Missing prepared file: \(name)")
            }
        }
        let countBefore = VerifiedModelFixture.snapshot().1
        try await models.prepare(at: base) { _ in }
        guard VerifiedModelFixture.snapshot().1 == countBefore else { fatalError("Ready model downloaded again") }
        try await models.remove(at: base)
        switch await models.status(at: base) { case .notInstalled: break; default: fatalError("Removed weights still ready") }
        guard try Data(contentsOf: sentinel) == Data("preserve".utf8) else { fatalError("Existing song model changed") }
        print("PASS: full local prepare, cancel/resume, integrity/status, reuse and separate removal")
        print("Real pinned model ranges served locally; Linux Swift only, not iPhone/audio generation")
    }
}
