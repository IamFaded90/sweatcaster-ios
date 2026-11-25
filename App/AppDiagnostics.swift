import Foundation

enum AppDiagnostics {
    private static let lock = NSLock()
    private static let key = AppStorageKeys.diagnosticsApiV1
    private static let mib: UInt64 = 1_048_576

    @discardableResult
    static func record<E: Error>(_ error: E) -> E {
        let label: String
        switch error {
        case is CancellationError: return error
        case let api as APIError:
            switch api {
            case .http(let status, _): label = "APIError HTTP \(status)"
            case .transport(let code): label = "APIError transport \(code)"
            case .addressLeadingZeros: label = "APIError: Ledende nuller i PC-adressen"
            default: label = "APIError: " + api.title
            }
        case let v2 as V2Failure:
            switch v2 {
            case .http(let status, _, _): label = "V2Failure HTTP \(status)"
            case .invalidInput: label = "V2Failure invalidInput"
            case .invalidResponse: label = "V2Failure invalidResponse"
            case .interrupted: label = "V2Failure interrupted"
            }
        case let network as URLError:
            guard network.code != .cancelled else { return error }
            label = "URLSession \(network.errorCode)"
        case let local as LocalComputeError:
            switch local {
            case .busy: label = "Lokal AI · Optaget — prøv igen, når den aktuelle opgave er færdig"
            case .lowMemory: label = "Lokal AI · For lidt ledig RAM"
            }
        case is DecodingError: label = "JSON: ugyldigt svarformat"
        default: label = "App-fejl · " + String(describing: type(of: error))
        }
        append(label)
        return error
    }

    // Capture the actual preflight sample, rather than measuring again after work has stopped.
    // Only numeric resource readings are stored; never include prompts or error userInfo.
    static func recordLowMemory(requiredMiB: UInt64, availableBytes: UInt64, footprintBytes: UInt64?) {
        let used = footprintBytes.map { "\($0 / mib) MiB" } ?? "ukendt"
        append("Lokal AI · For lidt RAM ved start · krævet \(requiredMiB) MiB · råderum \(availableBytes / mib) MiB · forbrug \(used)")
    }

    private static func append(_ label: String) {
        lock.withLock {
            var entries = UserDefaults.standard.stringArray(forKey: key) ?? []
            let entry = "\(ISO8601DateFormatter().string(from: .now))  \(label)"
            guard entries.last != entry else { return }
            entries.append(entry)
            UserDefaults.standard.set(Array(entries.suffix(50)), forKey: key)
        }
    }

    static func export(phoneModel: String? = nil, pcConnected: Bool? = nil) throws -> URL {
        let available = LocalCompute.headroom
        let used = LocalCompute.footprint().map { "\($0 / mib) MiB" } ?? "ukendt"
        let entries = lock.withLock { UserDefaults.standard.stringArray(forKey: key) ?? [] }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FadedAI-diagnostics", isDirectory: true)
        let url = folder.appendingPathComponent("FadedAI-fejllog.txt")
        var header = ["FadedAI · API-fejllog", "Eksporteret \(ISO8601DateFormatter().string(from: .now))"]
        if let phoneModel { header.append("Telefonmodel · \(phoneModel)") }
        if let pcConnected { header.append(pcConnected ? "PC · Forbundet" : "PC · Ingen aktiv forbindelse") }
        header.append("RAM ved eksport · ikke en måling fra fejltidspunktet")
        header.append("FadedAIs RAM · \(used)")
        header.append("Anslået RAM-råderum · \(available / mib) MiB")
        let content = entries.isEmpty ? "Ingen API-fejl registreret." : entries.joined(separator: "\n")
        let data = Data((header.joined(separator: "\n") + "\n\n" + content + "\n").utf8)
        try LocalFileStore.writeBytes(data, to: url, within: FileManager.default.temporaryDirectory)
        return url
    }
}
