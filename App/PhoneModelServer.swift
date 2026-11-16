import Darwin
import Foundation
import Network
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor @Observable private final class PhoneModelServer {
    private(set) var address: String?
    private(set) var token: String?
    private(set) var notice: String?
    private(set) var listening = false
    private var listener: NWListener?
    private var clients: [UUID: NWConnection] = [:]
    private var generation: Task<Void, Never>?
    private var model = ""
    private let wakeID = UUID()

    func start(model: String) {
        guard listener == nil, PhoneModels.isReady(model) else { return }
        guard let ip = Self.wifiAddress() else { notice = "Forbind iPhone til Wi-Fi først."; return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .wifi
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(ip), port: .any)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            self.model = model
            token = UUID().uuidString.lowercased() + UUID().uuidString.lowercased()
            listening = true
            notice = nil
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        if let port = listener.port { self.address = "http://\(ip):\(port.rawValue)/v1" }
                    case .failed:
                        self.stop()
                        self.notice = "Forbindelsen på lokalt netværk kunne ikke startes."
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: .main)
        } catch {
            notice = "Modellen kunne ikke gøres tilgængelig på Wi-Fi."
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        clients.values.forEach { $0.cancel() }
        clients.removeAll()
        generation?.cancel()
        ChatScreenWake.hold(wakeID, whileReplying: false)
        address = nil
        token = nil
        listening = false
    }

    private func accept(_ connection: NWConnection) {
        guard listening, clients.count < 3 else { connection.cancel(); return }
        let id = UUID()
        clients[id] = connection
        connection.start(queue: .main)
        receive(id, buffer: Data())
        Task {
            try? await Task.sleep(for: .seconds(95))
            if let expired = clients.removeValue(forKey: id) { expired.cancel() }
        }
    }

    private func receive(_ id: UUID, buffer: Data) {
        guard let connection = clients[id] else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, finished, error in
            Task { @MainActor in
                guard let self, self.clients[id] != nil else { return }
                var bytes = buffer
                if let data { bytes.append(data) }
                guard bytes.count <= 24_000, error == nil else { self.respond(id, status: "400 Bad Request"); return }
                if self.process(id, bytes: bytes) { return }
                if finished { self.respond(id, status: "400 Bad Request") }
                else { self.receive(id, buffer: bytes) }
            }
        }
    }

    private struct Input: Decodable {
        struct Message: Decodable { let role: String; let content: String }
        let messages: [Message]
        let stream: Bool?
    }

    private func process(_ id: UUID, bytes: Data) -> Bool {
        guard let separator = bytes.range(of: Data("\r\n\r\n".utf8)) else { return false }
        guard let header = String(data: bytes[..<separator.lowerBound], encoding: .utf8),
              let token else { respond(id, status: "400 Bad Request"); return true }
        let lines = header.components(separatedBy: "\r\n")
        let fields = Dictionary(lines.dropFirst().compactMap { line -> (String, String)? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (line[..<colon].lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }, uniquingKeysWith: { first, _ in first })
        guard fields["authorization"] == "Bearer " + token else { respond(id, status: "401 Unauthorized"); return true }
        let path = lines.first?.split(separator: " ").prefix(2).joined(separator: " ")
        if path == "GET /v1/models" {
            respond(id, payload: ["object": "list", "data": [["id": "fadedai-phone", "object": "model"]]])
            return true
        }
        guard path == "POST /v1/chat/completions" else { respond(id, status: "404 Not Found"); return true }
        guard fields["transfer-encoding"] == nil, let raw = fields["content-length"],
              let length = Int(raw), (1...16_000).contains(length) else {
            respond(id, status: "400 Bad Request"); return true
        }
        let body = bytes[separator.upperBound...]
        guard body.count >= length else { return false }
        guard body.count == length, let input = try? JSONDecoder().decode(Input.self, from: Data(body)),
              input.stream != true, input.messages.count <= 12, let last = input.messages.last, last.role == "user",
              input.messages.allSatisfy({ ["user", "assistant", "system"].contains($0.role) }),
              (1...2_000).contains(last.content.unicodeScalars.count) else {
            respond(id, status: "400 Bad Request"); return true
        }
        guard generation == nil else { respond(id, status: "429 Too Many Requests"); return true }
        let configured = model
        let previous = input.messages.dropLast().suffix(6).map {
            "\($0.role): " + String($0.content.prefix(260))
        }.joined(separator: "\n")
        let prompt = previous.isEmpty ? last.content : previous + "\n\nuser: " + last.content
        ChatScreenWake.hold(wakeID, whileReplying: true)
        generation = Task {
            defer {
                generation = nil
                ChatScreenWake.hold(wakeID, whileReplying: false)
            }
            do {
                var answer = ""
                try await PhoneModels.reply(modelID: configured, prompt: prompt) { answer = $0 }
                try Task.checkCancellation()
                respond(id, payload: [
                    "id": "chatcmpl-" + id.uuidString, "object": "chat.completion", "model": "fadedai-phone",
                    "created": Int(Date.now.timeIntervalSince1970),
                    "choices": [["index": 0, "finish_reason": "stop", "message": ["role": "assistant", "content": answer]]]
                ])
            } catch { respond(id, status: "503 Service Unavailable") }
        }
        return true
    }

    private func respond(_ id: UUID, status: String = "200 OK", payload: [String: Any] = ["error": "request unavailable"]) {
        guard let connection = clients.removeValue(forKey: id) else { return }
        let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        var message = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        message.append(body)
        connection.send(content: message, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func wifiAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(first) }
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let item = pointer {
            pointer = item.pointee.ifa_next
            guard String(cString: item.pointee.ifa_name) == "en0", let address = item.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }
}

@MainActor struct PhoneModelServerScreen: View {
    @Environment(\.scenePhase) private var phase
    @State private var server = PhoneModelServer()
    @AppStorage(AppStorageKeys.phoneModel) private var preferred = "apple"
    @State private var selected = ""

    var body: some View {
        Form {
            Picker("Telefonmodel", selection: $selected) {
                Text("Vælg model").tag("")
                ForEach(PhoneModels.textOptions.filter { PhoneModels.isReady($0.id) }) { model in
                    Text(model.name).tag(model.id)
                }
            }
            .disabled(server.listening)
            Text("En anden enhed på dit Wi-Fi kan bruge modellen, mens denne side er åben. Del kun koden med et værktøj, du selv vil forbinde.")
            if server.listening {
                Button("Stop deling", role: .destructive) { server.stop() }
                if let address = server.address, let token = server.token {
                    LabeledContent("Adresse", value: address).textSelection(.enabled)
                    Button("Kopiér adresse") { UIPasteboard.general.string = address }
                    Button("Kopiér adgangskode") {
                        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: token]], options: [.localOnly: true])
                    }
                    FadedDetailText("OpenAI-kompatibel klient · Modelnavn fadedai-phone")
                } else { ProgressView("Forbinder til Wi-Fi…") }
            } else {
                Button("Start deling på Wi-Fi") { server.start(model: selected) }
                    .disabled(selected.isEmpty)
            }
            if let notice = server.notice { FadedDetailText(notice) }
        }
        .navigationTitle("Del iPhone-modellen")
        .onAppear { if PhoneModels.isReady(preferred) { selected = preferred } }
        .onDisappear { server.stop() }
        .onChange(of: phase) { if phase != .active { server.stop() } }
    }
}
