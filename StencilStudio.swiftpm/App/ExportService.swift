import UIKit
import ImageIO
import UniformTypeIdentifiers
import StencilCore

enum ExportFormat: String, CaseIterable { case png = "PNG", pdf = "PDF" }

enum ExportService {
    static func export(_ result: StencilResult, styles: [LayerKind: LayerStyle], parameters: Parameters,
                       widthMM: Double, transparent: Bool, inverted: Bool, format: ExportFormat) throws -> URL {
        guard widthMM.isFinite, widthMM >= 10, widthMM <= 2000 else { throw StencilError.invalidParameters }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("StencilExports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Stencil-\(UUID().uuidString).\(format == .png ? "png" : "pdf")")
        if format == .png {
            let image = try StencilRenderer.image(result, styles: styles, parameters: parameters, strokeScale: 1, transparent: transparent, inverted: inverted)
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw ImportError.allocation }
            let dpi = Double(result.width) / widthMM * 25.4
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw ImportError.allocation }
        } else {
            let width = widthMM / 25.4 * 72
            let height = width * Double(result.height) / Double(result.width)
            let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: width, height: height))
            try renderer.writePDF(to: url) { rendererContext in
                rendererContext.beginPage()
                let c = rendererContext.cgContext
                c.setFillColor((inverted ? UIColor.black : UIColor.white).cgColor)
                c.fill(CGRect(x: 0, y: 0, width: width, height: height))
                c.scaleBy(x: width / Double(result.width), y: height / Double(result.height))
                StencilRenderer.draw(result, context: c, styles: styles, parameters: parameters, strokeScale: 1, inverted: inverted)
            }
        }
        return url
    }
}
