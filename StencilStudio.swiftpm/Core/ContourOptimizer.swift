import Foundation

public struct ContourOptimizer: Sendable {
    public init() {}
    public func optimize(_ contours: [Contour], minimumLength: Double, tolerance: Double) throws -> [Contour] {
        var output: [Contour] = []
        for contour in contours {
            try Task.checkCancellation()
            let required = contour.isFeature ? min(minimumLength,max(2,minimumLength*0.18)) : minimumLength
            guard contour.length >= required else { continue }
            // No positional averaging: simplification only, bounded by source-pixel tolerance.
            var points = contour.points
            if contour.closed { points.append(points[0]) }
            points = try simplify(points, tolerance: tolerance)
            if contour.closed && points.last == points.first { points.removeLast() }
            if points.count >= (contour.closed ? 3 : 2) {
                output.append(Contour(points: points,closed: contour.closed,isPrimary: contour.isPrimary,isFeature: contour.isFeature))
            }
        }
        return output
    }
    private func simplify(_ points: [Point], tolerance: Double) throws -> [Point] {
        guard points.count > 2, tolerance > 0 else { return points }
        var keep = Set([0, points.count - 1]), stack = [(0, points.count - 1)]
        while let (start, end) = stack.popLast() {
            try Task.checkCancellation()
            guard end > start + 1 else { continue }
            let a = points[start], b = points[end], dx = b.x-a.x, dy = b.y-a.y, squared = dx*dx + dy*dy
            var maximum = tolerance * tolerance, split: Int?
            for i in (start+1)..<end {
                let t = squared > 0 ? min(1, max(0, ((points[i].x-a.x)*dx + (points[i].y-a.y)*dy) / squared)) : 0
                let ex = points[i].x-a.x-t*dx, ey = points[i].y-a.y-t*dy
                let distance = ex*ex + ey*ey
                if distance > maximum { maximum = distance; split = i }
            }
            if let split { keep.insert(split); stack.append((start, split)); stack.append((split, end)) }
        }
        return keep.sorted().map { points[$0] }
    }
}
