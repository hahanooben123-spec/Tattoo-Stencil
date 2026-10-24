import Foundation
import UIKit
import ImageIO
import StencilCore

enum ImportError: LocalizedError {
    case unreadable, allocation
    var errorDescription: String? {
        switch self {
        case .unreadable: return "This file could not be decoded as an image. Try a PNG, JPEG or HEIC reference."
        case .allocation: return "There is not enough memory to decode this reference at its original resolution."
        }
    }
}

struct ImportedImage: @unchecked Sendable {
    // Retain compressed bytes; full-resolution pixels are decoded only in the lane.
    let encoded: Data
    let width: Int
    let height: Int
    let preview: GrayImage
    let previewImage: CGImage
}

enum ImageImportService {
    static func load(_ data: Data) throws -> ImportedImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = metadata[kCGImagePropertyPixelWidth] as? Int,
              let height = metadata[kCGImagePropertyPixelHeight] as? Int else { throw ImportError.unreadable }
        try Task.checkCancellation()
        guard width > 1, height > 1, width <= Int.max / height else { throw ImportError.unreadable }
        let orientation = (metadata[kCGImagePropertyOrientation] as? Int) ?? 1
        let rotated = (5...8).contains(orientation)
        // Decode only the interactive thumbnail at import time.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 900
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw ImportError.unreadable }
        let preview = try luminance(thumbnail)
        return ImportedImage(encoded: data, width: rotated ? height : width, height: rotated ? width : height,
                             preview: preview, previewImage: thumbnail)
    }

    static func fullLuminance(_ imported: ImportedImage, limits: ProcessingLimits) throws -> GrayImage {
        _ = try limits.bounded(width: imported.width, height: imported.height)
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(imported.encoded as CFData, nil) else { throw ImportError.unreadable }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceThumbnailMaxPixelSize: max(imported.width, imported.height)]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              image.width == imported.width, image.height == imported.height else { throw ImportError.unreadable }
        try Task.checkCancellation()
        return try luminance(image)
    }

    static func luminance(_ image: CGImage) throws -> GrayImage {
        let w = image.width, h = image.height
        guard image.width > 1, image.height > 1, w <= Int.max / h / 4 else { throw StencilError.invalidImage }
        var bytes = [UInt8](repeating: 255, count: w*h*4)
        let didDraw = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w*4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setFillColor(UIColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: w, height: h))
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard didDraw else { throw ImportError.allocation }
        // sRGB -> linear relative luminance -> CIE L* perceptual brightness.
        let linear: [Float] = (0...255).map { v in
            let c = Float(v) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        var pixels = [Float](repeating: 0, count: w*h)
        for i in pixels.indices {
            if i % 65536 == 0 { try Task.checkCancellation() }
            let y = 0.2126 * linear[Int(bytes[i*4])] + 0.7152 * linear[Int(bytes[i*4+1])] + 0.0722 * linear[Int(bytes[i*4+2])]
            pixels[i] = min(1, max(0, y > 0.008856 ? (116 * pow(y, 1 / Float(3)) - 16) / 100 : 9.03296 * y))
        }
        return try GrayImage(width: w, height: h, pixels: pixels)
    }

}
