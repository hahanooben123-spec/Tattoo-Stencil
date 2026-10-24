import XCTest
@testable import StencilCore

final class InteractivePreviewTests: XCTestCase {
    func fixture() throws -> GrayImage {
        let w = 120, h = 80
        return try GrayImage(width: w,height: h,pixels: (0..<w*h).map { i -> Float in
            let x = i % w, y = i / w
            if x > 20 && x < 90 && y > 10 && y < 65 { return 0.1+Float(x)/300 }
            return 0.85
        })
    }
    func assertSame(_ a: StencilResult,_ b: StencilResult,file: StaticString = #filePath,line: UInt = #line) {
        XCTAssertEqual(a.width,b.width,file: file,line: line)
        XCTAssertEqual(a.edges,b.edges,file: file,line: line)
        XCTAssertEqual(a.segmentation.labels,b.segmentation.labels,file: file,line: line)
        for kind in LayerKind.allCases {
            XCTAssertEqual(a.contours(for: kind).map(\.points),b.contours(for: kind).map(\.points),file: file,line: line)
            XCTAssertEqual(a.contours(for: kind).map(\.isPrimary),b.contours(for: kind).map(\.isPrimary),file: file,line: line)
            XCTAssertEqual(a.contours(for: kind).map(\.closed),b.contours(for: kind).map(\.closed),file: file,line: line)
        }
    }
    func testWarmFrameReusesEveryStageAndMatchesFresh() async throws {
        let source = try fixture(), engine = try InteractivePreviewEngine(source: source,nativeWidth: 120)
        let a = try await engine.render(parameters: Parameters(),quality: .refined)
        let b = try await engine.render(parameters: Parameters(),quality: .refined)
        XCTAssertEqual(a.statistics.computed.count,5)
        XCTAssertTrue(b.statistics.computed.isEmpty)
        XCTAssertEqual(b.statistics.reused.count,5)
        assertSame(b.result,try StencilProcessingCoordinator().process(source,parameters: Parameters()))
    }
    func testAppearanceOnlyChangesNeverRunComputerVision() async throws {
        let engine = try InteractivePreviewEngine(source: fixture(),nativeWidth: 120)
        let p = Parameters()
        _ = try await engine.render(parameters: p,quality: .interactive)
        var appearance = p; appearance.outlineEmphasis = 0.1; appearance.dashLength = 20; appearance.dashSpacing = 15
        XCTAssertTrue(appearance.hasSameGeometry(as: p))
        let frame = try await engine.render(parameters: appearance,quality: .interactive)
        XCTAssertEqual(frame.statistics.reused.count,5)
        XCTAssertTrue(frame.statistics.computed.isEmpty)
    }
    func testShadowSliderReusesPreprocessingAndOutlines() async throws {
        let engine = try InteractivePreviewEngine(source: fixture(),nativeWidth: 120)
        var controls = StencilControls()
        _ = try await engine.render(parameters: controls.parameters(width: 120,height: 80),quality: .refined)
        controls.shadows = 0.9
        let frame = try await engine.render(parameters: controls.parameters(width: 120,height: 80),quality: .refined)
        XCTAssertTrue(frame.statistics.reused.contains("preprocess"))
        XCTAssertTrue(frame.statistics.reused.contains("outlines"))
        XCTAssertTrue(frame.statistics.computed.contains("tones"))
        XCTAssertTrue(frame.statistics.computed.contains("shadows"))
    }
    func testDetailSliderInvalidatesPreprocessAndDependentGeometry() async throws {
        let engine = try InteractivePreviewEngine(source: fixture(),nativeWidth: 120)
        var controls = StencilControls()
        _ = try await engine.render(parameters: controls.parameters(width: 120,height: 80),quality: .refined)
        controls.detail = 0.9
        let frame = try await engine.render(parameters: controls.parameters(width: 120,height: 80),quality: .refined)
        XCTAssertEqual(Set(frame.statistics.computed),Set(["preprocess","outlines","tones","shadows","highlights"]))
    }
    func testGuidanceIdentityInvalidatesRelevantStagesOnly() async throws {
        let source = try fixture(), engine = try InteractivePreviewEngine(source: source,nativeWidth: 120)
        let mask = try GrayImage(width: 120,height: 80,pixels: (0..<9600).map { $0 % 120 < 60 ? 1 : 0 })
        _ = try await engine.render(parameters: Parameters(),quality: .refined)
        let focused = try await engine.render(parameters: Parameters(),quality: .refined,guidance: SubjectGuidance(mask: mask))
        XCTAssertEqual(Set(focused.statistics.reused),Set(["preprocess","tones"]))
        XCTAssertEqual(Set(focused.statistics.computed),Set(["outlines","shadows","highlights"]))
        assertSame(focused.result,try StencilProcessingCoordinator().process(source,parameters: Parameters(),guidance: SubjectGuidance(mask: mask)))
    }
    func testTwoResolutionCachesRemainIndependent() async throws {
        let engine = try InteractivePreviewEngine(source: fixture(),nativeWidth: 120,interactiveDimension: 60)
        let a = try await engine.render(parameters: Parameters(),quality: .interactive)
        let b = try await engine.render(parameters: Parameters(),quality: .refined)
        XCTAssertEqual(a.result.width,60); XCTAssertEqual(b.result.width,120)
        let warm = try await engine.render(parameters: Parameters(),quality: .interactive)
        XCTAssertEqual(warm.statistics.reused.count,5)
        assertSame(a.result,warm.result)
    }
    func testSameSizeDifferentSourcesCannotShareResults() async throws {
        let source = try fixture()
        let flat = try GrayImage(width: 120,height: 80,pixels: [Float](repeating: 0.5,count: 9600))
        let a = try InteractivePreviewEngine(source: source,nativeWidth: 120)
        let b = try InteractivePreviewEngine(source: flat,nativeWidth: 120)
        let first = try await a.render(parameters: Parameters(),quality: .refined)
        let second = try await b.render(parameters: Parameters(),quality: .refined)
        XCTAssertFalse(first.result.outlines.isEmpty)
        XCTAssertTrue(second.result.outlines.isEmpty)
        XCTAssertEqual(second.statistics.computed.count,5)
    }
    func testMixedCachedEditsMatchUncachedOracle() async throws {
        let source = try fixture(), engine = try InteractivePreviewEngine(source: source,nativeWidth: 120)
        var p = Parameters()
        for index in 0..<8 {
            switch index {
            case 1: p.minimumContourLength = 3
            case 2: p.highlightsEnabled = true
            case 3: p.minimumHighlightArea = 12
            case 4: p.suppressOutlineDuplicates = false
            case 5: p.shadowSensitivity = 0.8
            case 6: p.contrast = 1.2
            case 7: p.shadowsEnabled = false
            default: break
            }
            let cached = try await engine.render(parameters: p,quality: .refined)
            assertSame(cached.result,try StencilProcessingCoordinator().process(source,parameters: p))
        }
    }
    func testMemoryClearDropsAllStageEntries() async throws {
        let engine = try InteractivePreviewEngine(source: fixture(),nativeWidth: 120)
        _ = try await engine.render(parameters: Parameters(),quality: .interactive)
        await engine.clear()
        let cold = try await engine.render(parameters: Parameters(),quality: .interactive)
        XCTAssertEqual(cold.statistics.computed.count,5)
    }
    func testCancelledRequestCannotPoisonNextFrame() async throws {
        let source = try fixture(), engine = try InteractivePreviewEngine(source: source,nativeWidth: 120)
        let task = Task.detached {
            while !Task.isCancelled { await Task.yield() }
            return try await engine.render(parameters: Parameters(),quality: .refined)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        let result = try await engine.render(parameters: Parameters(),quality: .refined)
        assertSame(result.result,try StencilProcessingCoordinator().process(source,parameters: Parameters()))
    }
    func testBilateralRangeLookupStaysCloseToExactReference() throws {
        let source = try fixture(), w = source.width, h = source.height
        var p = Parameters(); p.noiseReduction = 0.35
        let filtered = try ImagePreprocessor().process(source,parameters: p)
        let sigma = 0.025+Double(p.noiseReduction)*0.12, spatial = 0.8+Double(p.noiseReduction)
        for (x,y) in [(20,20),(21,20),(50,40),(90,50),(0,0)] {
            let center = Double(source.pixels[y*w+x])
            var sum = 0.0, weights = 0.0
            for dy in -2...2 { for dx in -2...2 {
                let v = Double(source.pixels[min(h-1,max(0,y+dy))*w+min(w-1,max(0,x+dx))])
                let delta = v-center
                let weight = exp(-Double(dx*dx+dy*dy)/(2*spatial*spatial))*exp(-delta*delta/(2*sigma*sigma))
                sum += v*weight; weights += weight
            } }
            XCTAssertEqual(Double(filtered.pixels[y*w+x]),sum/weights,accuracy: 0.0005)
        }
    }
}
