import Foundation
import MediaGenerationKit
import UIKit
import ImageIO

/// One owner and one operation at a time; cancellation is awaited before reuse.
actor LocalAIEngine {
    static let model = "flux_2_klein_4b_q6p.ckpt"
    static let prompt = """
    Make a precise tattoo transfer tracing of the input artwork. Preserve the entire original composition, proportions, eye positions and expression. Keep every existing design element in place, including original lettering, jewelry and ornaments. Pure white paper, very thin black monoline outlines. Dark shapes are empty white shapes bounded by thin lines, including pupils, lashes and eyebrows. Trace visible eyelids, iris, pupil, lips, fingers and object overlaps accurately. Simplify hair into a few flowing strands. Add only a few short dashed guides for broad shadows. No black filled areas, no shading, no crosshatching, no gray, no texture, no signature. Do not redraw or beautify the subject. One sparse stencil only.
    """
    private var occupied = false
    private var environment: MediaGenerationEnvironment {
        MediaGenerationEnvironment.default
    }
    private func configure() throws {
        let folder = try ModelFiles.folder()
        environment.externalUrls = [folder]
        // This bounds the optional weights cache, not total GPU/app memory.
        environment.maxTotalWeightsCacheSize = 0
    }
    func isInstalled() throws -> Bool {
        try configure()
        return try ModelFiles.isVerified()
    }
    func install(progress: @escaping @Sendable (Double,String) -> Void) async throws {
        guard !occupied else { throw LocalAIError.busy }
        occupied = true
        defer { occupied = false }
        try configure()
        try ModelFiles.preflightStorage()
        // Explicit installation is the only operation permitted to download weights.
        _ = try await environment.ensure(Self.model) { state in
            switch state {
            case .resolving: progress(0,"Finder model")
            case .verifying(_,let index,let total):
                progress(Double(index-1)/Double(max(total,1)),"Kontrollerer modelfiler · \(index)/\(total)")
            case .downloading(_,let index,let total,let bytes,let expected):
                let fraction = expected > 0 ? min(1,Double(bytes)/Double(expected)) : 0
                progress((Double(index-1)+fraction)/Double(max(total,1)),"Henter model · fil \(index)/\(total)")
            }
        }
        try Task.checkCancellation()
        // Independently hash each pinned dependency, including files >300 MB.
        // A cached "ready" flag is never sufficient for first installation.
        try ModelFiles.verifyAndRecord(progress:progress)
    }
    func generate(data: Data, progress: @escaping @Sendable (Double,String) -> Void) async throws -> LocalAIOutput {
        guard !occupied else { throw LocalAIError.busy }
        occupied = true
        defer { occupied = false }
        try configure()
        guard try ModelFiles.isVerified() else { throw LocalAIError.notInstalled }
        guard ProcessInfo.processInfo.physicalMemory >= 7_500_000_000 else { throw LocalAIError.memory }
        let start = Date()
        progress(0.02,"Forbereder reference på iPad")
        let input = try LocalAIImages.prepare(data)
        try Task.checkCancellation()
        // The pinned checkpoint and matching bundled preset both resolve locally.
        // No remote/cloud backend or ensure/download is used here.
        var pipeline = try await MediaGenerationPipeline.fromPretrained(Self.model,backend:.local)
        pipeline.configuration.width = input.canvasWidth
        pipeline.configuration.height = input.canvasHeight
        pipeline.configuration.seed = 42
        pipeline.configuration.steps = 4
        pipeline.configuration.guidanceScale = 1
        pipeline.configuration.strength = 1
        pipeline.configuration.batchCount = 1
        pipeline.configuration.batchSize = 1
        pipeline.configuration.hiresFix = false
        pipeline.configuration.tiledDecoding = true
        pipeline.configuration.decodingTileWidth = 256
        pipeline.configuration.decodingTileHeight = 256
        pipeline.configuration.decodingTileOverlap = 64
        pipeline.configuration.tiledDiffusion = false
        pipeline.configuration.teaCache = false
        let results = try await pipeline.generate(prompt:Self.prompt,negativePrompt:"",
            inputs:[MediaGenerationPipeline.data(input.png)]) { state in
            switch state {
            case .encodingText: progress(0.08,"Læser stencilinstruktion")
            case .encodingInputs: progress(0.15,"Analyserer reference")
            case .generating(let step,let total): progress(0.2+0.65*Double(step)/Double(max(total,1)),"Danner stencil · \(step)/\(total)")
            case .decoding: progress(0.9,"Tegner resultat")
            case .postprocessing: progress(0.95,"Gør stregerne sorte")
            case .cancelling, .cancelled: progress(0,"Afbryder …")
            default: break
            }
        }
        try Task.checkCancellation()
        guard let result = results.first else { throw LocalAIError.noImage }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("AI-result-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at:temporary) }
        try result.write(to:temporary,type:.png)
        guard let source = CGImageSourceCreateWithURL(temporary as CFURL,nil),
              let raster = CGImageSourceCreateImageAtIndex(source,0,nil),
              raster.width == input.canvasWidth, raster.height == input.canvasHeight else {
            throw LocalAIError.dimensions
        }
        let stencil = try LocalAIImages.binary(raster, crop:input.contentRect)
        return LocalAIOutput(reference:input.reference,stencil:stencil,seconds:Date().timeIntervalSince(start))
    }
}

struct LocalAIOutput: @unchecked Sendable {
    let reference: CGImage
    let stencil: CGImage
    let seconds: Double
}
enum LocalAIError: LocalizedError {
    case busy, notInstalled, memory, storage, noImage, dimensions, invalidImage, checksum(String)
    var errorDescription: String? {
        switch self {
        case .busy: return "En behandling afsluttes stadig. Vent et øjeblik."
        case .notInstalled: return "Hent og kontrollér modellen først."
        case .memory: return "Prototypen kræver en iPad med mindst 8 GB RAM."
        case .storage: return "Der skal være mindst 12 GB ledig plads til modellen."
        case .noImage: return "Modellen leverede ikke et billede."
        case .dimensions: return "Modellen ændrede billedets størrelse. Resultatet blev afvist."
        case .invalidImage: return "Billedet kunne ikke åbnes. Vælg et andet referencebillede."
        case .checksum(let file): return "Modelfilen \(file) bestod ikke kontrollen. Hent modellen igen."
        }
    }
}
