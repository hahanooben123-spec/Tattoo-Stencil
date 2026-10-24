import Foundation
#if canImport(Vision) && canImport(CoreVideo)
import Vision
import CoreVideo
import CoreGraphics

public struct SubjectAnalysis: Sendable {
    public let guidance: SubjectGuidance?
    public let message: String
    public init(guidance: SubjectGuidance?, message: String) { self.guidance = guidance; self.message = message }
}

/// Uses only Apple's on-device subject model, on the orientation-normalized thumbnail.
/// Its soft mask selects/ranks source edges; the mask itself is never drawn as artwork.
@available(iOS 17, macOS 14, *)
public enum AppleSubjectDetector {
    public static func detect(_ image: CGImage, point: Point?) throws -> SubjectAnalysis {
        try Task.checkCancellation()
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do {
            try handler.perform([request])
            try Task.checkCancellation()
            guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
                return SubjectAnalysis(guidance: nil,message: "Intet sikkert motiv fundet · hele billedet bruges")
            }
            let instances = observation.instanceMask
            guard CVPixelBufferGetPixelFormatType(instances) == kCVPixelFormatType_OneComponent8 else {
                return SubjectAnalysis(guidance: nil,message: "Motivformat ikke understøttet · hele billedet bruges")
            }
            let selected = try selectInstance(instances, available: observation.allInstances, point: point)
            guard let selected else {
                return SubjectAnalysis(guidance: nil,message: "Intet motiv ved trykket · prøv et andet sted")
            }
            let buffer = try observation.generateScaledMaskForImage(forInstances: IndexSet(integer: selected), from: handler)
            guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent32Float,
                  CVPixelBufferGetWidth(buffer) == image.width, CVPixelBufferGetHeight(buffer) == image.height else {
                return SubjectAnalysis(guidance: nil,message: "Motivmasken kunne ikke justeres · hele billedet bruges")
            }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw StencilError.invalidImage }
            let stride = CVPixelBufferGetBytesPerRow(buffer), w = image.width, h = image.height
            var pixels = [Float](repeating: 0,count: w*h)
            for y in 0..<h {
                try Task.checkCancellation()
                let row = base.advanced(by: y*stride).assumingMemoryBound(to: Float.self)
                for x in 0..<w { pixels[y*w+x] = row[x].isFinite ? min(1,max(0,row[x])) : 0 }
            }
            guard pixels.contains(where: { $0 >= 0.5 }) else {
                return SubjectAnalysis(guidance: nil,message: "Motivmasken var tom · hele billedet bruges")
            }
            let mask = try GrayImage(width: w,height: h,pixels: pixels)
            return SubjectAnalysis(guidance: SubjectGuidance(mask: mask),message: "\(point == nil ? "Automatisk" : "Valgt") motiv · Apple Vision lokalt")
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            return SubjectAnalysis(guidance: nil,message: "Motivgenkendelse ikke tilgængelig · hele billedet bruges")
        }
    }

    private static func selectInstance(_ buffer: CVPixelBuffer, available: IndexSet, point: Point?) throws -> Int? {
        CVPixelBufferLockBaseAddress(buffer,.readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer,.readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw StencilError.invalidImage }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        if let point {
            guard point.x.isFinite,point.y.isFinite,(0...1).contains(point.x),(0...1).contains(point.y) else { return nil }
            let x = min(w-1,Int(point.x*Double(w))), y = min(h-1,Int(point.y*Double(h)))
            let id = Int(bytes[y*stride+x])
            return available.contains(id) ? id : nil
        }
        var counts = [Int](repeating: 0,count: 256)
        for y in 0..<h {
            try Task.checkCancellation()
            for x in 0..<w { counts[Int(bytes[y*stride+x])] += 1 }
        }
        // Largest instance is stable and transparent; a tap can select any other.
        return available.sorted().max { counts[$0] == counts[$1] ? $0 > $1 : counts[$0] < counts[$1] }
    }
}
#endif
