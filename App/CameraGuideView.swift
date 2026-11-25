import AVFoundation
import SwiftUI
import UIKit

@MainActor struct CameraGuideView: View {
    let bot: VillageBot
    let api: LiveAPI?
    let model: String
    var initialQuestion = ""
    var initialPhoto: Data?
    var onResult: (String) -> Void = { _ in }
    @State private var session = CameraGuide.Session()
    @State private var photo: Data?
    @State private var pickerPhoto: Data?
    @State private var question = ""
    @State private var marks: [CameraGuide.Mark] = []
    @State private var anchors: [CameraGuide.Anchor] = []
    @State private var loading = false
    @State private var cameraOpen = false
    @State private var modelsOpen = false
    @State private var usingPC = false
    @State private var busy = false
    @State private var correcting: Int?
    @State private var notice: String?
    @State private var operation: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Vis det til \(bot.name)").font(.title2.bold())
                    Text("Tag et foto, spørg, og få vist stedet på billedet. Tag næste foto for at fortsætte.").foregroundStyle(.secondary)
                    FadedCard {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Button(photo == nil ? "Tag foto" : "Vis næste billede", systemImage: "camera") { openCamera() }
                                    .frame(minHeight: 44).disabled(busy)
                                Spacer()
                                if photo != nil { Button("Slet foto", systemImage: "trash", role: .destructive) { clearPhoto() }.labelStyle(.iconOnly).frame(width: 44, height: 44).disabled(busy) }
                            }
                            ChatPhotoPicker(photo: $pickerPhoto, loading: $loading, onError: { notice = $0 }, addTitle: "Vælg foto eller skærmbillede", replaceTitle: "Vælg et andet foto").disabled(busy)
                            if let photo, let image = UIImage(data: photo) {
                                CameraGuideOverlay(image: image, marks: marks, correcting: correcting) { index, x, y in
                                    guard marks.indices.contains(index), let box = try? marks[index].box.moved(centerX: x, centerY: y) else { return }
                                    marks[index].box = box; marks[index].origin = .user; correcting = nil
                                }
                                if correcting != nil { Text("Tryk midt på det rigtige sted i fotoet.").font(.caption); Button("Annuller flytning") { correcting = nil } }
                                ForEach(Array(marks.enumerated()), id: \.element.id) { index, mark in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("\(index + 1). \(mark.label)").font(.headline)
                                            Text(mark.originTitle).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Button("Flyt") { correcting = index }.frame(minWidth: 44, minHeight: 44)
                                        Button("Fjern", systemImage: "xmark.circle") { marks.remove(at: index); correcting = nil }.labelStyle(.iconOnly).frame(width: 44, height: 44)
                                    }
                                }
                                if !marks.isEmpty {
                                    let marked = CameraGuideImage.render(image, marks: marks)
                                    ShareLink(item: Image(uiImage: marked), preview: SharePreview("Kamerahjælp", image: Image(uiImage: marked))) { Label("Del billedet med markeringer", systemImage: "square.and.arrow.up") }.frame(minHeight: 44)
                                }
                            }
                            TextField("Fx: Hvor skal jeg trykke for at skifte lydspor?", text: $question, axis: .vertical).lineLimit(2...5)
                                .onChange(of: question) { _, value in if value.count > 1_000 { question = String(value.prefix(1_000)) } }
                            if api != nil {
                                Toggle("Brug PC’en til billedanalysen", isOn: $usingPC).disabled(busy)
                            }
                            Button("Vælg billedmodel til iPhone", systemImage: "iphone") { modelsOpen = true }.frame(minHeight: 44).disabled(busy)
                            Text(usingPC ? "Dit valgte foto sendes til den parrede PC." : "Billedanalyse og tekstgenkendelse foregår på telefonen. En hentet billedmodel bruges til selve vejledningen.")
                                .font(.caption).foregroundStyle(.secondary)
                            FadedPrimaryButton("Vis mig stedet", icon: "viewfinder") { analyse() }
                                .disabled(busy || loading || photo == nil || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            if busy { ProgressView("\(bot.name) kigger på fotoet…"); Button("Stop") { operation?.cancel() }.frame(minHeight: 44) }
                            if let notice { Text(notice).foregroundStyle(.secondary).textSelection(.enabled) }
                        }
                    }
                    if let current = session.current {
                        FadedCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(current.question).font(.headline)
                                Text(current.answer).textSelection(.enabled)
                                Text(current.source + " · " + current.model).font(.caption).foregroundStyle(.secondary)
                                Button("Gem vejledningen i chatten", systemImage: "checkmark.bubble") {
                                    onResult(current.answer + (marks.isEmpty ? "" : "\n\nMarkeringer: " + marks.map(\.label).joined(separator: ", ")) + "\n\n" + current.source + " · " + current.model)
                                    notice = "Vejledningen er lagt i chatten. Du kan fortsætte med næste foto."
                                }.frame(minHeight: 44)
                            }
                        }
                    }
                    if !anchors.isEmpty && session.current == nil {
                        DisclosureGroup("Læsbar tekst på fotoet") {
                            ForEach(Array(anchors.enumerated()), id: \.offset) { _, anchor in
                                Button("Markér: " + anchor.text) { marks = [.init(label: anchor.text, box: anchor.box, origin: .text)] }.frame(minHeight: 44)
                            }
                        }
                    }
                    if !session.steps.isEmpty {
                        DisclosureGroup("Tidligere trin · \(session.steps.count)") {
                            ForEach(session.steps) { step in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(step.question).font(.headline); Text(step.answer)
                                    Button("Slet dette trin", systemImage: "trash", role: .destructive) { session.remove(step.id); if session.current == nil { marks = [] } }
                                        .frame(minHeight: 44).disabled(busy)
                                }.padding(.vertical, 8)
                            }
                        }
                        Button("Start forfra og slet forløbet", systemImage: "trash", role: .destructive) { clearPhoto(); session.clear() }.frame(minHeight: 44).disabled(busy)
                    }
                }.padding()
            }.background { FadedBackground() }.navigationTitle("Kamerahjælp").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Luk") { operation?.cancel(); dismiss() } }
                .onAppear {
                    guard photo == nil else { return }
                    question = String(initialQuestion.prefix(1_000)); if let initialPhoto { setPhoto(initialPhoto) }
                }
                .onChange(of: pickerPhoto) { _, data in if let data { setPhoto(data); pickerPhoto = nil } }
                .onDisappear { operation?.cancel() }
                .fullScreenCover(isPresented: $cameraOpen) { CameraGuideCapture(captured: setPhoto, failed: { notice = $0 }).ignoresSafeArea() }
                .sheet(isPresented: $modelsOpen) { PhoneModelsView() }
        }
    }
    private func setPhoto(_ data: Data) {
        do {
            let normalized = try CameraGuideImage.normalize(data)
            operation?.cancel(); session.replacePhoto(); photo = normalized; marks = []; anchors = []; correcting = nil; notice = nil
        } catch { notice = "Fotoet kunne ikke åbnes. Vælg et almindeligt foto eller skærmbillede." }
    }
    private func clearPhoto() {
        operation?.cancel(); session.replacePhoto(); photo = nil; pickerPhoto = nil; marks = []; anchors = []; correcting = nil; notice = nil
    }
    private func openCamera() {
        Task {
            guard UIImagePickerController.isSourceTypeAvailable(.camera) else { notice = "Kameraet er ikke tilgængeligt. Vælg et foto i stedet."; return }
            let allowed: Bool
            if AVCaptureDevice.authorizationStatus(for: .video) == .authorized { allowed = true }
            else { allowed = await AVCaptureDevice.requestAccess(for: .video) }
            if allowed { cameraOpen = true } else { notice = "Kameraadgang er slået fra. Du kan vælge et foto eller tillade Kamera i iPhones indstillinger." }
        }
    }
    private func analyse() {
        guard !busy, let photo else { return }
        busy = true; notice = nil; marks = []; correcting = nil
        session.beginAttempt()
        let photoID = session.photoID, requested = question, context = session.context, pc = usingPC ? api : nil
        operation = Task {
            defer { busy = false }
            do {
                let read = try await CameraGuideImage.anchors(photo)
                try Task.checkCancellation(); guard session.photoID == photoID else { return }; anchors = read
                if !usingPC && PhoneModels.preferredVisionModel(preferred: model) == nil {
                    notice = "Vælg en hentet billedmodel til vejledningen. Tekst på fotoet kan markeres herunder uden en billedmodel."; return
                }
                let result = try await AgentChatPhotoReply.answer(photo,
                    question: CameraGuide.prompt(question: requested, context: context, anchors: read), agent: bot.name,
                    language: "da-DK", pc: pc, preferredModel: model)
                try Task.checkCancellation()
                let step = try CameraGuide.decode(result.text, photoID: photoID, question: requested,
                    source: result.source, model: result.model, anchors: read)
                try session.append(step); marks = step.marks
                if marks.isEmpty { notice = "Der er ingen sikker markering i svaret. Du kan vælge en læsbar tekstposition eller tage et tydeligere foto." }
            } catch { if !Task.isCancelled { notice = error.localizedDescription } }
        }
    }
}
