// Viser Video Studio, spilmapper, klipvalg og start af videojobs.

import SwiftUI
import UIKit

struct Media: Identifiable {
    let id = UUID()
    let url: URL
    let demo: Bool
}

extension Home {
    var videoStudio: some View {
        NavigationStack {
            videoPageContent
                .navigationTitle("Video Studio")
                .background { FadedBackground(variant: .standard) }
                .safeAreaInset(edge: .top, spacing: 0) { videoPageBar }
                .safeAreaInset(edge: .bottom, spacing: 0) { videoBottomBar }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Tilbage", systemImage: "chevron.left") { selectSpace(.brain) }
                    }
                    if videoPage == .clips && selectedGameFolder != nil {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Luk mappe", systemImage: "folder") { selectedGameFolder = nil }
                                .labelStyle(.iconOnly)
                        }
                    }
                }
                .onChange(of: model.selected) { if !model.selected.isEmpty { videoStartNotice = nil } }
        }
        .task(id: videoFolderScope) {
            guard let server = videoFolderScope, videoFolderServer != server else { return }
            await loadGameFolders(for: server)
        }
        .task(id: "\(videoFolderScope ?? ""):\(selectedGameFolder ?? "")") {
            guard let id = selectedGameFolder, let server = videoFolderScope else { return }
            await loadFolderPage(id, for: server)
        }
    }

    @ViewBuilder private var videoPageContent: some View {
        switch videoPage {
        case .clips:
            videoSection {
                videoStudioHeader
                clipSection { openVideoRecipe() }
            }
            .refreshable { await refreshVideoStudio() }
        case .recipe:
            videoSection {
                if model.selected.isEmpty {
                    FadedEmptyState(icon: "film", title: "Vælg klip først", detail: "Vælg op til 10 klip, og lav så din video.",
                                    actionTitle: "Åbn Klip") { videoPage = .clips }
                } else {
                    FadedDetailText("\(model.selected.count) klip valgt")
                }
                moodSection
            }
            .refreshable { await model.refresh() }
        case .jobs:
            ScrollViewReader { scroll in
                videoSection {
                    VStack(alignment: .leading, spacing: FadedSpacing.section) {
                        videoOutboxSection
                        jobSection
                    }.id("video-jobs-top")
                }
                .refreshable { await model.refresh() }
                .task(id: showJobs) { await revealVideoJob(scroll) }
            }
        }
    }

    private func videoSection<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FadedSpacing.section) {
                videoFeedback
                content()
            }
            .padding(FadedSpacing.edge).frame(maxWidth: 640).frame(maxWidth: .infinity)
        }
    }

    private var videoPageBar: some View {
        Group {
            if videoTypeSize.isAccessibilitySize { videoPagePicker.pickerStyle(.menu).frame(minHeight: 44) }
            else { videoPagePicker.pickerStyle(.segmented) }
        }
        .frame(maxWidth: 640).padding(FadedSpacing.edge).frame(maxWidth: .infinity)
        .background(palette.background)
    }

    private var videoPagePicker: some View {
        Picker("Sektion i Video Studio", selection: $videoPage) {
            ForEach(VideoPage.allCases) { page in Text(page.rawValue).tag(page) }
        }
    }

    @ViewBuilder private var videoBottomBar: some View {
        if !model.selected.isEmpty && videoPage != .jobs {
            Group {
                if videoPage == .clips {
                    FadedPrimaryButton("Gå til opskrift · \(model.selected.count) klip", icon: "arrow.right", action: openVideoRecipe)
                        .frame(maxWidth: 640)
                } else {
                    videoStartControls
                }
            }
            .padding(.horizontal, FadedSpacing.edge).padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(palette.raised.opacity(0.96))
        }
    }

    private func openVideoRecipe() {
        selectedGameFolder = nil
        videoPage = .recipe
    }

    private func revealVideoJob(_ scroll: ScrollViewProxy) async {
        let request = showJobs
        guard request > 0, handledVideoJobRequest != request else { return }
        let jobID = searchVideoJobID
        if let jobID {
            jobFilter = 0
            hiddenJobs.remove(jobID)
        }
        await Task.yield()
        guard !Task.isCancelled, videoPage == .jobs, request == showJobs else { return }
        handledVideoJobRequest = request
        searchVideoJobID = nil
        let target = jobID.flatMap { id in model.jobs.contains { $0.id == id } ? "video-job:\(id)" : nil }
        scroll.scrollTo(target ?? "video-jobs-top", anchor: .top)
        if target == nil { jobsFocus = true }
    }
    private var videoStudioHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            FadedSignature()
            FadedSectionLabel("Video Studio")
            Text("Skab noget, der rammer.").font(.largeTitle.bold())
                .foregroundStyle(palette.text).accessibilityAddTraits(.isHeader)
            Text("Vælg dine klip. Din agent klarer resten.")
                .font(.body).foregroundStyle(palette.secondary)
            FadedSecondaryButton(model.isDemo ? "Opdatér testklip" : "Opdatér spilmapper", icon: "arrow.clockwise") {
                Task { await refreshVideoStudio() }
            }.disabled(switchDisabled || catalogLoading != nil || pageLoading != nil)
        }
    }

    @ViewBuilder private var videoFeedback: some View {
        if let notice = model.videoStorageNotice {
            FadedCard(accent: palette.coral) { Label(notice, systemImage: "externaldrive.badge.exclamationmark") }
        }
        if model.selected.isEmpty, let message = videoStartNotice ?? model.errorTitle {
            FadedCard(accent: palette.coral) {
                Label(message, systemImage: "exclamationmark.circle").font(.headline)
                    .accessibilityFocused($errorFocus)
            }
        }
    }

    func startVideo(_ mood: Mood) {
        videoStartNotice = nil
        Task {
            let accepted = await model.submit(mood)
            if accepted || model.requiresVideoReview {
                selectedGameFolder = nil
                showJobs += 1
            } else if model.error == nil {
                videoStartNotice = videoStartBlocker ?? "Videojobbet blev ikke sendt. Kontrollér klipvalget, og prøv igen."
            }
        }
    }

    func clipColor(_ clip: Clip) -> Color {
        let colors = [palette.green, palette.purple, palette.cyan, palette.coral]
        return colors[Int(clip.id.hashValue.magnitude % UInt(colors.count))]
    }
    private var availableVideoMood: Mood? {
        let moods = videoMoods
        let preference = model.isDemo ? selectedVideoMood : model.lastVideoMood ?? .hype
        return moods.contains(preference) ? preference : moods.first
    }
    private var videoMoods: [Mood] {
        if let moods = model.capabilities?.moods { return moods }
        return model.connected ? [] : Mood.allCases
    }
    private var videoStartBlocker: String? {
        if model.requiresVideoReview { return "Tjek joblisten, før du starter et nyt job." }
        if model.checkingVideoOutbox { return "Kontrollerer den lokale videokø…" }
        if model.blocked { return "PC’en mangler en tjeneste. Se Status på PC’en under videoindstillinger." }
        if !model.options.roi.valid { return "Ret området til tekstlæsning i videoindstillinger." }
        if availableVideoMood == nil { return "PC’en har ingen tilgængelige stilarter." }
        if model.selected.count > (model.capabilities?.limit ?? 0) { return "PC’en tillader færre klip. Ryd klipvalget, og vælg igen." }
        if !model.cancelling.isEmpty { return "Venter på, at PC’en stopper videojobbet." }
        if !model.connected { return "Forbind til PC’en for at starte." }
        return nil
    }

    private var videoStartControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.connected && !model.isDemo {
                if let notice = videoStartNotice { Text(notice).font(.caption).foregroundStyle(palette.secondary) }
                Text("Køjob sendes første gang, når appen igen får kontakt til denne PC.")
                    .font(.caption).foregroundStyle(palette.secondary)
                FadedPrimaryButton("Gem i lokal kø · \(model.selected.count) klip", icon: "tray.and.arrow.down") {
                    guard let mood = availableVideoMood else { return }
                    if model.queueVideoOffline(mood) { selectedGameFolder = nil; videoStartNotice = "Videojob gemt på telefonen."; showJobs += 1 }
                    else { videoStartNotice = "Køjobbet kunne ikke gemmes. Kontrollér klipvalget." }
                }.disabled(!model.canQueueVideoOffline || availableVideoMood == nil)
            } else {
                if let message = videoStartNotice ?? model.errorTitle ?? videoStartBlocker {
                    Label(message, systemImage: "info.circle").font(.caption).foregroundStyle(palette.secondary)
                }
                FadedPrimaryButton(model.busy ? "Sender videojob…" : "Start videomagi · \(model.selected.count) klip",
                                   icon: "play.fill") {
                    guard let mood = availableVideoMood else { return }
                    if confirmVideoStart { pendingVideoMood = mood }
                    else { startVideo(mood) }
                }.disabled(!model.canSubmit || videoStartBlocker != nil)
            }
        }
        .frame(maxWidth: 640)
    }

    private var moodSection: some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 12) { videoRecipeContents }
        }
    }

    @ViewBuilder private var videoRecipeContents: some View {
            FadedSectionLabel("Opskrift")
            Text("Vælg din energi").font(FadedTypography.title).foregroundStyle(palette.text)
            if !videoMoods.isEmpty {
                let columns = videoTypeSize.isAccessibilitySize ? [GridItem(.flexible(), alignment: .leading)] :
                    [GridItem(.adaptive(minimum: 118), alignment: .leading)]
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(Mood.allCases.filter(videoMoods.contains)) { mood in
                        FadedChip(mood.title, accent: palette.lime, selected: availableVideoMood == mood) {
                            if model.isDemo { selectedVideoMood = mood }
                            else { model.rememberVideoMood(mood) }
                        }.disabled(model.busy)
                    }
                }
            }
            if !model.isDemo {
                Toggle("Kommentator", isOn: Binding(
                    get: { model.options.commentary != false },
                    set: { model.options.commentary = $0 ? nil : false }
                ))
                .tint(palette.lime).disabled(model.busy)
                Text(model.options.commentary == false ? "Video uden tale og undertekster" : "Engelsk reaktion med stemme og undertekster")
                    .font(.caption).foregroundStyle(palette.secondary)
            }
            Toggle("Fjern støj", isOn: Binding(get: { model.options.denoise }, set: { model.options.denoise = $0 }))
                .tint(palette.lime).disabled(model.busy)
            if let caps = model.capabilities {
                if model.blocked { Label("PC’en er ikke klar til at lave videoer.", systemImage: "exclamationmark.circle").font(.headline) }
                if !caps.dependencies.isEmpty {
                    DisclosureGroup("Status på PC’en") {
                        ForEach(caps.dependencies, id: \.name) { dependency in
                            Text(dependency.message)
                        }
                    }
                }
                if caps.moods.isEmpty { Text("PC’en tilbyder ingen stilarter lige nu.") }
            }
            advanced(Binding(get: { model.options }, set: { model.options = $0 }))
                .disabled(model.busy)
            Label(model.options.crop_mode == .auto ? "9:16 · Automatisk beskæring" : "9:16 · Beskær til midten",
                  systemImage: "aspectratio")
                .font(.caption.monospaced()).foregroundStyle(palette.secondary)
    }

    private func advanced(_ options: Binding<Options>) -> some View {
        DisclosureGroup("Avancerede indstillinger") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Beskæring", selection: options.crop_mode) {
                    Text("Automatisk").tag(Crop.auto)
                    Text("Midten").tag(Crop.center)
                }.frame(minHeight: 48)
                Text("Område til tekstlæsning").font(.headline)
                Text("Brug tal fra 0 til 1, målt fra øverste venstre hjørne.")
                coordinate("Fra venstre", options.roi.x)
                coordinate("Fra toppen", options.roi.y)
                coordinate("Bredde", options.roi.width)
                coordinate("Højde", options.roi.height)
                if !model.options.roi.valid {
                    Text("Området skal have en bredde og højde og ligge inden for billedet.")
                }
            }.padding(.top, 12)
        }
    }

    private func coordinate(_ title: String, _ value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            TextField(title, value: value, format: .number.locale(Locale(identifier: "da_DK")))
                .keyboardType(.numbersAndPunctuation).textFieldStyle(.roundedBorder)
                .frame(minHeight: 48)
        }
    }
    func heading(_ title: String) -> some View {
        Text(title).font(FadedTypography.title).tracking(-0.5).accessibilityAddTraits(.isHeader)
    }
    func action(_ title: String, _ work: @escaping () -> Void) -> some View {
        FadedSecondaryButton(title, action: work)
    }
}

