import Foundation

public struct ShadowBoundaryCleaner: Sendable {
    public init() {}
    /// Longest shadow paths receive spacing priority. Masks clip crowded sections
    /// into separate open paths, never draw a shortcut across the removed section.
    public func clean(_ paths: [Contour], outlines: [Contour], width w: Int, height h: Int,
                      spacing: Double, minimumLength: Double, maximumSamples: Int = 800_000) throws -> [Contour] {
        guard w > 1, h > 1, w <= Int.max / h, spacing.isFinite, (0...16).contains(spacing),
              minimumLength.isFinite, minimumLength >= 0, maximumSamples > 0 else { throw StencilError.invalidParameters }
        guard spacing > 0 else { return paths }
        var occupied = [UInt8](repeating: 0, count: w*h)
        // Conservatively cover pixel cells intersecting the spacing disk. The half
        // diagonal prevents fractional preview widths from leaking duplicate lines.
        // Spacing has up to one cell-diagonal of raster uncertainty; paths never move.
        let radius = spacing + sqrt(0.5), integerRadius = Int(ceil(radius + 0.5))
        func mark(_ point: Point) {
            let cx = min(w-1, max(0, Int(point.x))), cy = min(h-1, max(0, Int(point.y)))
            for y in max(0,cy-integerRadius)...min(h-1,cy+integerRadius) {
                for x in max(0,cx-integerRadius)...min(w-1,cx+integerRadius) {
                    let dx = Double(x)+0.5-point.x, dy = Double(y)+0.5-point.y
                    if dx*dx + dy*dy <= radius*radius { occupied[y*w+x] = 1 }
                }
            }
        }
        func markPath(_ path: Contour) throws {
            guard let first = path.points.first else { return }
            mark(first)
            var points = path.points
            if path.closed { points.append(first) }
            for (a,b) in zip(points, points.dropFirst()) {
                let length = hypot(b.x-a.x, b.y-a.y)
                let steps = max(1, Int(ceil(length / max(0.5, radius / 2))))
                for i in 1...steps {
                    if i % 1024 == 0 { try Task.checkCancellation() }
                    let t = Double(i) / Double(steps)
                    mark(Point(a.x+(b.x-a.x)*t, a.y+(b.y-a.y)*t))
                }
            }
        }
        for outline in outlines { try Task.checkCancellation(); try markPath(outline) }
        let order = paths.indices.sorted {
            let a = paths[$0].length, b = paths[$1].length
            return a == b ? $0 < $1 : a > b
        }
        var output: [Contour] = []
        var sampleCount = 0
        for index in order {
            try Task.checkCancellation()
            let original = paths[index]
            var dense: [Point] = []
            var segments = original.points
            if original.closed, let first = segments.first { segments.append(first) }
            for (a,b) in zip(segments, segments.dropFirst()) {
                let steps = max(1,Int(ceil(hypot(b.x-a.x,b.y-a.y))))
                guard steps <= maximumSamples - sampleCount else { throw StencilError.complexityLimit("shadow spacing samples") }
                for step in 0..<steps {
                    if step % 2048 == 0 { try Task.checkCancellation() }
                    let t = Double(step)/Double(steps)
                    dense.append(Point(a.x+(b.x-a.x)*t,a.y+(b.y-a.y)*t))
                }
                sampleCount += steps
            }
            if !original.closed, let last = original.points.last {
                sampleCount += 1
                guard sampleCount <= maximumSamples else { throw StencilError.complexityLimit("shadow spacing samples") }
                dense.append(last)
            }
            let path = Contour(points: dense, closed: original.closed), points = dense
            guard !points.isEmpty else { continue }
            let blocked = points.map { point -> Bool in
                let x = min(w-1,max(0,Int(point.x))), y = min(h-1,max(0,Int(point.y)))
                return occupied[y*w+x] != 0
            }
            var pieces: [Contour] = []
            if !blocked.contains(true) { pieces = [path] }
            else {
                // Start after a blocked vertex so a closed ring's surviving wraparound
                // section stays continuous. Any clipped ring becomes an open stroke.
                let start = path.closed ? (blocked.firstIndex(of: true)! + 1) % points.count : 0
                var run: [Point] = []
                for offset in 0..<points.count {
                    let i = path.closed ? (start+offset) % points.count : offset
                    if blocked[i] {
                        if run.count > 1 { pieces.append(Contour(points: run)) }
                        run = []
                    } else { run.append(points[i]) }
                }
                if run.count > 1 { pieces.append(Contour(points: run)) }
            }
            pieces = pieces.filter { $0.length >= minimumLength }
            for piece in pieces { try markPath(piece) }
            output += pieces
        }
        return output
    }
}
