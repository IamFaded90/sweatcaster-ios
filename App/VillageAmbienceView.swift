import SwiftUI
import UIKit

@MainActor final class VillageAmbienceHub: ObservableObject {
    static let shared = VillageAmbienceHub()
    @Published private(set) var records: [String: VillageAmbience.Record] = [:]
    @Published var notice: String?
    private var failed = Set<String>()
    private let storage = VillageAmbience.Store()
    private let images = NSCache<NSUUID, UIImage>()
    func load(_ scene: String) {
        guard records[scene] == nil, !failed.contains(scene) else { return }
        do { records[scene] = try storage.load(scene) }
        catch { failed.insert(scene); notice = "Den gemte stemning kunne ikke læses. Den er ikke ændret." }
    }
    func settings(_ scene: String) -> VillageAmbience.Settings { records[scene]?.current ?? .init() }
    func image(_ scene: String) -> UIImage? {
        guard let id = settings(scene).imageID else { return nil }
        if let image = images.object(forKey: id as NSUUID) { return image }
        guard let image = UIImage(contentsOfFile: storage.image(id).path) else { return nil }
        images.totalCostLimit = 32 * 1024 * 1024
        images.setObject(image, forKey: id as NSUUID, cost: (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0))
        return image
    }
    func update(_ scene: String, change: (inout VillageAmbience.Record) throws -> Void) throws {
        load(scene)
        guard !failed.contains(scene) else { throw VillageAmbience.Failure.invalid }
        var value = records[scene] ?? .init()
        try change(&value); try storage.save(value, scene: scene)
        records[scene] = value
    }
    func addImage(_ bytes: Data) throws -> UUID { try storage.saveImage(AgentRoomImages.sketch(bytes)) }
    func removeImage(_ scene: String, id: UUID) throws {
        try update(scene) { $0.removeImage(id) }
        images.removeObject(forKey: id as NSUUID)
        try storage.collectUnusedImages()
    }
    func reset(_ scene: String) throws {
        try storage.remove(scene); failed.remove(scene); records[scene] = .init()
        VillageAmbienceAudio.shared.stop(scene: scene)
    }
}

