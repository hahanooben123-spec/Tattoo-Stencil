import Foundation

public struct TonalSegmentationEngine: Sendable {
    public init() {}
    /// Deterministic weighted histogram clustering, initialized by occupied quantiles.
    /// Thresholds follow actual tone populations, rather than equal brightness bands.
    public func segment(_ image: GrayImage, levels: Int, minimumArea: Int, coherence: Float = 0.5,
                        limits: ProcessingLimits = ProcessingLimits()) throws -> Segmentation {
        guard (3...10).contains(levels), minimumArea > 0, coherence.isFinite, (0...1).contains(coherence) else { throw StencilError.invalidParameters }
        var histogram = [Int](repeating: 0, count: 256)
        for (i, v) in image.pixels.enumerated() {
            if i % 65536 == 0 { try Task.checkCancellation() }
            histogram[Int((v * 255).rounded())] += 1
        }
        var centers: [Float] = []
        for k in 0..<levels {
            let target = Double(image.pixels.count) * (Double(k) + 0.5) / Double(levels)
            var sum = 0
            for b in 0..<256 { sum += histogram[b]; if Double(sum) >= target { centers.append(Float(b) / 255); break } }
        }
        centers = Array(Set(centers)).sorted()
        // Quantiles can all fall in one dominant background tone. Seed missing
        // centers from the occupied bin with largest weighted reconstruction error
        // so less common shadow masses still get an opportunity to form a cluster.
        while centers.count < levels {
            var bestBin: Int?, bestError = 0.0
            for b in 0..<256 where histogram[b] > 0 {
                let value = Float(b) / 255
                let distance = Double(value - centers[nearest(value, centers)])
                let error = Double(histogram[b]) * distance * distance
                if error > bestError { bestError = error; bestBin = b }
            }
            guard let bin = bestBin, bestError > 1e-12 else { break }
            centers.append(Float(bin) / 255); centers.sort()
        }
        for _ in 0..<30 {
            try Task.checkCancellation()
            var sums = [Float](repeating: 0, count: levels), counts = [Int](repeating: 0, count: levels)
            for b in 0..<256 where histogram[b] > 0 {
                let value = Float(b) / 255
                let k = nearest(value, centers)
                sums[k] += value * Float(histogram[b]); counts[k] += histogram[b]
            }
            let updated = centers.indices.map { counts[$0] > 0 ? sums[$0] / Float(counts[$0]) : centers[$0] }.sorted()
            let change = zip(updated, centers).map { abs($0 - $1) }.max() ?? 0
            centers = updated
            if change < 0.0001 { break }
        }
        // Empty/duplicate clusters are removed; a flat image correctly has one region.
        centers = centers.reduce(into: [Float]()) { result, value in
            if result.last.map({ abs($0 - value) > 0.002 }) ?? true { result.append(value) }
        }
        var labels = image.pixels.map { UInt8(nearest($0, centers)) }
        if coherence > 0 {
            labels = try cohere(labels, image: image, centers: centers, strength: coherence)
        }
        try suppressSmallRegions(&labels, width: image.width, height: image.height, minimumArea: minimumArea, centers: centers, limits: limits)
        let thresholds = zip(centers, centers.dropFirst()).map { ($0 + $1) / 2 }
        return Segmentation(labels: labels, thresholds: thresholds, centers: centers)
    }
    private func nearest(_ value: Float, _ centers: [Float]) -> Int {
        var best = 0
        for k in centers.indices where abs(value - centers[k]) < abs(value - centers[best]) { best = k }
        return best
    }

    /// Only ambiguous, low-contrast pixels may follow a local majority. Decisions
    /// read an immutable pass, so no directional sweep can drag a boundary.
    private func cohere(_ input: [UInt8], image: GrayImage, centers: [Float], strength: Float) throws -> [UInt8] {
        let w = image.width, h = image.height
        guard w >= 3, h >= 3 else { return input }
        var output = input
        var votes = [Int](repeating: 0, count: centers.count)
        for y in 1..<(h-1) {
            try Task.checkCancellation()
            for x in 1..<(w-1) {
                let i = y*w+x, current = Int(input[i])
                for k in votes.indices { votes[k] = 0 }
                var low: Float = 1, high: Float = 0
                for dy in -1...1 { for dx in -1...1 {
                    let j = i+dy*w+dx
                    votes[Int(input[j])] += 1
                    low = min(low, image.pixels[j]); high = max(high, image.pixels[j])
                } }
                guard let candidate = votes.indices.max(by: { votes[$0] == votes[$1] ? $0 > $1 : votes[$0] < votes[$1] }),
                      candidate != current, votes[candidate] >= 6, high-low <= 0.04 + 0.12*strength else { continue }
                let value = image.pixels[i]
                let penalty = abs(value-centers[candidate]) - abs(value-centers[current])
                if penalty <= 0.025 * strength { output[i] = UInt8(candidate) }
            }
        }
        return output
    }
}

