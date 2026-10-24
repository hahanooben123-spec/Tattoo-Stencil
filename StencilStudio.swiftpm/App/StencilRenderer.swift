import UIKit
import StencilCore

enum DebugStage: String, CaseIterable { case stencil = "Stencil", luminance = "Preprocessed", edges = "Edges", tones = "Tonal regions" }

/// CGPaths are copied to immutable paths before crossing the worker/UI boundary.
struct PreparedStencil: @unchecked Sendable {
    struct Stroke { let path: CGPath; let primary: Bool }
    let width: Int
    let height: Int
    let layers: [LayerKind: [Stroke]]
}

enum StencilRenderer {
    static func prepare(_ result: StencilResult) throws -> PreparedStencil {
        var layers: [LayerKind: [PreparedStencil.Stroke]] = [:]
        for kind in LayerKind.allCases {
            var strokes: [PreparedStencil.Stroke] = []
            for contour in result.contours(for: kind) {
                try Task.checkCancellation()
                guard let first = contour.points.first else { continue }
                let path = CGMutablePath(); path.move(to: CGPoint(x: first.x,y: first.y))
                for (index,point) in contour.points.dropFirst().enumerated() {
                    if index % 4096 == 0 { try Task.checkCancellation() }
                    path.addLine(to: CGPoint(x: point.x,y: point.y))
                }
                if contour.closed { path.closeSubpath() }
                guard let immutable = path.copy() else { throw ImportError.allocation }
                strokes.append(PreparedStencil.Stroke(path: immutable,primary: contour.isPrimary))
            }
            layers[kind] = strokes
        }
        return PreparedStencil(width: result.width,height: result.height,layers: layers)
    }
    static func draw(_ result: StencilResult, context: CGContext, styles: [LayerKind: LayerStyle],
                     parameters: Parameters, strokeScale: Double, inverted: Bool) {
        guard let prepared = try? prepare(result) else { return }
        draw(prepared,context: context,styles: styles,parameters: parameters,strokeScale: strokeScale,inverted: inverted)
    }
    static func draw(_ prepared: PreparedStencil, context: CGContext, styles: [LayerKind: LayerStyle],
                     parameters: Parameters, strokeScale: Double, inverted: Bool) {
        context.setLineCap(.round); context.setLineJoin(.round)
        context.setStrokeColor((inverted ? UIColor.white : UIColor.black).cgColor)
        for kind in LayerKind.allCases {
            let style = styles[kind] ?? LayerStyle()
            guard style.visible else { continue }
            context.setAlpha(style.opacity)
            context.setLineWidth(style.width * strokeScale)
            switch kind {
            case .outlines: context.setLineDash(phase: 0, lengths: [])
            case .shadows: context.setLineDash(phase: 0, lengths: [parameters.dashLength * strokeScale, parameters.dashSpacing * strokeScale])
            case .highlights: context.setLineDash(phase: 0, lengths: [0.5 * strokeScale, 3 * strokeScale])
            }
            for stroke in prepared.layers[kind] ?? [] {
                if Task.isCancelled { return }
                if kind == .outlines {
                    let appearance = OutlineStroke.style(primary: stroke.primary, emphasis: parameters.outlineEmphasis)
                    context.setLineWidth(style.width * strokeScale * appearance.widthMultiplier)
                    context.setAlpha(style.opacity * appearance.opacityMultiplier)
                }
                context.beginPath(); context.addPath(stroke.path)
                context.strokePath()
            }
        }
        context.setAlpha(1)
    }

    static func image(_ result: StencilResult, styles: [LayerKind: LayerStyle], parameters: Parameters,
                      strokeScale: Double, transparent: Bool, inverted: Bool) throws -> CGImage {
        try Task.checkCancellation()
        guard let context = CGContext(data: nil, width: result.width, height: result.height, bitsPerComponent: 8,
                                      bytesPerRow: result.width*4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ImportError.allocation }
        if !transparent {
            context.setFillColor((inverted ? UIColor.black : UIColor.white).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: result.width, height: result.height))
        }
        context.translateBy(x: 0, y: Double(result.height)); context.scaleBy(x: 1, y: -1)
        draw(result, context: context, styles: styles, parameters: parameters, strokeScale: strokeScale, inverted: inverted)
        try Task.checkCancellation()
        guard let image = context.makeImage() else { throw ImportError.allocation }
        return image
    }

    static func debugImage(_ result: StencilResult, stage: DebugStage) throws -> CGImage {
        let values: [UInt8]
        switch stage {
        case .luminance: values = result.preprocessed.pixels.map { UInt8(($0 * 255).rounded()) }
        case .edges: values = result.edges.map { $0 > 0 ? 0 : 255 }
        case .tones:
            values = result.segmentation.labels.map { UInt8((result.segmentation.centers[Int($0)] * 255).rounded()) }
        case .stencil: values = []
        }
        guard !values.isEmpty, let provider = CGDataProvider(data: Data(values) as CFData),
              let image = CGImage(width: result.width, height: result.height, bitsPerComponent: 8, bitsPerPixel: 8,
                                  bytesPerRow: result.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [],
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw ImportError.allocation }
        return image
    }
}
