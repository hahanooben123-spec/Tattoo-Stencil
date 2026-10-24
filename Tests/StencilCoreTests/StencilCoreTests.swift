import XCTest
@testable import StencilCore

final class StencilCoreTests: XCTestCase {
    func image(_ w: Int = 64, _ h: Int = 48, pixel: (Int, Int) -> Float) throws -> GrayImage {
        try GrayImage(width: w, height: h, pixels: (0..<h).flatMap { y in (0..<w).map { x in pixel(x, y) } })
    }

    func testRejectsInvalidInputsAndParameters() throws {
        XCTAssertThrowsError(try GrayImage(width: 3, height: 3, pixels: [0]))
        XCTAssertThrowsError(try GrayImage(width: 2, height: 2, pixels: [0, 0, .nan, 1]))
        var p = Parameters(); p.tonalLevels = 11
        XCTAssertThrowsError(try p.validate())
        p = Parameters(); p.edgeThreshold = .nan
        XCTAssertThrowsError(try p.validate())
    }

    func testUniformReferenceHasNoInventedLines() throws {
        let source = try image { _, _ in 0.55 }
        var p = Parameters(); p.highlightsEnabled = true
        let result = try StencilProcessingCoordinator().process(source, parameters: p)
        XCTAssertTrue(result.outlines.isEmpty)
        XCTAssertTrue(result.shadows.isEmpty)
        XCTAssertTrue(result.highlights.isEmpty)
        XCTAssertEqual(result.segmentation.centers.count, 1)
        XCTAssertEqual(result.width, source.width); XCTAssertEqual(result.height, source.height)
    }

    func testBilateralPreservesStrongBoundaryAndReducesNoise() throws {
        let source = try image { x, y in (x < 32 ? Float(0.1) : Float(0.9)) + ((x+y) % 2 == 0 ? 0.025 : -0.025) }
        var p = Parameters(); p.noiseReduction = 0.8
        let output = try ImagePreprocessor().process(source, parameters: p)
        XCTAssertLessThan(abs(output.pixels[20*64+15] - output.pixels[20*64+16]), 0.05)
        XCTAssertLessThan(output.pixels[20*64+31], 0.2)
        XCTAssertGreaterThan(output.pixels[20*64+32], 0.8)
    }

    func testCannyBoundaryStaysAtReferenceCoordinates() throws {
        let source = try image { x, _ in x < 32 ? 0.1 : 0.9 }
        var p = Parameters(); p.minimumContourLength = 2
        let result = try StencilProcessingCoordinator().process(source, parameters: p)
        XCTAssertFalse(result.outlines.isEmpty)
        for point in result.outlines.flatMap(\.points) { XCTAssertLessThanOrEqual(abs(point.x - 32), 1) }
        XCTAssertTrue(result.outlines.contains { $0.length > 40 })
        XCTAssertLessThanOrEqual(result.edges.filter { $0 != 0 }.count, 48)
    }

    func testThresholdsFollowUnevenHistogram() throws {
        let source = try image(90, 30) { x, _ in x < 30 ? 0.05 : x < 60 ? 0.2 : 0.9 }
        let tones = try TonalSegmentationEngine().segment(source, levels: 3, minimumArea: 1)
        XCTAssertEqual(tones.centers.count, 3)
        XCTAssertEqual(tones.thresholds[0], 0.125, accuracy: 0.01)
        XCTAssertEqual(tones.thresholds[1], 0.55, accuracy: 0.01)
        XCTAssertEqual(Set(tones.labels).count, 3)
    }

    func testSmallRegionIsSuppressed() throws {
        var labels = [UInt8](repeating: 0, count: 25)
        labels[12] = 1
        try suppressSmallRegions(&labels, width: 5, height: 5, minimumArea: 2)
        XCTAssertEqual(Set(labels), Set([UInt8(0)]))
    }

