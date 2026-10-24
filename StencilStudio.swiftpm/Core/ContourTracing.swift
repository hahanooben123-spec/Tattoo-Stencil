import Foundation

private struct Link: Hashable {
    let a: Int
    let b: Int
    init(_ a: Int, _ b: Int) { self.a = min(a, b); self.b = max(a, b) }
}

/// Follow graph edges once. Junctions terminate a stroke, avoiding artificial lines
/// connecting unrelated branches. Iterative traversal handles long contours safely.
private func trace(_ graph: [Int: [Int]], stride: Int, offset: Double) throws -> [Contour] {
    var used = Set<Link>(), result: [Contour] = []
    let nodes = graph.keys.sorted()
    func point(_ node: Int) -> Point { Point(Double(node % stride) + offset, Double(node / stride) + offset) }
    for start in nodes.filter({ graph[$0]!.count != 2 }) + nodes.filter({ graph[$0]!.count == 2 }) {
        try Task.checkCancellation()
        for next in graph[start]!.sorted() where !used.contains(Link(start, next)) {
            var path = [point(start)], previous = start, current = next
            used.insert(Link(previous, current))
            var closed = false
            while true {
                if path.count % 4096 == 0 { try Task.checkCancellation() }
                if current == start { closed = true; break }
                path.append(point(current))
                let neighbors = graph[current]!
                guard neighbors.count == 2,
                      let candidate = neighbors.first(where: { $0 != previous }),
                      !used.contains(Link(current, candidate)) else { break }
                used.insert(Link(current, candidate)); previous = current; current = candidate
            }
            if path.count >= 2 { result.append(Contour(points: path, closed: closed)) }
        }
    }
    return result
}

public struct StructuralContourTracer: Sendable {
    public init() {}
    public func traceEdges(_ edges: [UInt8], width w: Int, height h: Int) throws -> [Contour] {
        var graph: [Int: [Int]] = [:]
        for y in 0..<h {
            try Task.checkCancellation()
            for x in 0..<w where edges[y*w+x] != 0 {
                let i = y*w+x
                for (dx, dy) in [(1, 0), (0, 1), (1, 1), (-1, 1)] {
                    let nx = x+dx, ny = y+dy
                    guard nx >= 0, nx < w, ny < h, edges[ny*w+nx] != 0 else { continue }
                    // Avoid diagonal shortcuts where an orthogonal connection exists.
                    if dx != 0 && dy != 0 && (edges[y*w+nx] != 0 || edges[ny*w+x] != 0) { continue }
                    let j = ny*w+nx
                    graph[i, default: []].append(j); graph[j, default: []].append(i)
                }
            }
        }
        return try trace(graph, stride: w, offset: 0.5)
    }
}

public struct ShadowBoundaryGenerator: Sendable {
    public init() {}
    public func generate(_ segmentation: Segmentation, width: Int, height: Int, sensitivity: Float) throws -> [Contour] {
        let centers = segmentation.centers
        // Similar neighboring clusters can be ignored without suppressing deeper transitions.
        let minimumDifference = 0.02 + (1 - sensitivity) * 0.14
        return try regionBoundaries(segmentation.labels, width: width, height: height) { a, b in
            abs(centers[Int(a)] - centers[Int(b)]) >= minimumDifference
        }
    }
}

public struct HighlightBoundaryGenerator: Sendable {
    public init() {}
    public func generate(_ image: GrayImage, sensitivity: Float, minimumArea: Int) throws -> [Contour] {
        let threshold: Float = 0.98 - sensitivity * 0.22
        var labels = image.pixels.map { UInt8($0 >= threshold ? 1 : 0) }
        try suppressSmallRegions(&labels, width: image.width, height: image.height, minimumArea: minimumArea)
        // Bilateral preprocessing and the high threshold reduce small bright pixel noise.
        // Local contrast screening is deferred to Phase 2; this is opt-in experimental output.
        return try regionBoundaries(labels, width: image.width, height: image.height) { _, _ in true }
    }
}

/// Shared pixel-cell borders are emitted once, grouped by label pair. No synthetic
/// boundary is drawn along the outer image frame. Coordinates span [0, width] × [0, height].
private func regionBoundaries(_ labels: [UInt8], width w: Int, height h: Int,
                              include: (UInt8, UInt8) -> Bool) throws -> [Contour] {
    let stride = w + 1
    var graphs: [Int: [Int: [Int]]] = [:]
    func add(_ a: Int, _ b: Int, _ first: UInt8, _ second: UInt8) {
        guard first != second, include(first, second) else { return }
        let pair = Int(min(first, second)) * 256 + Int(max(first, second))
        graphs[pair, default: [:]][a, default: []].append(b)
        graphs[pair, default: [:]][b, default: []].append(a)
    }
    for y in 0..<h {
        try Task.checkCancellation()
        for x in 0..<w {
            let i = y*w+x
            if x+1 < w { add(y*stride+x+1, (y+1)*stride+x+1, labels[i], labels[i+1]) }
            if y+1 < h { add((y+1)*stride+x, (y+1)*stride+x+1, labels[i], labels[i+w]) }
        }
    }
    var result: [Contour] = []
    for key in graphs.keys.sorted() { result += try trace(graphs[key]!, stride: stride, offset: 0) }
    return result
}
