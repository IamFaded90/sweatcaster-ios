import SwiftUI

struct DashboardActivityScreen: View {
    let connection: DashboardConnectionStatus
    let queue: DashboardActivityQueue
    let approval: () -> DashboardStatusCard?
    let activeJob: () -> DashboardActiveJobCard?
    @Binding var recentChats: [ChatTurn]
    @Binding var savedVideos: [URL]
    let openRecentChat: (ChatTurn) -> Void
    let playVideo: (URL) -> Void
    let openVideoLibrary: () -> Void
    let refresh: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: FadedSpacing.section) {
                connection
                queue
                if let approval = approval() { approval }
                if let activeJob = activeJob() { activeJob }
                DashboardActivityHistory(recentChats: recentChats, savedVideos: savedVideos,
                                         openRecentChat: openRecentChat, playVideo: playVideo,
                                         openVideoLibrary: openVideoLibrary)
            }
            .padding(FadedSpacing.edge)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background { FadedBackground() }
        .navigationTitle("Seneste aktivitet")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { refresh() }
    }
}

struct DashboardConnectionStatus: View {
    let model: Model
    @Binding var errorDetails: Bool
    let errorFocus: AccessibilityFocusState<Bool>.Binding
    let switchDisabled: () -> Bool
    let fixError: (AppErrorPresentation.FixAction) -> Void
    let openPhoneChat: () -> Void
    @Environment(\.fadedPalette) private var palette

    var body: some View {
        if model.connected, let error = model.errorPresentation {
            VStack(alignment: .leading, spacing: 6) {
                Text(error.title).font(.headline).accessibilityFocused(errorFocus)
                if let detail = error.detail {
                    DisclosureGroup("Tekniske detaljer", isExpanded: $errorDetails) {
                        Text(detail).textSelection(.enabled)
                    }
                }
                FadedSecondaryButton(error.fixAction.title) { fixError(error.fixAction) }
                    .disabled(switchDisabled())
                FadedCopyErrorButton(title: error.title)
            }
        } else if !model.isDemo, !model.connected {
            FadedCard(accent: model.refreshing ? palette.cyan : palette.coral) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.refreshing ? "Opdaterer forbindelsen…" : (model.errorTitle ?? "Tjekker PC’en…"))
                        .font(FadedTypography.action)
                    if !model.refreshing, let error = model.errorPresentation {
                        FadedSecondaryButton("Brug Telefon", icon: "iphone", action: openPhoneChat)
                        FadedSecondaryButton(error.fixAction.title, icon: "arrow.clockwise") { fixError(error.fixAction) }
                        FadedCopyErrorButton(title: error.title)
                    }
                }
            }
        }
    }
}

struct DashboardActivityQueue: View {
    let model: Model
    @Binding var queuedChatCount: Int
    @Binding var chatReviewCount: Int
    let openChat: () -> Void
    let openVideoJobs: () -> Void
    @Environment(\.fadedPalette) private var palette

    static func needsAttention(model: Model, chatReviewCount: Int) -> Bool {
        chatReviewCount > 0 || model.requiresVideoReview || model.videoOutbox.contains {
            $0.state == .rejected || ($0.state == .attempted && !model.checkingVideoOutbox)
        }
    }

    var body: some View {
        let videos = model.videoOutbox.count
        if !model.isDemo && (model.requiresVideoReview || queuedChatCount + chatReviewCount + videos > 0) {
            let needsAttention = Self.needsAttention(model: model, chatReviewCount: chatReviewCount)
            FadedCard(accent: needsAttention ? palette.coral : palette.cyan) {
                VStack(alignment: .leading, spacing: 8) {
                    FadedSectionLabel("Udbakke")
                    if queuedChatCount > 0 {
                        FadedSecondaryButton("Chat i kø · \(queuedChatCount)", icon: "bubble.left", action: openChat)
                    }
                    if chatReviewCount > 0 {
                        FadedSecondaryButton("Tjek afsendelse · \(chatReviewCount)", icon: "exclamationmark.circle", action: openChat)
                    }
                    if videos > 0 {
                        FadedSecondaryButton("Videokø · \(videos)", icon: "film", action: openVideoJobs)
                    }
                    if model.requiresVideoReview {
                        FadedSecondaryButton("Tjek dit videojob", icon: "exclamationmark.circle", action: openVideoJobs)
                    }
                }
            }
        }
    }
}

