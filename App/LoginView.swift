// Manual PC pairing and time-limited QR scanning.
import AVFoundation
import SwiftUI
import UIKit

struct PairingQRCode: Decodable {
    let version: Int
    let address: String
    let token: String
    let expiresAt: Date?
    let nonce: String?

    // Parsing validates the wire format. Scans must also pass PairingQRSession.accept.
    static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= 2_048,
              let payload = try? contractDecoder().decode(Self.self, from: Data(text.utf8)),
              payload.version == 1,
              !payload.token.isEmpty, payload.token.utf8.count <= 512,
              payload.nonce?.isEmpty != true,
              payload.token.utf8.allSatisfy({ (33...126).contains($0) }) else { throw APIError.input }
        let server = try Server(payload.address)
        return Self(version: 1, address: server.address, token: payload.token,
                    expiresAt: payload.expiresAt, nonce: payload.nonce)
    }
}

@MainActor enum PairingQRSession {
    enum Failure: Error { case replay }

    private static var scannedNonces: Set<String> = []

    static func accept(_ text: String, now: Date = .now) throws -> PairingQRCode {
        let payload = try PairingQRCode.parse(text)
        guard let expiresAt = payload.expiresAt, expiresAt > now else { throw APIError.pairingExpired }
        if let nonce = payload.nonce, !scannedNonces.insert(nonce).inserted {
            throw Failure.replay
        }
        return payload
    }
}

struct LoginView: View {
    let model: Model
    let close: (() -> Void)?
    let openLocalChat: () -> Void
    let openLocalStudio: () -> Void
    let openLocalBots: () -> Void
    let exportDiagnostics: () -> Void

    @State private var profile: ConnectionProfile
    @State private var address: String
    @State private var token = ""
    @State private var scannedExpiry: Date?
    @State private var connecting = false
    @State private var message: String?
    @State private var scanning = false
    @State private var pinging = false

