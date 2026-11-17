import SwiftUI
import UIKit

extension ChatView {
    func everydayTools(close: @escaping () -> Void) -> some View {
        EverydayToolsView(api: demo ? nil : api as? LiveAPI, showAppleApps: !demo, draftTitle: "Brug i chat") { text in
            let existing = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            let contextSize = transportMessage.unicodeScalars.count - existing.unicodeScalars.count
            guard task == nil, !dictation.active,
                  let updated = EverydayDraft.appending(text, to: draft, limit: 2_000 - contextSize) else { return false }
            draft = updated
            close()
            return true
        }
    }

    func agentHandoff(_ text: String) -> some View {
        let bots = VillageBot.list(from: MigratedAppData.shared.villageBots)
        return NavigationStack {
            List {
                Section {
                    FadedDetailText("Vælg, hvem der får teksten som en kladde, og ret den før du sender.")
                    if text.unicodeScalars.count > 2_000 {
                        FadedDetailText("De første 2.000 tegn følger med. Hele svaret er stadig i Chat.")
                    }
                    if bots.isEmpty { FadedDetailText("Opret en agent under fanen Agenter først.") }
                    ForEach(bots) { bot in
                        NavigationLink {
                            BotComputerView(bot: bot, roster: bots, api: api as? LiveAPI,
                                            initialPrompt: String(text.unicodeScalars.prefix(2_000)))
                        } label: {
                            Label(bot.name, systemImage: "person.crop.circle")
                        }.frame(minHeight: 44)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background { FadedBackground() }
            .navigationTitle("Opgave til agent")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Luk") { agentTaskDraft = nil } }
            }
        }
    }

    func headerButton(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(label, systemImage: icon, action: action)
            .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
            .help(label)
    }

    func openComposerSettings() {
        composerFocused = false
        showChatSettings = true
    }

    var chatSettingsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FadedSpacing.m) {
                    StatsBar(turns: turns.count, streaming: task != nil)
                    if effectiveReplySource == .pc { modelControls }
                    if !demo { CloudModelSettings() }
                    if !demo { ComposioCloudSetup(api: api as? LiveAPI) }
                    if !demo { NvidiaCloudSetup(api: api as? LiveAPI) }
                    if !demo { OpenRouterCloudSetup(api: api as? LiveAPI) }
                    voiceControls
                    aiBoostControls
                    if demo { Text("Demotilstand · Ingen rigtige job").font(.headline) }
                    if let pc = api as? LiveAPI, !demo {
                        NavigationLink {
                            PCServiceLookupView(api: pc, service: .web, onUse: nil)
                        } label: {
                            Label("Søg på nettet via PC’en", systemImage: "magnifyingglass")
                                .frame(minHeight: 44)
                        }
                    }
                    Toggle("Vis kun favoritter", isOn: $favoritesOnly)
                    ShareLink(item: conversationText) {
                        Label("Eksportér samtale", systemImage: "square.and.arrow.up")
                            .frame(minHeight: 44)
                    }.disabled(turns.isEmpty)
                }
                .padding(FadedSpacing.edge)
            }
            .background { FadedBackground() }
            .navigationTitle("Chatindstillinger")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Luk") { showChatSettings = false }
                }
            }
        }
    }

    func acceptDroppedPhotos(_ items: [StudioPhotoInput]) -> Bool {
        guard task == nil, droppedPhoto == nil, stagedPhoto == nil else { return false }
        guard items.count == 1, let photo = items.first, let preview = UIImage(data: photo.data) else {
            if items.count > 1 { chatNotice = "Træk ét billede ad gangen." }
            return false
        }
        dictation.stop()
        composerFocused = false
        stagedPhoto = DroppedPhoto(data: photo.data, preview: preview)
        return true
    }

    func analyzeStagedPhoto() {
        guard task == nil, let stagedPhoto else { return }
        composerFocused = false
        droppedPhoto = stagedPhoto
        self.stagedPhoto = nil
    }

    func attachPhotoExcerpt(_ excerpt: String) {
        guard task == nil else { return }
        attachedNote = excerpt
        noteDestination = effectiveReplySource
        chatNotice = "Tekstuddraget er vedhæftet. Det sendes først, når du trykker Send."
    }}
