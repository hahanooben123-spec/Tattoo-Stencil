import Foundation

public enum FacialFeature: String, Sendable { case eye, eyebrow, nose, mouth }

/// Top-left normalized image coordinates, not landmark paths to be drawn.
public struct FeatureRegion: Sendable, Equatable {
    public let kind: FacialFeature
    public let minX: Double, minY: Double, maxX: Double, maxY: Double
    public let landmarks: [Point]
    public let supportRadius: Double
    public let closed: Bool
    public init(kind: FacialFeature,minX: Double,minY: Double,maxX: Double,maxY: Double,
                landmarks: [Point] = [],supportRadius: Double = 0,closed: Bool = false) throws {
        guard [minX,minY,maxX,maxY].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              maxX > minX,maxY > minY,supportRadius.isFinite,(0...1).contains(supportRadius),landmarks.count <= 256,
              landmarks.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }),
              landmarks.isEmpty || (landmarks.count > 1 && supportRadius > 0) else { throw StencilError.invalidParameters }
        self.kind = kind; self.minX = minX; self.minY = minY; self.maxX = maxX; self.maxY = maxY
        self.landmarks = landmarks; self.supportRadius = supportRadius; self.closed = closed
    }
    public func contains(x: Double,y: Double) -> Bool {
        guard x >= minX && x <= maxX && y >= minY && y <= maxY else { return false }
        guard !landmarks.isEmpty else { return true }
        // The iris and pupil lie inside the eyelid polygon, not on its perimeter.
        // Protect that aperture while leaving surrounding skin outside the band.
        if kind == .eye && closed && landmarks.count >= 3 {
            var inside = false
            var previous = landmarks.count-1
            for current in landmarks.indices {
                let a = landmarks[previous], b = landmarks[current]
                if (a.y > y) != (b.y > y),x < (b.x-a.x)*(y-a.y)/(b.y-a.y)+a.x { inside.toggle() }
                previous = current
            }
            if inside { return true }
        }
        let segments = closed ? landmarks.count : landmarks.count-1
        for i in 0..<segments {
            let a = landmarks[i], b = landmarks[(i+1) % landmarks.count]
            let dx = b.x-a.x, dy = b.y-a.y
            let t = min(1,max(0,((x-a.x)*dx+(y-a.y)*dy)/max(0.000000000001,dx*dx+dy*dy)))
            let ex = x-a.x-t*dx, ey = y-a.y-t*dy
            if ex*ex+ey*ey <= supportRadius*supportRadius { return true }
        }
        return false
    }
    /// Vision points are face-local with a bottom-left origin. Only an image ROI
    /// is produced here, never a polyline that could replace source anatomy.
    public static func fromVisionPoints(kind: FacialFeature,points: [Point],faceX: Double,faceY: Double,
                                        faceWidth: Double,faceHeight: Double,closed: Bool = false) throws -> FeatureRegion {
        guard !points.isEmpty,[faceX,faceY,faceWidth,faceHeight].allSatisfy(\.isFinite),faceWidth > 0,faceHeight > 0,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { throw StencilError.invalidParameters }
        let xs = points.map { faceX+$0.x*faceWidth }, ys = points.map { 1-(faceY+$0.y*faceHeight) }
        return try FeatureRegion(kind: kind,minX: max(0,xs.min()!-faceWidth*0.04),minY: max(0,ys.min()!-faceHeight*0.035),
                                 maxX: min(1,xs.max()!+faceWidth*0.04),maxY: min(1,ys.max()!+faceHeight*0.035),
                                 landmarks: zip(xs,ys).map { Point(min(1,max(0,$0)),min(1,max(0,$1))) },
                                 supportRadius: max(faceWidth*0.025,faceHeight*0.012),closed: closed)
    }
}

extension SubjectGuidance {
    func featureMap(width: Int,height: Int) throws -> [UInt8]? {
        guard !features.isEmpty else { return nil }
        var map = [UInt8](repeating: 0,count: width*height)
        for region in features {
            try Task.checkCancellation()
            let left = min(width-1,Int(region.minX*Double(width))), right = min(width-1,Int(region.maxX*Double(width)))
            let top = min(height-1,Int(region.minY*Double(height))), bottom = min(height-1,Int(region.maxY*Double(height)))
            for y in top...bottom {
                if y % 64 == 0 { try Task.checkCancellation() }
                for x in left...right where region.contains(x: (Double(x)+0.5)/Double(width),y: (Double(y)+0.5)/Double(height)) {
                    map[y*width+x] = max(map[y*width+x],region.kind == .eye ? 2 : 1)
                }
            }
        }
        return map
    }
    func isFeature(x: Int,y: Int,width: Int,height: Int) -> Bool {
        let nx = (Double(x)+0.5)/Double(width), ny = (Double(y)+0.5)/Double(height)
        return features.contains { $0.contains(x: nx,y: ny) }
    }
}
