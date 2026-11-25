import ImageIO
import SwiftUI
import UIKit

@MainActor final class RoomWorkHub: ObservableObject {
    static let shared = RoomWorkHub()
    @Published private(set) var layouts: [String: RoomWorks.Layout] = [:]
    @Published var editing: Set<String> = []
    @Published var notice: String?
    private let store = RoomWorks.Store()
    func load(_ scene: String) { do { layouts[scene] = try store.load(scene) } catch { notice = error.localizedDescription } }
    func change(_ scene: String, _ update: (inout RoomWorks.Layout) throws -> Void) {
        do {
            var layout = try store.load(scene); try update(&layout); try store.save(layout, scene: scene)
            layouts[scene] = layout; notice = nil
        } catch { notice = error.localizedDescription }
    }
    func project(_ item: RoomWorks.Item) -> CreativeProject? {
        guard item.source.kind == .project, let id = UUID(uuidString: item.source.key) else { return nil }
        return (try? CreativeProject.Store().list())?.first { $0.id == id }
    }
    func track(_ item: RoomWorks.Item) -> MusicTrack? {
        guard item.source.kind == .song, SongLibrary().localURL(item.source.key) != nil else { return nil }
        return MusicLibrary.shared.saved.downloads.first { $0.id == item.source.key }
    }
    func imageURL(_ item: RoomWorks.Item) -> URL? {
        guard item.source.kind == .image, StudioImageFiles.hasSavedPNG(item.source.key) else { return nil }
        return StudioImageFiles.savedImage(item.source.key)
    }
    func available(_ item: RoomWorks.Item) -> Bool {
        switch item.source.kind { case .song: track(item) != nil; case .image: imageURL(item) != nil; case .project: project(item) != nil }
    }
    func title(_ item: RoomWorks.Item) -> String { project(item)?.title ?? track(item)?.title ?? item.title }
    func icon(_ item: RoomWorks.Item) -> String {
        guard available(item) else { return "exclamationmark.triangle" }
        switch item.source.kind { case .song: return "hifispeaker.fill"; case .image: return "photo.artframe"; case .project: return "hammer.fill" }
    }
    func thumbnail(_ item: RoomWorks.Item) -> UIImage? {
        guard let url = imageURL(item), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 180] as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
    func open(_ item: RoomWorks.Item) -> Bool {
        guard available(item) else { notice = RoomWorks.Failure.missing.localizedDescription; return false }
        if let song = track(item) { MusicPlayer.shared.play(song); return false }
        return true
    }
}

@MainActor struct RoomWorksOverlay: View {
    let scene: String
    @ObservedObject private var hub = RoomWorkHub.shared
    @State private var selected: RoomWorks.Item?
    var body: some View {
        GeometryReader { proxy in
            ForEach(hub.layouts[scene]?.items ?? []) { item in
                Button { if !hub.editing.contains(scene), hub.open(item) { selected = item } } label: {
                    Group {
                        if let image = hub.thumbnail(item) { Image(uiImage: image).resizable().scaledToFill() }
                        else { Image(systemName: hub.icon(item)).font(.title2).foregroundStyle(.white) }
                    }
                    .frame(width: 44, height: 44).background(.black.opacity(0.7), in: .rect(cornerRadius: 8))
                    .clipShape(.rect(cornerRadius: 8)).overlay { RoundedRectangle(cornerRadius: 8).stroke(hub.editing.contains(scene) ? .cyan : .white.opacity(0.7), lineWidth: 2) }
                }
                .buttonStyle(.plain).accessibilityLabel(hub.title(item)).accessibilityHint(hub.editing.contains(scene) ? "Flyt genstanden ved at trække den" : "Åbn det gemte værk")
                .position(x: item.x * proxy.size.width, y: item.y * proxy.size.height)
                .highPriorityGesture(DragGesture(minimumDistance: 8).onEnded { value in
                    guard hub.editing.contains(scene), proxy.size.width > 0, proxy.size.height > 0 else { return }
                    hub.change(scene) { try $0.move(item.id, x: item.x + value.translation.width / proxy.size.width, y: item.y + value.translation.height / proxy.size.height) }
                }, including: hub.editing.contains(scene) ? .all : .none)
            }
        }.task(id: scene) { hub.load(scene) }
            .sheet(item: $selected, onDismiss: { hub.load(scene) }) { RoomWorkDetail(item: $0) }
    }
}

