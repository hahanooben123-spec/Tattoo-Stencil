import Foundation

public struct LayerAgreement: Sendable {
    public let previewPrecision: Double
    public let finalCoverage: Double
    public var score: Double {
        let sum = previewPrecision + finalCoverage
        return sum > 0 ? 2 * previewPrecision * finalCoverage / sum : 0
    }
}
public struct PreviewAgreement: Sendable {
    public let outlines: LayerAgreement
    public let shadows: LayerAgreement
    public let tolerancePixels: Int
    public var score: Double { (outlines.score + shadows.score) / 2 }
}

public enum PreviewFidelity {
    /// Symmetric coverage of rasterized paths, in preview coordinates. This measures
    /// agreement with final processing, not artistic correctness or source fidelity.
    public static func compare(preview: StencilResult, final: StencilResult,
                               tolerancePixels: Int = 2) throws -> PreviewAgreement {
        guard (0...8).contains(tolerancePixels), preview.width <= 1200, preview.height <= 1200,
              abs(Double(preview.width)/Double(preview.height) - Double(final.width)/Double(final.height)) < 0.02 else {
            throw StencilError.invalidParameters
        }
        let w = preview.width, h = preview.height
        func raster(_ paths: [Contour], sourceWidth: Int, sourceHeight: Int) throws -> [UInt8] {
            var mask = [UInt8](repeating: 0, count: w*h)
            let sx = Double(w) / Double(sourceWidth), sy = Double(h) / Double(sourceHeight)
            for path in paths {
                try Task.checkCancellation()
                var points = path.points
                if path.closed, let first = points.first { points.append(first) }
                for (a,b) in zip(points, points.dropFirst()) {
                    let ax = a.x*sx, ay = a.y*sy, bx = b.x*sx, by = b.y*sy
                    let steps = max(1, Int(ceil(max(abs(bx-ax), abs(by-ay)) * 2)))
                    for step in 0...steps {
                        if step % 2048 == 0 { try Task.checkCancellation() }
                        let t = Double(step) / Double(steps)
                        let x = min(w-1,max(0,Int(ax+(bx-ax)*t))), y = min(h-1,max(0,Int(ay+(by-ay)*t)))
                        mask[y*w+x] = 1
                    }
                }
            }
            return mask
        }
        func coverage(_ source: [UInt8], _ target: [UInt8]) throws -> Double {
            var total = 0, matched = 0
            for y in 0..<h {
                try Task.checkCancellation()
                for x in 0..<w where source[y*w+x] != 0 {
                    total += 1
                    var found = false
                    for ny in max(0,y-tolerancePixels)...min(h-1,y+tolerancePixels) {
                        for nx in max(0,x-tolerancePixels)...min(w-1,x+tolerancePixels) {
                            let dx = nx-x, dy = ny-y
                            if dx*dx+dy*dy <= tolerancePixels*tolerancePixels && target[ny*w+nx] != 0 { found = true; break }
                        }
                        if found { break }
                    }
                    if found { matched += 1 }
                }
            }
            return total > 0 ? Double(matched)/Double(total) : (target.contains(1) ? 0 : 1)
        }
        func agreement(_ kind: LayerKind) throws -> LayerAgreement {
            let a = try raster(preview.contours(for: kind), sourceWidth: preview.width, sourceHeight: preview.height)
            let b = try raster(final.contours(for: kind), sourceWidth: final.width, sourceHeight: final.height)
            return try LayerAgreement(previewPrecision: coverage(a,b), finalCoverage: coverage(b,a))
        }
        return try PreviewAgreement(outlines: agreement(.outlines), shadows: agreement(.shadows), tolerancePixels: tolerancePixels)
    }
}

public extension GrayImage {
    /// Area averaging for reproducible offline preview/full-resolution validation.
    /// App thumbnails are decoded by ImageIO and may differ slightly in color sampling.
    func downsampled(maximumDimension: Int) throws -> GrayImage {
        guard maximumDimension >= 2 else { throw StencilError.invalidParameters }
        guard max(width,height) > maximumDimension else { return self }
        let scale = Double(maximumDimension) / Double(max(width,height))
        let w = max(2, Int((Double(width)*scale).rounded())), h = max(2,Int((Double(height)*scale).rounded()))
        var output = [Float](repeating: 0, count: w*h)
        for y in 0..<h {
            try Task.checkCancellation()
            let top = Double(y)*Double(height)/Double(h), bottom = Double(y+1)*Double(height)/Double(h)
            for x in 0..<w {
                let left = Double(x)*Double(width)/Double(w), right = Double(x+1)*Double(width)/Double(w)
                var sum = 0.0
                for sy in Int(floor(top))..<min(height,Int(ceil(bottom))) {
                    let wy = min(bottom,Double(sy+1))-max(top,Double(sy))
                    for sx in Int(floor(left))..<min(width,Int(ceil(right))) {
                        let wx = min(right,Double(sx+1))-max(left,Double(sx))
                        sum += Double(pixels[sy*width+sx])*wx*wy
                    }
                }
                output[y*w+x] = Float(min(1,max(0,sum/((right-left)*(bottom-top)))))
            }
        }
        return try GrayImage(width: w, height: h, pixels: output)
    }
}
