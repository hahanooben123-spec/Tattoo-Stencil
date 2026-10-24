import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

public struct ImagePreprocessor: Sendable {
    public init() {}
    /// Small bilateral kernel: spatial smoothing weighted by luminance similarity.
    public func process(_ image: GrayImage, parameters p: Parameters,guidance: SubjectGuidance? = nil) throws -> GrayImage {
        try p.validate()
        let w = image.width, h = image.height
        var output = image.pixels
        let features = try guidance?.featureMap(width: w,height: h)
        if p.noiseReduction > 0 {
            let radius = max(1, Int(((p.noiseReduction > 0.65 ? 3.0 : 2.0) * p.samplingScale).rounded()))
            let rangeSigma = 0.025 + Double(p.noiseReduction) * 0.12
            let spatialSigma = max(0.45, (0.8 + Double(p.noiseReduction)) * p.samplingScale)
            // Quantized range weights avoid an exponential for every neighbor of
            // every pixel. Luminance distance error is at most 1/8192.
            let rangeWeights = (0...4096).map { index -> Double in
                let delta = Double(index) / 4096
                return exp(-delta * delta / (2 * rangeSigma * rangeSigma))
            }
            var kernel: [(Int, Int, Double)] = []
            for dy in -radius...radius { for dx in -radius...radius {
                kernel.append((dx, dy, exp(-Double(dx * dx + dy * dy) / (2 * spatialSigma * spatialSigma))))
            } }
            for y in 0..<h {
                try Task.checkCancellation()
                for x in 0..<w {
                    let center = Double(image.pixels[y * w + x])
                    var sum = 0.0, weights = 0.0
                    for (dx, dy, spatial) in kernel {
                        let nx = min(w - 1, max(0, x + dx)), ny = min(h - 1, max(0, y + dy))
                        let sample = Double(image.pixels[ny * w + nx]), delta = sample - center
                        let weight = spatial * rangeWeights[min(4096,Int(abs(delta) * 4096 + 0.5))]
                        sum += sample * weight; weights += weight
                    }
                    let filtered = sum/weights
                    // Thin low-contrast facial lines must survive smoothing before
                    // edge selection gets a chance to protect them.
                    let preserve = features?[y*w+x] == 1 ? 0.45+0.35*Double(p.detail) : 0
                    output[y*w+x] = Float(filtered*(1-preserve)+center*preserve)
                }
            }
        }
        #if canImport(Accelerate)
        try output.withUnsafeMutableBufferPointer { buffer in
            var multiplier = p.contrast, bias = (1 - p.contrast) * 0.5
            var lower: Float = 0, upper: Float = 1
            for start in stride(from: 0, to: buffer.count, by: 65536) {
                try Task.checkCancellation()
                let count = vDSP_Length(min(65536, buffer.count - start))
                let pointer = buffer.baseAddress!.advanced(by: start)
                vDSP_vsmsa(pointer, 1, &multiplier, &bias, pointer, 1, count)
                vDSP_vclip(pointer, 1, &lower, &upper, pointer, 1, count)
            }
        }
        #else
        for i in output.indices {
            if i % 65536 == 0 { try Task.checkCancellation() }
            output[i] = min(1, max(0, (output[i] - 0.5) * p.contrast + 0.5))
        }
        #endif
        return try GrayImage(width: w, height: h, pixels: output)
    }
}
