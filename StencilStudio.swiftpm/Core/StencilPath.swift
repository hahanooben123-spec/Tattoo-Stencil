import Foundation

/// A bounded rounding of traced polylines. Endpoints and intentional sharp
/// corners remain fixed; curves stay inside their adjacent source segments' hull.
public struct StencilPath: Sendable {
    public enum Element: Sendable {
        case line(to: Point)
        case quadratic(control: Point,to: Point)
    }
    public let start: Point
    public let elements: [Element]
    public let closed: Bool
    public static func roundingLimit(width: Int,height: Int) -> Double {
        max(0.5,0.6*Double(max(width,height))/900)
    }
    public init(contour: Contour,maximumDeviation: Double) throws {
        guard let first = contour.points.first,maximumDeviation.isFinite,maximumDeviation >= 0 else {
            throw StencilError.invalidParameters
        }
        let points = contour.points, count = points.count
        var entry = points, exit = points, rounded = [Bool](repeating: false,count: count)
        if count > 2 && maximumDeviation > 0 {
            for i in 0..<count where contour.closed || (i > 0 && i < count-1) {
                if i % 4096 == 0 { try Task.checkCancellation() }
                let a = points[(i+count-1) % count], b = points[i], c = points[(i+1) % count]
                let before = hypot(b.x-a.x,b.y-a.y), after = hypot(c.x-b.x,c.y-b.y)
                guard before > 0,after > 0 else { continue }
                let ux = (b.x-a.x)/before, uy = (b.y-a.y)/before
                let vx = (c.x-b.x)/after, vy = (c.y-b.y)/after
                let alignment = ux*vx+uy*vy
                // Round shallow turns, or one-pixel staircase corners. Do not
                // round deliberate long-segment corners of lettering/ornaments.
                guard alignment > -0.1,alignment < 0.9999,
                      alignment >= 0.5 || max(before,after) <= maximumDeviation*2 else { continue }
                let radius = min(min(before,after)*0.25,maximumDeviation*2)
                entry[i] = Point(b.x-ux*radius,b.y-uy*radius)
                exit[i] = Point(b.x+vx*radius,b.y+vy*radius)
                rounded[i] = true
            }
        }
        start = contour.closed ? exit[0] : first
        closed = contour.closed
        var commands: [Element] = []
        if count > 1 {
            for offset in 1..<(contour.closed ? count+1 : count) {
                if offset % 4096 == 0 { try Task.checkCancellation() }
                let i = offset % count
                commands.append(.line(to: entry[i]))
                if rounded[i] { commands.append(.quadratic(control: points[i],to: exit[i])) }
            }
        }
        elements = commands
    }
}
