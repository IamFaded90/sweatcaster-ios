import Foundation

/// ACE-Step 1.5's supported vocal language codes, including instrumental/auto.
enum ACESongLanguages {
    static let codes: Set<String> = [
        "ar", "az", "bg", "bn", "ca", "cs", "da", "de", "el", "en",
        "es", "fa", "fi", "fr", "he", "hi", "hr", "ht", "hu", "id",
        "is", "it", "ja", "ko", "la", "lt", "ms", "ne", "nl", "no",
        "pa", "pl", "pt", "ro", "ru", "sa", "sk", "sr", "sv", "sw",
        "ta", "te", "th", "tl", "tr", "uk", "ur", "vi", "yue", "zh",
        "unknown"
    ]

    static func validated(_ code: String) -> String? { codes.contains(code) ? code : nil }
}

/// Copies a positive-stride Core ML output into row-major order, including
/// padding between outer dimensions as well as padding between individual rows.
struct ACEStridedTensor {
    let shape: [Int]
    let strides: [Int]

    init(shape: [Int], strides: [Int]) {
        precondition(!shape.isEmpty && shape.count == strides.count)
        precondition(shape.allSatisfy { $0 > 0 } && strides.allSatisfy { $0 >= 0 })
        self.shape = shape
        self.strides = strides
    }

    var count: Int { shape.reduce(1, *) }

    var isContiguous: Bool {
        var expected = 1
        for axis in shape.indices.reversed() {
            if shape[axis] > 1 && strides[axis] != expected { return false }
            expected *= shape[axis]
        }
        return true
    }

    func copy<T>(from source: UnsafeBufferPointer<T>) -> [T] {
        let width = shape.last!
        let rows = count / width
        var result: [T] = []
        result.reserveCapacity(count)
        for row in 0..<rows {
            var remaining = row
            var offset = 0
            for axis in shape.indices.dropLast().reversed() {
                offset += (remaining % shape[axis]) * strides[axis]
                remaining /= shape[axis]
            }
            if strides.last == 1 {
                result.append(contentsOf: source[offset..<(offset + width)])
            } else {
                for column in 0..<width { result.append(source[offset + column * strides.last!]) }
            }
        }
        return result
    }
}
