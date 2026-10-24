import XCTest
@testable import StencilCore

final class StencilPathTests: XCTestCase {
    func testCurveRoundingKeepsEndpointsAndStaysWithinSourceTolerance() throws {
        let points = [Point(0,0),Point(4,0),Point(8,2),Point(12,4)]
        let path = try StencilPath(contour: Contour(points: points),maximumDeviation: 0.6)
        XCTAssertEqual(path.start,points[0])
        var previous = path.start, curves = 0
        for element in path.elements {
            switch element {
            case let .line(to): previous = to
            case let .quadratic(control,to):
                curves += 1
                for step in 0...20 {
                    let t = Double(step)/20, u = 1-t
                    let sample = Point(u*u*previous.x+2*u*t*control.x+t*t*to.x,u*u*previous.y+2*u*t*control.y+t*t*to.y)
                    let distance = zip(points,points.dropFirst()).map { a,b -> Double in
                        let dx = b.x-a.x, dy = b.y-a.y
                        let s = min(1,max(0,((sample.x-a.x)*dx+(sample.y-a.y)*dy)/(dx*dx+dy*dy)))
                        return hypot(sample.x-a.x-s*dx,sample.y-a.y-s*dy)
                    }.min()!
                    XCTAssertLessThanOrEqual(distance,0.6)
                }
                previous = to
            }
        }
        XCTAssertGreaterThan(curves,0)
        XCTAssertEqual(previous,points.last)
    }
    func testClosedGraphicCornersRemainSharp() throws {
        let points = [Point(0,0),Point(10,0),Point(10,10),Point(0,10)]
        let path = try StencilPath(contour: Contour(points: points,closed: true),maximumDeviation: 0.6)
        XCTAssertTrue(path.closed)
        XCTAssertEqual(path.start,points[0])
        XCTAssertEqual(path.elements.count,4)
        for element in path.elements {
            if case .quadratic = element { XCTFail("A deliberate square corner was rounded") }
        }
    }
    func testGuideDashPatternKeepsImageRelativeSpacing() throws {
        let controls = StencilControls()
        let normal = try controls.parameters(width: 900,height: 600)
        let large = try controls.parameters(width: 3600,height: 2400)
        XCTAssertEqual(large.dashLength,normal.dashLength*4)
        XCTAssertEqual(large.dashSpacing,normal.dashSpacing*4)
        XCTAssertEqual(large.dashSpacing/large.dashLength,2)
    }
}
