import Foundation

enum VillageAmbience {
    enum Light: String, CaseIterable, Codable, Identifiable {
        case original, golden, moon, aurora, rose
        var id: Self { self }
        var title: String { switch self { case .original: "Original"; case .golden: "Gyldent lys"; case .moon: "Måneskin"; case .aurora: "Nordlys"; case .rose: "Varm rosa" } }
    }
    enum Sound: String, CaseIterable, Codable, Identifiable {
        case none, rain, fire, waves
        var id: Self { self }
        var title: String { switch self { case .none: "Ingen baggrundslyd"; case .rain: "Blød regn"; case .fire: "Pejs"; case .waves: "Bølger" } }
    }
    struct Settings: Codable, Equatable, Hashable {
        var name = "Min stemning"
        var light = Light.original
        var brightness = 0.0
        var saturation = 1.0
        var strength = 0.18
        var sound = Sound.none
        var volume = 0.22
        var music: MusicTrack?
        var offlineMusicOnly = true
        var autoplay = false
        var imageID: UUID?
        func hash(into hasher: inout Hasher) {
            hasher.combine(name); hasher.combine(light); hasher.combine(brightness); hasher.combine(saturation)
            hasher.combine(strength); hasher.combine(sound); hasher.combine(volume); hasher.combine(music?.id)
            hasher.combine(offlineMusicOnly); hasher.combine(autoplay); hasher.combine(imageID)
        }
        func validate() throws {
            guard name.count <= 80, brightness.isFinite, (-0.3...0.25).contains(brightness),
                  saturation.isFinite, (0.4...1.4).contains(saturation), strength.isFinite, (0...0.45).contains(strength),
                  volume.isFinite, (0...0.7).contains(volume), (music?.title.count ?? 0) <= 500,
                  (music?.id.count ?? 0) <= 180 else { throw Failure.invalid }
        }
    }
    struct Snapshot: Codable, Equatable, Identifiable {
        var id = UUID()
        var saved = Date.now
        let settings: Settings
    }
    struct Record: Codable, Equatable {
        var current = Settings()
        var history: [Snapshot] = []
        var presets: [Snapshot] = []
        mutating func apply(_ settings: Settings) throws {
            try settings.validate()
            guard current != settings else { return }
            history = Array((history + [.init(settings: current)]).suffix(24))
            current = settings
        }
        mutating func restore(_ id: UUID) throws {
            guard let snapshot = (history + presets).first(where: { $0.id == id }) else { throw Failure.missing }
            try apply(snapshot.settings)
        }
        mutating func savePreset(_ settings: Settings) throws {
            try settings.validate()
            guard !settings.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.invalid }
            presets.insert(.init(settings: settings), at: 0); presets = Array(presets.prefix(12))
        }
        var imageIDs: Set<UUID> { Set(([current] + history.map(\.settings) + presets.map(\.settings)).compactMap(\.imageID)) }
        mutating func removeImage(_ id: UUID) {
            if current.imageID == id { current.imageID = nil }
            history = history.map { value in
                var settings = value.settings; if settings.imageID == id { settings.imageID = nil }
                return Snapshot(id: value.id, saved: value.saved, settings: settings)
            }
            presets = presets.map { value in
                var settings = value.settings; if settings.imageID == id { settings.imageID = nil }
                return Snapshot(id: value.id, saved: value.saved, settings: settings)
            }
        }
    }
    enum Failure: Error { case invalid, missing }
    static func room(_ id: UUID) -> String { "room-" + id.uuidString.lowercased() }
    static func zone(_ raw: String) -> String { "zone-" + raw }
    static func command(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).range(of:
            #"^(?:(?:kan|vil) du (?:lige )?)?(?:skift stemning|indret landsbyen|vis mine stemninger|lav (?:en )?stemning|gør landsbyen hyggelig)\b"#,
            options: [.regularExpression, .caseInsensitive]) != nil
    }
    struct Store {
        var root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FadedAI/VillageAmbience", isDirectory: true)
        private func file(_ scene: String) throws -> URL {
            guard scene.range(of: #"^[a-zA-Z0-9-]{1,80}$"#, options: .regularExpression) != nil else { throw Failure.invalid }
            return root.appendingPathComponent(scene + ".json")
        }
        func load(_ scene: String) throws -> Record {
            let path = try file(scene)
            guard FileManager.default.fileExists(atPath: path.path) else { return .init() }
            let data = try Data(contentsOf: path)
            guard data.count <= 200_000 else { throw Failure.invalid }
            let record = try JSONDecoder().decode(Record.self, from: data)
            guard record.history.count <= 24, record.presets.count <= 12 else { throw Failure.invalid }
            for settings in [record.current] + record.history.map(\.settings) + record.presets.map(\.settings) { try settings.validate() }
            return record
        }
        func save(_ record: Record, scene: String) throws {
            let path = try file(scene)
            guard record.history.count <= 24, record.presets.count <= 12 else { throw Failure.invalid }
            for settings in [record.current] + record.history.map(\.settings) + record.presets.map(\.settings) { try settings.validate() }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode(record).write(to: path, options: [.atomic, .completeFileProtection])
        }
        func image(_ id: UUID) -> URL { root.appendingPathComponent("assets", isDirectory: true).appendingPathComponent(id.uuidString.lowercased() + ".jpg") }
        func saveImage(_ data: Data) throws -> UUID {
            guard !data.isEmpty, data.count <= 3_300_000 else { throw Failure.invalid }
            let id = UUID()
            try FileManager.default.createDirectory(at: image(id).deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: image(id), options: [.atomic, .completeFileProtection]); return id
        }
        func remove(_ scene: String) throws {
            let path = try file(scene)
            if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
            try? collectUnusedImages()
        }
        func collectUnusedImages() throws {
            guard FileManager.default.fileExists(atPath: root.path) else { return }
            let records = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
            var referenced = Set<UUID>()
            for record in records { referenced.formUnion(try load(record.deletingPathExtension().lastPathComponent).imageIDs) }
            let assets = root.appendingPathComponent("assets", isDirectory: true)
            guard FileManager.default.fileExists(atPath: assets.path) else { return }
            for asset in try FileManager.default.contentsOfDirectory(at: assets, includingPropertiesForKeys: nil) {
                guard asset.pathExtension == "jpg", let id = UUID(uuidString: asset.deletingPathExtension().lastPathComponent), !referenced.contains(id) else { continue }
                try FileManager.default.removeItem(at: asset)
            }
        }
    }
}

