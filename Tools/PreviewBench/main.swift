import Foundation
import StencilCore

// Synthetic CPU benchmark, deliberately excluding Vision, UIKit rendering and touch
// latency. Results must not be presented as measured iPad frame rates.
let iterations = min(100,max(5,CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 20))
let w = 900, h = 600
let source = try GrayImage(width: w,height: h,pixels: (0..<w*h).map { index -> Float in
    let x = index % w, y = index / w
    if x > 70 && x < 320 && y > 50 && y < 350 { return 0.12 }
    let distance = hypot(Double(x-620),Double(y-360))
    if distance < 140 { return Float(0.2+distance/400) }
    return 0.85+0.03*sin(Float(x)/55)+0.02*cos(Float(y)/60)
})
let engine = try InteractivePreviewEngine(source: source,nativeWidth: 3600)
var controls = StencilControls()
var fresh: [Double] = [], details: [Double] = [], shadows: [Double] = []
var shadowReuse = 0
for index in 0..<iterations {
    controls.detail = 0.2+Float(index)/Float(iterations)*0.6
    let p = try controls.parameters(width: 3600,height: 2400)
    let start = ProcessInfo.processInfo.systemUptime
    _ = try StencilProcessingCoordinator().process(source,parameters: p.forPreview(scale: 0.25))
    fresh.append((ProcessInfo.processInfo.systemUptime-start)*1000)
    let frame = try await engine.render(parameters: p,quality: .interactive)
    details.append(frame.statistics.seconds*1000)
}
for index in 0..<iterations {
    controls.shadows = Float(index)/Float(iterations)
    let frame = try await engine.render(parameters: controls.parameters(width: 3600,height: 2400),quality: .interactive)
    shadows.append(frame.statistics.seconds*1000)
    if frame.statistics.reused.contains("preprocess") && frame.statistics.reused.contains("outlines") { shadowReuse += 1 }
}
func distribution(_ values: [Double]) -> [String: Double] {
    let sorted = values.sorted()
    return ["medianMS": sorted[sorted.count/2],"p95MS": sorted[min(sorted.count-1,Int(Double(sorted.count)*0.95))]]
}
let report: [String: Any] = [
    "scope": "Synthetic CPU pipeline only; excludes Vision, UIKit paths/rendering, scheduler and touch latency. Not an iPad FPS claim.",
    "host": ProcessInfo.processInfo.operatingSystemVersionString,"iterationsPerSweep": iterations,
    "freshRefined900": distribution(fresh),"interactiveDetails320": distribution(details),
    "interactiveShadows320": distribution(shadows),"shadowEditsReusingOutlinesAndPreprocessing": shadowReuse
]
let data = try JSONSerialization.data(withJSONObject: report,options: [.prettyPrinted,.sortedKeys])
print(String(decoding: data,as: UTF8.self))
