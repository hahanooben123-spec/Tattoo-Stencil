import Foundation

public enum StencilError: Error, LocalizedError {
    case invalidImage, invalidParameters
    case memoryBudget(required: Int, available: Int)
    case complexityLimit(String)
    public var errorDescription: String? {
        switch self {
        case .invalidImage: return "The image dimensions or luminance values are invalid."
        case .invalidParameters: return "One or more processing settings are outside their supported range."
        case let .memoryBudget(required, available):
            return "Full-resolution processing needs an estimated minimum of \(required / 1_048_576) MB; the working budget is \(available / 1_048_576) MB. Use a smaller reference or a device with more memory. Resolution was not reduced."
        case let .complexityLimit(stage):
            return "The reference exceeds the bounded processing limit for \(stage). Reduce detail or tonal levels, increase noise reduction, or use a smaller reference. Resolution was not reduced."
        }
    }
}

/// Row-major perceptual luminance in [0, 1], in orientation-corrected source coordinates.
public struct GrayImage: Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [Float]
    public init(width: Int, height: Int, pixels: [Float]) throws {
        guard width > 1, height > 1, width <= Int.max / height,
              pixels.count == width * height,
              pixels.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else {
            throw StencilError.invalidImage
        }
        self.width = width; self.height = height; self.pixels = pixels
    }
}

public struct Point: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
}
public struct Contour: Sendable {
    public var points: [Point]
    public var closed: Bool
    public var isPrimary: Bool
    public var isFeature: Bool
    public init(points: [Point], closed: Bool = false, isPrimary: Bool = false,isFeature: Bool = false) {
        self.points = points; self.closed = closed; self.isPrimary = isPrimary; self.isFeature = isFeature
    }
    public var length: Double {
        guard points.count > 1 else { return 0 }
        let open = zip(points, points.dropFirst()).reduce(0.0) { $0 + hypot($1.0.x - $1.1.x, $1.0.y - $1.1.y) }
        return open + (closed ? hypot(points.last!.x - points[0].x, points.last!.y - points[0].y) : 0)
    }
}
public enum LayerKind: String, CaseIterable, Sendable { case outlines, shadows, highlights }
public struct LayerStyle: Sendable, Equatable {
    public var visible = true
    /// Source-image pixels; independent of preview resolution.
    public var width: Double = 1.5
    public init() {}
}
public struct Parameters: Sendable, Equatable {
    public var noiseReduction: Float = 0.35
    public var contrast: Float = 1
    public var detail: Float = 0.5
    public var edgeThreshold: Float = 0.16
    public var minimumContourLength: Double = 18
    public var minimumShadowContourLength: Double = 24
    public var smoothing: Double = 0.6
    public var tonalLevels = 7
    public var shadowSensitivity: Float = 0.5
    public var minimumRegionArea = 100
    public var dashLength: Double = 7
    public var dashSpacing: Double = 5
    public var highlightsEnabled = false
    public var highlightSensitivity: Float = 0.5
    public var minimumHighlightArea = 80
    public var textureSuppression: Float = 0.55
    public var regionCoherence: Float = 0.5
    public var shadowSpacing: Double = 3
    public var suppressOutlineDuplicates = true
    public var outlineEmphasis: Float = 0.75
    public var shadowsEnabled = true
    /// Internal analysis scale, relative to original pixels. Use forPreview(scale:).
    public var samplingScale: Double = 1
    public init() {}
    public func validate() throws {
        let bounded: [Float] = [noiseReduction, detail, shadowSensitivity, highlightSensitivity, textureSuppression, regionCoherence, outlineEmphasis]
        guard bounded.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              contrast.isFinite, (0.1...3).contains(contrast),
              edgeThreshold.isFinite, (0.001...2).contains(edgeThreshold),
              (3...10).contains(tonalLevels), minimumRegionArea > 0, minimumHighlightArea > 0,
              minimumContourLength.isFinite, minimumContourLength >= 0,
              minimumShadowContourLength.isFinite, minimumShadowContourLength >= 0,
              smoothing.isFinite, (0...2).contains(smoothing),
              dashLength.isFinite, dashLength > 0, dashSpacing.isFinite, dashSpacing > 0,
              shadowSpacing.isFinite, (0...16).contains(shadowSpacing),
              samplingScale.isFinite, samplingScale > 0, samplingScale <= 1 else {
            throw StencilError.invalidParameters
        }
    }
    public func forPreview(scale: Double) throws -> Parameters {
        guard scale.isFinite, scale > 0, scale <= 1 else { throw StencilError.invalidParameters }
        var p = self
        p.samplingScale *= scale
        p.minimumContourLength *= scale; p.minimumShadowContourLength *= scale; p.smoothing *= scale; p.shadowSpacing *= scale
        p.minimumRegionArea = max(1, Int((Double(minimumRegionArea) * scale * scale).rounded()))
        p.minimumHighlightArea = max(1, Int((Double(minimumHighlightArea) * scale * scale).rounded()))
        return p
    }
    /// Stroke appearance does not affect generated geometry or verified caches.
    public func hasSameGeometry(as other: Parameters) -> Bool {
        var a = self, b = other
        a.outlineEmphasis = 0; b.outlineEmphasis = 0
        a.dashLength = 1; b.dashLength = 1
        a.dashSpacing = 1; b.dashSpacing = 1
        return a == b
    }
}
public enum Preset: String, CaseIterable {
    case portrait = "Portrait Realism", animal = "Animal Realism", blackGray = "Black & Grey"
    case color = "Color Realism", fine = "Fine Detail", minimal = "Minimal Stencil"
    public var parameters: Parameters {
        var p = Parameters()
        switch self {
        case .portrait: p.noiseReduction = 0.45
        case .animal: p.detail = 0.7; p.minimumContourLength = 12; p.noiseReduction = 0.25
        case .blackGray: p.tonalLevels = 6; p.contrast = 1.1
        case .color: p.tonalLevels = 8; p.shadowSensitivity = 0.6
        case .fine: p.detail = 0.85; p.minimumContourLength = 6; p.smoothing = 0.25
        case .minimal: p.detail = 0.2; p.tonalLevels = 3; p.minimumRegionArea = 350; p.minimumContourLength = 40
        }
        return p
    }
}
public struct Segmentation: Sendable {
    public let labels: [UInt8]
    public let thresholds: [Float]
    public let centers: [Float]
}
public struct StencilResult: Sendable {
    public let width: Int
    public let height: Int
    public let outlines: [Contour]
    public let shadows: [Contour]
    public let highlights: [Contour]
    public let preprocessed: GrayImage
    public let edges: [UInt8]
    public let segmentation: Segmentation
    public func contours(for kind: LayerKind) -> [Contour] {
        switch kind { case .outlines: return outlines; case .shadows: return shadows; case .highlights: return highlights }
    }
}
