import Foundation

public enum FacialFeature: String, Sendable { case eye, eyebrow, nose, mouth }

/// Top-left normalized image coordinates, not landmark paths to be drawn.
public struct FeatureRegion: Sendable, Equatable {
    public let kind: FacialFeature
    public let minX: Double, minY: Double, maxX: Double, maxY: Double
    public init(kind: FacialFeature,minX: Double,minY: Double,maxX: Double,maxY: Double) throws {
        guard [minX,minY,maxX,maxY].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              maxX > minX,maxY > minY else { throw StencilError.invalidParameters }
        self.kind = kind; self.minX = minX; self.minY = minY; self.maxX = maxX; self.maxY = maxY
    }
    public func contains(x: Double,y: Double) -> Bool { x >= minX && x <= maxX && y >= minY && y <= maxY }
    /// Vision points are face-local with a bottom-left origin. Only an image ROI
    /// is produced here, never a polyline that could replace source anatomy.
    public static func fromVisionPoints(kind: FacialFeature,points: [Point],faceX: Double,faceY: Double,
                                        faceWidth: Double,faceHeight: Double) throws -> FeatureRegion {
        guard !points.isEmpty,[faceX,faceY,faceWidth,faceHeight].allSatisfy(\.isFinite),faceWidth > 0,faceHeight > 0,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { throw StencilError.invalidParameters }
        let xs = points.map { faceX+$0.x*faceWidth }, ys = points.map { 1-(faceY+$0.y*faceHeight) }
        return try FeatureRegion(kind: kind,minX: max(0,xs.min()!-faceWidth*0.04),minY: max(0,ys.min()!-faceHeight*0.035),
                                 maxX: min(1,xs.max()!+faceWidth*0.04),maxY: min(1,ys.max()!+faceHeight*0.035))
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
                for x in left...right { map[y*width+x] = 1 }
            }
        }
        return map
    }
    func isFeature(x: Int,y: Int,width: Int,height: Int) -> Bool {
        let nx = (Double(x)+0.5)/Double(width), ny = (Double(y)+0.5)/Double(height)
        return features.contains { $0.contains(x: nx,y: ny) }
    }
}
