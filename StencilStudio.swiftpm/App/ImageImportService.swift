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
    // CGImage is immutable. Orientation is already baked into the pixels.
    let original: CGImage
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
        // Transform orientation at native resolution; do not reduce export dimensions.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height)
        ]
        guard let original = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw ImportError.unreadable }
        let preview = try luminance(original, maximumDimension: 900)
        let previewImage = try resized(original, width: preview.width, height: preview.height)
        return ImportedImage(original: original, preview: preview, previewImage: previewImage)
    }

    static func luminance(_ image: CGImage, maximumDimension: Int? = nil) throws -> GrayImage {
        let scale = maximumDimension.map { min(1, Double($0) / Double(max(image.width, image.height))) } ?? 1
        let w = max(2, Int((Double(image.width) * scale).rounded()))
        let h = max(2, Int((Double(image.height) * scale).rounded()))
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

    static func resized(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width*4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ImportError.allocation }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw ImportError.allocation }
        return result
    }
}
