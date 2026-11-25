// Test-only stand-in for weight-shape validation on Linux. No tensor math.
public enum DType { case float32, float16, int32 }
public protocol MLXIndex {}
extension Int: MLXIndex {}
extension Range: MLXIndex where Bound == Int {}
extension PartialRangeFrom: MLXIndex where Bound == Int {}

public struct MLXArray {
    public let shape: [Int]
    public init(shape: [Int]) { self.shape = shape }
    public init(_ values: [Float], _ shape: [Int]) { self.shape = shape }
    public func dim(_ i: Int) -> Int { shape[i] }
    public func asType(_ dtype: DType) -> Self { self }
    public func reshaped(_ sizes: Int...) -> Self { Self(shape: sizes) }
    public func split(parts: Int, axis: Int) -> [Self] { Array(repeating: self, count: parts) }
    public func sum(axis: Int) -> Self { self }
    public func round() -> Self { self }
    public var T: Self { self }
    public subscript(_ index: any MLXIndex...) -> Self { self }
    public static func ones(_ dimensions: [Int], dtype: DType) -> Self { Self(shape: dimensions) }
}

public func +(lhs: MLXArray, rhs: MLXArray) -> MLXArray { lhs }
public func +(lhs: MLXArray, rhs: Float) -> MLXArray { lhs }
public func +(lhs: Float, rhs: MLXArray) -> MLXArray { rhs }
public func -(lhs: MLXArray, rhs: MLXArray) -> MLXArray { lhs }
public func -(lhs: MLXArray, rhs: Float) -> MLXArray { lhs }
public func /(lhs: MLXArray, rhs: MLXArray) -> MLXArray { lhs }
public func /(lhs: MLXArray, rhs: Float) -> MLXArray { lhs }
public func /(lhs: Float, rhs: MLXArray) -> MLXArray { rhs }
public func *(lhs: MLXArray, rhs: MLXArray) -> MLXArray { lhs }
public func *(lhs: MLXArray, rhs: Float) -> MLXArray { lhs }
public func *(lhs: Float, rhs: MLXArray) -> MLXArray { rhs }
infix operator .>: ComparisonPrecedence
public func .>(lhs: MLXArray, rhs: Float) -> MLXArray { lhs }
public func `where`(_ predicate: MLXArray, _ a: MLXArray, _ b: MLXArray) -> MLXArray { a }
public func exp(_ value: MLXArray) -> MLXArray { value }
public func log(_ value: MLXArray) -> MLXArray { value }
public func sin(_ value: MLXArray) -> MLXArray { value }
public func tanh(_ value: MLXArray) -> MLXArray { value }
public func floor(_ value: MLXArray) -> MLXArray { value }
public func clip(_ value: MLXArray, min: Float, max: Float) -> MLXArray { value }
public func matmul(_ a: MLXArray, _ b: MLXArray) -> MLXArray { a }
public func concatenated(_ values: [MLXArray], axis: Int) -> MLXArray { values[0] }
public func conv1d(_ a: MLXArray, _ b: MLXArray, stride: Int, padding: Int, dilation: Int) -> MLXArray { a }
public func eval(_ value: MLXArray...) {}
public func compile(shapeless: Bool, _ fn: @escaping (MLXArray, MLXArray, MLXArray) -> MLXArray)
    -> (MLXArray, MLXArray, MLXArray) -> MLXArray { fn }
