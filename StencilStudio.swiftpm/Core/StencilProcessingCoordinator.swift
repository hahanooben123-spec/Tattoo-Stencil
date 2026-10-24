import Foundation

public struct StencilProcessingCoordinator: Sendable {
    public init() {}
    public func process(_ input: GrayImage, parameters p: Parameters,
                        progress: @Sendable (Double, String) -> Void = { _, _ in }) throws -> StencilResult {
        try p.validate()
        progress(0.02, "Edge-preserving preprocessing")
        let image = try ImagePreprocessor().process(input, parameters: p)
        progress(0.3, "Structural contours")
        let edges = try StructuralEdgeDetector().detect(image, parameters: p)
        let traced = try StructuralContourTracer().traceEdges(edges, width: image.width, height: image.height)
        let optimizer = ContourOptimizer()
        let outlines = try optimizer.optimize(traced, minimumLength: p.minimumContourLength, tolerance: p.smoothing)
        progress(0.55, "Adaptive tonal regions")
        let segmentation = try TonalSegmentationEngine().segment(image, levels: p.tonalLevels, minimumArea: p.minimumRegionArea)
        progress(0.78, "Shadow boundaries")
        let shadowPaths = try ShadowBoundaryGenerator().generate(segmentation, width: image.width, height: image.height, sensitivity: p.shadowSensitivity)
        let shadows = try optimizer.optimize(shadowPaths, minimumLength: p.minimumContourLength, tolerance: p.smoothing)
        progress(0.9, "Highlight boundaries")
        let highlights: [Contour]
        if p.highlightsEnabled {
            let paths = try HighlightBoundaryGenerator().generate(image, sensitivity: p.highlightSensitivity, minimumArea: p.minimumHighlightArea)
            highlights = try optimizer.optimize(paths, minimumLength: p.minimumContourLength, tolerance: p.smoothing)
        } else { highlights = [] }
        try Task.checkCancellation()
        progress(1, "Complete")
        return StencilResult(width: image.width, height: image.height, outlines: outlines,
                             shadows: shadows, highlights: highlights, preprocessed: image,
                             edges: edges, segmentation: segmentation)
    }
}
