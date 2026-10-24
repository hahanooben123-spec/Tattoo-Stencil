import XCTest
@testable import StencilCore
#if canImport(Vision)
import CoreGraphics
#endif

final class SubjectGuidanceTests: XCTestCase {
    func image(_ w: Int = 100,_ h: Int = 80,_ pixel: (Int,Int) -> Float) throws -> GrayImage {
        try GrayImage(width: w,height: h,pixels: (0..<h).flatMap { y in (0..<w).map { pixel($0,y) } })
    }
    func testMaskCannotInventContoursOnUniformReference() throws {
        let source = try image { _,_ in 0.5 }
        let mask = try image { x,y in x > 20 && x < 80 && y > 15 && y < 65 ? 1 : 0 }
        let result = try StencilProcessingCoordinator().process(source,parameters: Parameters(),guidance: SubjectGuidance(mask: mask))
        XCTAssertTrue(result.outlines.isEmpty)
        XCTAssertTrue(result.shadows.isEmpty)
    }
    func testForegroundGuidanceRemovesUnrelatedBackgroundEdges() throws {
        let source = try image { x,_ in x < 20 ? 0.1 : x < 65 ? 0.9 : 0.1 }
        let mask = try image { x,_ in x < 45 ? 1 : 0 }
        let p = Parameters()
        let plain = try StencilProcessingCoordinator().process(source,parameters: p)
        let focused = try StencilProcessingCoordinator().process(source,parameters: p,guidance: SubjectGuidance(mask: mask))
        XCTAssertTrue(plain.outlines.flatMap(\.points).contains { $0.x > 60 })
        XCTAssertFalse(focused.outlines.isEmpty)
        XCTAssertTrue(focused.outlines.flatMap(\.points).allSatisfy { abs($0.x-20)<1 })
    }
    func testWeakerSilhouetteIsRecoveredAtItsActualImagePosition() throws {
        let source = try image { x,_ in x < 50 ? 0.4 : 0.5 }
        let mask = try image { x,_ in x < 50 ? 1 : 0 }
        var p = Parameters(); p.noiseReduction = 0; p.edgeThreshold = 0.16
        let plain = try StencilProcessingCoordinator().process(source,parameters: p)
        let guided = try StencilProcessingCoordinator().process(source,parameters: p,guidance: SubjectGuidance(mask: mask))
        XCTAssertTrue(plain.outlines.isEmpty)
        XCTAssertFalse(guided.outlines.isEmpty)
        XCTAssertTrue(guided.outlines.allSatisfy(\.isPrimary))
        XCTAssertTrue(guided.outlines.flatMap(\.points).allSatisfy { abs($0.x-50)<1 })
    }
    func testIncorrectMaskDoesNotMoveDetectedEdges() throws {
        let source = try image { x,_ in x < 50 ? 0.1 : 0.9 }
        let mask = try image { x,_ in x < 53 ? 1 : 0 }
        let result = try StencilProcessingCoordinator().process(source,parameters: Parameters(),guidance: SubjectGuidance(mask: mask))
        XCTAssertFalse(result.outlines.isEmpty)
        XCTAssertTrue(result.outlines.flatMap(\.points).allSatisfy { abs($0.x-50)<1 })
    }
    func testLowResolutionMaskSharesNativeCoordinates() throws {
        let small = try image(20,16) { x,_ in x < 10 ? 1 : 0 }
        let guidance = SubjectGuidance(mask: small)
        XCTAssertEqual(guidance.value(x: 25,y: 40,width: 100,height: 80),1)
        XCTAssertEqual(guidance.value(x: 75,y: 40,width: 100,height: 80),0)
        XCTAssertTrue(guidance.boundary(x: 50,y: 40,width: 100,height: 80))
    }
    func testSilhouetteClassificationSurvivesOptimization() throws {
        let source = try image { x,_ in x < 50 ? 0.1 : 0.9 }
        let mask = try image { x,_ in x < 50 ? 1 : 0 }
        let path = Contour(points: (1..<79).map { Point(49.5,Double($0)) })
        let ranked = try MainContourSelector().classify([path],image: source,guidance: SubjectGuidance(mask: mask))
        let optimized = try ContourOptimizer().optimize(ranked,minimumLength: 2,tolerance: 0.6)
        XCTAssertTrue(optimized[0].isPrimary)
        XCTAssertEqual(optimized[0].points,[path.points.first!,path.points.last!])
    }
    func testMaskClippingNeverBridgesOutsideRuns() throws {
        let mask = try image { x,_ in x < 30 || x > 70 ? 1 : 0 }
        let path = Contour(points: (1..<99).map { Point(Double($0),40) })
        let clipped = try SubjectGuidance(mask: mask).clip([path],width: 100,height: 80)
        XCTAssertEqual(clipped.count,2)
        XCTAssertTrue(clipped.allSatisfy { $0.points.allSatisfy { $0.x < 30 } || $0.points.allSatisfy { $0.x > 70 } })
    }
    func testMainStrokeHasClearHierarchyAndCanBeNeutralized() {
        let primary = OutlineStroke.style(primary: true,emphasis: 0.8)
        let detail = OutlineStroke.style(primary: false,emphasis: 0.8)
        XCTAssertGreaterThan(primary.widthMultiplier,detail.widthMultiplier*1.9)
        XCTAssertEqual(primary.opacityMultiplier,1)
        XCTAssertEqual(detail.opacityMultiplier,1)
        XCTAssertEqual(OutlineStroke.style(primary: true,emphasis: 0).widthMultiplier,1)
        XCTAssertEqual(OutlineStroke.style(primary: false,emphasis: 0).opacityMultiplier,1)
    }
    func testSimpleControlsHaveCoherentResolutionAwareDefaults() throws {
        let controls = StencilControls()
        let p = try controls.parameters(width: 900,height: 600)
        let large = try controls.parameters(width: 3600,height: 2400)
        XCTAssertLessThanOrEqual(p.tonalLevels,4)
        XCTAssertGreaterThan(p.textureSuppression,0.7)
        XCTAssertEqual(large.minimumContourLength,p.minimumContourLength*4,accuracy: 0.001)
        XCTAssertEqual(large.minimumRegionArea,Int(Double(3600*2400)*(0.0002+Double(1-controls.shadows)*0.0008)))
        try large.validate()
    }
    func testZeroShadowsControlActuallyGeneratesNoShadowPaths() throws {
        var controls = StencilControls(); controls.shadows = 0
        let p = try controls.parameters(width: 100,height: 80)
        let source = try image { x,_ in Float(x)/100 }
        let output = try StencilProcessingCoordinator().process(source,parameters: p)
        XCTAssertFalse(p.shadowsEnabled)
        XCTAssertTrue(output.shadows.isEmpty)
    }
    func testGuidanceRejectsMismatchedAspectRatio() throws {
        let source = try image { _,_ in 0.5 }
        let mask = try image(20,40) { _,_ in 1 }
        XCTAssertThrowsError(try StencilProcessingCoordinator().process(source,parameters: Parameters(),guidance: SubjectGuidance(mask: mask)))
    }
    #if canImport(Vision)
    func testAppleVisionBlankReferenceHasSafeFallback() throws {
        guard #available(macOS 14,iOS 17,*) else { throw XCTSkip("Vision subject API requires macOS 14 / iOS 17") }
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil,width: 128,height: 128,bitsPerComponent: 8,bytesPerRow: 128*4,
                                            space: space,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1,alpha: 1)); context.fill(CGRect(x: 0,y: 0,width: 128,height: 128))
        let cgImage = try XCTUnwrap(context.makeImage())
        let result = try AppleSubjectDetector.detect(cgImage,point: nil)
        XCTAssertNil(result.guidance)
        XCTAssertFalse(result.message.isEmpty)
    }
    #endif
}
