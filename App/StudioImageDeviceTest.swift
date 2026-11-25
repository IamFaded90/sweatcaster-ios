import Foundation
import Observation
import SwiftUI
import UIKit

@MainActor struct StudioImageTestButton: View {
    let model: StudioImageModel
    @State private var showingTest = false

    var body: some View {
        let history = StudioImageProbeHistory.shared
        if let last = history.record(model: model.id, pair: false) {
            FadedDetailText(last.summary(pair: false))
        } else {
            FadedDetailText("Lav et prøvebillede for at se, om denne iPhone kan køre modellen.")
        }
        if model == .fluxKlein, let pair = history.record(model: model.id, pair: true) {
            FadedDetailText(pair.summary(pair: true))
        }
        FadedSecondaryButton("Lav prøvebillede på iPhone", icon: "iphone") { showingTest = true }
            .sheet(isPresented: $showingTest) { StudioImageTestView(model: model) }
    }
}

@MainActor private struct StudioImageTestView: View {
    let model: StudioImageModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @AppStorage(AppStorageKeys.offlineStudioImageBatteryProtection) private var protectBattery = true
    @State private var attempt: UUID? = UUID()
    @State private var result: UIImage?
    @State private var message = ""
    @State private var testingPair = false
    @State private var showingPair = false
    @State private var pairVerified = false
    @State private var pairSeed: UInt32 = 42
    @State private var memoryReading: StudioImageMemoryReading?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FadedSpacing.m) {
                    Label(model.title, systemImage: "iphone").font(.headline)
                    if let result {
                        Image(uiImage: result).resizable().scaledToFit()
                            .accessibilityLabel(showingPair ? "Resultat med to referencebilleder" : "Prøve med et rødt æble")
                    }
                    if attempt != nil {
                        ProgressView(testingPair ? "Telefonen kombinerer to testbilleder…" : "Telefonen laver et prøvebillede af et rødt æble…")
                    }
                    if !message.isEmpty { Text(message).accessibilityAddTraits(.updatesFrequently) }
                    if let memoryReading {
                        StudioImageMemoryDetails(reading: memoryReading) {
                            self.memoryReading = StudioImageMemoryReading(model: model)
                        }
                    }
                    if model == .fluxKlein, result != nil {
                        FadedDetailText("Prøven leder efter en rød cirkel fra det første foto til venstre og en blå firkant fra det andet til højre.")
                        if attempt == nil && !pairVerified {
                            FadedSecondaryButton(showingPair ? "Prøv med to fotos igen" : "Prøv med to fotos på iPhone", icon: "photo.on.rectangle") {
                                if showingPair { pairSeed = UInt32.random(in: 43 ... .max) }
                                testingPair = true
                                message = ""
                                attempt = UUID()
                            }
                        }
                    }
                    if attempt == nil && result == nil {
                        FadedSecondaryButton("Prøv igen", icon: "arrow.clockwise") {
                            message = ""
                            attempt = UUID()
                        }
                    }
                }
                .padding(FadedSpacing.edge).frame(maxWidth: 640).frame(maxWidth: .infinity)
            }
            .background { FadedBackground() }
            .navigationTitle("Prøve på denne iPhone").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Luk") { dismiss() } }
            .task(id: attempt) { if let id = attempt { await run(id) } }
            .onChange(of: phase) { _, phase in
                if phase == .background && attempt != nil {
                    attempt = nil
                    message = "Prøven blev afbrudt, da appen gik i baggrunden."
                }
            }
        }
    }

    private func run(_ id: UUID) async {
        let start = ContinuousClock.now
        let pair = testingPair
        let seed = pairSeed
        guard !Task.isCancelled, attempt == id, phase != .background else { return }
        memoryReading = nil
        defer { if attempt == id { attempt = nil } }
        let history = StudioImageProbeHistory.shared
        history.begin(id, model: model.id, pair: pair)
        do {
            let bytes = try await StudioImageGeneration.whileDeviceReady(model: model, protectBattery: protectBattery) { [model] in
                if pair {
                    return try await StudioImageGeneration.render(
                        model: model, prompt: "Place the object from image one on the left and the object from image two on the right. Keep their shapes and colors on a plain white background.",
                        seed: seed, source: Self.testPhoto(circle: true), referenceMode: .edit,
                        secondReference: Self.testPhoto(circle: false))
                }
                return try await StudioImageGeneration.render(model: model, prompt: "A red apple on a light table", seed: 42)
            }
            guard let bytes, let image = UIImage(data: bytes), let raster = image.cgImage else {
                throw PhoneModelError.emptyResponse
            }
            guard !Task.isCancelled, attempt == id else { return }
            let time = start.duration(to: .now).components
            let seconds = Double(time.seconds) + Double(time.attoseconds) / 1e18
            result = image
            showingPair = pair
            if pair {
                pairVerified = StudioImagePairColors.matches(raster)
                guard pairVerified else {
                    message = "Prøven kunne ikke genkende den røde cirkel til venstre og den blå firkant til højre. Se billedet, eller prøv igen."
                    return
                }
            }
            history.finish(id, model: model.id, pair: pair, width: raster.width, height: raster.height, seconds: seconds)
            let title = pair ? "Begge figurer genkendt på denne iPhone" : "Lavet på denne iPhone"
            message = "\(title) · \(raster.width) × \(raster.height) · \(seconds.formatted(.number.precision(.fractionLength(1)))) sek."
        } catch {
            guard !Task.isCancelled, attempt == id else { return }
            switch error {
            case LocalComputeError.lowMemory:
                memoryReading = StudioImageMemoryReading(model: model)
                message = "Prøven blev stoppet, fordi FadedAI havde for lidt ledig RAM til modellen."
            case LocalComputeError.busy: message = "En anden lokal opgave kører. Prøv igen, når den er færdig."
            case StudioImageInterruption.battery: message = "Sæt telefonen til opladning, og prøv igen."
            case StudioImageInterruption.heat: message = "Lad telefonen køle af, og prøv igen."
            case is CancellationError: message = "Prøven blev afbrudt. Prøv igen med FadedAI åben."
            case PhoneModelError.unavailable: message = "Hent modellen under Lokale modeller → Billeder først."
            default: message = "Modellen kunne ikke lave prøvebilledet på denne iPhone."
            }
        }
    }

    private static func testPhoto(circle: Bool) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: format).pngData { renderer in
            let canvas = renderer.cgContext
            canvas.setFillColor(UIColor.white.cgColor)
            canvas.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            let bounds = CGRect(x: 56, y: 56, width: 144, height: 144)
            canvas.setFillColor(circle ? UIColor.red.cgColor : UIColor.blue.cgColor)
            if circle { canvas.fillEllipse(in: bounds) } else { canvas.fill(bounds) }
        }
    }
}

