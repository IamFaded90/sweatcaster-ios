import Foundation

enum Mood: String, Codable, CaseIterable, Identifiable, Sendable {
    case roast, hype, sweaty, funnyNPC = "funny_npc"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .roast: "Roast"
        case .hype: "Hype"
        case .sweaty: "Sweaty"
        case .funnyNPC: "Funny NPC"
        }
    }
}

enum Stage: String, Codable, CaseIterable, Sendable {
    case queued, analyzing, commentating, synthesizing, rendering, completed, failed, cancelled
    var active: Bool { self != .completed && self != .failed && self != .cancelled }
    var title: String {
        switch self {
        case .queued: "Venter"
        case .analyzing: "Ser klippet igennem"
        case .commentating: "Skriver kommentar"
        case .synthesizing: "Laver stemme"
        case .rendering: "Gør videoen klar"
        case .completed: "Klar"
        case .failed: "Kunne ikke lave videoen"
        case .cancelled: "Stoppet"
        }
    }
}

struct Health: Codable, Sendable { let api_version, status: String }
struct Capabilities: Codable, Sendable {
    struct Features: Codable, Sendable { let upload, cancel, range_preview: Bool }
    struct Dependency: Codable, Sendable { let name: String; let ready: Bool; let message: String }
    let moods: [Mood]
    let max_batch_size: Int
    let features: Features
    let dependencies: [Dependency]
    var limit: Int { min(10, max(0, max_batch_size)) }
    var missingRequired: [Dependency] {
        dependencies.filter { !$0.ready && Self.requiredDependencies.contains($0.name) }
    }
    static let requiredDependencies: Set<String> = ["ffmpeg", "ffprobe", "ollama", "piper"]
}
func validWireID(_ id: String) -> Bool {
    (8...64).contains(id.utf8.count) && id.utf8.allSatisfy {
        (65...90).contains($0) || (97...122).contains($0) ||
        (48...57).contains($0) || $0 == 45 || $0 == 95
    }
}
struct Clip: Codable, Identifiable, Sendable {
    let id, name: String
    let duration_seconds: Double
    let width, height: Int
}
struct Clips: Codable, Sendable { let clips: [Clip] }
struct Jobs: Codable, Sendable { let jobs: [Job] }
struct Problem: Codable, Sendable {
    let code, message: String
}
struct Envelope: Codable, Sendable { let error: Problem }
struct Job: Codable, Identifiable, Sendable {
    let id, clip_id: String
    let mood: Mood
    var status: Stage
    var progress: Double
    var message: String
    var warnings: [String]
    let created_at: Date
    var updated_at: Date
    var output_url: String?
    var error: Problem?
}

struct ROI: Codable, Sendable {
    var x = 0.15, y = 0.62, width = 0.70, height = 0.30
    var valid: Bool {
        [x, y, width, height].allSatisfy { (0...1).contains($0) }
            && width > 0 && height > 0 && x + width <= 1 && y + height <= 1
    }
}
enum Crop: String, Codable, CaseIterable, Sendable { case auto, center }
struct Options: Codable, Sendable {
    var roi = ROI()
    var crop_mode = Crop.auto
    var denoise = false
}
struct Batch: Codable, Sendable {
    let clip_ids: [String]
    let mood: Mood
    let options: Options
    func validate(limit: Int) throws {
        guard (1...10).contains(clip_ids.count), clip_ids.count <= limit,
              Set(clip_ids).count == clip_ids.count, clip_ids.allSatisfy(validWireID),
              options.roi.valid else { throw APIError.input }
    }
}

enum APIError: Error, Sendable {
    case address, token, input, version, unhealthy, malformed, unsafeVideo, offline, localNetwork, storage
    case transport(Int)
    case http(Int, Problem?)
    var ambiguous: Bool {
        switch self {
        case .transport, .malformed: true
        case .http(let status, _): ![401, 404, 409, 422, 503].contains(status)
        default: false
        }
    }
    var title: String {
        switch self {
        case .address: "Indsæt den lokale adresse, der vises på PC’en."
        case .token, .http(401, _): "Tjek adgangskoden fra PC’en."
        case .input, .http(422, _): "Tjek de valgte klip og indstillinger."
        case .version: "PC’en bruger en anden API-version. Appen kræver version 1."
        case .unhealthy: "PC’ens server er ikke klar."
        case .malformed: "PC’en gav et svar, appen ikke kunne læse."
        case .unsafeVideo: "PC’en gav ikke en gyldig videofil."
        case .offline: "Kan ikke nå PC’en. Tjek Wi-Fi, adressen og om serveren kører. Tjek også adgang til lokalt netværk."
        case .localNetwork: "Giv appen adgang til lokalt netværk i Indstillinger, og prøv igen."
        case .storage: "Appen kunne ikke gemme data på telefonen."
        case .http(404, _): "Klippet eller jobbet findes ikke længere."
        case .http(409, _): "Videoen er ikke klar endnu."
        case .http(503, _): "PC’en mangler noget for at kunne lave videoen."
        case .transport: "Forbindelsen blev afbrudt. Tjek PC’en og Wi-Fi."
        case .http: "PC’en kunne ikke udføre handlingen."
        }
    }
    var detail: String? {
        switch self {
        case .http(let status, let problem):
            ["HTTP \(status)", problem?.code, problem?.message].compactMap { $0 }.joined(separator: " · ")
        case .transport(let code): "Netværksfejl \(code)"
        default: nil
        }
    }
}

func contractDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: raw) { return date }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO-8601 timestamp")
    }
    return decoder
}