    func testDominantBackgroundDoesNotHideRareShadowTones() throws {
        let source = try image(100, 10) { x, _ in x < 6 ? 0.05 : x < 10 ? 0.3 : 0.9 }
        let tones = try TonalSegmentationEngine().segment(source, levels: 3, minimumArea: 1)
        XCTAssertEqual(tones.centers.count, 3)
        XCTAssertEqual(tones.centers[0], 0.05, accuracy: 0.01)
        XCTAssertEqual(tones.centers[1], 0.3, accuracy: 0.01)
        XCTAssertEqual(tones.centers[2], 0.9, accuracy: 0.01)
    }

    func testTonalBoundaryIsSingleContinuousSharedBorder() throws {
        let w = 10, h = 12
        let labels = (0..<w*h).map { UInt8($0 % w < 5 ? 0 : 1) }
        let tones = Segmentation(labels: labels, thresholds: [0.5], centers: [0.1, 0.9])
        let paths = try ShadowBoundaryGenerator().generate(tones, width: w, height: h, sensitivity: 0.5)
        XCTAssertEqual(paths.count, 1)
        XCTAssertEqual(paths[0].length, 12, accuracy: 0.001)
        XCTAssertTrue(paths[0].points.allSatisfy { $0.x == 5 })
        XCTAssertFalse(paths[0].closed)
    }

    func testClosedShadowRegionRemainsClosed() throws {
        var labels = [UInt8](repeating: 0, count: 100)
        for y in 3...6 { for x in 3...6 { labels[y*10+x] = 1 } }
        let tones = Segmentation(labels: labels, thresholds: [0.5], centers: [0.1, 0.9])
        let paths = try ShadowBoundaryGenerator().generate(tones, width: 10, height: 10, sensitivity: 1)
        XCTAssertEqual(paths.count, 1)
        XCTAssertTrue(paths[0].closed)
        XCTAssertEqual(paths[0].length, 16, accuracy: 0.001)
        let optimized = try ContourOptimizer().optimize(paths, minimumLength: 0, tolerance: 0.1)
        XCTAssertTrue(optimized[0].closed)
        XCTAssertEqual(optimized[0].points.count, 4)
    }

    func testDiagonalEdgeDoesNotGainShortcutBranches() throws {
        let pixels: [UInt8] = [1, 1, 0, 0, 1, 0, 0, 1, 1]
        let paths = try StructuralContourTracer().traceEdges(pixels, width: 3, height: 3)
        XCTAssertEqual(paths.count, 1)
        XCTAssertEqual(paths[0].length, 4, accuracy: 0.001)
    }

    func testSimplificationPreservesEndpoints() throws {
        let points = (0...100).map { Point(Double($0), 10) }
        let result = try ContourOptimizer().optimize([Contour(points: points)], minimumLength: 5, tolerance: 0.5)
        XCTAssertEqual(result[0].points, [Point(0, 10), Point(100, 10)])
    }

    func testPipelineDeterministicAndWithinImageBounds() throws {
        let source = try image { x, y in Float((x*17 + y*31) % 101) / 100 }
        let first = try StencilProcessingCoordinator().process(source, parameters: Parameters())
        let second = try StencilProcessingCoordinator().process(source, parameters: Parameters())
        XCTAssertEqual(first.edges, second.edges)
        XCTAssertEqual(first.segmentation.labels, second.segmentation.labels)
        XCTAssertEqual(first.shadows.map(\.points), second.shadows.map(\.points))
        for path in first.outlines + first.shadows + first.highlights {
            XCTAssertTrue(path.points.allSatisfy { $0.x >= 0 && $0.x <= 64 && $0.y >= 0 && $0.y <= 48 })
        }
    }

    func testCancelledProcessingStops() async throws {
        let source = try image(256, 256) { x, y in Float((x+y) % 100) / 100 }
        let task = Task.detached {
            // Wait until cancellation is visible, then exercise the pipeline checkpoint.
            while !Task.isCancelled { await Task.yield() }
            return try StencilProcessingCoordinator().process(source, parameters: Parameters())
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
    }
}
