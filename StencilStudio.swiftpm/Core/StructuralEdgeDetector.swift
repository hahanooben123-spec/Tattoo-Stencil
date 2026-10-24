import Foundation

public struct StructuralEdgeDetector: Sendable {
    public init() {}
    /// Scharr gradients, non-maximum suppression and eight-connected Canny hysteresis.
    public func detect(_ image: GrayImage, parameters p: Parameters) throws -> [UInt8] {
        let w = image.width, h = image.height, n = w * h
        var magnitude = [Float](repeating: 0, count: n)
        var direction = [UInt8](repeating: 0, count: n)
        let a = image.pixels
        if w < 3 || h < 3 { return [UInt8](repeating: 0, count: n) }
        for y in 1..<(h - 1) {
            try Task.checkCancellation()
            for x in 1..<(w - 1) {
                let i = y * w + x
                let gx = (3 * (a[i-w+1] - a[i-w-1]) + 10 * (a[i+1] - a[i-1]) + 3 * (a[i+w+1] - a[i+w-1])) / 16
                let gy = (3 * (a[i+w-1] - a[i-w-1]) + 10 * (a[i+w] - a[i-w]) + 3 * (a[i+w+1] - a[i-w+1])) / 16
                magnitude[i] = hypot(gx, gy)
                var angle = atan2(gy, gx) * 180 / Float.pi
                if angle < 0 { angle += 180 }
                direction[i] = angle < 22.5 || angle >= 157.5 ? 0 : angle < 67.5 ? 1 : angle < 112.5 ? 2 : 3
            }
        }
        var state = [UInt8](repeating: 0, count: n), queue: [Int] = []
        let high = p.edgeThreshold * (1.4 - p.detail), low = high * 0.4
        let offsets = [1, w + 1, w, w - 1]
        for y in 1..<(h - 1) {
            try Task.checkCancellation()
            for x in 1..<(w - 1) {
                let i = y * w + x, m = magnitude[i], d = offsets[Int(direction[i])]
                // Asymmetric plateau tie-break prevents doubled step edges.
                if m >= low && m > magnitude[i-d] && m >= magnitude[i+d] {
                    state[i] = m >= high ? 2 : 1
                    if state[i] == 2 { queue.append(i) }
                }
            }
        }
        var head = 0
        while head < queue.count {
            if head % 4096 == 0 { try Task.checkCancellation() }
            let i = queue[head]; head += 1
            for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                let j = i + dy * w + dx
                if state[j] == 1 { state[j] = 2; queue.append(j) }
            } }
        }
        return state.map { $0 == 2 ? 1 : 0 }
    }
}
