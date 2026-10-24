import XCTest
@testable import StencilCore

final class FacialFeatureTests: XCTestCase {
    func source(_ pixel: (Int,Int) -> Float) throws -> GrayImage {
        try GrayImage(width: 160,height: 120,pixels: (0..<19200).map { pixel($0 % 160,$0 / 160) })
    }
    func eyeRegion() throws -> FeatureRegion {
        try FeatureRegion(kind: .eye,minX: 0.40,minY: 0.35,maxX: 0.55,maxY: 0.48)
    }
    func testVisionCoordinateConversionFlipsVerticalOriginExactlyOnce() throws {
        let region = try FeatureRegion.fromVisionPoints(kind: .eye,points: [Point(0.2,0.7),Point(0.4,0.8)],
                                                       faceX: 0.1,faceY: 0.2,faceWidth: 0.5,faceHeight: 0.6)
        XCTAssertEqual(region.minX,0.18,accuracy: 0.00001)
        XCTAssertEqual(region.maxX,0.32,accuracy: 0.00001)
        XCTAssertEqual(region.minY,0.299,accuracy: 0.00001)
        XCTAssertEqual(region.maxY,0.401,accuracy: 0.00001)
    }
    func testFacialRegionsCannotInventLinesOnAFlatReference() throws {
        let flat = try source { _,_ in 0.5 }
        let mask = try source { _,_ in 1 }
        let guidance = SubjectGuidance(mask: mask,features: [try eyeRegion()])
        let output = try StencilProcessingCoordinator().process(flat,parameters: Parameters(),guidance: guidance)
        XCTAssertTrue(output.outlines.isEmpty)
    }
    func testShortLowContrastEyeStrokeIsRecoveredWithoutMovingIt() throws {
        let reference = try source { x,y in (70...78).contains(x) && y == 50 ? 0.44 : 0.5 }
        let mask = try source { _,_ in 1 }
        let region = try FeatureRegion(kind: .eye,minX: 0.4,minY: 0.38,maxX: 0.55,maxY: 0.47)
        var p = Parameters(); p.minimumContourLength = 40; p.noiseReduction = 0
        let plain = try StencilProcessingCoordinator().process(reference,parameters: p,guidance: SubjectGuidance(mask: mask))
        let guided = try StencilProcessingCoordinator().process(reference,parameters: p,guidance: SubjectGuidance(mask: mask,features: [region]))
        XCTAssertTrue(plain.outlines.isEmpty)
        XCTAssertFalse(guided.outlines.isEmpty)
        XCTAssertTrue(guided.outlines.contains { $0.isFeature && $0.isPrimary && $0.length < 40 })
        for point in guided.outlines.flatMap(\.points) {
            XCTAssertTrue((68...81).contains(point.x))
            XCTAssertTrue((48...53).contains(point.y))
        }
    }
    func testLengthProtectionDoesNotRetainUnrelatedShortArtifacts() throws {
        let points = (0...8).map { Point(Double($0),10) }
        let marked = Contour(points: points,isPrimary: true,isFeature: true)
        let ordinary = Contour(points: points)
        let output = try ContourOptimizer().optimize([ordinary,marked],minimumLength: 40,tolerance: 0.5)
        XCTAssertEqual(output.count,1)
        XCTAssertTrue(output[0].isFeature)
        XCTAssertTrue(output[0].isPrimary)
        XCTAssertEqual(output[0].points,[points.first!,points.last!])
    }
    func testDetailedModeCanKeepCoherentLowContrastEdgesWithoutVision() throws {
        let reference = try source { x,_ in x < 80 ? 0.48 : 0.52 }
        var p = Parameters(); p.detail = 1; p.noiseReduction = 0; p.minimumContourLength = 4
        let result = try StencilProcessingCoordinator().process(reference,parameters: p)
        XCTAssertFalse(result.outlines.isEmpty)
        XCTAssertTrue(result.outlines.flatMap(\.points).allSatisfy { abs($0.x-80) <= 1 })
    }
    func testSmoothShadingDoesNotBecomeAnInventedOutline() throws {
        let reference = try source { x,_ in 0.3+Float(x)/160*0.3 }
        let mask = try source { _,_ in 1 }
        var p = Parameters(); p.detail = 1; p.noiseReduction = 0
        let output = try StencilProcessingCoordinator().process(reference,parameters: p,guidance: SubjectGuidance(mask: mask,features: [try eyeRegion()]))
        XCTAssertTrue(output.outlines.isEmpty)
    }
    func testFeatureMapScalesInImageCoordinates() throws {
        let mask = try GrayImage(width: 16,height: 12,pixels: [Float](repeating: 1,count: 192))
        let guidance = SubjectGuidance(mask: mask,features: [try eyeRegion()])
        let map = try XCTUnwrap(guidance.featureMap(width: 160,height: 120))
        XCTAssertEqual(map[50*160+75],1)
        XCTAssertEqual(map[90*160+75],0)
    }
    func testShadowLengthsStayIndependentOfFineOutlineDetail() throws {
        var controls = StencilControls(); controls.detail = 1
        let p = try controls.parameters(width: 900,height: 600)
        XCTAssertLessThanOrEqual(p.minimumContourLength,4)
        XCTAssertGreaterThanOrEqual(p.minimumShadowContourLength,24)
        let scaled = try p.forPreview(scale: 0.5)
        XCTAssertEqual(scaled.minimumShadowContourLength,p.minimumShadowContourLength*0.5)
    }
    func testChangingFeatureRegionsInvalidatesPreprocessingAndOutlines() async throws {
        let reference = try source { x,y in (70...78).contains(x) && y == 50 ? 0.44 : 0.5 }
        let mask = try source { _,_ in 1 }
        let engine = try InteractivePreviewEngine(source: reference,nativeWidth: 160)
        _ = try await engine.render(parameters: Parameters(),quality: .refined,guidance: SubjectGuidance(mask: mask))
        let result = try await engine.render(parameters: Parameters(),quality: .refined,guidance: SubjectGuidance(mask: mask,features: [try eyeRegion()]))
        XCTAssertTrue(result.statistics.computed.contains("outlines"))
        XCTAssertTrue(result.statistics.computed.contains("preprocess"))
    }
    func testNoiseReductionDoesNotEraseGuidedThinFeature() throws {
        let reference = try source { x,y in (70...78).contains(x) && y == 50 ? 0.44 : 0.5 }
        let mask = try source { _,_ in 1 }
        let region = try FeatureRegion(kind: .eye,minX: 0.4,minY: 0.38,maxX: 0.55,maxY: 0.47)
        var p = Parameters(); p.noiseReduction = 0.8; p.minimumContourLength = 40
        let result = try StencilProcessingCoordinator().process(reference,parameters: p,guidance: SubjectGuidance(mask: mask,features: [region]))
        XCTAssertTrue(result.outlines.contains { $0.isFeature && $0.isPrimary })
    }
    func testDetailChangeRefreshesFeaturePreservingPreprocessing() async throws {
        let reference = try source { x,y in (70...78).contains(x) && y == 50 ? 0.44 : 0.5 }
        let guidance = SubjectGuidance(mask: try source { _,_ in 1 },features: [try eyeRegion()])
        let engine = try InteractivePreviewEngine(source: reference,nativeWidth: 160)
        var p = Parameters(); p.detail = 0.2
        _ = try await engine.render(parameters: p,quality: .refined,guidance: guidance)
        p.detail = 0.9
        let frame = try await engine.render(parameters: p,quality: .refined,guidance: guidance)
        let oracle = try StencilProcessingCoordinator().process(reference,parameters: p,guidance: guidance)
        XCTAssertTrue(frame.statistics.computed.contains("preprocess"))
        XCTAssertEqual(frame.result.outlines.map(\.points),oracle.outlines.map(\.points))
    }
}