@MainActor struct VillageAmbienceView: View {
    let scene: String
    let title: String
    @ObservedObject private var hub = VillageAmbienceHub.shared
    @ObservedObject private var library = MusicLibrary.shared
    @ObservedObject private var audio = VillageAmbienceAudio.shared
    @State private var draft = VillageAmbience.Settings()
    @State private var photo: Data?
    @State private var loadingPhoto = false
    @State private var initialized = false
    @State private var notice: String?
    @Environment(\.dismiss) private var dismiss
    private var record: VillageAmbience.Record { hub.records[scene] ?? .init() }
    private var tracks: [MusicTrack] {
        (library.saved.downloads + library.saved.favorites).reduce(into: []) { result, item in
            if !result.contains(where: { $0.id == item.id }) { result.append(item) }
        }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Din stemning i \(title)").font(.title2.bold())
                    Text("Lyset og baggrunden gemmes særskilt. Figurer, placering og det oprindelige rum bevares.").foregroundStyle(.secondary)
                    FadedCard {
                        VStack(alignment: .leading, spacing: 12) {
                            TextField("Stemningens navn", text: $draft.name)
                            Picker("Lys", selection: $draft.light) { ForEach(VillageAmbience.Light.allCases) { Text($0.title).tag($0) } }
                            Text("Lysstyrke"); Slider(value: $draft.brightness, in: -0.3...0.25)
                            Text("Farvemætning"); Slider(value: $draft.saturation, in: 0.4...1.4)
                            Text("Farvet lys"); Slider(value: $draft.strength, in: 0...0.45)
                            ChatPhotoPicker(photo: $photo, loading: $loadingPhoto, onError: { notice = $0 }, addTitle: "Vælg ny baggrund", replaceTitle: "Skift baggrund")
                            if draft.imageID != nil {
                                Button("Brug rummets oprindelige baggrund") { draft.imageID = nil }
                            }
                            if let image = draft.imageID.flatMap({ UIImage(contentsOfFile: VillageAmbience.Store().image($0).path) }) {
                                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 190)
                                    .brightness(draft.brightness).saturation(draft.saturation)
                                    .overlay { VillageAmbienceLight(settings: draft) }.clipped()
                            }
                        }
                    }
                    FadedCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("Baggrundslyd", selection: $draft.sound) { ForEach(VillageAmbience.Sound.allCases) { Text($0.title).tag($0) } }
                            Text("Lydstyrke"); Slider(value: $draft.volume, in: 0...0.7)
                            Picker("Musik", selection: Binding(get: { draft.music?.id ?? "" }, set: { id in draft.music = tracks.first { $0.id == id } })) {
                                Text("Ingen ændring af musikken").tag("")
                                if let music = draft.music, !tracks.contains(where: { $0.id == music.id }) { Text(music.title + " · ikke i biblioteket").tag(music.id) }
                                ForEach(tracks) { Text($0.title + " · " + $0.artist).tag($0.id) }
                            }
                            Toggle("Brug kun hentet musik", isOn: $draft.offlineMusicOnly)
                            Toggle("Start lyd, når jeg åbner stedet", isOn: $draft.autoplay)
                            HStack {
                                Button("Hør stemningen", systemImage: "play.fill") { Task { await audio.preview(scene: "preview-" + scene, settings: draft) } }
                                Button("Stop lyd", systemImage: "stop.fill") {
                                    audio.endPreview(scene: "preview-" + scene)
                                    if let music = draft.music, MusicPlayer.shared.current?.id == music.id { MusicPlayer.shared.pause() }
                                }
                            }.buttonStyle(.bordered).frame(minHeight: 44)
                            Text("Baggrundslydene laves på telefonen. Musik spiller videre i Musik-afspilleren, når du forlader rummet.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let notice = notice ?? hub.notice ?? audio.notice { Text(notice).foregroundStyle(.secondary) }
                    FadedPrimaryButton("Brug stemningen", icon: "sparkles") {
                        do { try hub.update(scene) { try $0.apply(draft) }; notice = "Stemningen er gemt og bruges på stedet." }
                        catch { notice = "Stemningen kunne ikke gemmes." }
                    }.disabled(!initialized || loadingPhoto)
                    FadedSecondaryButton("Gem som favoritstemning", icon: "heart") {
                        do { try hub.update(scene) { try $0.savePreset(draft) }; notice = "Favoritstemningen er gemt." }
                        catch { notice = "Giv stemningen et kort navn, og prøv igen." }
                    }.disabled(!initialized || loadingPhoto)
                    if !record.presets.isEmpty {
                        Text("Dine stemninger").font(.headline)
                        ForEach(record.presets) { snapshot in
                            HStack {
                                Button(snapshot.settings.name) { restore(snapshot.id) }.frame(minHeight: 44)
                                Spacer()
                                Button("Slet", systemImage: "trash", role: .destructive) {
                                    do { try hub.update(scene) { $0.presets.removeAll { $0.id == snapshot.id } } }
                                    catch { notice = "Stemningen kunne ikke slettes." }
                                }
                            }
                        }
                    }
                    if !record.history.isEmpty {
                        DisclosureGroup("Gendan en tidligere udgave") {
                            ForEach(record.history.reversed()) { snapshot in
                                Button { restore(snapshot.id) } label: {
                                    VStack(alignment: .leading) {
                                        Text(snapshot.settings.name)
                                        Text(snapshot.saved.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                }
                            }
                        }
                    }
                    if let imageID = draft.imageID {
                        Button("Slet denne baggrund fra alle udgaver", systemImage: "trash", role: .destructive) {
                            do { try hub.removeImage(scene, id: imageID); draft.imageID = nil; photo = nil; notice = "Baggrunden er fjernet fra stemningerne." }
                            catch { notice = "Baggrunden kunne ikke slettes helt." }
                        }.frame(minHeight: 44)
                    }
                    Button("Nulstil alle stemninger for dette sted", systemImage: "arrow.counterclockwise", role: .destructive) {
                        do { try hub.reset(scene); draft = .init(); photo = nil }
                        catch { notice = "Stemningerne kunne ikke nulstilles." }
                    }.frame(minHeight: 44)
                }.padding()
            }.background { FadedBackground(variant: .village) }.navigationTitle("Lys, lyd og stemning")
                .toolbar { Button("Luk") { dismiss() } }
                .onAppear { guard !initialized else { return }; hub.load(scene); draft = hub.settings(scene); initialized = hub.records[scene] != nil }
                .onDisappear { audio.endPreview(scene: "preview-" + scene) }
                .onChange(of: photo) { _, data in
                    guard let data else { return }
                    do { draft.imageID = try hub.addImage(data) }
                    catch { notice = "Baggrunden kunne ikke gemmes. Vælg et mindre foto." }
                }
        }
    }
    private func restore(_ id: UUID) {
        do { try hub.update(scene) { try $0.restore(id) }; draft = hub.settings(scene); notice = "Stemningen er gendannet." }
        catch { notice = "Udgaven kunne ikke gendannes." }
    }
}

struct VillageAmbienceLight: View {
    let settings: VillageAmbience.Settings
    private var color: Color {
        switch settings.light { case .original: .clear; case .golden: .orange; case .moon: .indigo; case .aurora: FadedBrand.mint; case .rose: .pink }
    }
    var body: some View { color.opacity(settings.strength).blendMode(.softLight).allowsHitTesting(false).accessibilityHidden(true) }
}

struct VillageAmbienceButton: View {
    let scene: String
    let title: String
    @State private var editing = false
    var body: some View {
        Button("Lys, lyd og stemning", systemImage: "sun.haze") { editing = true }.frame(minHeight: 44)
            .sheet(isPresented: $editing) { VillageAmbienceView(scene: scene, title: title) }
    }
}

struct VillageAmbienceLifecycle: ViewModifier {
    let scene: String
    @ObservedObject private var hub = VillageAmbienceHub.shared
    @Environment(\.scenePhase) private var phase
    @State private var lease = UUID()
    private var owner: String { scene + "--" + lease.uuidString }
    func body(content: Content) -> some View {
        let settings = hub.records[scene]?.current
        content.task(id: settings) {
            guard let settings else { hub.load(scene); return }
            VillageAmbienceAudio.shared.register(owner)
            await start(settings)
        }
            .onChange(of: phase) { _, value in
                if value != .active { VillageAmbienceAudio.shared.stop(scene: owner) }
                else if let settings { Task { await start(settings) } }
            }
            .onDisappear { VillageAmbienceAudio.shared.unregister(owner) }
    }
    private func start(_ settings: VillageAmbience.Settings) async {
        guard phase == .active, !Task.isCancelled else { return }
        if settings.autoplay { await VillageAmbienceAudio.shared.play(scene: owner, settings: settings) }
        else { VillageAmbienceAudio.shared.stop(scene: owner) }
    }
}
