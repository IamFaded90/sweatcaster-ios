import SwiftUI

@MainActor struct VillageBuildingRoomView: View {
    let zone: VillageZoneID
    @ObservedObject var life: VillageLifeSimulator
    let onOpenProfile: (VillageLifeBot) -> Void
    @Environment(\.fadedPalette) private var palette

    private var imageName: String {
        switch zone {
        case .research: "room-research-lab"
        case .video: "room-media-studio"
        case .cafe: "room-cafe"
        case .sleep: "room-sleeping-corner"
        }
    }

    private var description: String {
        switch zone {
        case .research: "Bøger, noter og computere til fordybelse."
        case .video: "Farver, skitser og et stort arbejdsbord."
        case .cafe: "Sofaer, kaffe og et bord til samtaler."
        case .sleep: "Senge, planter og dæmpet aftenlys."
        }
    }

    private var residents: [VillageLifeBot] {
        life.bots.filter { $0.zoneID == zone && $0.destinationZoneID == nil }
    }

    private var incoming: [VillageLifeBot] {
        life.bots.filter { $0.zoneID != zone && $0.destinationZoneID == zone }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(description).font(.subheadline).foregroundStyle(palette.secondary)
                VillageAmbienceButton(scene: VillageAmbience.zone(zone.rawValue), title: zone.title)
                VillageSpeakingRoom(artwork: imageName, zone: zone, residents: residents, animated: !life.paused)
                RoomWorksPanel(scene: VillageAmbience.zone(zone.rawValue))
                Text("Her lige nu").font(.headline)
                if residents.isEmpty {
                    FadedCard {
                        Text("Ingen bot er her lige nu.").font(.subheadline)
                            .foregroundStyle(palette.secondary)
                    }
                }
                ForEach(residents) { bot in residentRow(bot, status: bot.poseLabel) }
                VillageRoomActivities(residents: residents)
                if !incoming.isEmpty {
                    Text("På vej hertil").font(.headline)
                    ForEach(incoming) { bot in residentRow(bot, status: "På vej") }
                }
            }
            .padding(FadedSpacing.edge)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background { FadedBackground(variant: .village) }
        .foregroundStyle(palette.text)
        .navigationTitle(zone.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func residentRow(_ bot: VillageLifeBot, status: String) -> some View {
        Button { onOpenProfile(bot) } label: {
            FadedCard {
                HStack(spacing: 12) {
                    VillageBotSprite(bot: bot, size: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(bot.displayName).font(.headline)
                        Text(status).font(.caption).foregroundStyle(palette.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                }
                .frame(minHeight: 44)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Åbn profil for \(bot.displayName)")
        .accessibilityValue(status)
    }
}
