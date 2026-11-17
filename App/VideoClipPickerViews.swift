import SwiftUI

struct VideoFolderItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
}

struct VideoFolderCatalog: View {
    let folders: [VideoFolderItem]
    let lastOpened: String?
    let loading: Bool
    let onOpen: (String) -> Void
    let onRowAppeared: (String) -> Void

    var body: some View {
        if loading {
            LoadingSkeleton(label: "Henter spilmapper…")
        } else {
            ForEach(folders) { folder in
                VideoFolderRow(folder: folder, lastOpened: lastOpened == folder.id) {
                    onOpen(folder.id)
                }
                .onAppear { onRowAppeared(folder.id) }
            }
        }
    }
}

private struct VideoFolderRow: View {
    @Environment(\.fadedPalette) private var palette
    let folder: VideoFolderItem
    let lastOpened: Bool
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Label(folder.title, systemImage: "folder").font(.headline)
                    if lastOpened { Text("Senest åbnet").font(.caption).foregroundStyle(palette.secondary) }
                    if let subtitle = folder.subtitle { Text(subtitle).font(.caption).foregroundStyle(palette.secondary) }
                }
                Spacer()
                Image(systemName: "chevron.right").accessibilityHidden(true)
            }
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(FadedButtonStyle(kind: .secondary))
    }
}

struct VideoFolderScreen: View {
    let folderID: String
    let server: String?
    let list: VideoClipList?
    let loading: Bool
    let didLoad: Bool
    let notice: String?
    let onLoad: (Bool) async -> Void
    let onClipsAppeared: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: FadedSpacing.section) {
            if let list {
                list.onAppear(perform: onClipsAppeared)
            }
            if loading {
                LoadingSkeleton(label: "Henter klip i mappen…")
            } else if let notice {
                FadedDetailText(notice)
            } else if list == nil {
                FadedDetailText(didLoad ? "PC’en har ingen klip klar til valg i denne mappe. Klip må højst vare tre minutter."
                                        : "Henter klip i mappen…")
            }
            if list == nil || notice != nil {
                FadedSecondaryButton("Opdatér mappen", icon: "arrow.clockwise") {
                    Task { await onLoad(true) }
                }.disabled(loading)
            }
        }
        .task(id: server) { await onLoad(false) }
        .id(folderID)
    }
}

struct VideoClipList: View {
    @Environment(\.fadedPalette) private var palette
    @Environment(\.dynamicTypeSize) private var videoTypeSize
    let model: Model
    let clips: [Clip]
    @Binding var clipGame: String
    @Binding var shortClips: Bool
    @Binding var recentJobsFirst: Bool
    @Binding var clipDateRange: Int
    let compactClipCards: Bool
    let showClipDurations: Bool
    let onDone: () -> Void

