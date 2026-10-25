import Foundation
import UIKit
import ImageIO

enum LocalAIImages {
    struct Input: @unchecked Sendable {
        let png: Data
        let reference: CGImage
        let canvasWidth: Int
        let canvasHeight: Int
        let contentRect: CGRect
    }
    static func prepare(_ data: Data) throws -> Input {
        guard let source = CGImageSourceCreateWithData(data as CFData,nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let w = properties[kCGImagePropertyPixelWidth] as? Int,
              let h = properties[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, Double(w)*Double(h) <= 40_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source,0,[
                kCGImageSourceCreateThumbnailFromImageAlways:true,
                kCGImageSourceCreateThumbnailWithTransform:true,
                kCGImageSourceThumbnailMaxPixelSize:768] as CFDictionary)
        else { throw LocalAIError.invalidImage }
        let cw = (image.width+63)/64*64, ch = (image.height+63)/64*64
        let rect = CGRect(x:(cw-image.width)/2,y:(ch-image.height)/2,width:image.width,height:image.height)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let padded = UIGraphicsImageRenderer(size:CGSize(width:cw,height:ch),format:format).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x:0,y:0,width:cw,height:ch))
            UIImage(cgImage:image).draw(in:rect)
        }
        guard let png = padded.pngData() else { throw LocalAIError.invalidImage }
        return Input(png:png,reference:image,canvasWidth:cw,canvasHeight:ch,contentRect:rect)
    }
    static func binary(_ source: CGImage, crop: CGRect) throws -> CGImage {
        guard let image = source.cropping(to:crop) else { throw LocalAIError.invalidImage }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating:255,count:width*height)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data:buffer.baseAddress,width:width,height:height,bitsPerComponent:8,
                bytesPerRow:width,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue) else { return false }
            context.setFillColor(gray:1,alpha:1); context.fill(CGRect(x:0,y:0,width:width,height:height))
            context.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
            return true
        }
        guard rendered else { throw LocalAIError.invalidImage }
        for i in pixels.indices { pixels[i] = pixels[i] < 192 ? 0 : 255 }
        guard let provider = CGDataProvider(data:Data(pixels) as CFData),
              let binary = CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:8,bytesPerRow:width,
                space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.none.rawValue),
                provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) else { throw LocalAIError.invalidImage }
        return binary
    }
}
