import XCTest
@testable import StencilCore

final class QualityAndResourceTests: XCTestCase {
    func testShadowGuideSeparatesDarkMassOnceInsteadOfTracingEveryToneBand() throws {
        let labels = (0..<40*24).map { UInt8(($0 % 40)/10) }
        let segmentation = Segmentation(labels: labels,thresholds: [0.2,0.5,0.8],centers: [0.1,0.3,0.7,0.9])
        let paths = try ShadowBoundaryGenerator().generate(segmentation,width: 40,height: 24,sensitivity: 0.5)
        XCTAssertEqual(paths.count,1)
        XCTAssertTrue(paths[0].points.allSatisfy { $0.x == 20 })
    }
    func testInkSelectionDropsParallelDuplicateButPreservesCrossingAndCoordinates() throws {
        let reference = try image(900,100) { x,y in x < 201 && y < 50 ? 0.1 : 0.9 }
        let main = Contour(points: [Point(200.5,5.5),Point(200.5,94.5)],isPrimary: true)
        let duplicate = Contour(points: [Point(201.5,5.5),Point(201.5,94.5)])
        let crossing = Contour(points: [Point(150.5,49.5),Point(250.5,49.5)])
        var p = Parameters(); p.textureSuppression = 0.9
        let result = try ContourInkSelector().select([main,duplicate,crossing],image: reference,parameters: p)
        XCTAssertEqual(result.map(\.points),[main.points,crossing.points])
        p.textureSuppression = 0
        XCTAssertEqual(try ContourInkSelector().select([main,duplicate,crossing],image: reference,parameters: p).count,3)
    }
    func testGaussianWhiteMarginsStayValidAcrossPreviewScales() throws {
        for sigma in [0.8,1.0666666667,1.6,3,3.2,3508.0/300] {
            let pixels = try ScaleSpace.gaussian([Float](repeating: 1,count: 64),width: 8,height: 8,sigma: sigma)
            XCTAssertTrue(pixels.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 },"Out-of-range white at sigma \(sigma): \(pixels[0])")
            _ = try GrayImage(width: 8,height: 8,pixels: pixels)
        }
    }
    func testMaximumDetailDoesNotTurnPreviewTextureIntoContours() throws {
        let source = try image(320,200) { x,y in
            if x >= 240 { return 0.95 }
            return 0.5 + 0.12*sin(Float(x)*2*Float.pi/5 + Float(y)*0.18)
        }
        var controls = StencilControls(); controls.detail = 1
        let p = try controls.parameters(width: 2480,height: 3508).forPreview(scale: 320.0/3508)
        let selected = try StructuralEdgeDetector().detect(source,parameters: p)
        var unrestricted = p; unrestricted.textureSuppression = 0
        let raw = try StructuralEdgeDetector().detect(source,parameters: unrestricted)
        let texture = selected.indices.filter { $0 % 320 < 220 }
        XCTAssertLessThan(texture.reduce(0) { $0+Int(selected[$1]) },texture.reduce(0) { $0+Int(raw[$1]) }/4)
        XCTAssertGreaterThan((1..<199).reduce(0) { $0+Int(selected[$1*320+239])+Int(selected[$1*320+240]) },160)
    }
    func image(_ w: Int, _ h: Int, _ pixel: (Int,Int) -> Float) throws -> GrayImage {
        try GrayImage(width: w, height: h, pixels: (0..<h).flatMap { y in (0..<w).map { pixel($0,y) } })
    }
    func testTextureSuppressionReducesRepeatedWeakStripesButKeepsStrongFeature() throws {
        let source = try image(128,64) { x,_ in
            if x >= 90 { return 0.95 }
            return 0.45 + 0.12 * sin(Float(x) * 2 * Float.pi / 5)
        }
        var p = Parameters(); p.edgeThreshold = 0.10; p.detail = 0.2; p.textureSuppression = 0
        let unrestricted = try StructuralEdgeDetector().detect(source, parameters: p)
        p.textureSuppression = 1
        let selected = try StructuralEdgeDetector().detect(source, parameters: p)
        let noisy = (0..<source.pixels.count).filter { $0 % 128 < 80 }
        XCTAssertLessThan(noisy.reduce(0) { $0+Int(selected[$1]) }, noisy.reduce(0) { $0+Int(unrestricted[$1]) })
        XCTAssertGreaterThan((1..<63).reduce(0) { $0+Int(selected[$1*128+89])+Int(selected[$1*128+90]) }, 50)
    }
    func testFineHighContrastFeatureSurvivesMultiscaleRanking() throws {
        let source = try image(80,80) { x,y in abs(x-40) <= 1 && y > 8 && y < 72 ? 0.05 : 0.95 }
        var p = Parameters(); p.detail = 0.85; p.textureSuppression = 1
        let edges = try StructuralEdgeDetector().detect(source, parameters: p)
        XCTAssertGreaterThan(edges.filter { $0 == 1 }.count, 100)
        for i in edges.indices where edges[i] == 1 {
            XCTAssertTrue((37...43).contains(i % 80))
        }
    }
    func testTinyRegionMergesIntoClosestToneInsteadOfStrongOppositeMass() throws {
        // Tiny 0.4 island touches the 0.9 region on three sides, and the 0.3
        // region on one: tonal similarity should win over simple boundary voting.
        var labels = [UInt8](repeating: 2,count: 25)
        for y in 0..<5 { labels[y*5+1] = 0 }
        labels[12] = 1
        try suppressSmallRegions(&labels,width: 5,height: 5,minimumArea: 2,centers: [0.3,0.4,0.9])
        XCTAssertEqual(labels[12],0)
    }
    func testAdjacentSmallComponentsMergeWithoutLeavingStrayPixels() throws {
        var labels: [UInt8] = [0,0,0,0,0, 0,1,2,3,0, 0,0,0,0,0]
        try suppressSmallRegions(&labels,width: 5,height: 3,minimumArea: 4)
        XCTAssertTrue(labels.allSatisfy { $0 == 0 })
    }
    func testCoherenceDoesNotMoveStrongTonalBoundary() throws {
        let source = try image(40,24) { x,_ in x < 20 ? 0.1 : 0.9 }
        let a = try TonalSegmentationEngine().segment(source,levels: 3,minimumArea: 1,coherence: 0)
        let b = try TonalSegmentationEngine().segment(source,levels: 3,minimumArea: 1,coherence: 1)
        XCTAssertEqual(a.labels,b.labels)
    }
    func testDuplicateShadowAlongOutlineIsRemovedButSeparateTransitionSurvives() throws {
        let outlines = [Contour(points: [Point(10.5,1),Point(10.5,38)])]
        let duplicate = Contour(points: (1...38).map { Point(11,Double($0)) })
        let separate = Contour(points: (1...38).map { Point(25,Double($0)) })
        let output = try ShadowBoundaryCleaner().clean([duplicate,separate],outlines: outlines,width: 40,height: 40,spacing: 3,minimumLength: 5)
        XCTAssertEqual(output.count,1)
        XCTAssertTrue(output[0].points.allSatisfy { $0.x == 25 })
    }
    func testCrowdedConcentricRingIsSuppressed() throws {
        func square(_ low: Double,_ high: Double) -> Contour {
            Contour(points: [Point(low,low),Point(high,low),Point(high,high),Point(low,high)],closed: true)
        }
        let output = try ShadowBoundaryCleaner().clean([square(4,36),square(6,34)],outlines: [],width: 40,height: 40,spacing: 3,minimumLength: 8)
        XCTAssertEqual(output.count,1)
        XCTAssertTrue(output[0].closed)
    }
    func testClippingSparseShadowDoesNotBridgeAnOutline() throws {
        let shadow = Contour(points: [Point(1,20),Point(38,20)])
        let outline = Contour(points: [Point(20,1),Point(20,38)])
        let output = try ShadowBoundaryCleaner().clean([shadow],outlines: [outline],width: 40,height: 40,spacing: 3,minimumLength: 3)
        XCTAssertEqual(output.count,2)
        XCTAssertTrue(output.allSatisfy { !$0.closed })
        XCTAssertTrue(output.allSatisfy { $0.points.allSatisfy { $0.x < 17 } || $0.points.allSatisfy { $0.x > 22 } })
    }
    func testZeroSpacingRetainsAllBoundaries() throws {
        let path = Contour(points: [Point(2,2),Point(20,2)])
        let output = try ShadowBoundaryCleaner().clean([path],outlines: [path],width: 24,height: 24,spacing: 0,minimumLength: 0)
        XCTAssertEqual(output.map(\.points),[path.points])
    }
    func testFractionalPreviewSpacingDoesNotLeakDuplicateBoundary() throws {
        let outline = Contour(points: [Point(10.5,1),Point(10.5,30)])
        let shadow = Contour(points: [Point(11,1),Point(11,30)])
        let output = try ShadowBoundaryCleaner().clean([shadow],outlines: [outline],width: 32,height: 32,spacing: 0.75,minimumLength: 3)
        XCTAssertTrue(output.isEmpty)
    }
    func testMemoryPreflightRejectsBeforeProcessingStagesRun() throws {
        let source = try image(32,32) { _,_ in 0.5 }
        let limits = ProcessingLimits(memoryBudgetBytes: 1024)
        XCTAssertThrowsError(try StencilProcessingCoordinator().process(source,parameters: Parameters(),limits: limits)) { error in
            guard case StencilError.memoryBudget = error else { return XCTFail("Expected memory budget error: \(error)") }
        }
        XCTAssertThrowsError(try limits.bounded(width: Int.max,height: 8))
    }
    func testResourceBudgetsBoundGraphsAndRegions() throws {
        let edges = [UInt8](repeating: 1,count: 100)
        XCTAssertThrowsError(try StructuralContourTracer().traceEdges(edges,width: 10,height: 10,maximumLinks: 3))
        var labels: [UInt8] = (0..<100).map { index in
            let row = index / 10, column = index % 10
            return UInt8((row + column) % 2)
        }
        let limits = ProcessingLimits(maximumGraphLinks: 3,maximumRegions: 4)
        XCTAssertThrowsError(try suppressSmallRegions(&labels,width: 10,height: 10,minimumArea: 2,limits: limits))
        let toneLabels: [UInt8] = (0..<100).map { index in index % 10 < 5 ? 0 : 1 }
        let tones = Segmentation(labels: toneLabels,thresholds: [0.5],centers: [0.1,0.9])
        XCTAssertThrowsError(try ShadowBoundaryGenerator().generate(tones,width: 10,height: 10,sensitivity: 1,maximumLinks: 2))
    }
    func testPreviewParameterScalingUsesPixelAreaAndLengths() throws {
        let p = Parameters(), scaled = try p.forPreview(scale: 0.25)
        XCTAssertEqual(scaled.minimumContourLength,p.minimumContourLength*0.25)
        XCTAssertEqual(scaled.shadowSpacing,p.shadowSpacing*0.25)
        XCTAssertEqual(scaled.minimumRegionArea,6)
        XCTAssertEqual(scaled.samplingScale,0.25)
        XCTAssertThrowsError(try p.forPreview(scale: .nan))
    }
    func testAreaDownsamplingPreservesAspectAndConstantField() throws {
        let source = try image(128,64) { _,_ in 0.4 }
        let small = try source.downsampled(maximumDimension: 32)
        XCTAssertEqual(small.width,32); XCTAssertEqual(small.height,16)
        XCTAssertTrue(small.pixels.allSatisfy { abs($0-0.4)<0.00001 })
    }
    func testPreviewFidelityIsSymmetricAndDetectsDisplacedGeometry() throws {
        let source = try image(80,60) { x,_ in x < 40 ? 0.1 : 0.9 }
        let output = try StencilProcessingCoordinator().process(source,parameters: Parameters())
        let identical = try PreviewFidelity.compare(preview: output,final: output)
        XCTAssertEqual(identical.score,1,accuracy: 0.00001)
        let displacedSource = try image(80,60) { x,_ in x < 20 ? 0.1 : 0.9 }
        let displaced = try StencilProcessingCoordinator().process(displacedSource,parameters: Parameters())
        let mismatch = try PreviewFidelity.compare(preview: output,final: displaced)
        XCTAssertLessThan(mismatch.outlines.score,0.1)
        let reversed = try PreviewFidelity.compare(preview: displaced,final: output)
        XCTAssertEqual(mismatch.score,reversed.score,accuracy: 0.00001)
    }
    func testHalfScalePreviewTracksStrongGeometry() throws {
        let source = try image(160,120) { x,y in x >= 40 && x < 120 && y >= 25 && y < 95 ? 0.1 : 0.9 }
        var p = Parameters(); p.shadowSpacing = 0
        let final = try StencilProcessingCoordinator().process(source,parameters: p)
        let small = try source.downsampled(maximumDimension: 80)
        let preview = try StencilProcessingCoordinator().process(small,parameters: p.forPreview(scale: 0.5))
        let agreement = try PreviewFidelity.compare(preview: preview,final: final)
        XCTAssertGreaterThan(agreement.outlines.score,0.9)
        XCTAssertGreaterThan(agreement.shadows.score,0.9)
    }
    func testCancelledQueuedLaneJobDoesNotAllocate() async throws {
        let lane = ProcessingLane()
        let task = Task.detached {
            while !Task.isCancelled { await Task.yield() }
            return try await lane.run { XCTFail("Cancelled queued work must not execute"); return 1 }
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
    }
    func testActiveProcessingStopsAfterCancellationBetweenStages() async throws {
        let source = try image(64,64) { x,_ in x < 32 ? 0.1 : 0.9 }
        let started = expectation(description: "Preprocessing completed")
        let proceed = DispatchSemaphore(value: 0)
        let task = Task.detached {
            try StencilProcessingCoordinator().process(source,parameters: Parameters()) { fraction,_ in
                if fraction == 0.3 { started.fulfill(); proceed.wait() }
            }
        }
        await fulfillment(of: [started],timeout: 5)
        task.cancel(); proceed.signal()
        do { _ = try await task.value; XCTFail("Expected active cancellation") } catch is CancellationError { }
    }
}
