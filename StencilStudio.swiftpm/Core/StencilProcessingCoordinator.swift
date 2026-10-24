import Foundation

public struct StencilProcessingCoordinator: Sendable {
    public init() {}
    public func process(_ input: GrayImage, parameters: Parameters, limits: ProcessingLimits = .device,
                        guidance: SubjectGuidance? = nil,
                        progress: @Sendable (Double, String) -> Void = { _, _ in }) throws -> StencilResult {
        var cache = PipelineCache(), statistics = PreviewStatistics()
        return try processStencil(input,parameters: parameters,limits: limits,guidance: guidance,
                                  guidanceRevision: UUID(),cache: &cache,statistics: &statistics,progress: progress)
    }
}

/// Shared pipeline: interactive caching never substitutes different algorithms for
/// final processing. Each cache is bound to one immutable source/resolution.
func processStencil(_ input: GrayImage, parameters p: Parameters, limits: ProcessingLimits,
                    guidance: SubjectGuidance?, guidanceRevision: UUID, cache: inout PipelineCache,
                    statistics: inout PreviewStatistics,
                    progress: @Sendable (Double,String) -> Void = { _,_ in }) throws -> StencilResult {
    try p.validate()
    let limits = try limits.bounded(width: input.width,height: input.height)
    if let guidance {
        let a = Double(input.width)/Double(input.height), b = Double(guidance.mask.width)/Double(guidance.mask.height)
        guard abs(a-b)/max(a,b) < 0.02 else { throw StencilError.invalidImage }
    }
    progress(0.02,"Edge-preserving preprocessing")
    let imageKey = PreprocessKey(p,features: guidance?.features ?? []), image: GrayImage
    if let saved = cache.image, saved.0 == imageKey {
        image = saved.1; statistics.reused.append("preprocess")
    } else {
        image = try ImagePreprocessor().process(input,parameters: p,guidance: guidance)
        cache.image = (imageKey,image); statistics.computed.append("preprocess")
    }
    progress(0.3,"Multiscale structural contours")
    let outlineKey = OutlineKey(p,guidanceRevision,image: imageKey), edges: [UInt8], outlines: [Contour]
    let optimizer = ContourOptimizer()
    if let saved = cache.outlines, saved.0 == outlineKey {
        edges = saved.1; outlines = saved.2; statistics.reused.append("outlines")
    } else {
        edges = try StructuralEdgeDetector().detect(image,parameters: p,guidance: guidance)
        let traced = try StructuralContourTracer().traceEdges(edges,width: image.width,height: image.height,maximumLinks: limits.maximumGraphLinks)
        let ranked = try MainContourSelector().classify(traced,image: image,guidance: guidance)
        let simplified = try optimizer.optimize(ranked,minimumLength: p.minimumContourLength,tolerance: p.smoothing)
        outlines = try ContourInkSelector().select(simplified,image: image,parameters: p)
        cache.outlines = (outlineKey,edges,outlines); statistics.computed.append("outlines")
    }
    progress(0.55,"Adaptive tonal regions")
    let toneKey = ToneKey(p,image: imageKey), segmentation: Segmentation
    if let saved = cache.tones, saved.0 == toneKey {
        segmentation = saved.1; statistics.reused.append("tones")
    } else {
        // Shadow guides describe broad tone masses, not individual fur/skin
        // fluctuations. Fine source coordinates remain in the outline stage.
        let tonePixels = try ScaleSpace.gaussian(image.pixels,width: image.width,height: image.height,
                                                 sigma: max(0.8,3*Double(max(image.width,image.height))/900))
        let toneImage = try GrayImage(width: image.width,height: image.height,pixels: tonePixels)
        segmentation = try TonalSegmentationEngine().segment(toneImage,levels: p.tonalLevels,minimumArea: p.minimumRegionArea,
                                                             coherence: p.regionCoherence,limits: limits)
        cache.tones = (toneKey,segmentation); statistics.computed.append("tones")
    }
    progress(0.78,"Shadow boundaries")
    let shadowKey = ShadowKey(p,guidanceRevision,image: imageKey), shadows: [Contour]
    if let saved = cache.shadows, saved.0 == shadowKey {
        shadows = saved.1; statistics.reused.append("shadows")
    } else {
        if p.shadowsEnabled {
            let raw = try ShadowBoundaryGenerator().generate(segmentation,width: image.width,height: image.height,
                                                             sensitivity: p.shadowSensitivity,maximumLinks: limits.maximumGraphLinks)
            let selected = try guidance?.clip(raw,width: image.width,height: image.height) ?? raw
            progress(0.84,"Spacing and duplicate suppression")
            let cleaned = try ShadowBoundaryCleaner().clean(selected,outlines: p.suppressOutlineDuplicates ? outlines : [],
                                                            width: image.width,height: image.height,spacing: p.shadowSpacing,
                                                            minimumLength: max(p.minimumContourLength,p.minimumShadowContourLength),maximumSamples: limits.maximumGraphLinks*2)
            shadows = try optimizer.optimize(cleaned,minimumLength: max(p.minimumContourLength,p.minimumShadowContourLength),tolerance: p.smoothing)
        } else { shadows = [] }
        cache.shadows = (shadowKey,shadows); statistics.computed.append("shadows")
    }
    progress(0.9,"Highlight boundaries")
    let highlightKey = HighlightKey(p,guidanceRevision,image: imageKey), highlights: [Contour]
    if let saved = cache.highlights, saved.0 == highlightKey {
        highlights = saved.1; statistics.reused.append("highlights")
    } else {
        if p.highlightsEnabled {
            let paths = try HighlightBoundaryGenerator().generate(image,sensitivity: p.highlightSensitivity,minimumArea: p.minimumHighlightArea,limits: limits)
            let selected = try guidance?.clip(paths,width: image.width,height: image.height) ?? paths
            highlights = try optimizer.optimize(selected,minimumLength: p.minimumContourLength,tolerance: p.smoothing)
        } else { highlights = [] }
        cache.highlights = (highlightKey,highlights); statistics.computed.append("highlights")
    }
    try Task.checkCancellation()
    progress(1,"Complete")
    return StencilResult(width: image.width,height: image.height,outlines: outlines,shadows: shadows,highlights: highlights,
                         preprocessed: image,edges: edges,segmentation: segmentation)
}
