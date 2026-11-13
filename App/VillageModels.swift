import Foundation
import SwiftUI

/// Minimum bot-life state from docs/UNIVERSIM-SPLIT.md.
/// LIFE-DESIGN: Del B may extend optional fields; keep these required keys stable.

enum VillageZoneID: String, Codable, CaseIterable, Sendable {
    case research, video, cafe, sleep

    var title: String {
        switch self {
        case .research: "Research Lab"
        case .video: "Video Studio"
        case .cafe: "Café"
        case .sleep: "Sovekrog"
        }
    }

    var buildingAsset: String {
        switch self {
        case .research: "building_research_lab"
        case .video: "building_video_studio"
        case .cafe: "building_cafe"
        case .sleep: "building_sleep_nook"
        }
    }

    /// Matches legacy AgentHub villagePoint indices.
    var pointIndex: Int {
        switch self {
        case .research: 0
        case .video: 1
        case .cafe: 2
        case .sleep: 3
        }
    }

    static func fromHubRoom(_ roomID: String) -> VillageZoneID {
        let id = roomID.lowercased()
        if id.contains("video") { return .video }
        if id.contains("cafe") || id.contains("kaffe") { return .cafe }
        if id.contains("sleep") || id.contains("sove") { return .sleep }
        return .research
    }
}

enum VillageActivity: String, Codable, Sendable {
    case idle, walk, work, talk, rest, sleep

    var label: String {
        switch self {
        case .idle: "Klar"
        case .walk: "På vej"
        case .work: "Arbejder"
        case .talk: "Snakker"
        case .rest: "Hviler"
        case .sleep: "Sover"
        }
    }
}

enum VillageArchetype: String, Codable, Sendable {
    case logic, creative, care, playful

    var workZone: VillageZoneID {
        switch self {
        case .logic, .care: .research
        case .creative, .playful: .video
        }
    }

    static func from(personality: String?, color: String?, name: String) -> VillageArchetype {
        let p = (personality ?? "").lowercased()
        if p.contains("omsorg") { return .care }
        if p.contains("sjov") { return .playful }
        if p.contains("rolig") { return .logic }
        if name.localizedCaseInsensitiveContains("eva") { return .creative }
        if color == "Lilla" { return .creative }
        return .logic
    }
}

struct VillageNeeds: Codable, Equatable, Sendable {
    var energy: Double
    var social: Double
    var fulfillment: Double
    var mood: Double

    static let balanced = VillageNeeds(energy: 0.75, social: 0.55, fulfillment: 0.6, mood: 0.6)

    mutating func clamp() {
        energy = min(1, max(0, energy))
        social = min(1, max(0, social))
        fulfillment = min(1, max(0, fulfillment))
        mood = min(1, max(0, mood))
    }
}

struct VillageCarryItem: Codable, Equatable, Identifiable, Sendable {
    var id: String { "\(kind)-\(fromBotID)-\(toBotID)" }
    var kind: String
    var labelKey: String
    var fromBotID: String
    var toBotID: String

    var label: String {
        switch labelKey {
        case "shared_clip": "Deler klip"
        case "shared_note": "Deler note"
        default: "Pakke"
        }
    }
}

struct VillageLifeBot: Identifiable, Equatable, Sendable {
    var id: String
    var displayName: String
    var archetype: VillageArchetype
    var spriteID: String
    var zoneID: VillageZoneID
    var activity: VillageActivity
    var pose: VillageActivity
    var needs: VillageNeeds
    var destinationZoneID: VillageZoneID?
    var pathProgress: Double
    var speechHint: String?
    var carrying: VillageCarryItem?
    var lastEventID: String?
    var customSprite: Data?
    var linkedAgentID: String?
    var updatedAt: Date

    var poseLabel: String { activity.label }
}

enum VillageSurface: String, CaseIterable, Identifiable {
    case map, office
    var id: String { rawValue }
    var title: String { self == .map ? "Landsby" : "Kontor" }
}

enum VillageCopy {
    static func speech(_ key: String?) -> String? {
        guard let key else { return nil }
        switch key {
        case "cafe_chat": return "Hej…"
        case "file_handoff": return "Her!"
        case "inspired": return "Idé!"
        case "needs_break": return "Pause"
        case "stuck_on_task": return "Hmm…"
        case "morning_startup": return "Godmorgen"
        case "night_wind_down": return "Zzz"
        default: return nil
        }
    }
}