enum VillageAmbiencePCM {
    /// Bounded procedural loops; no model, downloads, microphones or network.
    static func samples(sound: VillageAmbience.Sound, rate: Int = 24_000, seconds: Int = 6) -> [Float] {
        guard sound != .none, (8_000...48_000).contains(rate), (1...10).contains(seconds) else { return [] }
        var seed: UInt64 = 4_718_219
        var filtered: Float = 0, previous: Float = 0
        var result = [Float](); result.reserveCapacity(rate * seconds)
        for index in 0..<(rate * seconds) {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            let noise = Float((seed >> 40) & 0xFFFFFF) / Float(0x7FFFFF) - 1
            filtered = 0.96 * filtered + 0.04 * noise
            let sample: Float
            switch sound {
            case .none: sample = 0
            case .rain: sample = noise * 0.12 + filtered * 0.3
            case .fire:
                previous *= 0.86
                if seed % 7_003 < 3 { previous += noise * 0.6 }
                sample = filtered * 0.45 + previous
            case .waves:
                let phase = 2 * Double.pi * Double(index) / Double(rate * seconds)
                sample = (filtered * 0.8 + noise * 0.025) * Float(0.55 + 0.45 * sin(phase))
            }
            result.append(max(-0.8, min(0.8, sample)))
        }
        let fade = min(rate / 40, result.count / 4)
        for index in 0..<fade {
            let mix = Float(index) / Float(max(1, fade))
            let start = result[index], end = result[result.count - fade + index]
            result[index] = end * (1 - mix) + start * mix
            result[result.count - fade + index] = result[index]
        }
        return result
    }
}
