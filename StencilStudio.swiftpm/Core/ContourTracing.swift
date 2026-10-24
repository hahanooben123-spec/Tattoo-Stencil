import Foundation

private struct Link: Hashable {
    let a: Int
    let b: Int
    init(_ a: Int, _ b: Int) { self.a = min(a, b); self.b = max(a, b) }
}

/// Pair only unambiguous opposing branches. Every step still follows an existing
/// source edge; no endpoints are bridged across a gap.
private func junctionRoutes(_ graph: [Int: [Int]], node: Int, stride: Int) -> [Int: Int] {
    let neighbors = graph[node]!
    if neighbors.count == 2 { return [neighbors[0]: neighbors[1],neighbors[1]: neighbors[0]] }
    guard neighbors.count > 2 else { return [:] }
    func tangent(_ neighbor: Int) -> (Double,Double) {
        var previous = node, current = neighbor
        for _ in 0..<5 {
            guard let next = graph[current],next.count == 2,
                  let candidate = next.first(where: { $0 != previous }),candidate != node else { break }
            previous = current; current = candidate
        }
        let dx = Double(current % stride-node % stride), dy = Double(current / stride-node / stride)
        let length = max(1,hypot(dx,dy))
        return (dx/length,dy/length)
    }
    let directions = neighbors.map(tangent)
    var pairs: [(Int,Int,Double)] = []
    for a in neighbors.indices { for b in neighbors.indices where b > a {
        let dot = directions[a].0*directions[b].0+directions[a].1*directions[b].1
        if dot < -0.65 { pairs.append((neighbors[a],neighbors[b],dot)) }
    } }
    pairs.sort { $0.2 == $1.2 ? ($0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0) : $0.2 < $1.2 }
    var routes: [Int: Int] = [:]
    for pair in pairs {
        guard routes[pair.0] == nil,routes[pair.1] == nil else { continue }
        let ambiguous = pairs.contains { other in
            (other.0 != pair.0 || other.1 != pair.1) && routes[other.0] == nil && routes[other.1] == nil &&
            (other.0 == pair.0 || other.0 == pair.1 || other.1 == pair.0 || other.1 == pair.1) && other.2-pair.2 < 0.15
        }
        guard !ambiguous else { continue }
        routes[pair.0] = pair.1; routes[pair.1] = pair.0
    }
    return routes
}

/// Follow graph edges once. Tonal junctions terminate strokes. Structural
/// junctions may continue along a clearly matching tangent.
private func trace(_ graph: [Int: [Int]], stride: Int, offset: Double, continueForms: Bool = false) throws -> [Contour] {
    var used = Set<Link>(), result: [Contour] = []
    let nodes = graph.keys.sorted()
    func point(_ node: Int) -> Point { Point(Double(node % stride) + offset, Double(node / stride) + offset) }
    var routes: [Int: [Int: Int]] = [:]
    if continueForms {
        for node in nodes where graph[node]!.count > 2 {
            try Task.checkCancellation()
            routes[node] = junctionRoutes(graph,node: node,stride: stride)
        }
    }
    func continuation(_ node: Int,_ previous: Int) -> Int? {
        if graph[node]!.count == 2 { return graph[node]!.first { $0 != previous } }
        return routes[node]?[previous]
    }
    // Start at unmatched endpoints before visiting the remaining closed loops.
    for phase in 0...1 { for start in nodes {
        try Task.checkCancellation()
        for next in graph[start]!.sorted() where !used.contains(Link(start, next)) {
            guard (continuation(start,next) == nil) == (phase == 0) else { continue }
            var path = [point(start)], previous = start, current = next
            used.insert(Link(previous, current))
            var closed = false
            while true {
                if path.count % 4096 == 0 { try Task.checkCancellation() }
                if current == start { closed = true; break }
                path.append(point(current))
                guard let candidate = continuation(current,previous),
                      !used.contains(Link(current, candidate)) else { break }
                used.insert(Link(current, candidate)); previous = current; current = candidate
            }
            if path.count >= 2 { result.append(Contour(points: path, closed: closed)) }
        }
    } }
    return result
}

public struct StructuralContourTracer: Sendable {
    public init() {}
    public func traceEdges(_ edges: [UInt8], width w: Int, height h: Int,
                           maximumLinks: Int = 400_000) throws -> [Contour] {
        var graph: [Int: [Int]] = [:]
        var links = 0
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
                    links += 1
                    guard links <= maximumLinks else { throw StencilError.complexityLimit("structural contours") }
                    graph[i, default: []].append(j); graph[j, default: []].append(i)
                }
            }
        }
        return try trace(graph, stride: w, offset: 0.5, continueForms: true)
    }
}

public struct ShadowBoundaryGenerator: Sendable {
    public init() {}
    public func generate(_ segmentation: Segmentation, width: Int, height: Int, sensitivity: Float,
                         maximumLinks: Int = 400_000) throws -> [Contour] {
        let centers = segmentation.centers
        // Similar neighboring clusters can be ignored without suppressing deeper transitions.
        let minimumDifference = 0.02 + (1 - sensitivity) * 0.14
        return try regionBoundaries(segmentation.labels, width: width, height: height, maximumLinks: maximumLinks) { a, b in
            abs(centers[Int(a)] - centers[Int(b)]) >= minimumDifference
        }
    }
}

public struct HighlightBoundaryGenerator: Sendable {
    public init() {}
    public func generate(_ image: GrayImage, sensitivity: Float, minimumArea: Int,
                         limits: ProcessingLimits = ProcessingLimits()) throws -> [Contour] {
        let threshold: Float = 0.98 - sensitivity * 0.22
        var labels = image.pixels.map { UInt8($0 >= threshold ? 1 : 0) }
        try suppressSmallRegions(&labels, width: image.width, height: image.height, minimumArea: minimumArea, limits: limits)
        // Bilateral preprocessing and the high threshold reduce small bright pixel noise.
        // Local contrast screening is deferred to Phase 2; this is opt-in experimental output.
        return try regionBoundaries(labels, width: image.width, height: image.height, maximumLinks: limits.maximumGraphLinks) { _, _ in true }
    }
}

/// Shared pixel-cell borders are emitted once, grouped by label pair. No synthetic
/// boundary is drawn along the outer image frame. Coordinates span [0, width] × [0, height].
private func regionBoundaries(_ labels: [UInt8], width w: Int, height h: Int, maximumLinks: Int,
                              include: (UInt8, UInt8) -> Bool) throws -> [Contour] {
    let stride = w + 1
    var graphs: [Int: [Int: [Int]]] = [:]
    var links = 0
    func add(_ a: Int, _ b: Int, _ first: UInt8, _ second: UInt8) throws {
        guard first != second, include(first, second) else { return }
        links += 1
        guard links <= maximumLinks else { throw StencilError.complexityLimit("tonal boundary paths") }
        let pair = Int(min(first, second)) * 256 + Int(max(first, second))
        graphs[pair, default: [:]][a, default: []].append(b)
        graphs[pair, default: [:]][b, default: []].append(a)
    }
    for y in 0..<h {
        try Task.checkCancellation()
        for x in 0..<w {
            let i = y*w+x
            if x+1 < w { try add(y*stride+x+1, (y+1)*stride+x+1, labels[i], labels[i+1]) }
            if y+1 < h { try add((y+1)*stride+x, (y+1)*stride+x+1, labels[i], labels[i+w]) }
        }
    }
    var result: [Contour] = []
    for key in graphs.keys.sorted() { result += try trace(graphs[key]!, stride: stride, offset: 0) }
    return result
}
