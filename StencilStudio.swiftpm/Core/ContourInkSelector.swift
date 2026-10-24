import Foundation

/// Keep the strongest complete source paths when several contours compete for
/// the same ink space. Unlike spacing by clipping, this never leaves new gaps.
struct ContourInkSelector {
    func select(_ paths: [Contour],image: GrayImage,parameters p: Parameters) throws -> [Contour] {
        guard p.textureSuppression > 0 else { return paths }
        let dimension = Double(max(image.width,image.height))
        let scale = min(1,900/dimension), unit = dimension/900*scale
        let w = Int(ceil(Double(image.width)*scale)), h = Int(ceil(Double(image.height)*scale))
        var occupied = [UInt8](repeating: 0,count: w*h)
        var ranked: [(index: Int,score: Double)] = []
        for (index,path) in paths.enumerated() {
            try Task.checkCancellation()
            guard path.points.count > 1 else { continue }
            let xs = path.points.map(\.x), ys = path.points.map(\.y)
            let diagonal = hypot(xs.max()!-xs.min()!,ys.max()!-ys.min()!)
            let winding = path.length/max(1,diagonal)
            // Dense tangled islands turn into blobs at transfer size. Closed
            // pupils/letters/clean curves have far smaller perimeter/diagonal.
            guard winding <= 7 else { continue }
            var strength = 0.0
            for point in path.points {
                let x = min(image.width-1,max(0,Int(point.x))), y = min(image.height-1,max(0,Int(point.y)))
                let dx = abs(image.pixels[y*image.width+min(image.width-1,x+1)]-image.pixels[y*image.width+max(0,x-1)])
                let dy = abs(image.pixels[min(image.height-1,y+1)*image.width+x]-image.pixels[max(0,y-1)*image.width+x])
                strength += Double(max(dx,dy))
            }
            strength /= Double(path.points.count)
            let role = path.isFeature ? 1.6 : path.isPrimary ? 1.25 : 1
            let score = (0.025+strength)*sqrt(min(path.length,dimension*0.25)/dimension)*role/max(1,winding/3)
            ranked.append((index,score))
        }
        ranked.sort { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }
        var kept = Set<Int>()
        for item in ranked {
            try Task.checkCancellation()
            let path = paths[item.index]
            var vertices = path.points
            if path.closed { vertices.append(vertices[0]) }
            var samples: [(Int,Int)] = []
            for (a,b) in zip(vertices,vertices.dropFirst()) {
                let steps = max(1,Int(ceil(hypot(b.x-a.x,b.y-a.y)*scale)))
                for step in 0..<steps {
                    if step % 4096 == 0 { try Task.checkCancellation() }
                    let t = Double(step)/Double(steps)
                    let x = min(w-1,max(0,Int((a.x+(b.x-a.x)*t)*scale)))
                    let y = min(h-1,max(0,Int((a.y+(b.y-a.y)*t)*scale)))
                    samples.append((x,y))
                }
            }
            guard !samples.isEmpty else { continue }
            let covered = samples.reduce(0) { $0+Int(occupied[$1.1*w+$1.0] != 0 ? 1 : 0) }
            // Crossings are fine. A mostly parallel duplicate loses as a whole.
            guard Double(covered)/Double(samples.count) < 0.35 else { continue }
            kept.insert(item.index)
            let radius = max(0.65,(1+2*Double(p.textureSuppression))*unit*(path.isFeature ? 0.7 : 1))
            let r = Int(ceil(radius))
            for (index,sample) in samples.enumerated() {
                if index % 4096 == 0 { try Task.checkCancellation() }
                let (x,y) = sample
                for dy in -r...r { for dx in -r...r where Double(dx*dx+dy*dy) <= radius*radius {
                    let nx = x+dx, ny = y+dy
                    if nx >= 0 && nx < w && ny >= 0 && ny < h { occupied[ny*w+nx] = 1 }
                } }
            }
        }
        return paths.indices.filter { kept.contains($0) }.map { paths[$0] }
    }
}
