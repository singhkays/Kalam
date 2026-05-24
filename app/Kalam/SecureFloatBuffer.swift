import Foundation

extension Array where Element == Float {
    mutating func secureZero() {
        withUnsafeMutableBufferPointer { buffer in
            if let baseAddress = buffer.baseAddress {
                memset(baseAddress, 0, buffer.count * MemoryLayout<Float>.size)
            }
        }
    }
}

