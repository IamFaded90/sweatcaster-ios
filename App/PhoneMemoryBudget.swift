import Foundation

/// Cold-start heuristic adapted from PocketPal's useMemoryCheck.ts (MIT).
/// Keep the OS's current process allowance as a hard upper bound, even after a successful run.
enum PhoneMemoryBudget {
    enum Fit: Equatable { case comfortable, tight, unavailable }

    struct Assessment {
        let fit: Fit
        let recommendedBytes: UInt64

        var explanation: String {
            switch fit {
            case .comfortable: "Ser ud til at passe · prøv modellens test før brug"
            case .tight: "Tæt på hukommelsesgrænsen · en mindre model anbefales"
            case .unavailable: "For lidt ledig hukommelse lige nu · vælg en mindre model eller PC"
            }
        }
    }

    static func assess(required: UInt64, physical: UInt64, available: UInt64) -> Assessment {
        let reserved = physical > 1_200_000_000 ? physical - 1_200_000_000 : 0
        let conservative = min(UInt64(Double(physical) * 0.6), reserved)
        let recommended = min(conservative, available)
        let fit: Fit = required == 0 || required > min(physical, available) ? .unavailable
            : required <= recommended ? .comfortable : .tight
        return Assessment(fit: fit, recommendedBytes: recommended)
    }

    @MainActor static func assess(_ model: GGUFPhoneModel) -> Assessment {
        assess(required: model.memoryEstimateMiB * 1_048_576,
               physical: ProcessInfo.processInfo.physicalMemory, available: LocalCompute.headroom)
    }
}