@MainActor struct RoomWorksPanel: View {
    let scene: String
    @ObservedObject private var hub = RoomWorkHub.shared
    @ObservedObject private var music = MusicLibrary.shared
    @State private var projects: [CreativeProject] = []
    @State private var images: [String] = []
    @State private var adding = false
    @State private var selected: RoomWorks.Item?
    @Environment(\.scenePhase) private var phase
    private var items: [RoomWorks.Item] { hub.layouts[scene]?.items ?? [] }
    var body: some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Dine værker i rummet").font(.headline); Spacer()
                    Button("Tilføj", systemImage: "plus") { refresh(); adding = true }.frame(minHeight: 44).disabled(items.count >= 12)
                }
                if items.isEmpty { Text("Sæt din egen sang på stereoanlægget, hæng et billede op, eller læg et projekt på arbejdsbordet.").foregroundStyle(.secondary) }
                else {
                    Toggle("Flyt genstande i rummet", isOn: Binding(get: { hub.editing.contains(scene) }, set: { if $0 { hub.editing.insert(scene) } else { hub.editing.remove(scene) } }))
                    ForEach(items) { item in
                        HStack {
                            Button { if hub.open(item) { selected = item } } label: {
                                Label(hub.title(item), systemImage: hub.icon(item)).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }.disabled(!hub.available(item))
                            if !hub.available(item) { Text("Original slettet").font(.caption).foregroundStyle(.secondary) }
                            Button("Fjern fra rummet", systemImage: "trash", role: .destructive) { hub.change(scene) { $0.remove(item.id) } }
                                .labelStyle(.iconOnly).frame(width: 44, height: 44)
                        }
                    }
                }
                if hub.layouts[scene]?.previous != nil { Button("Fortryd sidste ændring", systemImage: "arrow.uturn.backward") { hub.change(scene) { $0.undo() } }.frame(minHeight: 44) }
                if let notice = hub.notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .task(id: scene) { refresh() }.onChange(of: phase) { _, next in if next == .active { refresh() } }
        .onDisappear { hub.editing.remove(scene) }
        .sheet(isPresented: $adding) { candidates }
        .sheet(item: $selected, onDismiss: refresh) { item in RoomWorkDetail(item: item) }
    }
    private var candidates: some View {
        NavigationStack {
            List {
                Section("Egne sange · stereo") {
                    let songs = music.saved.downloads.filter { $0.id.hasPrefix("faded-song-") && SongLibrary().localURL($0.id) != nil }
                    if songs.isEmpty { Text("Gem først en sang fra Musikstudiet.") }
                    ForEach(songs) { song in candidate(.init(kind: .song, key: song.id), title: song.title) }
                }
                Section("Gemte billeder · væg") {
                    if images.isEmpty { Text("Gem først et billede fra billedstudiet.") }
                    ForEach(images, id: \.self) { name in
                        let date = Double(name.split(separator: "-").first ?? "").map { Date(timeIntervalSince1970: $0 / 1_000) }
                        candidate(.init(kind: .image, key: name), title: "Billede · " + (date?.formatted(date: .abbreviated, time: .shortened) ?? "Gemt"))
                    }
                }
                Section("Projekter · arbejdsbord") {
                    if projects.isEmpty { Text("Gem først et kreativt projekt.") }
                    ForEach(projects) { project in candidate(.init(kind: .project, key: project.id.uuidString), title: project.title.isEmpty ? project.kind.rawValue : project.title) }
                }
            }.navigationTitle("Vælg et gemt værk").toolbar { Button("Luk") { adding = false } }
        }
    }
    private func candidate(_ source: RoomWorks.Source, title: String) -> some View {
        Button { hub.change(scene) { try $0.add(source: source, title: title) }; if hub.notice == nil { adding = false } } label: {
            HStack {
                if let image = hub.thumbnail(.init(source: source, title: title, x: 0.5, y: 0.5)) {
                    Image(uiImage: image).resizable().scaledToFill().frame(width: 52, height: 52).clipShape(.rect(cornerRadius: 8))
                }
                Text(title)
            }
        }
            .frame(minHeight: 44).disabled(items.contains { $0.source == source })
    }
    private func refresh() {
        hub.load(scene); projects = (try? CreativeProject.Store().list()) ?? []
        images = ((try? FileManager.default.contentsOfDirectory(at: StudioImageFiles.library, includingPropertiesForKeys: nil)) ?? [])
            .map(\.lastPathComponent).filter { StudioImageFiles.hasSavedPNG($0) }.sorted(by: >).prefix(60).map { $0 }
    }
}

@MainActor private struct RoomWorkDetail: View {
    let item: RoomWorks.Item
    @ObservedObject private var hub = RoomWorkHub.shared
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Group {
                if let url = hub.imageURL(item), let image = UIImage(contentsOfFile: url.path) {
                    ScrollView { VStack { Image(uiImage: image).resizable().scaledToFit(); ShareLink(item: url) { Label("Del billede", systemImage: "square.and.arrow.up") }.frame(minHeight: 44) }.padding() }
                } else if let project = hub.project(item) {
                    if let bot = VillageBot.list(from: MigratedAppData.shared.villageBots).first(where: { $0.id == project.botID }) {
                        CreativeProjectView(bot: bot, model: UserDefaults.standard.string(forKey: PhoneModels.selectionKey) ?? "apple", initial: project)
                    } else {
                        ScrollView { VStack(alignment: .leading, spacing: 16) { Text(project.title).font(.title2); Text(project.text).textSelection(.enabled) }.padding() }
                    }
                } else { Text(RoomWorks.Failure.missing.localizedDescription).padding() }
            }.background { FadedBackground(variant: .village) }.navigationTitle(hub.title(item)).navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Luk") { dismiss() } }
        }
    }
}
