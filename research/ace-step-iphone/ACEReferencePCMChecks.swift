// Standalone PC checks, not included in the application.
import Foundation

@main struct ACEReferencePCMChecks {
    static func mustThrow(_ body: () throws -> Void, _ expected: ACEReferencePCMError) {
        do { try body(); fatalError("Expected \(expected)") }
        catch let error as ACEReferencePCMError { precondition(error == expected) }
        catch { fatalError("Unexpected error: \(error)") }
    }

    static func main() async throws {
        mustThrow({ _ = try ACEReferencePCM(maxSeconds: .nan) }, .invalidDuration)
        mustThrow({ _ = try ACEReferencePCM(maxSeconds: 181) }, .invalidDuration)
        mustThrow({ _ = try ACEReferencePCM(maxSeconds: 0.001) }, .invalidDuration)
        var empty = try ACEReferencePCM(maxSeconds: 1)
        mustThrow({ _ = try empty.finish { _, _ in } }, .empty)
        var silent = try ACEReferencePCM(maxSeconds: 1)
        try silent.append(left: [0, 0], right: [0, 0]) { _, _ in }
        mustThrow({ _ = try silent.finish { _, _ in } }, .silent)
        var invalid = try ACEReferencePCM(maxSeconds: 1)
        mustThrow({ try invalid.append(left: [1], right: []) { _, _ in } }, .invalidChannels)
        mustThrow({ try invalid.append(left: [.nan], right: [1]) { _, _ in } }, .invalidSample)
        mustThrow({ try invalid.append(left: [1, .nan], right: [0, 0]) { _, _ in } }, .invalidSample)
        try invalid.append(left: [0], right: [0]) { _, _ in }
        mustThrow({ _ = try invalid.finish { _, _ in } }, .silent)

        let sourceL = (0..<3_000).map { Float($0) / 3_000 }
        let sourceR = sourceL.map { -$0 }
        var outputL: [Float] = [], outputR: [Float] = []
        var blocks: [Int] = []
        var pipeline = try ACEReferencePCM(maxSeconds: 1)
        func emit(_ left: [Float], _ right: [Float]) {
            precondition(left.count == right.count && left.count % ACEReferencePCM.hop == 0)
            outputL += left; outputR += right; blocks.append(left.count)
        }
        try pipeline.append(left: Array(sourceL.prefix(1_000)), right: Array(sourceR.prefix(1_000)), emit: emit)
        try pipeline.append(left: Array(sourceL.dropFirst(1_000)), right: Array(sourceR.dropFirst(1_000)), emit: emit)
        let result = try pipeline.finish(emit: emit)
        precondition(result.originalFrames == 3_000 && result.alignedFrames == 3_840 && !result.reachedLimit)
        precondition(blocks == [1_920, 1_920])
        precondition(Array(outputL.prefix(3_000)) == sourceL && Array(outputR.prefix(3_000)) == sourceR)
        precondition(outputL.dropFirst(3_000).allSatisfy { $0 == 0 })

        var limited = try ACEReferencePCM(maxSeconds: 0.04)
        var limitCount = 0
        try limited.append(left: Array(repeating: 0.25, count: 2_000), right: Array(repeating: -0.25, count: 2_000)) {
            limitCount += $0.count; precondition($0.count == $1.count)
        }
        let limitedResult = try limited.finish { _, _ in fatalError("Unexpected padding") }
        precondition(limitedResult.reachedLimit && limitedResult.originalFrames == 1_920 && limitCount == 1_920)
        mustThrow({ try limited.append(left: [1], right: [1]) { _, _ in } }, .alreadyFinished)
        mustThrow({ _ = try limited.finish { _, _ in } }, .alreadyFinished)

        let task = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                var pcm = try ACEReferencePCM(maxSeconds: 1)
                try pcm.append(left: [0.5], right: [0.5]) { _, _ in }
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        let wasCancelled = await task.value
        precondition(wasCancelled, "Cancellation must interrupt processing")
        print("PASS: stereo alignment, bounds, padding, silence, invalid samples and cancellation")
    }
}
