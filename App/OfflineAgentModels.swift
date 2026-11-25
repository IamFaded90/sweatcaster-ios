import Foundation

enum OfflineAgentModels {
    // Non-thinking instruct model: reasoning does not consume the mobile reply budget.
    static let chat = GGUFHub.File(repository: "unsloth/Qwen3-4B-Instruct-2507-GGUF",
        revision: "a06e946bb6b655725eafa393f4a9745d460374c9",
        name: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf", bytes: 2_497_281_120,
        sha256: "3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597")

    static func matches(_ model: GGUFPhoneModel) -> Bool {
        model.url.lastPathComponent == chat.name && model.bytes == chat.bytes
    }
    static var installedChat: GGUFPhoneModel? { GGUFPhoneModel.installed.first(where: matches) }
}

extension PhoneModels {
    @MainActor static func readyTextModel(for agentID: UUID) -> String {
        let defaults = UserDefaults.standard
        for key in [agentModelKey(agentID), selectionKey] {
            if let id = defaults.string(forKey: key), !id.isEmpty, isReady(id) { return id }
        }
        return textOptions.first { isReady($0.id) }?.id ?? ""
    }

    @MainActor static func preferredVisionModel(preferred: String? = nil) -> String? {
        OfflineAgentPolicy.visionModel(preferred: preferred, candidates: readyVisionModelIDs.map {
            .init(id: $0, requiredMiB: minimumMemory(for: $0))
        }, availableMiB: LocalCompute.headroom / 1_048_576)
    }
}
