import Foundation

enum ScaleSpace {
    /// Finite, separable Gaussian; row checkpoints bound cancellation latency.
    static func gaussian(_ input: [Float], width w: Int, height h: Int, sigma: Double) throws -> [Float] {
        let radius = max(1, min(24, Int(ceil(sigma * 3))))
        let raw = (-radius...radius).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        let total = raw.reduce(0, +), kernel = raw.map { Float($0 / total) }
        var temporary = [Float](repeating: 0, count: input.count)
        var output = temporary
        for y in 0..<h {
            try Task.checkCancellation()
            for x in 0..<w {
                var value: Float = 0
                for k in -radius...radius { value += input[y*w + min(w-1, max(0, x+k))] * kernel[k+radius] }
                temporary[y*w+x] = value
            }
        }
        for y in 0..<h {
            try Task.checkCancellation()
            for x in 0..<w {
                var value: Float = 0
                for k in -radius...radius { value += temporary[min(h-1, max(0, y+k))*w+x] * kernel[k+radius] }
                output[y*w+x] = value
            }
        }
        return output
    }

    /// Separable box mean with O(pixels) work and bounded, clamped-edge windows.
    static func mean(_ input: [Float], width w: Int, height h: Int, radius: Int) throws -> [Float] {
        let r = max(1, radius), divisor = Float(2*r+1)
        var temporary = [Float](repeating: 0, count: input.count), output = temporary
        for y in 0..<h {
            try Task.checkCancellation()
            var sum: Float = 0
            for k in -r...r { sum += input[y*w+min(w-1,max(0,k))] }
            for x in 0..<w {
                temporary[y*w+x] = sum / divisor
                sum += input[y*w+min(w-1,x+r+1)] - input[y*w+max(0,x-r)]
            }
        }
        for x in 0..<w {
            if x % 32 == 0 { try Task.checkCancellation() }
            var sum: Float = 0
            for k in -r...r { sum += temporary[min(h-1,max(0,k))*w+x] }
            for y in 0..<h {
                output[y*w+x] = sum / divisor
                sum += temporary[min(h-1,y+r+1)*w+x] - temporary[max(0,y-r)*w+x]
            }
        }
        return output
    }
}
