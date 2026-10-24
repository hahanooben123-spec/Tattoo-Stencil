import Foundation

public struct TonalSegmentationEngine: Sendable {
    public init() {}
    /// Deterministic weighted histogram clustering, initialized by occupied quantiles.
    /// Thresholds follow actual tone populations, rather than equal brightness bands.
    public func segment(_ image: GrayImage, levels: Int, minimumArea: Int) throws -> Segmentation {
        guard (3...10).contains(levels), minimumArea > 0 else { throw StencilError.invalidParameters }
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
        try suppressSmallRegions(&labels, width: image.width, height: image.height, minimumArea: minimumArea)
        let thresholds = zip(centers, centers.dropFirst()).map { ($0 + $1) / 2 }
        return Segmentation(labels: labels, thresholds: thresholds, centers: centers)
    }
    private func nearest(_ value: Float, _ centers: [Float]) -> Int {
        var best = 0
        for k in centers.indices where abs(value - centers[k]) < abs(value - centers[best]) { best = k }
        return best
    }
}

/// Merge small components into their most frequent adjacent label. Four connectivity
/// keeps diagonal contacts from joining unrelated shadow masses.
func suppressSmallRegions(_ labels: inout [UInt8], width w: Int, height h: Int, minimumArea: Int) throws {
    var visited = [Bool](repeating: false, count: labels.count)
    for seed in labels.indices where !visited[seed] {
        if seed % 1024 == 0 { try Task.checkCancellation() }
        let label = labels[seed]
        var queue = [seed], head = 0, neighbors: [UInt8: Int] = [:]
        visited[seed] = true
        while head < queue.count {
            if head % 8192 == 0 { try Task.checkCancellation() }
            let i = queue[head]; head += 1
            let x = i % w, y = i / w
            let candidates = [x > 0 ? i-1 : -1, x+1 < w ? i+1 : -1, y > 0 ? i-w : -1, y+1 < h ? i+w : -1]
            for j in candidates where j >= 0 {
                if labels[j] == label {
                    if !visited[j] { visited[j] = true; queue.append(j) }
                } else { neighbors[labels[j], default: 0] += 1 }
            }
        }
        if queue.count < minimumArea,
           let replacement = neighbors.keys.sorted().max(by: { neighbors[$0]! < neighbors[$1]! }) {
            for i in queue { labels[i] = replacement }
        }
    }
}
