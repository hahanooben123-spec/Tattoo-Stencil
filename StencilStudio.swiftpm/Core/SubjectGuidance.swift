import Foundation

/// Guidance only: normalized sampling changes ranking, never image/contour coordinates.
/// Keeping the mask at thumbnail size avoids a native-resolution mask allocation.
public struct SubjectGuidance: Sendable {
    public let mask: GrayImage
    public let revision: UUID
    public let features: [FeatureRegion]
    public init(mask: GrayImage,features: [FeatureRegion] = []) {
        self.mask = mask; self.features = Array(features.prefix(64)); self.revision = UUID()
    }
    public func value(x: Int, y: Int, width: Int, height: Int) -> Float {
        let mx = min(mask.width-1, max(0, x * mask.width / width))
        let my = min(mask.height-1, max(0, y * mask.height / height))
        return mask.pixels[my * mask.width + mx]
    }
    public func boundary(x: Int, y: Int, width: Int, height: Int) -> Bool {
        let r = max(2, Int((Double(max(width,height)) * 0.006).rounded()))
        let center = value(x: x,y: y,width: width,height: height)
        var low = center, high = center
        let left = value(x: x-r,y: y,width: width,height: height)
        let right = value(x: x+r,y: y,width: width,height: height)
        let top = value(x: x,y: y-r,width: width,height: height)
        let bottom = value(x: x,y: y+r,width: width,height: height)
        low = min(low,min(min(left,right),min(top,bottom)))
        high = max(high,max(max(left,right),max(top,bottom)))
        return high-low > 0.35 || (center > 0.15 && center < 0.85)
    }
    /// Raw traced paths have closely spaced vertices. Cut runs rather than joining
    /// endpoints across a removed background segment.
    public func clip(_ paths: [Contour], width: Int, height: Int) throws -> [Contour] {
        var output: [Contour] = []
        for path in paths {
            try Task.checkCancellation()
            let keep = path.points.map { value(x: Int($0.x),y: Int($0.y),width: width,height: height) >= 0.25 }
            guard let removed = keep.firstIndex(of: false) else { output.append(path); continue }
            let start = path.closed ? (removed+1) % max(1,keep.count) : 0
            var run: [Point] = []
            for offset in 0..<keep.count {
                let i = path.closed ? (start+offset) % keep.count : offset
                if keep[i] { run.append(path.points[i]) }
                else { if run.count > 1 { output.append(Contour(points: run,isPrimary: path.isPrimary)) }; run = [] }
            }
            if run.count > 1 { output.append(Contour(points: run,isPrimary: path.isPrimary)) }
        }
        return output
    }
}

public struct MainContourSelector: Sendable {
    public init() {}
    public func classify(_ paths: [Contour], image: GrayImage, guidance: SubjectGuidance?) throws -> [Contour] {
        let w = image.width, h = image.height, dimension = Double(max(w,h))
        var output: [Contour] = []
        for var path in paths {
            try Task.checkCancellation()
            guard !path.points.isEmpty else { continue }
            var contrast: Float = 0, boundaryCount = 0, insideCount = 0, featureCount = 0
            for (i,point) in path.points.enumerated() {
                if i % 4096 == 0 { try Task.checkCancellation() }
                let x = min(w-1,max(0,Int(point.x))), y = min(h-1,max(0,Int(point.y)))
                let gx = abs(image.pixels[y*w+min(w-1,x+2)] - image.pixels[y*w+max(0,x-2)])
                let gy = abs(image.pixels[min(h-1,y+2)*w+x] - image.pixels[max(0,y-2)*w+x])
                // A wide difference can cancel across both sides of a thin eyelid
                // or lip. Retain the immediate gradient evidence as well.
                let nearX = abs(image.pixels[y*w+min(w-1,x+1)] - image.pixels[y*w+max(0,x-1)])
                let nearY = abs(image.pixels[min(h-1,y+1)*w+x] - image.pixels[max(0,y-1)*w+x])
                contrast += max(max(gx,gy),max(nearX,nearY))
                if let guidance {
                    if guidance.boundary(x: x,y: y,width: w,height: h) { boundaryCount += 1 }
                    if guidance.value(x: x,y: y,width: w,height: h) >= 0.25 { insideCount += 1 }
                    if guidance.isFeature(x: x,y: y,width: w,height: h) { featureCount += 1 }
                }
            }
            let count = Float(path.points.count), strength = contrast/count, length = path.length
            // Long, coherent source curves and enclosed shapes make useful
            // separators even when their contrast is lower than tiny texture.
            var chordLength = 0.0
            for start in stride(from: 0,to: max(0,path.points.count-1),by: 6) {
                let end = min(path.points.count-1,start+6)
                chordLength += hypot(path.points[end].x-path.points[start].x,path.points[end].y-path.points[start].y)
            }
            let coherentForm = length >= dimension*0.06 && strength >= 0.04 &&
                (path.closed || chordLength/max(length,0.000001) >= 0.86)
            path.isFeature = Float(featureCount)/count >= 0.2 && strength >= 0.015 && length >= 2
            if guidance != nil {
                // Keep actual silhouette edges just outside a soft mask, but discard
                // irrelevant background strokes. The mask perimeter is never traced.
                guard path.isFeature || Float(insideCount)/count >= 0.35 || Float(boundaryCount)/count >= 0.25 else { continue }
                path.isPrimary = path.isFeature || coherentForm || Float(boundaryCount)/count >= 0.2 || (strength >= 0.12 && length >= dimension*0.025)
            } else {
                path.isPrimary = coherentForm || (length >= dimension*0.12 && strength >= 0.06) || (length >= dimension*0.025 && strength >= 0.25)
            }
            output.append(path)
        }
        return output
    }
}

public struct OutlineStroke: Sendable {
    public let widthMultiplier: Double
    public let opacityMultiplier: Double
    public static func style(primary: Bool, emphasis: Float) -> OutlineStroke {
        let amount = Double(min(1,max(0,emphasis)))
        return OutlineStroke(widthMultiplier: primary ? 1+0.5*amount : 1-0.08*amount,
                             opacityMultiplier: 1)
    }
}