extension Home {
    func clipSection(onDone: @escaping () -> Void) -> some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 12) {
                FadedSectionLabel("Vælg klip")
                Text("\(model.selected.count) valgt af maks. \(model.capabilities?.limit ?? 10)")
                    .font(.subheadline).foregroundStyle(palette.secondary)
                if !model.selected.isEmpty {
                    let seconds = model.clips.filter { model.selected.contains($0.id) }.reduce(0) { $0 + $1.duration_seconds }
                    Text("Valgt spilletid · \(durationLabel(seconds))").font(.caption.bold())
                        .foregroundStyle(palette.isDark ? palette.lime : palette.text)
                    FadedSecondaryButton("Ryd klipvalg", icon: "xmark") { model.clearSelection() }.disabled(model.busy)
                }
                if model.connected || model.isDemo {
                    videoFolders(onDone: onDone)
                } else {
                    Text(model.selected.isEmpty ? "PC’en er offline. Forbind igen for at hente klip." :
                            "PC’en er offline. Du kan gemme de valgte klip til senere.")
                        .font(.subheadline).foregroundStyle(palette.secondary)
                    ForEach(model.clips.filter { model.selected.contains($0.id) }) { clip in
                        Label(clip.name, systemImage: "film").font(.subheadline)
                    }
                }
                if let folderNotice { Text(folderNotice).font(.caption).foregroundStyle(palette.secondary) }
            }
        }
        .id("clips")
    }

    @ViewBuilder private func videoFolders(onDone: @escaping () -> Void) -> some View {
        if model.isDemo {
            clipFolder(id: "demo", title: "Testklip", subtitle: nil, onDone: onDone)
        } else if catalogLoading != nil || (videoFolderServer != model.address && folderNotice == nil) {
            LoadingSkeleton(label: "Henter spilmapper…")
        } else if videoFolderServer == model.address {
            if legacyClipCatalog {
                clipFolder(id: "legacy", title: "PC’ens V1-klipliste", subtitle: "Ældre server uden spilmapper", onDone: onDone)
            } else {
                ForEach(clipRoots) { root in
                    let subtitle = root.indexing || !root.ready ? "PC’en indekserer klip" : "\(root.file_count) filer på PC’en"
                    clipFolder(id: root.id, title: root.label, subtitle: subtitle, onDone: onDone)
                }
            }
        }
    }

    private func clipFolder(id: String, title: String, subtitle: String?, onDone: @escaping () -> Void) -> some View {
        let expanded = selectedGameFolder == id
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                selectedGameFolder = expanded ? nil : id
                if !expanded { model.rememberVideoFolder(id) }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(title, systemImage: expanded ? "folder.fill" : "folder")
                            .font(.headline)
                        if model.lastVideoFolder == id {
                            Text("Senest åbnet").font(.caption).foregroundStyle(palette.secondary)
                        }
                        if let subtitle { Text(subtitle).font(.caption).foregroundStyle(palette.secondary) }
                    }
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").accessibilityHidden(true)
                }.frame(minHeight: 48).contentShape(Rectangle())
            }
            .buttonStyle(FadedButtonStyle(kind: .secondary))
            .accessibilityValue(expanded ? "Åben" : "Lukket")
            if expanded {
                if id == "demo" {
                    clipList(model.clips, onDone: onDone)
                } else if pageLoading != nil {
                    LoadingSkeleton(label: "Henter klip i mappen…")
                } else if let clips = folderPages[id] {
                    clipList(clips, onDone: onDone)
                }
                if let notice = folderPageNotices[id] {
                    Text(notice).font(.caption).foregroundStyle(palette.secondary)
                    FadedSecondaryButton("Opdatér mappen", icon: "arrow.clockwise") {
                        guard let server = videoFolderScope else { return }
                        Task { await loadFolderPage(id, for: server, force: true) }
                    }
                }
            }
        }
    }

    private func clipList(_ clips: [Clip], onDone: @escaping () -> Void) -> some View {
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

    private func durationLabel(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", value / 60, value % 60)
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

    var videoFolderScope: String? {
        guard !privateStudioPresented else { return nil }
        guard phase == .active, space == .gallery, videoPage == .clips, selectedModuleTab == nil, model.connected else { return nil }
        return model.isDemo ? "demo" : model.address
    }

    func refreshVideoStudio() async {
        guard catalogLoading == nil, pageLoading == nil else { return }
        videoStartNotice = nil
        await model.refresh()
        guard let server = videoFolderScope else { return }
        await loadGameFolders(for: server)
        if let id = selectedGameFolder { await loadFolderPage(id, for: server, force: true) }
    }

    func loadGameFolders(for server: String) async {
        guard videoFolderScope == server else { return }
        if videoFolderServer != server {
            clipRoots = []
            folderPages = [:]
            folderPageNotices = [:]
            folderNotice = nil
            selectedGameFolder = nil
            legacyClipCatalog = false
        }
        if model.isDemo { videoFolderServer = server; return }
        guard let api = model.api as? LiveAPI else { return }
        let ticket = UUID()
        catalogLoading = ticket
        defer { if catalogLoading == ticket { catalogLoading = nil } }
        do {
            let roots = try await api.v2ClipRoots().roots
            guard !Task.isCancelled, videoFolderScope == server, catalogLoading == ticket else { return }
            videoFolderServer = server
            legacyClipCatalog = false
            var seen = Set<String>()
            clipRoots = roots.filter { root in
                (root.label.localizedCaseInsensitiveContains("fortnite") || root.label.localizedCaseInsensitiveContains("finals")) &&
                    seen.insert(root.id).inserted
            }
            if let id = selectedGameFolder, !clipRoots.contains(where: { $0.id == id }) { selectedGameFolder = nil }
            folderNotice = clipRoots.isEmpty ? "Ingen Fortnite- eller The Finals-mapper er sat op på PC’en." : nil
        } catch V2Failure.http(let status, _, _) where [404, 405, 501].contains(status) {
            AppDiagnostics.record(V2Failure.http(status: status, code: nil, message: nil))
            guard !Task.isCancelled, videoFolderScope == server, catalogLoading == ticket else { return }
            videoFolderServer = server
            clipRoots = []
            legacyClipCatalog = true
            if selectedGameFolder != "legacy" { selectedGameFolder = nil }
            folderNotice = nil
        } catch {
            AppDiagnostics.record(error)
            guard !Task.isCancelled, videoFolderScope == server, catalogLoading == ticket else { return }
            folderNotice = "Spilmapperne kunne ikke hentes. Tryk på Opdatér spilmapper for at prøve igen."
        }
    }

    func loadFolderPage(_ id: String, for server: String, force: Bool = false) async {
        guard videoFolderScope == server, videoFolderServer == server, !model.isDemo,
              let api = model.api as? LiveAPI,
              force || folderPages[id] == nil || folderPageNotices[id] != nil else { return }
        let ticket = UUID()
        pageLoading = ticket
        defer { if pageLoading == ticket { pageLoading = nil } }
        do {
            let clips: [Clip]
            let limit: Int
            let notice: String?
            if legacyClipCatalog && id == "legacy" {
                clips = try await api.clips().clips
                limit = 200
                notice = nil
            } else {
                guard clipRoots.contains(where: { $0.id == id }) else { return }
                let page = try await api.v2ClipPage(rootID: id, limit: 100)
                guard page.root_id == id else { throw V2Failure.invalidResponse }
                clips = page.clips
                limit = 100
                notice = page.ready && !page.indexing ? nil : "PC’en indekserer stadig klip. Opdatér mappen om lidt."
            }
            guard !Task.isCancelled, videoFolderScope == server, selectedGameFolder == id, pageLoading == ticket else { return }
            var seen = Set<String>()
            let pageClips = Array(clips.lazy.filter { validWireID($0.id) && seen.insert($0.id).inserted }.prefix(limit))
            folderPages[id] = pageClips
            folderPageNotices[id] = notice
            model.includeFolderClips(pageClips, folderID: id)
        } catch {
            AppDiagnostics.record(error)
            guard !Task.isCancelled, videoFolderScope == server, selectedGameFolder == id, pageLoading == ticket else { return }
            folderPageNotices[id] = "Klip i denne mappe kunne ikke hentes."
        }
    }
}
