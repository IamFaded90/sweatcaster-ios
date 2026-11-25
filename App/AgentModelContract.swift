import Foundation

enum AgentModelContract {
    static let followUpReserve = 384
    enum Route { case phone, computer, cloud
        var instructionLimit: Int { switch self { case .phone: 10_000; case .computer: 3_000; case .cloud: 10_000 } }
        var promptLimit: Int { switch self { case .phone: 10_000; case .computer: 2_000; case .cloud: 16_000 } }
    }
    struct Block { let id: String; let text: String; var required = false }
    struct Packed { let text: String; let included: Set<String>; let omitted: Set<String> }
    enum Failure: LocalizedError {
        case question, rules
        var errorDescription: String? { self == .question ? "Denne besked med kilder er for lang til den valgte forbindelse. Forkort beskeden eller vælg telefonmodellen. Intet er sendt." : "De nødvendige instruktioner er for lange til modellen. Forkort agentens indstillinger. Intet er sendt." }
    }
    /// Each source/profile/tool unit is whole or absent; quotes, addresses and JSON schemas are never cut in half.
    static func pack(_ blocks: [Block], limit: Int) throws -> Packed {
        var text = "", included = Set<String>(), omitted = Set<String>()
        for block in blocks.filter(\.required) + blocks.filter({ !$0.required }) {
            guard !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !included.contains(block.id) else { continue }
            let candidate = text + (text.isEmpty ? "" : "\n") + block.text
            if candidate.unicodeScalars.count <= max(0, limit) { text = candidate; included.insert(block.id) }
            else if block.required { throw Failure.rules }
            else { omitted.insert(block.id) }
        }
        return .init(text: text, included: included, omitted: omitted)
    }
    static func validate(prompt: String, instructions: String, route: Route) throws {
        guard prompt.unicodeScalars.count <= route.promptLimit else { throw Failure.question }
        guard instructions.unicodeScalars.count <= route.instructionLimit else { throw Failure.rules }
    }
    static func history(_ entries: [(prompt: String, reply: String)], limit: Int = 5_000) -> [(prompt: String, reply: String)] {
        var result: [(String, String)] = [], remaining = limit
        for entry in entries.suffix(8).reversed() {
            let size = entry.prompt.unicodeScalars.count + entry.reply.unicodeScalars.count + 24
            guard size <= remaining else { break }
            result.append(entry); remaining -= size
        }
        return Array(result.reversed())
    }
    static func legacyHistory(instructions: String, previous: String) -> String {
        let heading = "\nTidligere samtale:\n"
        guard !previous.isEmpty, instructions.unicodeScalars.count + heading.unicodeScalars.count + previous.unicodeScalars.count <= 3_000 else { return instructions }
        return instructions + heading + previous
    }
}
