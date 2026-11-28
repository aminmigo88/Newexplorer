import Foundation

// CAD supplies malloc-backed coordinates. Keep the same storage from the native reader
// through SceneKit. Other formats already produce Swift arrays and retain that representation.
enum MeshPositions {
    case array([Float])
    case native(Data)

    var count: Int {
        switch self {
        case let .array(values): return values.count
        case let .native(data): return data.count / MemoryLayout<Float>.stride
        }
    }

    func withFloats<T>(_ body: (UnsafeBufferPointer<Float>) -> T) -> T {
        switch self {
        case let .array(values): return values.withUnsafeBufferPointer(body)
        case let .native(data): return data.withUnsafeBytes { body($0.bindMemory(to: Float.self)) }
        }
    }

    var vertexData: Data {
        switch self {
        case let .array(values): return values.withUnsafeBufferPointer { Data(buffer: $0) }
        case let .native(data): return data
        }
    }
}
