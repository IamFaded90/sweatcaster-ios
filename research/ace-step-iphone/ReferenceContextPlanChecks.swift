// Standalone Swift 5 checks against fixtures from the actual PC handlers.
// This checks routing and shapes, not model inference or iPhone execution.
import Foundation

private struct Fixture: Decodable {
    let mode: ReferenceContextPlan.Mode
    let sourceFrames, channels, steps: Int
    let strength: Double
    let source, silence, target, tokenValues, tokenMask, pooledMask, hints, context: [Float]
    let instruction: String
    let isCover: Bool
    let releaseAfter: Int?
}

private enum CheckError: Error { case failed(String) }

@main struct ReferenceContextChecks {
    static func check(_ result: @autoclosure () -> Bool, _ message: String) throws {
        guard result() else { throw CheckError.failed(message) }
    }

    static func invalid(_ body: () throws -> Void, _ message: String) throws {
        do { try body() } catch is ReferenceContextFailure { return }
        throw CheckError.failed(message)
    }

    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw CheckError.failed("Expected one fixture path") }
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let cases = try JSONDecoder().decode([Fixture].self, from: data)
        try check(cases.count == 120, "Unexpected fixture count")
        for test in cases {
            let plan = try ReferenceContextPlan(mode: test.mode, sourceFrames: test.sourceFrames,
                                                channels: test.channels, steps: test.steps,
                                                strength: test.strength)
            let target = try plan.paddedTarget(source: test.source, silence: test.silence)
            try check(target == test.target, "Target padding disagreed at \(test.sourceFrames) \(test.mode)")
            let token = try plan.tokenizerInput(target: target, silence: test.silence)
            try check(token.values == test.tokenValues, "Tokenizer patches disagreed at \(test.sourceFrames)")
            try check(token.mask == test.tokenMask, "Attention mask disagreed at \(test.sourceFrames)")
            let pooled = stride(from: 0, to: token.mask.count, by: 5).map {
                token.mask[$0..<min($0 + 5, token.mask.count)].max() ?? 0
            }
            try check(pooled == test.pooledMask, "Pooled attention mask disagreed")
            let context = try plan.context(source: target, hints: test.hints)
            try check(context == test.context, "Context routing disagreed for \(test.mode)")
            try check(plan.usesTokenizer == test.isCover, "Cover route disagreed")
            try check(plan.instruction == test.instruction, "Instruction disagreed")
            try check(plan.releaseAfter == test.releaseAfter, "Cover strength disagreed")
        }
        try invalid({ _ = try ReferenceContextPlan(mode: .cover, sourceFrames: 0, channels: 2, steps: 8, strength: 1) }, "zero frames")
        try invalid({ _ = try ReferenceContextPlan(mode: .cover, sourceFrames: 4501, channels: 2, steps: 8, strength: 1) }, "too many frames")
        try invalid({ _ = try ReferenceContextPlan(mode: .cover, sourceFrames: 1, channels: 2, steps: 8, strength: .nan) }, "NaN strength")
        let cover = try ReferenceContextPlan(mode: .cover, sourceFrames: 1, channels: 2, steps: 8, strength: 1)
        try invalid({ _ = try cover.paddedTarget(source: [0], silence: []) }, "wrong target")
        try invalid({ _ = try cover.context(source: Array(repeating: 0, count: 256), hints: nil) }, "missing hints")
        try invalid({ _ = try cover.context(source: Array(repeating: .nan, count: 256), hints: Array(repeating: 0, count: 256)) }, "nonfinite source")
        print("PASS: \(cases.count) PC-oracle routing cases, plus invalid-input checks")
    }
}