private struct StudioImageMemoryReading {
    let required: UInt64
    let available: UInt64
    let footprint: UInt64?

    @MainActor init(model: StudioImageModel) {
        required = model.minimumWorkingMemoryMiB * 1_048_576
        available = LocalCompute.headroom
        footprint = LocalCompute.footprint()
    }

    func label(_ bytes: UInt64) -> String {
        (Double(bytes) / 1_000_000_000).formatted(.number.precision(.fractionLength(2))) + " GB"
    }
}

private struct StudioImageMemoryDetails: View {
    let reading: StudioImageMemoryReading
    let refresh: () -> Void

    var body: some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("RAM på denne iPhone").font(.headline)
                LabeledContent("Ledigt til FadedAI", value: reading.label(reading.available))
                LabeledContent("Prøvens minimum", value: reading.label(reading.required))
                if let footprint = reading.footprint {
                    LabeledContent("FadedAI bruger", value: reading.label(footprint))
                }
                FadedDetailText("RAM er arbejdshukommelse. iOS bestemmer, hvor meget én app må bruge, også selv om telefonen har mere RAM i alt.")
                if reading.available >= reading.required {
                    FadedDetailText("Der er nu nok ledig RAM til at starte prøven. Tryk Prøv igen for at teste modellen.")
                } else {
                    FadedDetailText("Prøv testen direkte efter en genstart af iPhone. Hvis den stadig stopper, skal appens RAM-grænse undersøges.")
                }
                FadedSecondaryButton("Opdatér RAM-tal", icon: "memorychip", action: refresh)
            }
        }
    }
}

enum StudioImagePairColors {
    static let side = 64

