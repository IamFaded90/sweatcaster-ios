import SwiftUI

/// A figure is a saved choice, independent of name, voice and profile photograph.
enum VillageCharacterCatalog {
    struct Character: Identifiable {
        let id: String
        let name: String
        let detail: String
        let female: Bool
    }

    static let all: [Character] = [
        .init(id: "adam", name: "Adam", detail: "Briller · petroljakke", female: false),
        .init(id: "atlas", name: "Atlas", detail: "Blond · værktøjsbælte", female: false),
        .init(id: "milo", name: "Milo", detail: "Hue · grøn skjorte", female: false),
        .init(id: "noah", name: "Noah", detail: "Hovedtelefoner · lys frakke", female: false),
        .init(id: "theo", name: "Theo", detail: "Hestehale · kamera", female: false),
        .init(id: "eva", name: "Eva", detail: "Krøller · gul jakke", female: true),
        .init(id: "luna", name: "Luna", detail: "Sølvhår · mørk hættetrøje", female: true),
        .init(id: "iris", name: "Iris", detail: "Fletning · grøn blazer", female: true),
        .init(id: "nova", name: "Nova", detail: "Pink hår · limejakke", female: true),
        .init(id: "saga", name: "Saga", detail: "Lys fletning · strik", female: true)
    ]
    static let lumi = Character(id: "lumi", name: "Lumi", detail: "Lys fletning · lilla tøj", female: true)
    // Keep the original ordering for legacy UUID assignments.
    private static let legacy = ["adam", "eva", "atlas", "luna", "milo", "iris", "noah", "nova", "saga", "theo"]

    static func valid(_ value: String?, for id: UUID? = nil) -> String? {
        if id == VillageBot.lumiID, value == lumi.id { return value }
        guard let value, all.contains(where: { $0.id == value }) else { return nil }
        return value
    }

    static func initial(name: String, id: String) -> String {
        if UUID(uuidString: id) == VillageBot.lumiID { return lumi.id }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if legacy.contains(name) { return name }
        let hash = id.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return legacy[Int(hash % UInt64(legacy.count))]
    }

    static func availableDefault(preferred: String, among profiles: [VillageBot]) -> String {
        let occupied = Set(profiles.map(\.villageFigure))
        guard occupied.contains(preferred), let character = all.first(where: { $0.id == preferred }) else {
            return preferred
        }
        let free = all.filter { !occupied.contains($0.id) }
        return free.first(where: { $0.female == character.female })?.id ?? free.first?.id ?? preferred
    }

    static func resolved(name: String, id: String, defaults: UserDefaults = .standard) -> String {
        valid(defaults.string(forKey: key(id)), for: UUID(uuidString: id)) ?? initial(name: name, id: id)
    }

    /// Derived render index. The profile JSON remains the authoritative source and travels in backups.
    static func index(_ profiles: [VillageBot], defaults: UserDefaults = .standard) {
        for profile in profiles {
            defaults.set(profile.villageFigure, forKey: key(profile.id.uuidString))
        }
    }

    private static func key(_ id: String) -> String { "village.figure.v2." + id.lowercased() }
}

struct VillageFigurePicker: View {
    @Binding var selection: String
    var occupied: Set<String> = []
    var includeLumi = false
    @Environment(\.fadedPalette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Din bot, din figur").font(.largeTitle.bold())
                Text("Vælg mellem 5 mænd og 5 kvinder. Figuren bliver den samme, når du skifter navn eller profilbillede.")
                    .foregroundStyle(palette.secondary)
                if includeLumi { choice(VillageCharacterCatalog.lumi) }
                group("Mænd", female: false)
                group("Kvinder", female: true)
            }
            .padding(FadedSpacing.edge)
            .frame(maxWidth: 640).frame(maxWidth: .infinity)
        }
        .background { FadedBackground(variant: .village) }
        .navigationTitle("Landsbyfigur")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func group(_ title: String, female: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 240 : 145))], spacing: 12) {
                ForEach(VillageCharacterCatalog.all.filter { $0.female == female }) { character in
                    choice(character)
                }
            }
        }
    }

    private func choice(_ character: VillageCharacterCatalog.Character) -> some View {
        let selected = selection == character.id
        let used = occupied.contains(character.id)
        return Button { selection = character.id } label: {
            VStack(spacing: 8) {
                if let image = VillageProductionArt.frame(character: character.id, direction: 0, step: 0) {
                    Image(uiImage: image).resizable().interpolation(.none).scaledToFit()
                        .frame(height: 112)
                }
                HStack(spacing: 6) {
                    Text(character.name).font(.headline)
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.lime) }
                }
                Text(character.detail).font(.caption).foregroundStyle(palette.secondary)
                    .multilineTextAlignment(.center)
                if used { Text("I brug").font(.caption2.bold()).foregroundStyle(palette.secondary) }
            }
            .frame(maxWidth: .infinity, minHeight: 172)
            .padding(12)
            .fadedGlassSurface(radius: 20)
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(selected ? palette.lime : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .disabled(used && !selected)
        .foregroundStyle(palette.text)
        .accessibilityLabel("\(character.name), \(character.detail)")
        .accessibilityValue(used ? "Bruges af en anden agent" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
