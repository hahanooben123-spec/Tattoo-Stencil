import UIKit
import ImageIO
import UniformTypeIdentifiers
import StencilCore

enum ExportFormat: String, CaseIterable { case png = "PNG", pdf = "PDF" }

enum ExportService {
    static func exportRaster(_ image: CGImage, widthMM: Double, format: ExportFormat) throws -> URL {
        guard widthMM.isFinite, (10...2000).contains(widthMM) else { throw StencilError.invalidParameters }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("StencilExports",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let url = folder.appendingPathComponent("PC-Stencil-\(UUID().uuidString).\(format == .png ? "png" : "pdf")")
        if format == .png {
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil) else { throw ImportError.allocation }
            let dpi = Double(image.width)/widthMM*25.4
            CGImageDestinationAddImage(destination,image,[kCGImagePropertyDPIWidth:dpi,kCGImagePropertyDPIHeight:dpi] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw ImportError.allocation }
        } else {
            let width = widthMM/25.4*72
            let rect = CGRect(x:0,y:0,width:width,height:width*Double(image.height)/Double(image.width))
            try UIGraphicsPDFRenderer(bounds:rect).writePDF(to:url) { context in
                context.beginPage()
                UIImage(cgImage:image).draw(in:rect)
            }
        }
        return url
    }
    static func export(_ result: StencilResult, styles: [LayerKind: LayerStyle], parameters: Parameters,
                       widthMM: Double, transparent: Bool, format: ExportFormat) throws -> URL {
        guard widthMM.isFinite, widthMM >= 10, widthMM <= 2000 else { throw StencilError.invalidParameters }
        _ = try ProcessingLimits.device.bounded(width: result.width, height: result.height)
        try Task.checkCancellation()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("StencilExports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Stencil-\(UUID().uuidString).\(format == .png ? "png" : "pdf")")
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: url) } }
        if format == .png {
            let image = try StencilRenderer.image(result, styles: styles, parameters: parameters, strokeScale: 1, transparent: transparent)
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
                c.setFillColor(UIColor.white.cgColor)
                c.fill(CGRect(x: 0, y: 0, width: width, height: height))
                c.scaleBy(x: width / Double(result.width), y: height / Double(result.height))
                StencilRenderer.draw(result, context: c, styles: styles, parameters: parameters, strokeScale: 1)
            }
        }
        try Task.checkCancellation()
        completed = true
        return url
    }
}
