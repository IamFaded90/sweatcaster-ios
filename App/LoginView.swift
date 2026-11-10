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
    private enum ManualField: Equatable { case address, token, connection }

    let model: Model
    let close: (() -> Void)?
    let openLocalChat: () -> Void
    let openLocalStudio: () -> Void
    let openLocalBots: () -> Void
    let exportDiagnostics: () -> Void

    @Environment(\.fadedPalette) private var palette
    @State private var profile: ConnectionProfile
    @State private var address: String
    @State private var token = ""
    @State private var scannedPairing: PairingQRCode?
    @State private var testedQRAddress: String?
    @State private var qrError: String?
    @State private var manualError: (field: ManualField, text: String)?
    @State private var pingNotice: String?
    @State private var manualExpanded = false
    @State private var diagnosticsExpanded = false
    @State private var attemptedConnection = false
    @State private var connecting = false
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
            ScrollView {
                VStack(alignment: .leading, spacing: FadedSpacing.section) {
                    qrSection
                    manualSection
                    if close == nil { phoneSection }
                    diagnosticsSection
                }
                .padding(FadedSpacing.edge)
            }
            .background(FadedBackground())
            .onChange(of: manualExpanded) { _, _ in pingNotice = nil }
            .navigationTitle("Forbind til PC")
            .sheet(isPresented: $scanning) {
                NavigationStack {
                    PairingQRScanner { result in finishScan(result) }
                        .navigationTitle("Scan forbindelseskode")
                        .toolbar { Button("Luk") { scanning = false } }
                }
            }
            .toolbar {
                if let close { Button("Luk", action: close).disabled(connecting || pinging) }
            }
        }
    }

    private var connectionBusy: Bool {
        pinging || connecting || model.busy || model.refreshing || model.mediaLoading || !model.cancelling.isEmpty
    }

    private var manualAddressEmpty: Bool { address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var pingHasAddress: Bool { !manualAddressEmpty || (!manualExpanded && scannedPairing != nil) }

    private var qrSection: some View {
        FadedCard(size: .hero) {
            VStack(alignment: .leading, spacing: FadedSpacing.s) {
                FadedSectionHeader("QR fra din PC", detail: "Åbn forbindelseskoden på din PC, og scan den her.")
                if !manualExpanded { qrStages }
                if let pairing = scannedPairing, !manualExpanded {
                    FadedDetailText("Bekræft forbindelsen til \(pairing.address).")
                    FadedPrimaryButton(connecting ? "Tester forbindelsen…" : "Test og forbind", icon: "network") {
                        Task { await connect(pairing) }
                    }
                    FadedSecondaryButton("Scan en anden QR-kode", icon: "qrcode.viewfinder") { scanQR() }
                } else if manualExpanded {
                    FadedSecondaryButton("Scan QR fra PC’en", icon: "qrcode.viewfinder") { scanQR() }
                } else {
                    FadedPrimaryButton("Scan QR fra PC’en", icon: "qrcode.viewfinder") { scanQR() }
                }
                if let qrError {
                    pairingError(qrError)
                } else if model.refreshing && !connecting {
                    ProgressView("Kontrollerer den gemte forbindelse…")
                } else if !attemptedConnection, !manualExpanded, let error = model.errorTitle {
                    FadedDetailText(error)
                }
            }
        }
        .disabled(connectionBusy)
    }

    private var qrStages: some View {
        let verified = model.connected && !model.isDemo && testedQRAddress == model.address
        let scanned = scannedPairing != nil || verified
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: FadedSpacing.xs) { qrStageBadges(scanned: scanned, verified: verified) }
            VStack(alignment: .leading, spacing: FadedSpacing.xs) { qrStageBadges(scanned: scanned, verified: verified) }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func qrStageBadges(scanned: Bool, verified: Bool) -> some View {
        FadedBadge(scanned ? "QR læst" : "1. Scan", tone: scanned ? .success : .info)
        FadedBadge(scanned ? "Adresse klar" : "2. Adresse", tone: scanned ? .success : .info)
        FadedBadge(verified ? "PC forbundet" : connecting ? "Tester PC" : "3. Test",
                   tone: verified ? .success : .info)
    }

    private var manualSection: some View {
        FadedCard {
            DisclosureGroup(isExpanded: $manualExpanded) {
                VStack(alignment: .leading, spacing: FadedSpacing.section) {
                    Picker("Forbindelse", selection: Binding(get: { profile }, set: { selection in
                        profile = selection
                        address = model.savedAddresses[selection] ?? ""
                        token = ""
                        manualError = nil
                        pingNotice = nil
                    })) {
                        Text("Hjem").tag(ConnectionProfile.home)
                        Text("Tailscale").tag(ConnectionProfile.tailscale)
                    }.pickerStyle(.segmented)
                    VStack(alignment: .leading, spacing: FadedSpacing.xs) {
                        FadedFieldLabel("PC’ens IP-adresse")
                        TextField("PC’ens IP-adresse", text: $address)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            .padding(.horizontal, FadedSpacing.s).frame(minHeight: 44)
                            .background(palette.raised, in: RoundedRectangle(cornerRadius: FadedRadius.small))
                            .onChange(of: address) { _, _ in manualError = nil; pingNotice = nil }
                        if let error = manualError, error.field == .address { pairingError(error.text) }
                    }
                    VStack(alignment: .leading, spacing: FadedSpacing.xs) {
                        FadedFieldLabel("Token fra PC’en")
                        SecureField("Token fra PC’en", text: $token)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .padding(.horizontal, FadedSpacing.s).frame(minHeight: 44)
                            .background(palette.raised, in: RoundedRectangle(cornerRadius: FadedRadius.small))
                            .onChange(of: token) { _, _ in manualError = nil }
                        if let error = manualError, error.field == .token {
                            pairingError(error.text)
                        } else if let saved = model.savedAddresses[profile],
                                  saved == address.trimmingCharacters(in: .whitespacesAndNewlines) {
                            FadedDetailText("Lad tokenfeltet stå tomt for at bruge den gemte adgang.")
                        }
                    }
                    FadedPrimaryButton(connecting ? "Tester forbindelsen…" : "Test og forbind", icon: "network") {
                        Task { await connect() }
                    }.disabled(manualAddressEmpty)
                    if manualAddressEmpty { FadedDetailText("Indtast IP-adressen, der vises på din PC.") }
                    if let error = manualError, error.field == .connection { pairingError(error.text) }
                }.padding(.top, FadedSpacing.s)
            } label: {
                Label("Indtast IP og token manuelt", systemImage: "keyboard")
                    .frame(minHeight: 44, alignment: .leading)
            }
        }.disabled(connectionBusy)
    }

    private var phoneSection: some View {
        FadedCard {
            VStack(alignment: .leading, spacing: FadedSpacing.s) {
                FadedSectionLabel("På telefonen")
                FadedSecondaryButton("Brug telefonen", icon: "iphone", action: openLocalChat)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: FadedSpacing.s) { phoneShortcuts }
                    VStack(alignment: .leading, spacing: FadedSpacing.s) { phoneShortcuts }
                }
            }
        }
    }

    @ViewBuilder private var phoneShortcuts: some View {
        Button("Privat Studio", action: openLocalStudio).frame(minHeight: 44)
        Button("Mine bots", action: openLocalBots).frame(minHeight: 44)
        Button("Prøv demo") { Task { await model.useDemo() } }.frame(minHeight: 44)
            .disabled(connecting || model.busy || model.refreshing)
    }

    private var diagnosticsSection: some View {
        FadedCard {
            DisclosureGroup(isExpanded: $diagnosticsExpanded) {
                VStack(alignment: .leading, spacing: FadedSpacing.s) {
                    FadedSecondaryButton(pinging ? "Tester PC…" : "Ping PC", icon: "network") {
                        Task { await ping() }
                    }.disabled(connectionBusy || !pingHasAddress)
                    if let pingNotice { FadedDetailText(pingNotice) }
                    if !pingHasAddress {
                        FadedDetailText("Indtast IP-adressen, eller scan QR-koden, før du tester.")
                    }
                    if close == nil {
                        ResourceMonitor()
                        Button("Eksportér fejllog", action: exportDiagnostics).frame(minHeight: 44)
                    }
                }.padding(.top, FadedSpacing.s)
            } label: {
                Label("Flere muligheder", systemImage: "wrench.and.screwdriver")
                    .frame(minHeight: 44, alignment: .leading)
            }
        }
    }

    private func pairingError(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle")
            .font(.footnote).foregroundStyle(palette.coralText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func scanQR() {
        Task {
            if await AVCaptureDevice.requestAccess(for: .video) { scanning = true }
            else { qrError = "Giv FadedAI adgang til kameraet i iOS-indstillinger." }
        }
    }

    private func finishScan(_ result: Result<String, Error>) {
        scanning = false
        scannedPairing = nil
        testedQRAddress = nil
        qrError = nil
        pingNotice = nil
        do {
            scannedPairing = try PairingQRSession.accept(result.get())
            manualExpanded = false
        } catch {
            AppDiagnostics.record(error)
            if case .pairingExpired? = error as? APIError {
                qrError = APIError.pairingExpired.title
            } else if case .replay? = error as? PairingQRSession.Failure {
                qrError = "QR-koden er allerede scannet. Lav en ny kode på PC’en."
            } else {
                qrError = "QR-koden er ikke en gyldig FadedAI-forbindelse."
            }
        }
    }

    private func connect(_ pairing: PairingQRCode? = nil) async {
        guard !connectionBusy else { return }
        attemptedConnection = true
        if let expiresAt = pairing?.expiresAt, expiresAt <= .now {
            scannedPairing = nil
            qrError = APIError.pairingExpired.title
            return
        }
        connecting = true
        defer { connecting = false }
        let server: Server
        do { server = try Server(pairing?.address ?? address) }
        catch {
            AppDiagnostics.record(error)
            let title = AppErrorPresentation(error).title
            if pairing != nil { qrError = title }
            else { manualError = (.address, title) }
            return
        }
        if pairing != nil { qrError = nil }
        else {
            manualError = nil
            guard server.profile == profile else {
                manualError = (.address, "Vælg Hjem eller Tailscale, så det passer til IP-adressen.")
                return
            }
        }
        await model.saveProfile(server.profile, address: server.address, token: pairing?.token ?? token,
                                pairingExpiresAt: pairing?.expiresAt)
        guard !Task.isCancelled else { return }
        if let error = model.errorTitle {
            if pairing != nil {
                if case .pairingExpired? = model.error { scannedPairing = nil }
                qrError = error
            } else {
                switch model.error {
                case .token?, .http(401, _)?: manualError = (.token, error)
                default: manualError = (.connection, error)
                }
            }
            return
        }
        if model.connected && !model.isDemo {
            if pairing != nil && model.address == server.address { testedQRAddress = server.address }
            token = ""
            scannedPairing = nil
            close?()
        }
    }

    private func ping() async {
        guard !connectionBusy else { return }
        pinging = true
        pingNotice = nil
        defer { pinging = false }
        do {
            let pairing = manualExpanded ? nil : scannedPairing
            let server = try Server(pairing?.address ?? address)
            guard pairing != nil || server.profile == profile else {
                pingNotice = "Vælg Hjem eller Tailscale, så det passer til IP-adressen."
                return
            }
            let ms = try await Model.probe(server)
            pingNotice = "PC’en svarer · \(ms) ms. Tryk Test og forbind."
        } catch let error as APIError {
            AppDiagnostics.record(error)
            pingNotice = AppErrorPresentation(error).title
        } catch {
            AppDiagnostics.record(error)
            pingNotice = "PC’en svarer ikke. Tjek IP-adressen, Wi-Fi eller Tailscale."
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