    init(model: Model, close: (() -> Void)? = nil,
         openLocalChat: @escaping () -> Void = {}, openLocalStudio: @escaping () -> Void = {},
         openLocalBots: @escaping () -> Void = {},
         exportDiagnostics: @escaping () -> Void = {}) {
        self.model = model
        self.close = close
        self.openLocalChat = openLocalChat
        self.openLocalStudio = openLocalStudio
        self.openLocalBots = openLocalBots
        self.exportDiagnostics = exportDiagnostics
        _profile = State(initialValue: model.activeProfile)
        _address = State(initialValue: model.savedAddresses[model.activeProfile] ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Forbindelse til din PC") {
                    Picker("Forbindelse", selection: Binding(get: { profile }, set: { selection in
                        profile = selection
                        address = model.savedAddresses[selection] ?? ""
                        token = ""
                        scannedExpiry = nil
                        message = nil
                    })) {
                        Text("Hjem").tag(ConnectionProfile.home)
                        Text("Tailscale").tag(ConnectionProfile.tailscale)
                    }
                    .pickerStyle(.segmented)
                    TextField("PC’ens IP-adresse", text: $address)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .frame(minHeight: 44)
                        .disabled(scannedExpiry != nil)
                    SecureField("Token fra PC’en", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .frame(minHeight: 44)
                        .disabled(scannedExpiry != nil)
                    if scannedExpiry != nil {
                        Button("Indtast IP og token manuelt") {
                            clearScannedPairing()
                            message = nil
                        }.frame(minHeight: 44)
                    } else if let saved = model.savedAddresses[profile], saved == address.trimmingCharacters(in: .whitespacesAndNewlines) {
                        Text("Lad tokenfeltet stå tomt for at bruge den gemte adgang.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    FadedPrimaryButton(connecting ? "Tester forbindelsen…" : "Test og forbind", icon: "network") {
                        Task { await connect() }
                    }
                    .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Indtast PC’ens IP, eller scan QR-koden.").font(.caption).foregroundStyle(.secondary)
                    }
                    FadedSecondaryButton(pinging ? "Tester PC…" : "Ping PC", icon: "network") {
                        Task { await ping() }
                    }
                    .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Scan QR fra PC’en", systemImage: "qrcode.viewfinder") {
                        Task {
                            if await AVCaptureDevice.requestAccess(for: .video) { scanning = true }
                            else { message = "Giv FadedAI adgang til kameraet i iOS-indstillinger." }
                        }
                    }.frame(minHeight: 44)
                    if model.refreshing { ProgressView("Kontrollerer den gemte forbindelse…") }
                    if let error = message ?? model.errorTitle { Text(error).foregroundStyle(.secondary) }
                }.disabled(pinging || connecting || model.busy || model.refreshing || model.mediaLoading || !model.cancelling.isEmpty)
                if close == nil {
                    Section("På telefonen") {
                        Button("Åbn lokal chat", action: openLocalChat).frame(minHeight: 44)
                        Button("Privat Studio", action: openLocalStudio).frame(minHeight: 44)
                        Button("Mine bots", action: openLocalBots).frame(minHeight: 44)
                        Button("Prøv demo") { Task { await model.useDemo() } }.frame(minHeight: 44)
                            .disabled(connecting || model.busy || model.refreshing)
                    }
                    Section("Fejlfinding") {
                        ResourceMonitor()
                        Button("Eksportér fejllog", action: exportDiagnostics).frame(minHeight: 44)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(FadedBackground())
            .navigationTitle("Forbind til PC")
            .sheet(isPresented: $scanning) {
                NavigationStack {
                    PairingQRScanner { result in
                        scanning = false
                        clearScannedPairing()
                        do {
                            let payload = try PairingQRSession.accept(result.get())
                            profile = try Server(payload.address).profile
                            address = payload.address
                            token = payload.token
                            scannedExpiry = payload.expiresAt
                            message = "QR læst. Tryk Test og Forbind."
                        } catch {
                            AppDiagnostics.record(error)
                            if case .pairingExpired? = error as? APIError {
                                message = APIError.pairingExpired.title
                            } else if case .replay? = error as? PairingQRSession.Failure {
                                message = "QR-koden er allerede scannet. Lav en ny kode på PC’en."
                            } else {
                                message = "QR-koden er ikke en gyldig FadedAI-forbindelse."
                            }
                        }
                    }
                    .navigationTitle("Scan forbindelseskode")
                    .toolbar { Button("Luk") { scanning = false } }
                }
            }
            .toolbar {
                if let close { Button("Luk", action: close).disabled(connecting || pinging) }
            }
        }
    }

    private func connect() async {
        guard !connecting else { return }
        if let scannedExpiry, scannedExpiry <= .now {
            clearScannedPairing()
            message = APIError.pairingExpired.title
            return
        }
        connecting = true
        message = nil
        defer { connecting = false }
        await model.saveProfile(profile, address: address, token: token, pairingExpiresAt: scannedExpiry)
        guard !Task.isCancelled else { return }
        if case .pairingExpired? = model.error { clearScannedPairing() }
        if let error = model.errorTitle { message = error; return }
        if model.connected && !model.isDemo {
            token = ""
            scannedExpiry = nil
            close?()
        }
    }

    private func clearScannedPairing() {
        guard scannedExpiry != nil else { return }
        scannedExpiry = nil
        token = ""
    }

    private func ping() async {
        guard !pinging else { return }
        pinging = true
        message = nil
        defer { pinging = false }
        do {
            let server = try Server(address)
            guard server.profile == profile else {
                message = "Vælg Hjem eller Tailscale, så det passer til IP-adressen."
                return
            }
            let ms = try await Model.probe(server)
            message = "PC’en svarer · \(ms) ms. Tryk Test og forbind."
        } catch let error as APIError {
            AppDiagnostics.record(error)
            message = AppErrorPresentation(error).title
        } catch {
            AppDiagnostics.record(error)
            message = "PC’en svarer ikke. Tjek IP-adressen, Wi-Fi eller Tailscale."
        }
    }
}

private struct PairingQRScanner: UIViewRepresentable {
    let finish: (Result<String, Error>) -> Void

    final class Preview: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var captureLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let session = AVCaptureSession()
        let queue = DispatchQueue(label: "dk.fadedai.pairing-camera")
        let finish: (Result<String, Error>) -> Void
        private var delivered = false

        init(finish: @escaping (Result<String, Error>) -> Void) { self.finish = finish }

        func start() {
            queue.async {
                do {
                    guard let camera = AVCaptureDevice.default(for: .video) else { throw APIError.input }
                    let input = try AVCaptureDeviceInput(device: camera)
                    let output = AVCaptureMetadataOutput()
                    guard self.session.canAddInput(input), self.session.canAddOutput(output) else { throw APIError.input }
                    self.session.addInput(input)
                    self.session.addOutput(output)
                    guard output.availableMetadataObjectTypes.contains(.qr) else { throw APIError.input }
                    output.setMetadataObjectsDelegate(self, queue: .main)
                    output.metadataObjectTypes = [.qr]
                    self.session.startRunning()
                } catch { AppDiagnostics.record(error); DispatchQueue.main.async { self.deliver(.failure(error)) } }
            }
        }

        func cancel() {
            delivered = true
            stop()
        }

        private func stop() { queue.async { if self.session.isRunning { self.session.stopRunning() } } }

        private func deliver(_ result: Result<String, Error>) {
            guard !delivered else { return }
            delivered = true
            stop()
            finish(result)
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            if let value = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue {
                deliver(.success(value))
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(finish: finish) }

    func makeUIView(context: Context) -> Preview {
        let view = Preview()
        view.captureLayer.session = context.coordinator.session
        view.captureLayer.videoGravity = .resizeAspectFill
        context.coordinator.start()
        return view
    }

    func updateUIView(_ uiView: Preview, context: Context) {}
    static func dismantleUIView(_ uiView: Preview, coordinator: Coordinator) { coordinator.cancel() }
}
