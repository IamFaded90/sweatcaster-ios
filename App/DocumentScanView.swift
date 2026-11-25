import PhotosUI
import SwiftUI
import UIKit
import VisionKit

@MainActor struct DocumentScanView: View {
    let bot: VillageBot
    let model: String
    @State private var picks: [PhotosPickerItem] = []
    @State private var scanner = false
    @State private var camera = false
    @State private var result: DocumentScanNative.Result?
    @State private var title = "Mit dokument"
    @State private var records: [ScanDocument.Record] = []
    @State private var savedID: UUID?
    @State private var busy = false
    @State private var operation: Task<Void, Never>?
    @State private var notice: String?
    @State private var followUp = false
    @Environment(\.dismiss) private var dismiss
    private var store: ScanDocument.Store { .init(botID: bot.id) }
    var body: some View {
        NavigationStack {
            List {
                Section("Papir og QR · på iPhone") {
                    Button("Scan papir eller kvittering", systemImage: "doc.viewfinder") { scanner = true }.frame(minHeight: 44).disabled(busy || !VNDocumentCameraViewController.isSupported)
                    Button("Fotografér QR-kode", systemImage: "qrcode.viewfinder") { camera = true }.frame(minHeight: 44).disabled(busy || !UIImagePickerController.isSourceTypeAvailable(.camera))
                    PhotosPicker(selection: $picks, maxSelectionCount: 10, matching: .images) { Label("Vælg fotos · højst 10 sider", systemImage: "photo.on.rectangle") }.frame(minHeight: 44).disabled(busy)
                    Text("Scanner, tekstanalyse og PDF foregår lokalt. Kontrollér især beløb, navne og datoer i den genkendte tekst.").font(.caption).foregroundStyle(.secondary)
                    if busy { ProgressView("Læser sider og bygger PDF…"); Button("Stop") { operation?.cancel() }.frame(minHeight: 44) }
                    if let notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
                }
                if let result {
                    Section("Gennemgå dokumentet") {
                        TextField("Dokumentets titel", text: $title)
                        if let first = result.pages.first, let image = UIImage(data: first.photo) { Image(uiImage: image).resizable().scaledToFit().accessibilityLabel("Første scannede side") }
                        DisclosureGroup("Genkendt tekst · \(result.pages.count) sider") { Text(result.text).textSelection(.enabled) }
                        ForEach(Array(ScanDocument.amounts(in: result.text).enumerated()), id: \.offset) { _, amount in
                            VStack(alignment: .leading, spacing: 4) { Text("Muligt totalbeløb: \(amount.value)").font(.headline); Text("“\(amount.quote)”").font(.caption) }
                        }
                        ForEach(result.codes, id: \.self) { code in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(code).textSelection(.enabled)
                                if let url = ScanDocument.qrURL(code) { Link("Åbn \(url.host ?? "linket")", destination: url).frame(minHeight: 44) }
                            }
                        }
                        Button(savedID == nil ? "Gem søgbar PDF" : "PDF gemt", systemImage: savedID == nil ? "square.and.arrow.down" : "checkmark.circle") { save() }.frame(minHeight: 44).disabled(busy || savedID != nil || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.count > 160)
                        if let savedID { ShareLink(item: store.file(savedID)) { Label("Del PDF", systemImage: "square.and.arrow.up") }.frame(minHeight: 44) }
                        Button("Noter og opfølgning fra teksten", systemImage: "square.and.pencil") { followUp = true }.frame(minHeight: 44).disabled(busy || result.text.count > 6_000)
                        if result.text.count > 6_000 { Text("Vælg og del et kortere tekstuddrag til opfølgning.").font(.caption) }
                    }
                }
                Section("Gemte scanninger") {
                    ForEach(records) { record in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(record.title).font(.headline)
                            Text("\(record.pages) sider · \(record.created.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                ShareLink(item: store.file(record.id)) { Label("PDF", systemImage: "square.and.arrow.up") }
                                Spacer()
                                Button("Brug hos \(bot.name)", systemImage: "doc.text.magnifyingglass") { attach(record) }.disabled(busy)
                            }.frame(minHeight: 44)
                        }.swipeActions { Button("Slet PDF og tekst", role: .destructive) { do { try store.remove(record.id); if savedID == record.id { savedID = nil }; records = try store.load() } catch { notice = error.localizedDescription } }.disabled(busy) }
                    }
                }
            }.scrollContentBackground(.hidden).background { FadedBackground() }
                .navigationTitle("Scan og gem").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Luk") { dismiss() } }
                .onAppear { do { records = try store.load() } catch { notice = error.localizedDescription } }
                .onDisappear { operation?.cancel() }
                .onChange(of: picks) { _, selected in
                    guard !selected.isEmpty, !busy else { return }; busy = true; notice = nil
                    operation = Task {
                        defer { busy = false }
                        do {
                            var photos: [Data] = []
                            for item in selected { guard let bytes = try await item.loadTransferable(type: Data.self) else { throw ScanDocument.Failure.format }; photos.append(try CameraGuideImage.normalize(bytes)) }
                            let prepared = try await DocumentScanNative.prepare(photos); try Task.checkCancellation()
                            result = prepared; savedID = nil; title = suggestedTitle; picks = []
                        } catch { if !Task.isCancelled { notice = error.localizedDescription } }
                    }
                }
                .sheet(isPresented: $scanner) { DocumentScanCamera { response in do { prepare(try response.get()) } catch { notice = error.localizedDescription } } }
                .sheet(isPresented: $camera) { CameraGuideCapture(captured: { prepare([$0]) }, failed: { notice = $0 }) }
                .sheet(isPresented: $followUp) { if let result { CaptureReviewView(bot: bot, model: model, initial: result.text, initialSource: title) } }
        }
    }
    private var suggestedTitle: String {
        let text = result?.pages.first?.lines.first?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? "Mit dokument" : String(text.prefix(160))
    }
    private func prepare(_ photos: [Data]) {
        guard !busy else { return }; busy = true; notice = nil
        operation = Task { defer { busy = false }; do {
            let prepared = try await DocumentScanNative.prepare(photos); try Task.checkCancellation()
            result = prepared; savedID = nil; title = suggestedTitle
        } catch { if !Task.isCancelled { notice = error.localizedDescription } } }
    }
    private func save() {
        guard let result, savedID == nil else { return }
        do {
            let record = ScanDocument.Record(title: title.trimmingCharacters(in: .whitespacesAndNewlines), text: result.text, pages: result.pages.count, totals: ScanDocument.amounts(in: result.text))
            try store.save(record, pdf: result.pdf); records = try store.load(); savedID = record.id; notice = "Den søgbare PDF og kildekopien er gemt på telefonen."
        } catch { notice = error.localizedDescription }
    }
    private func attach(_ record: ScanDocument.Record) {
        busy = true; notice = nil
        operation = Task { defer { busy = false }; do {
            let file = store.file(record.id)
            let worker = Task.detached(priority: .userInitiated) { try AgentDocumentIndex.ingest(file) }
            let document = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            let named = AgentDocument(id: document.id, name: record.title + ".pdf", model: document.model, passages: document.passages)
            try AgentDocumentLibrary(botID: bot.id).add(named)
            notice = "PDF’en er tilføjet agentens dokumentbibliotek. Vælg den under Dokumenter i chatten."
        } catch { if !Task.isCancelled { notice = error.localizedDescription } } }
    }
}

@MainActor struct DocumentScanEntry: View {
    @State private var showing = false
    @AppStorage(AppStorageKeys.phoneModel) private var model = "apple"
    var body: some View {
        FadedSecondaryButton("Scan og gem", icon: "doc.viewfinder") { showing = true }
            .sheet(isPresented: $showing) {
                let bots = ((try? MigratedAppData.shared.loadBots().get()) ?? []).filter { $0.id != VillageBot.lumiID }
                if let bot = bots.first(where: { $0.name.caseInsensitiveCompare("Adam") == .orderedSame }) ?? bots.first { DocumentScanView(bot: bot, model: model) }
                else { Text("Opret en agent i Landsbyen først.").padding() }
            }
    }
}
