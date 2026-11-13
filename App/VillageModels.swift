import Foundation
import SwiftUI

/// Bot-life contract from docs/UNIVERSIM-LIFE-DESIGN.md + UNIVERSIM-LIFE-SCHEMA.json.

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

    /// Matches AgentHub villagePoint indices.
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

    static func fromQuestTitle(_ title: String) -> VillageZoneID? {
        let t = title.lowercased()
        if t.contains("video") || t.contains("clip") || t.contains("film") { return .video }
        if t.contains("code") || t.contains("research") || t.contains("kode") { return .research }
        return nil
    }
}

enum VillageActivity: String, Codable, Sendable {
    case idle, walk, work, talk, rest, sleep
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
        recomputeMood()
    }

    mutating func recomputeMood() {
        mood = min(1, max(0, 0.4 * energy + 0.3 * social + 0.3 * fulfillment))
    }
}

struct VillageCarryItem: Codable, Equatable, Identifiable, Sendable {
    var id: String { "\(kind)-\(fromBotID)-\(toBotID)-\(labelKey)" }
    var kind: String
    var labelKey: String
    var fromBotID: String
    var toBotID: String

    var label: String {
        switch labelKey {
        case "shared_clip": "Et klip er delt"
        case "shared_file": "En fil er delt"
        case "demo_file": "Sådan ser en deling ud i demo"
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

    /// Session / live markers (simulator-side).
    var pcJobRunning: Bool = false
    var pcJobQueued: Bool = false
    var pcJobZone: VillageZoneID? = nil
    var pcLiveLabel: String? = nil
    var localPractice: Bool = false
    var cafePartnerID: String? = nil
    var arrivedAt: Date? = nil
    var sleepSessionStarted: Date? = nil
    var sleepBonusGrantedThisSession: Bool = false
    var walkIntentRest: Bool = false
    var workStartedAnnounced: Bool = false
    var restBonusReadyAt: Date = .distantPast
    var practiceBonusReadyAt: Date = .distantPast
    var sleepBonusReadyAt: Date = .distantPast
    var cafeCooldownUntil: Date = .distantPast

    var poseLabel: String {
        VillageCopy.activityLabel(
            activity,
            zone: destinationZoneID ?? zoneID,
            pcJob: pcJobRunning,
            queued: pcJobQueued,
            localWork: localPractice
        )
    }
}

struct VillageEventOccurrence: Identifiable, Equatable, Sendable {
    var id: String
    var eventID: String
    var botIDs: [String]
    var zoneID: VillageZoneID?
    var speechHint: String?
    var startedAt: Date
    var durationSeconds: Double
    var bannerText: String?
}

enum VillageSurface: String, CaseIterable, Identifiable, Hashable {
    case map, office
    var id: String { rawValue }
    var title: String { self == .map ? "Landsby" : "Kontor" }
}

enum VillageCopy {
    static func activityLabel(
        _ activity: VillageActivity,
        zone: VillageZoneID,
        pcJob: Bool,
        queued: Bool,
        localWork: Bool
    ) -> String {
        if queued && activity != .work && activity != .sleep && activity != .idle {
            return "Venter på en opgave"
        }
        switch activity {
        case .idle: return queued ? "Venter på en opgave" : "Klar"
        case .walk: return "På vej til \(zone.title)"
        case .work:
            if pcJob { return "Arbejder på PC’en" }
            if localWork { return "Øver sig i \(zone.title)" }
            return "Arbejder"
        case .talk: return "Taler"
        case .rest: return "Holder pause"
        case .sleep: return queued ? "Sover · Venter på en opgave" : "Sover"
        }
    }

    static func speech(_ key: String?) -> String? {
        guard let key else { return nil }
        switch key {
        case "cafe_chat": return "En snak over kaffen"
        case "file_handoff", "shared_file": return "En fil er delt"
        case "shared_clip": return "Et klip er delt"
        case "demo_file": return "Sådan ser en deling ud i demo"
        case "inspired": return "Fik en ny idé"
        case "needs_break": return "Trænger til en pause"
        case "stuck_on_task": return "Opgaven kunne ikke gennemføres"
        case "morning_startup": return "Godmorgen, Landsby"
        case "night_wind_down": return "Der falder ro over Landsbyen"
        case "offline_rest": return "PC’en er afbrudt. Landsbyen fortsætter"
        case "pc_reconnected": return "PC’en er tilbage"
        case "work_started": return "Er gået i gang med opgaven"
        case "work_finished": return "Opgaven er færdig"
        case "sleep_started": return "Er gået til ro"
        case "awake": return "Er vågen igen"
        case "rested": return "Klar igen efter en pause"
        default: return nil
        }
    }

    static let pcUnavailable = "PC’en er afbrudt. Landsbyen fortsætter."
    static let paused = "Landsbyen er sat på pause."
    static let cameraReset = "Nulstil kortets udsnit"
}

enum VillageCamera {
    /// Clamp pan so the scaled map never leaves the frame.
    /// At zoom ≤ 1 the offset is always zero (centered).
    static func clampOffset(_ proposed: CGSize, zoom: CGFloat, frame: CGSize) -> CGSize {
        guard zoom > 1.001 else { return .zero }
        let maxX = max(0, (frame.width * zoom - frame.width) / 2)
        let maxY = max(0, (frame.height * zoom - frame.height) / 2)
        return CGSize(
            width: min(maxX, max(-maxX, proposed.width)),
            height: min(maxY, max(-maxY, proposed.height))
        )
    }
}
