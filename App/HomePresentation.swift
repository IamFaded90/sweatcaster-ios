// Håndterer login, præsentation og appens fælles PC-opdateringer.

import SwiftUI
import UIKit

extension Home {
    var homeLifecycle: some View {
        homeContent
        .onAppear {
            prunePreviews()
        }
        .onChange(of: model.error?.title) { _, title in
            errorDetails = false
            if title != nil { errorFocus = true }
        }
        .onChange(of: model.isDemo) { hiddenJobs.removeAll() }
        .onChange(of: model.address) { hiddenJobs.removeAll(); readJobCache(); refreshQueueBadge() }
        .onChange(of: (model.api as? LiveAPI)?.queueTargetID) { refreshQueueBadge() }
        .onChange(of: model.connected) { _, online in if online { cacheJobs() } }
        .onChange(of: model.jobs.map { "\($0.id):\($0.status.rawValue):\($0.progress)" }) { cacheJobs() }
    }

    private var homePresentation: some View {
        let design: Font.Design = font == "Afrundet" ? .rounded :
            (font == "Monospace" ? .monospaced : .default)
        return ZStack {
            homeBackground
            if !model.needsPairing || enteredWithoutPC {
                homeFeedback
                    .safeAreaInset(edge: .leading, spacing: 0) {
                        if teamPinned { teamRoster(close: nil).frame(width: teamSidebarCompact ? 64 : 300) }
                    }
                    .accessibilityHidden(showTeam && !teamPinned)
                if showTeam && !teamPinned {
                    Button { showTeam = false } label: {
                        Color.black.opacity(0.38).ignoresSafeArea()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Luk Holdet")
                    teamRoster(close: { showTeam = false })
                        .frame(maxWidth: 320)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                FadedLandingView(
                    openQRLogin: { showLogin = true },
                    enterLocally: { openLandingDestination(.tasks) },
                    openChatLocally: {
                        newChatRequest = UUID()
                        openLandingDestination(.notes)
                    },
                    openCodeLocally: { openLandingDestination(.library) }
                )
                .onAppear { onScreenAppeared?(.landing) }
            }
        }
        .fontDesign(design)
        .onChange(of: teamPinned) { _, pinned in
            if pinned { showTeam = false }
        }
    }

    private func openLandingDestination(_ destination: Space) {
        selectSpace(destination)
        enteredWithoutPC = true
    }

    private var homeStartup: some View {
        homePresentation
        .assistantShareInbox(api: studioAPI, enabled: !model.isDemo && !privateStudioPresented)
        .onAppear {
            FadedTheme.migrateIfNeeded()
            UIDevice.current.isBatteryMonitoringEnabled = true
            StudioScratch.purgeOnceAtLaunch()
            readJobCache()
            refreshQueueBadge()
            openShortcut()
        }
        .onOpenURL { url in
            guard url.scheme == "fadedai" else { return }
            if url.host == "agent-shortcut" {
                do { try AgentShortcutBridge.receive(url) } catch { AppDiagnostics.record(error) }
                return
            }
            switch url.host {
            case "video": openVideoJobs()
            case "code": selectSpace(.library)
            default: break
            }
        }
        .onChange(of: shortcut) { openShortcut() }
        .onReceive(NotificationCenter.default.publisher(for: PCChatOutbox.didChange)) { _ in refreshQueueBadge() }
        .onChange(of: phase, initial: true) { _, value in
            if value == .background { LocalCompute.suspend() }
            if value == .active { LocalCompute.resume() }
        }
        .task(id: renderActivityKey) {
            await RenderLiveActivity.shared.sync(jobs: model.jobs, codeJobs: model.observedCodeJobs,
                                                 videoWindow: model.jobsObservationWindow,
                                                 codeWindow: model.codeJobsObservationWindow, pairing: renderActivityPairing,
                                                 connected: model.connected, enabled: liveActivityEnabled)
        }
    }

    private func teamRoster(close: (() -> Void)?) -> some View {
        TeamRoster(api: studioAPI, studioUnlocked: $nsfwSessionUnlocked,
                   onPrivateSessionEnded: showPrivateSessionNotice, connectPC: { showLogin = true }, close: close,
                   compact: close == nil ? $teamSidebarCompact : .constant(false))
            .id(studioAPI?.queueTargetID ?? "phone")
    }

    func openTeam() {
        if teamPinned { teamSidebarCompact = false }
        else { showTeam = true }
    }

    private var homeNotices: some View {
        hubPresentation(homeStartup)
        .overlay(alignment: .top) {
            if let studioToast {
                Text(studioToast.text).font(.callout)
                    .padding(12).fadedGlassSurface(radius: 14, tint: FadedBrand.panel)
                    .padding(.top, 8)
            }
        }
        .task(id: studioToast?.id) {
            guard let id = studioToast?.id else { return }
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            if studioToast?.id == id { studioToast = nil }
        }
        .sheet(isPresented: $showLogin) {
            LoginView(model: model, close: { showLogin = false })
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSettings, onDismiss: openSettingsFollowup) { settingsSheet }
        .sheet(isPresented: $showPCStatus) {
            NavigationStack {
                PCStatusView(api: model.isDemo ? nil : model.api as? LiveAPI,
                             commentaryEnabled: model.options.commentary != false)
                    .toolbar { Button("Luk") { showPCStatus = false } }
            }
        }
        .sheet(isPresented: $showCodeAddOns) {
            NavigationStack {
                CodeAddOnsView(api: studioAPI)
                    .toolbar { Button("Luk") { showCodeAddOns = false } }
            }
        }
        .sheet(isPresented: $showConnections, onDismiss: {
            guard pairAfterConnections else { return }
            pairAfterConnections = false
            showLogin = true
        }) {
            NavigationStack {
                ConnectionsView(pcConnected: model.connected && !model.isDemo, openPairing: {
                    guard !switchDisabled else { return }
                    pairAfterConnections = true
                    showConnections = false
                }, pcAPI: model.isDemo || privateStudioPresented ? nil : model.api as? LiveAPI)
                .toolbar { Button("Luk") { showConnections = false } }
            }
        }
        .sheet(item: $diagnosticsExport) { DiagnosticsShareSheet(url: $0.url) }
        .alert("Fejlloggen kunne ikke eksporteres", isPresented: $diagnosticsError) {
            Button("OK", role: .cancel) {}
        }
    }

    private var homeVideoDialogs: some View {
        homeNotices
        .confirmationDialog("Slet den redigerede video fra PC’en?", isPresented: Binding(
            get: { pcDeletion != nil }, set: { if !$0 { pcDeletion = nil } }
        ), presenting: pcDeletion) { target in
            Button("Slet video fra PC’en", role: .destructive) {
                Task { await deletePCVideo(target.id, using: target.api) }
            }
        } message: { _ in
            Text("Originalklippet og eventuelle kopier på telefonen bevares.")
        }
        .confirmationDialog("Slet fejlet job fra PC’en?", isPresented: Binding(
            get: { failedJobDeletion != nil }, set: { if !$0 { failedJobDeletion = nil } }
        ), presenting: failedJobDeletion) { target in
            Button("Slet job og video", role: .destructive) {
                Task {
                    do {
                        try await target.api.deleteFailedJob(target.id)
                        await model.refresh()
                    } catch { AppDiagnostics.record(error); saveVideoNotice = "PC’en kunne ikke slette jobbet. Prøv at opdatere listen." }
                    failedJobDeletion = nil
                }
            }
        } message: { _ in Text("Sletter jobposten og et eventuelt videoudkast fra PC’en. Originalklippet bevares.") }
        .confirmationDialog(unavailableJobDeletion?.ids.count == 1 ? "Fjern det gamle jobkort?" : "Fjern gamle jobkort?", isPresented: Binding(
            get: { unavailableJobDeletion != nil }, set: { if !$0 { unavailableJobDeletion = nil } }
        ), presenting: unavailableJobDeletion) { target in
            Button(target.ids.count == 1 ? "Fjern jobkort" : "Fjern \(target.ids.count) jobkort", role: .destructive) {
                Task { await deleteUnavailableVideoJobs(target.ids, using: target.api) }
            }
        } message: { _ in Text("FadedAI fjerner jobkort uden en video på PC’en. Dine originalklip og gemte videoer bevares.") }
        .confirmationDialog("Start videomagi?", isPresented: Binding(
            get: { pendingVideoMood != nil }, set: { if !$0 { pendingVideoMood = nil } }
        ), presenting: pendingVideoMood) { mood in
            Button("Start \(mood.title)") { startVideo(mood); pendingVideoMood = nil }
            Button("Annuller", role: .cancel) { pendingVideoMood = nil }
        } message: { mood in
            Text("Starter \(model.selected.count) valgte klip med \(mood.title).")
        }
    }

    private var homeWorkspaceSheets: some View {
        homeVideoDialogs
        .sheet(isPresented: $showCodeWorkspace) {
            CodeWorkspaceView(api: studioAPI, onBack: { showCodeWorkspace = false }, initialPath: searchCodePath)
        }
        .sheet(item: $dashboardApproval) { approval in
            NavigationStack {
                Group {
                    if studioAPI?.queueTargetID == approval.api.queueTargetID {
                        BatchProposalView(api: approval.api, id: approval.id)
                    } else {
                        FadedEmptyState(icon: "desktopcomputer", title: "Forbind til din PC",
                                        detail: "Forslaget ligger på PC’en, hvor det blev lavet. Forbind igen for at se det.")
                    }
                }
                .toolbar { Button("Luk") { dashboardApproval = nil } }
            }
        }
        .sheet(isPresented: $showAttentionQueue) {
            NavigationStack {
                DashboardAttentionView(api: foregroundShortcutAPI) {
                    showAttentionQueue = false
                    openVideoJobs()
                }
                .toolbar { Button("Luk") { showAttentionQueue = false } }
            }
        }
        .sheet(isPresented: $showPhoneModels) { PhoneModelsView() }
        .sheet(isPresented: $showFadedCamera) { NavigationStack { FadedCaptureView(modal: true) } }
    }

    private var homeStudioSheets: some View {
        homeWorkspaceSheets
        .sheet(isPresented: $showOfflineStudio, onDismiss: openShortcut) {
            OfflineStudio(api: studioPage == .images ? foregroundShortcutAPI : studioAPI, sessionUnlocked: $nsfwSessionUnlocked,
                          onPrivateSessionEnded: showPrivateSessionNotice,
                          initialPage: studioPage == .chat ? nil : studioPage, initialImagePrompt: studioImagePrompt,
                          ephemeralOnly: studioPage == .chat, imageOnly: studioPage == .images,
                          privateImagePC: model.isDemo || model.needsPairing ? nil : model.api as? LiveAPI)
        }
        .sheet(isPresented: $showBots) {
            VillageBotLibrary(api: studioAPI, studioUnlocked: $nsfwSessionUnlocked,
                              onPrivateSessionEnded: showPrivateSessionNotice, onBack: { showBots = false })
        }
        .sheet(isPresented: $showNewBot) {
            VillageBotBuilder(api: studioAPI, onBack: { showNewBot = false })
        }
        .sheet(isPresented: $showSavedVideos) { savedVideoLibrary }
        .sheet(isPresented: $showProjects) { FadedProjectsView() }
    }

    var homeSheets: some View {
        homeStudioSheets
        .sheet(isPresented: $showHoldchatFromMore) {
            NavigationStack {
                TeamWorkflowView(mode: .group, bots: FadedMoreScreenData.bots, api: studioAPI)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Luk") { showHoldchatFromMore = false } } }
            }
        }
        .sheet(isPresented: $showBackupFromMore) {
            NavigationStack {
                BackupSettingsView(canRestore: {
                    !model.busy && !model.refreshing && !model.checkingVideoOutbox &&
                        !model.mediaLoading && model.cancelling.isEmpty
                }, onRestore: {
                    UserDefaults.standard.set(UUID().uuidString, forKey: AppStorageKeys.appResetGeneration)
                })
                .onAppear { showingBackupTools = true }
                .onDisappear { showingBackupTools = false }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Luk") { showBackupFromMore = false } } }
            }
        }
        .sheet(isPresented: $showHelp) {
            NavigationStack {
                V0HelpView()
                    .toolbar { Button("Luk") { showHelp = false } }
            }
        }
    }

    var homeSearchPresentation: some View {
        homePolling
            .sheet(isPresented: $showSearch, onDismiss: followSearchResult) {
                FadedSearchSheet(index: FadedSearchIndex(records: searchRecords)) { destination in
                    searchDestination = destination
                    showSearch = false
                }
            }
            .sheet(item: $searchBot, content: presentSearchBot)
            .sheet(isPresented: $showMorningOverview) { MorningOverviewSheet(api: studioAPI) }
            .sheet(isPresented: $showNotes) { FadedNotesSheet(onClose: { showNotes = false }) }
    }

    func refreshAfterChat() {
        preferPhoneInChat = false
        searchChatQuery = ""
        newChatRequest = nil
        refreshDashboard()
        if privateStudioAfterChat {
            privateStudioAfterChat = false
            openStudio(.chat)
            return
        }
        if let prompt = imagePromptAfterChat {
            imagePromptAfterChat = nil
            openStudio(.images, prompt: prompt)
            return
        }
        if agentsAfterChat {
            agentsAfterChat = false
            openLandingDestination(.tasks)
            return
        }
        guard !model.isDemo else { return }
        Task { await model.refresh() }
    }

    func openPhoneChat() {
        preferPhoneInChat = true
        openChat()
    }

    func openNewChat() {
        newChatRequest = UUID()
        openChat()
    }

    func openChat() {
        if model.needsPairing { showChat = true }
        else { selectSpace(.notes) }
    }

    private func reconnectFromChat() {
        if model.needsPairing {
            showChat = false
        } else {
            Task { await model.refresh() }
        }
    }

    var chatSheet: some View { chatContent(embedded: false) }

    func chatContent(embedded: Bool, onComposerFocusChange: ((Bool) -> Void)? = nil) -> some View {
        let session = model.isDemo ? "demo" : (model.address.isEmpty ? "offline" : model.address)
        let api: (any ChatAPI)? = model.connected || model.isDemo ? model.api as? any ChatAPI : nil
        let status = model.connected ? "Forbundet" : "Ikke forbundet"
        let connection = model.isDemo ? "Demo · Testdata" : "\(model.activeProfile.route) · \(status)"
        let target = model.api as? LiveAPI
        return ChatView(api: api, demo: model.isDemo, initialDraft: "", connection: connection,
                        storageKey: AppStorageKeys.chatSession(session), onBack: {
                            if embedded { goBackFromChat() }
                            else { showChat = false }
                        }, openHome: {
                            showChat = false
                            openLandingDestination(.brain)
                        }, openImageStudio: { prompt in
                            if embedded { openStudio(.images, prompt: prompt) }
                            else { openImagesFromChat(prompt) }
                        }, pcTargetAddress: target?.server.address,
                        pcQueueTargetID: target?.queueTargetID,
                        pcConnectionError: model.error, reconnectPC: reconnectFromChat,
                        initialSearch: searchChatQuery, openPrivateStudio: {
                            if embedded { openStudio(.chat) }
                            else {
                                privateStudioAfterChat = true
                                showChat = false
                            }
                        }, preferPhone: preferPhoneInChat, embedded: embedded,
                        newConversationRequest: newChatRequest,
                        onConsumeNewConversation: { newChatRequest = nil },
                        openBots: {
                            if embedded { selectSpace(.tasks) }
                            else {
                                agentsAfterChat = true
                                showChat = false
                            }
                        }, onConsumeSearch: { searchChatQuery = "" },
                        onConsumePhonePreference: { preferPhoneInChat = false },
                        onComposerFocusChange: onComposerFocusChange)
            .id(session)
    }

    var studioAPI: LiveAPI? {
        privateStudioPresented || model.isDemo || !model.connected ? nil : model.api as? LiveAPI
    }

    // Explicit foreground shortcuts keep their PC access when opened from Privat chat.
    // The chat and its background work still use studioAPI's private-session gate.
    private var foregroundShortcutAPI: LiveAPI? {
        model.isDemo || model.needsPairing || !model.connected ? nil : model.api as? LiveAPI
    }

    func openStudio(_ page: OfflineStudio.Page, prompt: String = "") {
        if page == .chat {
            selectSpace(.privateChat)
            return
        }
        studioPage = page
        studioImagePrompt = prompt
        showOfflineStudio = true
    }

    private func openImagesFromChat(_ prompt: String) {
        imagePromptAfterChat = prompt
        showChat = false
    }

    func showPrivateSessionNotice() {
        studioToast = StudioToast(text: "Privat session afsluttet og slettet.")
    }

    private var renderActivityKey: String {
        let video = model.jobs.filter { $0.status.active }.map { "\($0.id):\($0.status.rawValue):\($0.progress):\($0.updated_at.timeIntervalSinceReferenceDate)" }
        let code = model.observedCodeJobs.filter { $0.status == "queued" || $0.status == "running" }.map { "\($0.id):\($0.status)" }
        let connection = "\(liveActivityEnabled):\(phase == .active):\(renderActivityPairing ?? ""):\(model.connected)"
        return "\(connection):\(model.jobsObservationWindow):\(model.codeJobsObservationWindow):" + (video + code).joined(separator: ",")
    }

    private var renderActivityPairing: String? {
        guard !model.isDemo, !model.needsPairing, !model.address.isEmpty,
              let live = model.api as? LiveAPI else { return nil }
        let reset = model.defaults.string(forKey: AppStorageKeys.appResetGeneration) ?? ""
        return "\(live.queueTargetID):\(reset)"
    }

    var switchDisabled: Bool {
        model.busy || model.refreshing || model.checkingVideoOutbox || model.mediaLoading || !model.cancelling.isEmpty
    }
}

extension Home {
    var homePolling: some View {
        homeSheets
            .task { await JobNotifications.shared.configure() }
            .traderaAlerts(using: phase == .active && model.connected && !privateStudioPresented && !showingBackupTools ? studioAPI : nil)
            .task(id: phase == .active && !privateStudioPresented && !showingBackupTools && !model.needsPairing) {
                guard phase == .active, !privateStudioPresented, !showingBackupTools, !model.needsPairing else { return }
                await supervisePC()
            }
    }

    @MainActor
    private func supervisePC() async {
        let clock = ContinuousClock()
        var nextVideo = clock.now.advanced(by: .seconds(2))
        var nextCode = clock.now
        var nextRecovery = clock.now.advanced(by: .seconds(8))
        var recoveryDelay = 8
        var pollingTarget: String?
        var codeAvailable = true
        var lastCodeRevision = model.revision
        var codePoll: Task<Void, Never>?
        var deliveryTarget: String?
        var delivery: Task<Void, Never>?
        var needsVideoDelivery = false
        var nextDelivery = clock.now
        defer {
            codePoll?.cancel()
            delivery?.cancel()
        }

        await model.refresh()
        while !Task.isCancelled {
            let live = !model.isDemo ? model.api as? LiveAPI : nil
            let target = live?.queueTargetID
            if lastCodeRevision != model.revision {
                lastCodeRevision = model.revision
                codePoll?.cancel()
                codePoll = nil
                codeAvailable = true
                nextCode = clock.now
            }
            if pollingTarget != target {
                codePoll?.cancel()
                codePoll = nil
                pollingTarget = target
                nextCode = clock.now
                nextRecovery = clock.now.advanced(by: .seconds(8))
                recoveryDelay = 8
                codeAvailable = true
            }

            let eligible = model.connected && !model.requiresVideoReview ? target : nil
            if deliveryTarget != eligible {
                delivery?.cancel()
                delivery = nil
                deliveryTarget = eligible
                needsVideoDelivery = eligible != nil
                nextDelivery = clock.now
            }
            if let eligible, let live, delivery == nil, clock.now >= nextDelivery,
               needsVideoDelivery || queuedChatCount > 0 {
                let sendVideos = needsVideoDelivery
                needsVideoDelivery = false
                nextDelivery = clock.now.advanced(by: .seconds(8))
                delivery = Task { @MainActor in
                    defer {
                        if !Task.isCancelled { delivery = nil }
                    }
                    if sendVideos { await model.deliverQueuedVideos() }
                    guard !Task.isCancelled, model.connected, !model.requiresVideoReview,
                          (model.api as? LiveAPI)?.queueTargetID == eligible else { return }
                    await PCChatOutbox().deliverReady(using: live)
                }
            }

            if live != nil && !model.connected {
                codePoll?.cancel()
                codePoll = nil
                if clock.now >= nextRecovery, shouldRecoverPC {
                    await model.refresh()
                    if model.connected {
                        recoveryDelay = 8
                        codeAvailable = true
                        nextCode = clock.now
                    } else {
                        recoveryDelay = min(recoveryDelay * 2, 64)
                    }
                    nextRecovery = clock.now.advanced(by: .seconds(recoveryDelay))
                }
            } else {
                recoveryDelay = 8
                nextRecovery = clock.now.advanced(by: .seconds(recoveryDelay))
                if model.hasActive && clock.now >= nextVideo {
                    await model.poll()
                    nextVideo = clock.now.advanced(by: .seconds(2))
                }
                if !Task.isCancelled, model.connected, let target, codeAvailable, codePoll == nil, clock.now >= nextCode {
                    let codeRevision = lastCodeRevision
                    nextCode = clock.now.advanced(by: .seconds(8))
                    codePoll = Task { @MainActor in
                        let available = await model.pollCodeJobs()
                        guard !Task.isCancelled, (model.api as? LiveAPI)?.queueTargetID == target else { return }
                        if model.revision == codeRevision { codeAvailable = available }
                        codePoll = nil
                    }
                }
            }
            do { try await Task.sleep(for: .seconds(1)) }
            catch is CancellationError { return }
            catch { AppDiagnostics.record(error); return }
        }
    }

    private var shouldRecoverPC: Bool {
        switch model.error {
        case .offline?, .localNetwork?, .transport(_)?, nil: true
        default: false
        }
    }
}

struct TeamSidebarRail: View {
    let page: TeamRoster.Page
    let approvals: Int
    let open: (TeamRoster.Page?) -> Void
    @Environment(\.fadedPalette) private var palette

    var body: some View {
        VStack(spacing: FadedSpacing.s) {
            Button("Udvid Holdet", systemImage: "sidebar.left") { open(nil) }
                .labelStyle(.iconOnly).frame(width: 44, height: 44)
            shortcut(.roster, icon: "person.2")
            shortcut(.approvals, icon: "checkmark.seal", count: approvals)
            shortcut(.workflows, icon: "list.bullet")
        }
        .padding(.top, FadedSpacing.s)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func shortcut(_ target: TeamRoster.Page, icon: String, count: Int = 0) -> some View {
        let selected = page == target
        return Button { open(target) } label: {
            Image(systemName: icon)
                .foregroundStyle(selected ? FadedColors.deep : palette.text)
                .frame(width: 44, height: 44)
                .background(selected ? palette.lime : Color.clear, in: .rect(cornerRadius: FadedRadius.small))
                .overlay(alignment: .topTrailing) {
                    if count > 0 {
                        Text(count > 9 ? "9+" : "\(count)")
                            .font(.caption2.monospacedDigit())
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                            .foregroundStyle(FadedColors.deep)
                            .padding(.horizontal, FadedSpacing.xs)
                            .background(palette.lime, in: Capsule())
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(target.rawValue)
        .accessibilityValue(count > 0 ? "\(count) forslag" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