struct DashboardStatusCard: View {
    let title: String
    let detail: String
    let icon: String
    let accent: Color
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        FadedCard(accent: accent) {
            VStack(alignment: .leading, spacing: FadedSpacing.s) {
                Label(title, systemImage: icon).font(FadedTypography.action)
                FadedDetailText(detail)
                FadedSecondaryButton(actionTitle, action: action)
            }
        }
    }
}

struct DashboardActiveJobCard: View {
    let job: Home.DashboardJob
    let isCurrent: Bool
    let followVideo: () -> Void
    @Environment(\.fadedPalette) private var palette

    var body: some View {
        FadedCard(accent: palette.cyan) {
            VStack(alignment: .leading, spacing: FadedSpacing.s) {
                FadedSectionLabel("I gang")
                FadedDetailText(job.mood.title)
                VideoJobStatusLine(status: job.status, progress: job.progress, isCurrent: isCurrent, accent: palette.cyan)
                FadedSecondaryButton("Følg video", icon: "film", action: followVideo)
            }
        }
    }
}

private struct DashboardActivityHistory: View {
    let recentChats: [ChatTurn]
    let savedVideos: [URL]
    let openRecentChat: (ChatTurn) -> Void
    let playVideo: (URL) -> Void
    let openVideoLibrary: () -> Void
    @Environment(\.fadedPalette) private var palette

    var body: some View {
        resumeActivity
        chats
        videos
    }

    @ViewBuilder private var resumeActivity: some View {
        if !recentChats.isEmpty || !savedVideos.isEmpty {
            FadedCard {
                VStack(alignment: .leading, spacing: FadedSpacing.section) {
                    FadedSectionHeader("Fortsæt hvor du slap")
                    if let turn = recentChats.first {
                        Button { openRecentChat(turn) } label: {
                            Label(turn.prompt, systemImage: "bubble.left")
                                .lineLimit(2).frame(minHeight: 44, alignment: .leading)
                        }.buttonStyle(.plain).accessibilityHint("Find beskeden i chatarkivet")
                    }
                    if let file = savedVideos.first {
                        FadedSecondaryButton("Afspil seneste gemte video", icon: "play.circle") { playVideo(file) }
                    }
                }
            }
        }
    }

    @ViewBuilder private var chats: some View {
        if !recentChats.isEmpty {
            FadedSectionLabel("Sidste chats")
            ForEach(recentChats) { turn in
                FadedCard(accent: sourceColor(turn.source)) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(turn.prompt).font(FadedTypography.body).lineLimit(2)
                        if let date = turn.createdAt { Text(date, format: .dateTime.day().month().hour().minute()) }
                    }.foregroundStyle(palette.text)
                }
            }
        } else {
            FadedDetailText("Samtaler dukker op her, når du har skrevet i chatten.")
        }
    }

    private var videos: some View {
        VStack(alignment: .leading, spacing: FadedSpacing.section) {
            FadedSectionHeader("Gemte videoer")
            if savedVideos.isEmpty {
                FadedDetailText("Gem en færdig video fra Video Studio for at se den her.")
            }
            ForEach(savedVideos.prefix(3), id: \.self) { file in
                Button { playVideo(file) } label: { DashboardVideoCard(file: file) }
                    .buttonStyle(.plain)
            }
            FadedSecondaryButton("Åbn videobibliotek", icon: "film.stack", action: openVideoLibrary)
        }
    }

    private func sourceColor(_ source: String?) -> Color {
        if source == GrokAPI.sourceLabel { return palette.purple }
        if source == "PC" { return palette.cyan }
        return palette.green
    }
}
