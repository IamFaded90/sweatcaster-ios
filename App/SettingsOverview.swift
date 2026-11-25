import SwiftUI

struct SettingsOverview<Destination: View>: View {
    let category: (Home.SettingsCategory) -> Destination
    let api: LiveAPI?
    @State private var query = ""
    @State private var showModels = false
    @State private var showVoices = false
    @State private var showConnections = false
    @ObservedObject private var voice = AgentVoiceDownload.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Gør FadedAI til din").font(.title2.bold())
            Text("Start med det, du vil ændre. Telefonen kan bruges selvstændigt, og din PC kan tilføjes, når du har brug for den.")
                .font(.subheadline).foregroundStyle(.secondary)
            TextField("Søg: stemmer, tema, modeller, fejl…", text: $query)
                .textFieldStyle(.roundedBorder).accessibilityLabel("Søg i indstillinger")
            if query.isEmpty {
                FadedCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Din iPhone", systemImage: "iphone").font(.headline)
                        Button("Modeller og lagerplads") { showModels = true }.frame(minHeight: 44)
                        Button(voice.installed ? "Dine ti hentede stemmer" : "Hent danske stemmer") { showVoices = true }.frame(minHeight: 44)
                        Button("Netværktøjer uden PC") { showConnections = true }.frame(minHeight: 44)
                    }
                }
            }
            ForEach(Home.SettingsCategory.allCases.filter(matches), id: \.self) { category($0) }
            if !Home.SettingsCategory.allCases.contains(where: matches) {
                ContentUnavailableView.search(text: query)
            }
        }
        .sheet(isPresented: $showModels) { PhoneModelsView() }
        .sheet(isPresented: $showVoices) { NavigationStack { SettingsDownloadedVoices().toolbar { Button("Færdig") { showVoices = false } } } }
        .sheet(isPresented: $showConnections) { AgentPhoneConnections(api: api) }
    }
    private func matches(_ item: Home.SettingsCategory) -> Bool {
        let words = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "da"))
            .split(whereSeparator: \.isWhitespace)
        let text = (item.rawValue + " " + item.detail + " " + item.searchKeywords)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "da"))
        return words.allSatisfy { text.contains($0) }
    }
}

struct SettingsDownloadedVoices: View {
    @AppStorage(AppStorageKeys.chatVoiceIdentifier) private var selected = ""
    @AppStorage(AppStorageKeys.chatVoiceBot) private var voiceBot = ""
    @StateObject private var speech = ChristelPlayer()
    @State private var preview: String?
    var body: some View {
        Form {
            Section { Text("Vælg standardstemmen til chatten. Hver agent kan fortsat have sin egen stemme valgt på profilen.") }
            AgentVoicePackSection(selected: selected, previewing: speech.playing || speech.loading ? preview : nil,
                choose: { selected = $0; voiceBot = "" }, preview: { voice in
                    if preview == voice.id && (speech.playing || speech.loading) { speech.stop(); preview = nil }
                    else { preview = voice.id; speech.playDownloaded(text: "Hej! Jeg er en af dine danske stemmer. Hvad har du lyst til i dag?", voice: voice, agentID: nil, rate: 1) }
                }, stop: { speech.stop(); preview = nil })
            if let notice = speech.notice { Text(notice) }
        }.scrollContentBackground(.hidden).background { FadedBackground() }
            .navigationTitle("Stemmer på telefonen").onDisappear { speech.stop() }
    }
}
