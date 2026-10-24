import Foundation
import StencilCore

enum InspectionError: Error { case usage, invalidPGM }

/// Dependency-free P5 (8-bit binary PGM) validation harness. Inputs are test references,
/// never precomputed stencil outputs. Coordinates and measured timings are written out.
func readPGM(_ url: URL) throws -> GrayImage {
    let bytes = [UInt8](try Data(contentsOf: url))
    var index = 0
    func whitespace(_ b: UInt8) -> Bool { [9, 10, 13, 32].contains(b) }
    func token() -> String {
        while index < bytes.count {
            if whitespace(bytes[index]) { index += 1 }
            else if bytes[index] == 35 { while index < bytes.count && bytes[index] != 10 { index += 1 } }
            else { break }
        }
        let start = index
        while index < bytes.count && !whitespace(bytes[index]) { index += 1 }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }
    guard token() == "P5", let w = Int(token()), let h = Int(token()), token() == "255",
          w > 1, h > 1, w <= Int.max / h, index < bytes.count, whitespace(bytes[index]) else { throw InspectionError.invalidPGM }
    if bytes[index] == 13 && index+1 < bytes.count && bytes[index+1] == 10 { index += 2 } else { index += 1 }
    guard bytes.count - index == w*h else { throw InspectionError.invalidPGM }
    _ = try ProcessingLimits.device.bounded(width: w, height: h)
    let pixels = bytes[index...].map { byte -> Float in
        let srgb = Float(byte) / 255
        let y = srgb <= 0.04045 ? srgb / 12.92 : pow((srgb + 0.055) / 1.055, 2.4)
        return min(1, max(0, y > 0.008856 ? (116 * pow(y, 1 / Float(3)) - 16) / 100 : 9.03296*y))
    }
    return try GrayImage(width: w, height: h, pixels: pixels)
}

final class StageMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var previous = ProcessInfo.processInfo.systemUptime
    private var previousStage = "setup"
    private var durations: [String: Double] = [:]
    func checkpoint(_ fraction: Double, _ stage: String) {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        durations[previousStage, default: 0] += now - previous
        previous = now; previousStage = stage
    }
    func snapshot() -> [String: Double] { lock.lock(); defer { lock.unlock() }; return durations }
}

func peakResidentBytes() -> Int? {
    // Linux reports the process high-water RSS in KiB, including import/export.
    guard let status = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8),
          let line = status.split(separator: "\n").first(where: { $0.hasPrefix("VmHWM:") }),
          let kib = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).dropFirst().first.flatMap({ Int($0) }) else { return nil }
    return kib * 1024
}

func savePGM(_ values: [UInt8], width: Int, height: Int, to url: URL) throws {
    var data = Data("P5\n\(width) \(height)\n255\n".utf8); data.append(contentsOf: values)
    try data.write(to: url)
}

func svg(_ result: StencilResult, only: LayerKind? = nil) -> String {
    var text = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(result.width) \(result.height)\" width=\"\(result.width)\" height=\"\(result.height)\">\n<rect width=\"100%\" height=\"100%\" fill=\"white\"/>\n"
    for layer in LayerKind.allCases where only == nil || only == layer {
        let dash = layer == .shadows ? " stroke-dasharray=\"7 5\"" : layer == .highlights ? " stroke-dasharray=\"0.5 3\"" : ""
        text += "<g id=\"\(layer.rawValue)\" fill=\"none\" stroke=\"black\" stroke-width=\"1.5\" stroke-linejoin=\"round\" stroke-linecap=\"round\"\(dash)>\n"
        for contour in result.contours(for: layer) {
            guard let first = contour.points.first else { continue }
            var d = "M \(first.x) \(first.y)"
            for point in contour.points.dropFirst() { d += " L \(point.x) \(point.y)" }
            if contour.closed { d += " Z" }
            text += "<path d=\"\(d)\"/>\n"
        }
        text += "</g>\n"
    }
    return text + "</svg>\n"
}

do {
    let args = CommandLine.arguments
    guard args.count == 3 || args.count == 4 else { throw InspectionError.usage }
    let previewSize = args.count == 4 ? Int(args[3]) ?? 0 : 900
    guard (2...1200).contains(previewSize) else { throw InspectionError.usage }
    let source = try readPGM(URL(fileURLWithPath: args[1]))
    let folder = URL(fileURLWithPath: args[2], isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var p = Parameters(); p.highlightsEnabled = true
    let start = ProcessInfo.processInfo.systemUptime
    let stages = StageMetrics()
    let result = try StencilProcessingCoordinator().process(source, parameters: p) { fraction, stage in stages.checkpoint(fraction, stage) }
    let seconds = ProcessInfo.processInfo.systemUptime - start
    let previewImage = try source.downsampled(maximumDimension: previewSize)
    let previewStart = ProcessInfo.processInfo.systemUptime
    let preview = try StencilProcessingCoordinator().process(previewImage, parameters: p.forPreview(scale: Double(previewImage.width)/Double(source.width)))
    let previewSeconds = ProcessInfo.processInfo.systemUptime - previewStart
    let agreement = try PreviewFidelity.compare(preview: preview, final: result)
    try svg(preview).write(to: folder.appendingPathComponent("preview.svg"), atomically: true, encoding: .utf8)
    try svg(result).write(to: folder.appendingPathComponent("combined.svg"), atomically: true, encoding: .utf8)
    for layer in LayerKind.allCases {
        try svg(result, only: layer).write(to: folder.appendingPathComponent("\(layer.rawValue).svg"), atomically: true, encoding: .utf8)
    }
    try savePGM(result.preprocessed.pixels.map { UInt8(($0*255).rounded()) }, width: source.width, height: source.height, to: folder.appendingPathComponent("preprocessed.pgm"))
    try savePGM(result.edges.map { $0 == 0 ? 255 : 0 }, width: source.width, height: source.height, to: folder.appendingPathComponent("edges.pgm"))
    try savePGM(result.segmentation.labels.map { UInt8((result.segmentation.centers[Int($0)]*255).rounded()) }, width: source.width, height: source.height, to: folder.appendingPathComponent("tones.pgm"))
    let all = result.outlines + result.shadows + result.highlights
    let report: [String: Any] = [
        "width": result.width, "height": result.height, "processingSeconds": seconds,
        "outlines": result.outlines.count, "shadows": result.shadows.count, "highlights": result.highlights.count,
        "shortPathsUnderFivePixels": all.filter { $0.length < 5 }.count,
        "closedPaths": all.filter(\.closed).count, "thresholds": result.segmentation.thresholds.map(Double.init),
        "stageSeconds": stages.snapshot(), "previewProcessingSeconds": previewSeconds,
        "previewWidth": preview.width, "previewHeight": preview.height,
        "previewAgreement": ["outlines": agreement.outlines.score, "shadows": agreement.shadows.score,
                             "combined": agreement.score, "tolerancePixels": Double(agreement.tolerancePixels)],
        "processPeakResidentBytes": peakResidentBytes().map { $0 as Any } ?? NSNull(),
        "memoryMeasurementScope": "Linux CLI process lifetime including decode, native processing, preview comparison and output. Not an iPad measurement.",
        "memoryBudgetBytes": ProcessingLimits.device.memoryBudgetBytes,
        "professionalQualityValidated": false
    ]
    let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try json.write(to: folder.appendingPathComponent("metrics.json"))
    print(String(decoding: json, as: UTF8.self))
} catch {
    FileHandle.standardError.write(Data("Inspection failed: \(error). Usage: stencil-inspect reference.pgm output-directory [preview-longest-side]\n".utf8))
    exit(1)
}
