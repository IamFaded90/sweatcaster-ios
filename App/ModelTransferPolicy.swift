import Foundation

enum ModelTransferPolicy {
    static func keepResumeData(bytes: Int, status: Int?) -> Bool {
        bytes > 0 && bytes < 4_000_000 && ![401, 403, 416].contains(status ?? 0)
    }
    static func progress(written: Int64, expected: Int64) -> Double? {
        guard expected > 0, written >= 0, written <= expected else { return nil }
        return Double(written) / Double(expected)
    }
}
