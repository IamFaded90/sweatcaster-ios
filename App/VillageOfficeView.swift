import SwiftUI

struct VillageOfficeView: View {
    let bots: [VillageLifeBot]
    var onOpenProfile: (VillageLifeBot) -> Void
    var onOpenComputer: (VillageLifeBot) -> Void

    @Environment(\.fadedPalette) private var palette
    @State private var search = ""

    private var filteredBots: [VillageLifeBot] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return bots }
        return bots.filter { $0.displayName.localizedCaseInsensitiveContains(query) ||
                             $0.zoneID.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Personlige computere")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("Hver bot har sit eget rum, også når PC’en er slukket.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Find en bot", text: $search)
                    .textInputAutocapitalization(.never)
                    .padding(12)
                    .fadedGlassSurface(radius: FadedRadius.medium)

                LazyVStack(spacing: 10) {
                    ForEach(filteredBots) { bot in
                        officeBotRow(bot)
                    }
                }
                if filteredBots.isEmpty {
                    Text("Ingen botter matcher din søgning.")
                        .foregroundStyle(palette.secondary)
                }
            }
            .padding(FadedSpacing.edge)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background { FadedBackground(variant: .village) }
        .navigationTitle("Kontoret")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func officeBotRow(_ bot: VillageLifeBot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VillagePixelImage(name: "room-" + VillageAssets.newArtName(name: bot.displayName, id: bot.id),
                                  folder: "new", width: 92, height: 74)
                    .clipShape(.rect(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(bot.displayName).font(FadedTypography.section).lineLimit(1)
                    Text(bot.poseLabel + " · " + bot.zoneID.title)
                        .font(.caption)
                        .foregroundStyle(palette.secondary)
                        .lineLimit(2)
                    if bot.pcJobRunning, let live = bot.pcLiveLabel {
                        Text(live).font(.caption2).foregroundStyle(FadedBrand.mint).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button {
                    onOpenProfile(bot)
                } label: {
                    Label("Profil", systemImage: "person.crop.circle")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .fadedGlassSurface(radius: FadedRadius.medium)
                .accessibilityLabel("Åbn profil for \(bot.displayName)")

                Button {
                    onOpenComputer(bot)
                } label: {
                    Label("Computer", systemImage: "desktopcomputer")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(palette.isDark ? FadedBrand.mint : palette.text)
                }
                .buttonStyle(.plain)
                .fadedGlassSurface(radius: FadedRadius.medium, tint: FadedBrand.mint.opacity(0.16),
                                   border: FadedBrand.mint.opacity(0.45))
                .accessibilityLabel("Åbn computer for \(bot.displayName)")
            }
        }
        .padding(12)
        .fadedGlassSurface(radius: FadedRadius.card)
        .accessibilityElement(children: .contain)
    }

}
