import AVFAudio
import Security
import SwiftUI

struct ChristelConfiguration: Codable, Sendable {
    let region: String
    let key: String

    static let voice = "da-DK-ChristelNeural"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dk.fadedai.azure-speech",
         kSecAttrAccount as String: voice]
    }

    var valid: Bool {
        (2...30).contains(region.utf8.count) &&
            region.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) } &&
            (1...512).contains(key.utf8.count) && key.utf8.allSatisfy { (33...126).contains($0) }
    }

    static func load() -> Self? {
        var filter = query
        filter[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(filter as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let config = try? JSONDecoder().decode(Self.self, from: data), config.valid else { return nil }
        return config
    }

    func save() throws {
        guard valid else { throw APIError.input }
        let data = try JSONEncoder().encode(self)
        let status = SecItemUpdate(Self.query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status != errSecSuccess else { return }
        guard status == errSecItemNotFound else { throw APIError.storage }
        var item = Self.query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw APIError.storage }
    }

    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw APIError.storage }
    }
}

enum ChristelSpeech {
    static func markup(_ text: String) -> String {
        let clean = text.unicodeScalars.filter {
            $0.value == 9 || $0.value == 10 || $0.value == 13 ||
                (32...0xD7FF).contains($0.value) || (0xE000...0xFFFD).contains($0.value) ||
                (0x10000...0x10FFFF).contains($0.value)
        }
        let escaped = String(String.UnicodeScalarView(clean))
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xml:lang="da-DK"><voice name="\(ChristelConfiguration.voice)">\(escaped)</voice></speak>
        """
    }

    static func audio(for text: String, configuration: ChristelConfiguration) async throws -> Data {
        guard configuration.valid, (1...8_000).contains(text.utf8.count),
              let url = URL(string: "https://\(configuration.region).tts.speech.microsoft.com/cognitiveservices/v1")
        else { throw APIError.input }
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.httpMethod = "POST"
        request.httpBody = Data(markup(text).utf8)
        request.setValue(configuration.key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue("application/ssml+xml", forHTTPHeaderField: "Content-Type")
        request.setValue("audio-24khz-48kbitrate-mono-mp3", forHTTPHeaderField: "X-Microsoft-OutputFormat")
        request.setValue("FadedAI", forHTTPHeaderField: "User-Agent")

        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForResource = 35
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let mime = response.mimeType, ["audio/mpeg", "audio/mp3"].contains(mime),
              response.expectedContentLength <= 2_000_000 else { throw APIError.malformed }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 2_000_000 else { throw APIError.malformed }
            data.append(byte)
        }
        guard !data.isEmpty else { throw APIError.malformed }
        return data
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

@MainActor final class ChristelPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var loading = false
    @Published private(set) var playing = false
    @Published private(set) var notice: String?
    private var player: AVAudioPlayer?
    private var pending: Task<Void, Never>?
    private var run = UUID()
    private var sessionActive = false

    func play(text: String, pc: LiveAPI?) {
        stop()
        let configuration = ChristelConfiguration.load()
        guard configuration != nil || pc != nil else {
            notice = "Forbind Christel med Microsoft Speech først."
            return
        }
        guard (1...8_000).contains(text.utf8.count) else {
            notice = "Vælg oplæsning på iPhone til dette lange svar."
            return
        }
        let current = run
        loading = true
        pending = Task {
            defer {
                if current == run {
                    loading = false
                    pending = nil
                }
            }
            do {
                let audio: Data
                if let configuration {
                    audio = try await ChristelSpeech.audio(for: text, configuration: configuration)
                } else if let pc {
                    audio = try await pc.christelAudio(text)
                } else {
                    throw APIError.input
                }
                try Task.checkCancellation()
                guard current == run else { return }
                let audioPlayer = try AVAudioPlayer(data: audio)
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .spokenAudio)
                try session.setActive(true)
                sessionActive = true
                audioPlayer.delegate = self
                player = audioPlayer
                guard audioPlayer.play() else { throw APIError.malformed }
                playing = true
            } catch {
                guard !Task.isCancelled, current == run else { return }
                stop()
                if case APIError.http(_, let problem) = error, let message = problem?.message {
                    notice = message
                } else {
                    notice = "Christel kunne ikke læse op. Tjek forbindelsen til Microsoft Speech."
                }
            }
        }
    }

    func stop() {
        run = UUID()
        pending?.cancel()
        pending = nil
        loading = false
        playing = false
        notice = nil
        player?.stop()
        player = nil
        if sessionActive {
            sessionActive = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, let current = self.player, ObjectIdentifier(current) == identity else { return }
            self.stop()
        }
    }
}

struct ChristelSettingsView: View {
    let pcReady: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var region = ""
    @State private var key = ""
    @State private var existing = false
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Christel · dansk kvindestemme") {
                    Text("Når du trykker Læs med Christel, sendes kun det valgte svar til Microsoft for oplæsning.")
                        .font(.footnote)
                    if pcReady {
                        Label("Christel er klar via din PC.", systemImage: "checkmark.circle")
                    } else {
                        Text("Vælg Forbind Christel i FadedAI-opdateringen på PC’en for at bruge din eksisterende Azure Speech-ressource.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("Tilslut direkte fra iPhone") {
                    TextField("Region, fx westeurope", text: $region)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Microsoft Speech-nøgle", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if existing { Text("Der er en nøgle gemt på iPhone.").foregroundStyle(.secondary) }
                    if let docs = URL(string: "https://learn.microsoft.com/da-dk/azure/ai-services/speech-service/get-started-text-to-speech") {
                        Link("Sådan finder du nøgle og region", destination: docs)
                    }
                }
                Button("Gem Christel") {
                    do {
                        try configuration.save()
                        key = ""
                        dismiss()
                    } catch {
                        notice = "Christel-indstillingerne kunne ikke gemmes."
                    }
                }
                .disabled(!configuration.valid)
                if existing {
                    Button("Fjern den gemte nøgle", role: .destructive) {
                        do {
                            try ChristelConfiguration.remove()
                            key = ""
                            dismiss()
                        } catch {
                            notice = "Nøglen kunne ikke fjernes."
                        }
                    }
                }
                if let notice { Text(notice).foregroundStyle(.secondary) }
            }
            .navigationTitle("Stemme til Lumi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Luk") { dismiss() } }
            }
            .onAppear {
                let saved = ChristelConfiguration.load()
                region = saved?.region ?? ""
                existing = saved != nil
            }
        }
        .privacySensitive()
    }

    private var configuration: ChristelConfiguration {
        ChristelConfiguration(region: region.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                               key: key.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
