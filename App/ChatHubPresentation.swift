import PhotosUI
import SwiftUI
import UIKit

enum ChatHubDestination: String, CaseIterable, Identifiable {
    case home, music, film, images, video, agents, village
    var id: Self { self }
    var title: String {
        switch self {
        case .home: "Hjem"
        case .music: "Musik"
        case .film: "Film"
        case .images: "Billeder"
        case .video: "Video"
        case .agents: "Agenter"
        case .village: "Landsbyen"
        }
    }
    var icon: String {
        switch self {
        case .home: "house"
        case .music: "music.note"
        case .film: "play.rectangle"
        case .images: "photo"
        case .video: "video"
        case .agents: "person.2"
        case .village: "building.2"
        }
    }
}

extension ChatView {
    var chatSidebarDestinations: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().overlay(palette.border)
            Button {
                showHistory = false
                goBack()
            } label: {
                Label("Tilbage", systemImage: "chevron.left")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }.buttonStyle(.plain)
            DisclosureGroup("Udforsk FadedAI") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if let openDestination {
                            ForEach(ChatHubDestination.allCases) { destination in
                                Button {
                                    showHistory = false
                                    openDestination(destination)
                                } label: {
                                    Label(destination.title, systemImage: destination.icon)
                                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                }.buttonStyle(.plain)
                            }
                        }
                        if openPrivateStudio != nil {
                            Button {
                                showHistory = false
                                goToPrivateStudio()
                            } label: {
                                Label("Privat chat", systemImage: "lock.shield.fill")
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(maxHeight: 240)
            }.disabled(task != nil)
        }.padding(16).foregroundStyle(palette.text)
    }

    var chatAgentWorkspace: some View {
        let bots = VillageBot.list(from: MigratedAppData.shared.villageBots)
        let selected = bots.first { $0.id == selectedTaskAgent } ?? bots.first
        return VStack(spacing: 12) {
            if let selected {
                HStack {
                    Text("Opgaver til").foregroundStyle(palette.secondary)
                    Picker("Vælg agent", selection: Binding(get: { selected.id }, set: { selectedTaskAgent = $0 })) {
                        ForEach(bots) { Text($0.name).tag($0.id) }
                    }.pickerStyle(.menu)
                    Spacer()
                    if !demo {
                        Menu {
                            Button("iPhone", systemImage: "iphone") { chooseSource(.phone) }
                            Button("PC", systemImage: "desktopcomputer") { chooseSource(.pc) }
                        } label: {
                            Label(effectiveReplySource == .pc ? "PC" : "iPhone", systemImage: effectiveReplySource.icon)
                                .font(.subheadline).frame(minHeight: 44)
                        }.accessibilityLabel("Vælg enhed til agentopgaver")
                    }
                }.padding(.horizontal, 16)
                BotComputerView(bot: selected, roster: bots,
                                api: effectiveReplySource == .pc ? api as? LiveAPI : nil,
                                initialPrompt: draft)
                    .id(selected.id)
            } else {
                FadedEmptyState(icon: "person.badge.plus", title: "Vælg din første agent",
                                detail: "Opret en agent, og giv den opgaver herfra.", actionTitle: "Åbn Agenter") {
                    openBots?()
                }
                Spacer()
            }
        }
    }

    func pickChatPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        photoImportBusy = true
        defer {
            photoImportBusy = false
            // Reopening the tray must not re-import the previous selection.
            pickedPhoto = nil
        }
        do {
            guard let input = try await item.loadTransferable(type: StudioPhotoInput.self) else { throw APIError.input }
            try Task.checkCancellation()
            stageChatPhoto(input.data)
        } catch {
            if !Task.isCancelled { chatNotice = "Billedet kunne ikke åbnes. Prøv et andet foto." }
        }
    }

    func stageChatPhoto(_ data: Data) {
        guard task == nil, data.count <= 20_000_000, let preview = UIImage(data: data) else {
            chatNotice = "Vælg et billede under 20 MB."; return
        }
        let photo = DroppedPhoto(data: data, preview: preview)
        stagedPhoto = photo
        // Only explicitly selected photos; never enumerate the user's photo library.
        recentPickedPhotos.removeAll { $0.data == data }
        recentPickedPhotos.insert(photo, at: 0)
        recentPickedPhotos = Array(recentPickedPhotos.prefix(3))
        showComposerTools = false
    }
}

struct ChatToolRow: View {
    @Environment(\.fadedPalette) private var palette
    let title: String
    let detail: String
    let icon: String
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title3).frame(width: 28).foregroundStyle(palette.cyan)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.semibold)).foregroundStyle(palette.text)
                Text(detail).font(.caption).foregroundStyle(palette.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(palette.secondary)
        }.frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .contentShape(Rectangle()).multilineTextAlignment(.leading)
    }
}

struct ChatAttachmentTile: View {
    @Environment(\.fadedPalette) private var palette
    let title: String
    let icon: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.title2)
            Text(title).font(.caption.weight(.semibold))
        }.frame(width: 88, height: 88).foregroundStyle(palette.text)
            .fadedGlassSurface(radius: 20)
    }
}
