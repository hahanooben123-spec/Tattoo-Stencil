import Foundation

public enum PreviewQuality: Sendable, Hashable { case interactive, refined }
public struct PreviewStatistics: Sendable {
    public var computed: [String] = []
    public var reused: [String] = []
    public var seconds: Double = 0
}
public struct PreviewFrame: Sendable {
    public let result: StencilResult
    public let statistics: PreviewStatistics
    public let quality: PreviewQuality
}

struct PreprocessKey: Equatable {
    let noise: Float, contrast: Float
    let scale: Double
    init(_ p: Parameters) { noise = p.noiseReduction; contrast = p.contrast; scale = p.samplingScale }
}
struct OutlineKey: Equatable {
    let image: PreprocessKey
    let detail: Float, texture: Float, threshold: Float
    let length: Double, smoothing: Double
    let guidance: UUID
    init(_ p: Parameters,_ guidance: UUID) {
        image = PreprocessKey(p); detail = p.detail; texture = p.textureSuppression; threshold = p.edgeThreshold
        length = p.minimumContourLength; smoothing = p.smoothing; self.guidance = guidance
    }
}
struct ToneKey: Equatable {
    let image: PreprocessKey
    let levels: Int, area: Int
    let coherence: Float
    init(_ p: Parameters) { image = PreprocessKey(p); levels = p.tonalLevels; area = p.minimumRegionArea; coherence = p.regionCoherence }
}
struct ShadowKey: Equatable {
    let tones: ToneKey
    let outlines: OutlineKey?
    let guidance: UUID
    let enabled: Bool
    let sensitivity: Float
    let spacing: Double, length: Double, smoothing: Double
    init(_ p: Parameters,_ guidance: UUID) {
        tones = ToneKey(p); outlines = p.suppressOutlineDuplicates ? OutlineKey(p,guidance) : nil
        self.guidance = guidance; enabled = p.shadowsEnabled; sensitivity = p.shadowSensitivity
        spacing = p.shadowSpacing; length = p.minimumContourLength; smoothing = p.smoothing
    }
}
struct HighlightKey: Equatable {
    let image: PreprocessKey
    let guidance: UUID
    let enabled: Bool
    let sensitivity: Float
    let area: Int
    let length: Double, smoothing: Double
    init(_ p: Parameters,_ guidance: UUID) {
        image = PreprocessKey(p); self.guidance = guidance; enabled = p.highlightsEnabled
        sensitivity = p.highlightSensitivity; area = p.minimumHighlightArea
        length = p.minimumContourLength; smoothing = p.smoothing
    }
}
/// One entry per stage. Keys are installed only after a stage completes.
struct PipelineCache {
    var image: (PreprocessKey, GrayImage)?
    var outlines: (OutlineKey, [UInt8], [Contour])?
    var tones: (ToneKey, Segmentation)?
    var shadows: (ShadowKey, [Contour])?
    var highlights: (HighlightKey, [Contour])?
}

/// An instance owns one immutable reference. Two bounded cache slots prevent input
/// identity collisions, unbounded slider-history caches and concurrent CV buffers.
public actor InteractivePreviewEngine {
    private let backgroundRevision = UUID()
    private let refined: GrayImage
    private let interactive: GrayImage
    private let nativeWidth: Int
    private let limits: ProcessingLimits
    private var caches: [PreviewQuality: PipelineCache] = [:]
    public init(source: GrayImage, nativeWidth: Int, interactiveDimension: Int = 320,
                limits: ProcessingLimits = .device) throws {
        guard nativeWidth >= source.width, max(source.width,source.height) <= 1200,
              (2...640).contains(interactiveDimension) else { throw StencilError.invalidParameters }
        self.refined = source; self.interactive = try source.downsampled(maximumDimension: interactiveDimension)
        self.nativeWidth = nativeWidth; self.limits = limits
    }
    public func render(parameters: Parameters, quality: PreviewQuality, guidance: SubjectGuidance? = nil) throws -> PreviewFrame {
        try Task.checkCancellation()
        let image = quality == .interactive ? interactive : refined
        let p = try parameters.forPreview(scale: Double(image.width)/Double(nativeWidth))
        var cache = caches[quality] ?? PipelineCache(), statistics = PreviewStatistics()
        // Retain completed stages even if a later stage was cancelled.
        defer { caches[quality] = cache }
        let start = ProcessInfo.processInfo.systemUptime
        let output = try processStencil(image,parameters: p,limits: limits,guidance: guidance,
                                        guidanceRevision: guidance?.revision ?? backgroundRevision,cache: &cache,statistics: &statistics)
        statistics.seconds = ProcessInfo.processInfo.systemUptime - start
        return PreviewFrame(result: output,statistics: statistics,quality: quality)
    }
    public func clear() { caches.removeAll() }
}
