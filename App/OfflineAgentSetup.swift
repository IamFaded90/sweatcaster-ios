import CoreMLLLM
import SwiftUI

@MainActor struct OfflineAgentSetup: View {
    let bot: VillageBot
    @Binding var model: String
    @Binding var voice: String
    @Binding var language: String
    var api: LiveAPI? = nil
    let startConversation: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.fadedPalette) private var palette
    @State private var capture = AgentWhisperCapture()
    @State private var showModels = false
    @State private var showVoices = false
    @State private var voiceLanguage = "da-DK"
    @State private var revision = 0
    @State private var notice: String?
    @State private var installation: Task<Void, Never>?
    @ObservedObject private var pack = AgentVoiceDownload.shared
    private var downloads: GGUFModelDownloads { .shared }
    private var identifier: String { voice.isEmpty ? bot.voice : voice }
    private var installedChat: GGUFPhoneModel? { _ = revision; return OfflineAgentModels.installedChat }
    private var readiness: OfflineAgentPolicy.VoiceReadiness {
        OfflineAgentPolicy.voiceReadiness(chatReady: PhoneModels.isReady(model),
            dictationReady: !AgentWhisper.availableModels(for: language).isEmpty,
            pcVoice: AgentPCVoice(rawValue: identifier) != nil,
            downloadedVoice: DownloadedAgentVoice.selected(identifier) != nil,
            packReady: AgentVoiceDownload.ready(selection: identifier),
            systemVoiceReady: AgentVoiceSelection.resolve(identifier: identifier, language: language) != nil)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FadedSpacing.section) {
                    Text("\(bot.name) — også uden PC").font(.title2.bold())
                    FadedDetailText("Hent det, du vil bruge, én gang. Derefter bliver samtale, billedanalyse og tale på din iPhone.")
                    chatCard
                    visionCard
                    voiceCard
                    ComposioCloudSetup(api: api)
                    if let notice { FadedDetailText(notice) }
                }.padding(FadedSpacing.edge)
            }
            .background { FadedBackground() }
            .foregroundStyle(palette.text)
            .navigationTitle("Klar uden PC")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Luk") { dismiss() } }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    if let message = readiness.message { FadedDetailText(message) }
                    FadedPrimaryButton("Start offline samtale", icon: "waveform") { startConversation(); dismiss() }
                        .disabled(readiness != .ready || capture.installing)
                }.padding(FadedSpacing.edge).background(.ultraThinMaterial)
            }
        }
        .sheet(isPresented: $showModels, onDismiss: { revision += 1 }) { PhoneModelsView() }
        .sheet(isPresented: $showVoices) {
            AgentVoicePicker(botID: bot.id, name: bot.name, inheritedVoice: bot.voice,
                rate: bot.voiceRate ?? 1, api: nil, selection: $voice, language: $voiceLanguage, offlineOnly: true)
        }
        .onAppear { downloads.activate(); voiceLanguage = language }
        .onChange(of: downloads.revision) { revision += 1 }
        .onDisappear { installation?.cancel(); capture.cancelInstallation() }
    }

    private var chatCard: some View {
        FadedCard(accent: palette.lime) {
            VStack(alignment: .leading, spacing: 10) {
                Label("En større chathjerne", systemImage: "bubble.left.and.bubble.right").font(.headline)
                Text("Qwen3 4B · samtale").font(.title3.bold())
                FadedDetailText("Et ekstra valg til dansk chat. Ca. 2,5 GB at hente. Vi beholder dine nuværende modeller.")
                if let installedChat {
                    FadedDetailText(PhoneMemoryBudget.assess(installedChat).explanation)
                    FadedSecondaryButton(model == installedChat.id ? "Valgt til \(bot.name)" : "Brug til \(bot.name)", icon: "checkmark.circle") {
                        model = installedChat.id
                    }.disabled(model == installedChat.id)
                } else if downloads.pending != nil {
                    GGUFTransferStatus()
                } else {
                    FadedSecondaryButton("Hent Qwen3 4B · 2,5 GB", icon: "arrow.down.circle") { downloads.start(OfflineAgentModels.chat) }
                        .disabled(ModelDownloader.shared.isDownloading || PhoneModelDownloads.shared.preparingModelID != nil)
                }
                if let message = downloads.notice { FadedDetailText(message) }
                if PhoneModels.isReady(model) { FadedDetailText("Valgt: " + PhoneModels.textModelName(model)) }
                FadedSecondaryButton("Alle modeller og hastighedstest", icon: "cpu") { showModels = true }
            }
        }
    }

    private var visionCard: some View {
        FadedCard(accent: palette.cyan) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Vis mig billedet", systemImage: "photo").font(.headline)
                if let id = PhoneModels.preferredVisionModel(preferred: model) {
                    FadedDetailText("Klar: " + PhoneModels.textModelName(id))
                } else {
                    FadedDetailText("Hent en billedforståelsesmodel under Lokale modeller. Billedtekst kan allerede læses uden en ekstra model.")
                }
                Text("Vedhæft et foto eller screenshot i chatten, og spørg fx: Hvad betyder fejlen?")
                FadedSecondaryButton("Se billedforståelsesmodeller", icon: "arrow.down.circle") { showModels = true }
            }
        }
    }

    private var voiceCard: some View {
        FadedCard(accent: palette.lime) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Tal sammen offline", systemImage: "mic").font(.headline)
                Picker("Jeg taler", selection: $language) {
                    Text("Dansk").tag("da-DK")
                    Text("Engelsk").tag("en-US")
                }.pickerStyle(.segmented).disabled(capture.installing)
                let variant: AgentWhisper.Model = language.hasPrefix("en") ? .base : .danish
                if variant.installed { Label("Diktering hentet", systemImage: "checkmark.circle") }
                else if capture.installing {
                    ProgressView("Henter diktering…")
                    Button("Stop hentning") { capture.cancelInstallation() }
                } else {
                    FadedSecondaryButton(variant == .danish ? "Hent dansk diktering · 264 MB" : "Hent engelsk diktering · 60 MB", icon: "arrow.down.circle") {
                        installation = Task {
                            do { try await capture.install(variant); revision += 1 }
                            catch { if !Task.isCancelled { notice = "Dikteringen kunne ikke hentes. Prøv igen." } }
                        }
                    }
                }
                if let local = DownloadedAgentVoice.selected(identifier) { Text("Valgt: " + local.name) }
                else if AgentPCVoice(rawValue: identifier) != nil { FadedDetailText("Din valgte stemme kræver PC’en. Vælg en anden her for at tale offline.") }
                FadedDetailText(pack.installed ? "10 stemmer er hentet. Du bestemmer, hvem der får hvilken." : "Fem kvinde- og fem mandestemmer kan hentes og bruges uden PC.")
                FadedSecondaryButton("Vælg og hør offline-stemmer", icon: "speaker.wave.2") { voiceLanguage = language; showVoices = true }
            }
        }
    }
}