    var body: some View {
        let filtered = filteredClips(clips)
        return VStack(alignment: .leading, spacing: FadedSpacing.section) {
            DisclosureGroup("Filtrér klip") {
                TextField("Søg i filnavn", text: $clipGame).textFieldStyle(.roundedBorder).frame(minHeight: 44)
                Toggle("Under ét minut", isOn: $shortClips)
                Toggle("Seneste jobdato først", isOn: $recentJobsFirst)
                Picker("Jobdato", selection: $clipDateRange) {
                    Text("Alle datoer").tag(0)
                    Text("Seneste 7 dage").tag(7)
                    Text("Seneste 30 dage").tag(30)
                }
                Text("Datoen kommer fra tidligere job med klippet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack { clipListActions(filtered, onDone: onDone) }
                VStack(alignment: .leading) { clipListActions(filtered, onDone: onDone) }
            }
            if filtered.isEmpty {
                FadedEmptyState(icon: "film", title: clips.isEmpty ? "Mappen er tom" : "Ingen klip matcher",
                                detail: clips.isEmpty ? "Tilføj et klip på PC’en, og opdatér mappen." : "Prøv et andet filnavn eller filter.",
                                actionTitle: clips.isEmpty ? nil : "Ryd filtre") {
                    clipGame = ""
                    shortClips = false
                    recentJobsFirst = false
                    clipDateRange = 0
                }
            } else {
                Text("PC’en sender klipnavne og varighed.").font(.caption).foregroundStyle(palette.secondary)
                LazyVGrid(columns: videoClipColumns, spacing: 12) {
                    ForEach(filtered) { clip in videoClipCard(clip) }
                }
            }
        }
    }

    @ViewBuilder private func clipListActions(_ clips: [Clip], onDone: @escaping () -> Void) -> some View {
        FadedSecondaryButton("Vælg synlige", icon: "checkmark.circle") { model.select(clips) }
            .disabled(model.busy || clips.isEmpty)
        FadedSecondaryButton("Færdig med klipvalg", icon: "chevron.up", action: onDone)
    }

    private var videoClipColumns: [GridItem] {
        videoTypeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 132, maximum: 260), spacing: 12)]
    }

    private func videoClipCard(_ clip: Clip) -> some View {
        let selected = model.selected.contains(clip.id)
        let shape = RoundedRectangle(cornerRadius: 14)
        return Button { model.toggle(clip) } label: {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [clipColor(clip).opacity(0.58), Color.black.opacity(0.88)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "film").font(.title2.weight(.light)).foregroundStyle(.white.opacity(0.72))
                    .frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityHidden(true)
                LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .center, endPoint: .bottom)
                Text(clip.name).font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.96))
                    .lineLimit(2).padding(10)
            }
            .frame(minHeight: compactClipCards ? 86 : 116)
            .overlay(alignment: .topLeading) {
                if selected {
                    Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(palette.lime)
                        .padding(6).background(.black.opacity(0.9), in: Circle()).padding(8)
                }
            }
            .overlay(alignment: .topTrailing) {
                if showClipDurations {
                    Text(durationLabel(clip.duration_seconds)).font(.caption.monospacedDigit())
                        .foregroundStyle(.white).padding(5).background(.black.opacity(0.9), in: Capsule()).padding(8)
                }
            }
            .clipShape(shape)
            .overlay { shape.strokeBorder(selected ? palette.lime : palette.border, lineWidth: selected ? 2 : 1) }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(clip.name), \(durationLabel(clip.duration_seconds))")
        .accessibilityValue(selected ? "Valgt" : "Ikke valgt")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .disabled(model.busy || (!selected && model.selected.count >= (model.capabilities?.limit ?? 0)))
    }

    private func filteredClips(_ source: [Clip]) -> [Clip] {
        let query = clipGame.trimmingCharacters(in: .whitespacesAndNewlines)
        let dates = Dictionary(model.jobs.map { ($0.clip_id, $0.created_at) }, uniquingKeysWith: max)
        let cutoff = Calendar.current.date(byAdding: .day, value: -clipDateRange, to: .now) ?? .distantPast
        let clips = source.filter {
            (!shortClips || $0.duration_seconds < 60) &&
                (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) &&
                (clipDateRange == 0 || (dates[$0.id] ?? .distantPast) >= cutoff)
        }
        guard recentJobsFirst else { return clips }
        return clips.sorted {
            let lhs = dates[$0.id] ?? .distantPast
            let rhs = dates[$1.id] ?? .distantPast
            return lhs == rhs ? $0.name < $1.name : lhs > rhs
        }
    }

    private func clipColor(_ clip: Clip) -> Color {
        let colors = [palette.green, palette.purple, palette.cyan, palette.coral]
        return colors[Int(clip.id.hashValue.magnitude % UInt(colors.count))]
    }
}

func durationLabel(_ seconds: Double) -> String {
    let value = max(0, Int(seconds.rounded()))
    return String(format: "%d:%02d", value / 60, value % 60)
}
