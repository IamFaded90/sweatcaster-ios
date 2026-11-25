// Bounded PCM preparation for an ACE-Step audio reference.
import Foundation

enum ACEReferencePCMError: LocalizedError, Equatable {
    case invalidDuration, invalidChannels, invalidSample, empty, silent, alreadyFinished
    var errorDescription: String? {
        switch self {
        case .invalidDuration: return "Lydreferencens længde kunne ikke bruges."
        case .invalidChannels: return "Lydreferencens kanaler kunne ikke læses."
        case .invalidSample: return "Lydreferencen indeholder ugyldige lyddata."
        case .empty: return "Lydfilen er tom. Vælg en anden optagelse."
        case .silent: return "Lydfilen indeholder kun stilhed. Vælg en optagelse med lyd."
        case .alreadyFinished: return "Lydreferencen blev afbrudt. Prøv igen."
        }
    }
}

struct ACEReferencePCMResult: Equatable {
    let originalFrames: Int
    let alignedFrames: Int
    let peak: Float
    /// Reaching the requested limit does not establish whether the input was longer.
    let reachedLimit: Bool
}

/// Bounded 48 kHz stereo PCM. Output is padded to ACE's 1,920-sample hop.
/// The caller emits each block immediately rather than retaining the source.
struct ACEReferencePCM {
    static let sampleRate = 48_000
    static let hop = 1_920
    static let maxSeconds = 180.0
    private let limit: Int
    private var leftTail: [Float] = []
    private var rightTail: [Float] = []
    private(set) var inputFrames = 0
    private(set) var outputFrames = 0
    private var peak: Float = 0
    private var finished = false

    init(maxSeconds: Double) throws {
        guard maxSeconds.isFinite, maxSeconds >= Double(Self.hop) / Double(Self.sampleRate),
              maxSeconds <= Self.maxSeconds else { throw ACEReferencePCMError.invalidDuration }
        // Round down so hop padding never exceeds the caller's time limit.
        let requested = Int((maxSeconds * Double(Self.sampleRate)).rounded(.down))
        self.limit = requested / Self.hop * Self.hop
    }

    var hasCapacity: Bool { inputFrames < limit }

    /// `emit` receives equal-sized channel arrays and is called only with a
    /// whole number of hops. The method checks cancellation per input block.
    mutating func append(left: [Float], right: [Float],
                         emit: ([Float], [Float]) throws -> Void) throws {
        try Task.checkCancellation()
        guard !finished else { throw ACEReferencePCMError.alreadyFinished }
        guard left.count == right.count else { throw ACEReferencePCMError.invalidChannels }
        let used = min(left.count, limit - inputFrames)
        guard used > 0 else { return }
        var blockPeak = peak
        for i in 0..<used {
            guard left[i].isFinite, right[i].isFinite else { throw ACEReferencePCMError.invalidSample }
            blockPeak = max(blockPeak, abs(left[i]), abs(right[i]))
        }
        peak = blockPeak
        leftTail.append(contentsOf: left.prefix(used))
        rightTail.append(contentsOf: right.prefix(used))
        inputFrames += used
        let count = leftTail.count / Self.hop * Self.hop
        if count > 0 {
            try emit(Array(leftTail.prefix(count)), Array(rightTail.prefix(count)))
            leftTail.removeFirst(count)
            rightTail.removeFirst(count)
            outputFrames += count
        }
    }

    mutating func finish(emit: ([Float], [Float]) throws -> Void) throws -> ACEReferencePCMResult {
        try Task.checkCancellation()
        guard !finished else { throw ACEReferencePCMError.alreadyFinished }
        guard inputFrames > 0 else { throw ACEReferencePCMError.empty }
        guard peak >= 1e-6 else { throw ACEReferencePCMError.silent }
        if !leftTail.isEmpty {
            let missing = Self.hop - leftTail.count
            leftTail.append(contentsOf: repeatElement(0, count: missing))
            rightTail.append(contentsOf: repeatElement(0, count: missing))
            try emit(leftTail, rightTail)
            outputFrames += Self.hop
            leftTail.removeAll()
            rightTail.removeAll()
        }
        finished = true
        return .init(originalFrames: inputFrames, alignedFrames: outputFrames,
                     peak: peak, reachedLimit: inputFrames == limit)
    }
}
