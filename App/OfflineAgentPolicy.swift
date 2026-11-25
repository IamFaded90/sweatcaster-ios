import Foundation

/// Decisions shared by setup, photo chat and the hands-free preflight.
enum OfflineAgentPolicy {
    struct VisionCandidate: Equatable {
        let id: String
        let requiredMiB: UInt64
    }

    static func visionModel(preferred: String?, candidates: [VisionCandidate], availableMiB: UInt64) -> String? {
        let fitting = candidates.filter { $0.requiredMiB > 0 && $0.requiredMiB <= availableMiB }
        if let preferred, fitting.contains(where: { $0.id == preferred }) { return preferred }
        // Keep the catalog's routing priority. A minimum RAM gate is not a peak-memory measurement.
        return fitting.first?.id
    }

    enum VoiceReadiness: Equatable {
        case ready, missingChat, missingDictation, needsLocalVoice, missingVoicePack, unavailableVoice

        var message: String? {
            switch self {
            case .ready: nil
            case .missingChat: "Vælg en hentet chatmodel til samtalen."
            case .missingDictation: "Hent dansk eller engelsk diktering, før du starter offline samtale."
            case .needsLocalVoice: "Denne stemme kræver PC’en. Vælg en offline-stemme til agenten."
            case .missingVoicePack: "Hent stemmepakken igen for at bruge agentens valgte stemme."
            case .unavailableVoice: "Agentens stemme findes ikke på telefonen. Vælg en offline-stemme."
            }
        }
    }

    static func voiceReadiness(chatReady: Bool, dictationReady: Bool, pcVoice: Bool,
                               downloadedVoice: Bool, packReady: Bool, systemVoiceReady: Bool) -> VoiceReadiness {
        guard chatReady else { return .missingChat }
        guard dictationReady else { return .missingDictation }
        guard !pcVoice else { return .needsLocalVoice }
        if downloadedVoice { return packReady ? .ready : .missingVoicePack }
        return systemVoiceReady ? .ready : .unavailableVoice
    }
}