/// Label components once, build their shared-boundary graph, then merge smallest
/// components first. Tone distance, shared support, area and stable ID break ties.
/// Decisions never mutate the pixels being scanned. Graph growth is bounded.
func suppressSmallRegions(_ labels: inout [UInt8], width w: Int, height h: Int, minimumArea: Int,
                          centers: [Float]? = nil, limits: ProcessingLimits = ProcessingLimits()) throws {
    guard minimumArea > 1 else { return }
    var ids = [Int32](repeating: -1, count: labels.count)
    var tones: [UInt8] = [], areas: [Int] = [], parents: [Int] = [], queue: [Int] = []
    for seed in labels.indices where ids[seed] == -1 {
        try Task.checkCancellation()
        let id = tones.count
        guard id < limits.maximumRegions, id < Int(Int32.max) else { throw StencilError.complexityLimit("connected regions") }
        tones.append(labels[seed]); parents.append(id)
        queue.removeAll(keepingCapacity: true); queue.append(seed); ids[seed] = Int32(id)
        var head = 0
        while head < queue.count {
            if head % 4096 == 0 { try Task.checkCancellation() }
            let i = queue[head]; head += 1
            let x = i % w, y = i / w
            for j in [x > 0 ? i-1 : -1, x+1 < w ? i+1 : -1, y > 0 ? i-w : -1, y+1 < h ? i+w : -1] where j >= 0 {
                if ids[j] == -1 && labels[j] == labels[seed] { ids[j] = Int32(id); queue.append(j) }
            }
        }
        areas.append(queue.count)
    }
    queue = []
    var adjacency = Array(repeating: [Int: Int](), count: tones.count)
    var links = 0
    func connect(_ a: Int, _ b: Int) throws {
        guard a != b else { return }
        if adjacency[a][b] == nil {
            links += 1
            guard links <= limits.maximumGraphLinks else { throw StencilError.complexityLimit("region adjacency") }
        }
        adjacency[a][b, default: 0] += 1; adjacency[b][a, default: 0] += 1
    }
    for y in 0..<h {
        try Task.checkCancellation()
        for x in 0..<w {
            let i = y*w+x, a = Int(ids[i])
            if x+1 < w { try connect(a, Int(ids[i+1])) }
            if y+1 < h { try connect(a, Int(ids[i+w])) }
        }
    }
    func root(_ id: Int) -> Int {
        var r = id
        while parents[r] != r { r = parents[r] }
        var node = id
        while parents[node] != node { let next = parents[node]; parents[node] = r; node = next }
        return r
    }
    let order = areas.indices.sorted { areas[$0] == areas[$1] ? $0 < $1 : areas[$0] < areas[$1] }
    for id in order {
        try Task.checkCancellation()
        guard root(id) == id, areas[id] < minimumArea else { continue }
        let candidates = adjacency[id].keys.sorted()
        let tone = centers.map { $0[Int(tones[id])] } ?? Float(tones[id])
        let target = candidates.min { a, b in
            let da = abs(tone - (centers.map { $0[Int(tones[a])] } ?? Float(tones[a])))
            let db = abs(tone - (centers.map { $0[Int(tones[b])] } ?? Float(tones[b])))
            if da != db { return da < db }
            if adjacency[id][a] != adjacency[id][b] { return adjacency[id][a]! > adjacency[id][b]! }
            return areas[a] == areas[b] ? a < b : areas[a] > areas[b]
        }
        guard let target else { continue }
        parents[id] = target; areas[target] += areas[id]
        for (neighbor, boundary) in adjacency[id] {
            adjacency[neighbor].removeValue(forKey: id)
            if neighbor != target {
                adjacency[neighbor][target, default: 0] += boundary
                adjacency[target][neighbor, default: 0] += boundary
            }
        }
        adjacency[id] = [:]
    }
    for i in labels.indices {
        if i % 65536 == 0 { try Task.checkCancellation() }
        labels[i] = tones[root(Int(ids[i]))]
    }
}
