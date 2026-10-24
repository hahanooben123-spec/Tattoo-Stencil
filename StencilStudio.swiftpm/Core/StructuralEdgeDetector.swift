import Foundation

public struct StructuralEdgeDetector: Sendable {
    public init() {}
    /// Fine Scharr localization with coarse-scale support and local contrast ranking.
    /// Coarse information ranks existing fine edges; it never moves their coordinates.
    public func detect(_ image: GrayImage, parameters p: Parameters, guidance: SubjectGuidance? = nil) throws -> [UInt8] {
        try p.validate()
        let w = image.width, h = image.height, n = w * h
        var magnitude = [Float](repeating: 0, count: n)
        var direction = [UInt8](repeating: 0, count: n)
        let a = image.pixels
        let featureMap = try guidance?.featureMap(width: w,height: h)
        if w < 3 || h < 3 { return [UInt8](repeating: 0, count: n) }
        // Structural scale belongs to the displayed image, not native-pixel
        // samplingScale. Multiplying by the preview scale made the old coarse
        // image almost identical to the fine image on large imported references.
        let unit = Double(max(w,h))/900
        let coarse = try ScaleSpace.gaussian(a, width: w, height: h, sigma: max(1.6, 3.2 * unit))
        let residual = zip(a,coarse).map { abs($0-$1) }
        let texture = try ScaleSpace.mean(residual,width: w,height: h,radius: max(3,Int((7*unit).rounded())))
        let means = try ScaleSpace.mean(a, width: w, height: h, radius: max(2, Int((5 * unit).rounded())))
        let deviation = zip(a, means).map { abs($0 - $1) }
        let localContrast = try ScaleSpace.mean(deviation, width: w, height: h, radius: max(1, Int((3 * unit).rounded())))
        var support = [Float](repeating: 0, count: n)
        for y in 1..<(h - 1) {
            try Task.checkCancellation()
            for x in 1..<(w - 1) {
                let i = y * w + x
                let gx = (3 * (a[i-w+1] - a[i-w-1]) + 10 * (a[i+1] - a[i-1]) + 3 * (a[i+w+1] - a[i+w-1])) / 16
                let gy = (3 * (a[i+w-1] - a[i-w-1]) + 10 * (a[i+w] - a[i-w]) + 3 * (a[i+w+1] - a[i-w+1])) / 16
                magnitude[i] = hypot(gx, gy)
                let cx = (3 * (coarse[i-w+1] - coarse[i-w-1]) + 10 * (coarse[i+1] - coarse[i-1]) + 3 * (coarse[i+w+1] - coarse[i+w-1])) / 16
                let cy = (3 * (coarse[i+w-1] - coarse[i-w-1]) + 10 * (coarse[i+w] - coarse[i-w]) + 3 * (coarse[i+w+1] - coarse[i-w+1])) / 16
                support[i] = min(1, hypot(cx, cy) * 2.4 / max(magnitude[i], 0.000001))
                var angle = atan2(gy, gx) * 180 / Float.pi
                if angle < 0 { angle += 180 }
                direction[i] = angle < 22.5 || angle >= 157.5 ? 0 : angle < 67.5 ? 1 : angle < 112.5 ? 2 : 3
            }
        }
        var state = [UInt8](repeating: 0, count: n), queue: [Int] = []
        let high = p.edgeThreshold * (1.4 - p.detail)
        let offsets = [1, w + 1, w, w - 1]
        for y in 1..<(h - 1) {
            try Task.checkCancellation()
            for x in 1..<(w - 1) {
                let i = y * w + x, m = magnitude[i], d = offsets[Int(direction[i])]
                let nearSubject = guidance?.boundary(x: x,y: y,width: w,height: h) ?? false
                let eye = featureMap?[i] == 2
                let feature = (featureMap?[i] ?? 0) != 0
                if let guidance, !nearSubject && !feature && guidance.value(x: x,y: y,width: w,height: h) < 0.15 { continue }
                // Repeated fur/skin texture disappears at the structural scale.
                // An isolated strong fine line (eyelid, whisker, leaf vein) may
                // survive without coarse support, unlike dense repeated marks.
                let isolated = m >= max(0.18,texture[i]*4.5)
                if p.textureSuppression >= 0.5 && !feature && !nearSubject && support[i] < 0.45 && !isolated { continue }
                let penalty = p.textureSuppression * (1 - support[i]) * (eye ? 0.1 : 1)
                let score = m * (1 - penalty)
                let contrastFloor: Float = 0.008 + (1 - p.detail) * 0.035
                var localHigh = nearSubject ? high * 0.55 : high
                if eye {
                    localHigh = min(localHigh*0.5,max(0.012,localContrast[i]*0.8))
                } else if feature {
                    localHigh = min(localHigh*0.65,max(0.025,localContrast[i]*1.5))
                } else if p.detail > 0.65 && support[i] > 0.55 {
                    // Coherent low-contrast details should not need a global dark/light
                    // jump. A minimum absolute gradient still excludes flat gradients.
                    localHigh = min(localHigh,max(0.02,localContrast[i]))
                }
                let localLow = localHigh*0.4
                // Asymmetric plateau tie-break prevents doubled step edges.
                if score >= localLow && (localContrast[i] >= (feature ? 0.003 : contrastFloor * (nearSubject ? 0.5 : 1)) || m >= high * 2),
                   m > magnitude[i-d] && m >= magnitude[i+d] {
                    state[i] = score >= localHigh ? 2 : 1
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
