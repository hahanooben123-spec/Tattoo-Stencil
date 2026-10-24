import Foundation

public struct StencilProcessingCoordinator: Sendable {
    public init() {}
    public func process(_ input: GrayImage, parameters p: Parameters, limits: ProcessingLimits = .device,
                        progress: @Sendable (Double, String) -> Void = { _, _ in }) throws -> StencilResult {
        try p.validate()
        let limits = try limits.bounded(width: input.width, height: input.height)
        progress(0.02, "Edge-preserving preprocessing")
        let image = try ImagePreprocessor().process(input, parameters: p)
        progress(0.3, "Multiscale structural contours")
        let edges = try StructuralEdgeDetector().detect(image, parameters: p)
        let traced = try StructuralContourTracer().traceEdges(edges, width: image.width, height: image.height, maximumLinks: limits.maximumGraphLinks)
        let optimizer = ContourOptimizer()
        let outlines = try optimizer.optimize(traced, minimumLength: p.minimumContourLength, tolerance: p.smoothing)
        progress(0.55, "Adaptive tonal regions")
        let segmentation = try TonalSegmentationEngine().segment(image, levels: p.tonalLevels, minimumArea: p.minimumRegionArea,
                                                                 coherence: p.regionCoherence, limits: limits)
        progress(0.78, "Shadow boundaries")
        let shadowPaths = try ShadowBoundaryGenerator().generate(segmentation, width: image.width, height: image.height,
                                                                sensitivity: p.shadowSensitivity, maximumLinks: limits.maximumGraphLinks)
        progress(0.84, "Spacing and duplicate suppression")
        let cleaned = try ShadowBoundaryCleaner().clean(shadowPaths, outlines: p.suppressOutlineDuplicates ? outlines : [],
                                                        width: image.width, height: image.height,
                                                        spacing: p.shadowSpacing, minimumLength: p.minimumContourLength,
                                                        maximumSamples: limits.maximumGraphLinks * 2)
        let shadows = try optimizer.optimize(cleaned, minimumLength: p.minimumContourLength, tolerance: p.smoothing)
        progress(0.9, "Highlight boundaries")
        let highlights: [Contour]
        if p.highlightsEnabled {
            let paths = try HighlightBoundaryGenerator().generate(image, sensitivity: p.highlightSensitivity, minimumArea: p.minimumHighlightArea, limits: limits)
            highlights = try optimizer.optimize(paths, minimumLength: p.minimumContourLength, tolerance: p.smoothing)
        } else { highlights = [] }
        try Task.checkCancellation()
        progress(1, "Complete")
        return StencilResult(width: image.width, height: image.height, outlines: outlines,
                             shadows: shadows, highlights: highlights, preprocessed: image,
                             edges: edges, segmentation: segmentation)
    }
}