    static func matches(_ image: CGImage) -> Bool {
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { return false }
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let rendered = pixels.withUnsafeMutableBytes { raw -> Bool in
            let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            guard let canvas = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                         bytesPerRow: side * 4, space: sRGB, bitmapInfo: info) else { return false }
            let bounds = CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side))
            canvas.setFillColor(gray: 1, alpha: 1)
            canvas.fill(bounds)
            canvas.interpolationQuality = .medium
            let scale = CGFloat(side) / CGFloat(max(image.width, image.height))
            let width = CGFloat(image.width) * scale, height = CGFloat(image.height) * scale
            canvas.draw(image, in: CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2,
                                          width: width, height: height))
            return true
        }
        return rendered && matchesRGBA(pixels)
    }

    static func matchesRGBA(_ pixels: [UInt8]) -> Bool {
        guard pixels.count == side * side * 4 else { return false }
        var red = Set<Int>(), blue = Set<Int>()
        for index in 0 ..< side * side {
            let offset = index * 4
            let r = Int(pixels[offset]), g = Int(pixels[offset + 1]), b = Int(pixels[offset + 2])
            if r >= 80, r - max(g, b) >= 40 { red.insert(index) }
            if b >= 80, b - max(g, r) >= 40 { blue.insert(index) }
        }
        return matchesShape(red, circleOnLeft: true) && matchesShape(blue, circleOnLeft: false)
    }

    private static func matchesShape(_ indices: Set<Int>, circleOnLeft: Bool) -> Bool {
        guard indices.count >= (side * side + 99) / 100 else { return false }
        let xs = indices.map { $0 % side }.sorted(), ys = indices.map { $0 / side }.sorted()
        // Ignore isolated coloured pixels introduced by resampling.
        let trim = indices.count / 200, last = indices.count - 1 - trim
        let width = xs[last] - xs[trim] + 1, height = ys[last] - ys[trim] + 1
        let correctSide = xs.filter { ($0 < side / 2) == circleOnLeft }.count
        guard correctSide * 4 >= indices.count * 3, min(width, height) * 4 >= max(width, height) * 3 else { return false }

        var ellipse = 0, insideEllipse = 0, insideBox = 0
        for y in ys[trim]...ys[last] {
            for x in xs[trim]...xs[last] {
                let coloured = indices.contains(y * side + x)
                if coloured { insideBox += 1 }
                let dx = Double(2 * (x - xs[trim]) + 1) / Double(width) - 1
                let dy = Double(2 * (y - ys[trim]) + 1) / Double(height) - 1
                if dx * dx + dy * dy <= 1 {
                    ellipse += 1
                    if coloured { insideEllipse += 1 }
                }
            }
        }
        // Compare the colour mask to both outlines. A pair of squares passes a colour-only check.
        let circleFit = Double(insideEllipse) / Double(indices.count + ellipse - insideEllipse)
        let squareFit = Double(insideBox) / Double(indices.count + width * height - insideBox)
        let fit = circleOnLeft ? circleFit : squareFit
        let other = circleOnLeft ? squareFit : circleFit
        return fit >= 0.80 && fit >= other + 0.035
    }
}

/// Stores only outcomes of the built-in sample, locally in this device's cache.
@MainActor @Observable final class StudioImageProbeHistory {
    static let shared: StudioImageProbeHistory = {
        let files = FileManager.default
        let folder = files.urls(for: .cachesDirectory, in: .userDomainMask).first ?? files.temporaryDirectory
        return StudioImageProbeHistory(file: folder.appending(path: "StudioImageProbes-v1.json"))
    }()

    struct Measurement: Codable {
        let width: Int
        let height: Int
        let seconds: Double
        var checkedPairShapes: Bool?
    }

    struct Record: Codable {
        struct Success: Codable {
            let date: Date
            let measurement: Measurement
        }

        let id: UUID
        let date: Date
        var measurement: Measurement?
        var previousSuccess: Success?

        func summary(pair: Bool) -> String {
            let title = pair ? "To referencefotos" : "Prøvebillede"
            let latest = measurement.map { Success(date: date, measurement: $0) }
            guard let success = latest ?? previousSuccess else {
                return "\(title) · Den seneste prøve gav intet bekræftet resultat."
            }
            let when = success.date.formatted(date: .abbreviated, time: .shortened)
            let measured = success.measurement
            let seconds = measured.seconds.formatted(.number.precision(.fractionLength(1)))
            let label: String
            if pair {
                label = measured.checkedPairShapes == true ? "Begge figurer genkendt på denne iPhone" : "Tidligere farveprøve på denne iPhone"
            } else {
                label = "Prøvebillede lavet på denne iPhone"
            }
            let line = "\(label) · \(when) · \(measured.width) × \(measured.height) · \(seconds) sek."
            return latest == nil ? line + " Det seneste forsøg blev ikke gennemført." : line
        }
    }

    private let file: URL
    private var records: [String: Record]

    init(file: URL) {
        self.file = file
        if FileManager.default.fileExists(atPath: file.path) {
            do { records = try JSONDecoder().decode([String: Record].self, from: Data(contentsOf: file)) }
            catch { records = [:]; AppDiagnostics.record(error) }
        } else { records = [:] }
    }

    func record(model: String, pair: Bool) -> Record? { records[key(model, pair)] }

    func begin(_ id: UUID, model: String, pair: Bool) {
        let name = key(model, pair)
        let previous = records[name].flatMap { old in
            old.measurement.map { Record.Success(date: old.date, measurement: $0) } ?? old.previousSuccess
        }
        records[name] = Record(id: id, date: Date(), previousSuccess: previous)
        save()
    }

    func finish(_ id: UUID, model: String, pair: Bool, width: Int, height: Int, seconds: Double) {
        let name = key(model, pair)
        guard records[name]?.id == id, width > 0, height > 0, seconds.isFinite, seconds >= 0 else { return }
        records[name]?.measurement = Measurement(width: width, height: height, seconds: seconds, checkedPairShapes: pair ? true : nil)
        records[name]?.previousSuccess = nil
        save()
    }

    func forget(model: String) {
        records.removeValue(forKey: key(model, false))
        records.removeValue(forKey: key(model, true))
        save()
    }

    private func key(_ model: String, _ pair: Bool) -> String { model + (pair ? ".pair" : ".text") }

    private func save() {
        do { try JSONEncoder().encode(records).write(to: file, options: .atomic) }
        catch { AppDiagnostics.record(error) }
    }
}
