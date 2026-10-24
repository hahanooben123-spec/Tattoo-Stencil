import Foundation

/// Three artist-facing controls map to coherent algorithm parameters, rather than
/// exposing every threshold. Image-relative defaults work across source resolutions.
public struct StencilControls: Sendable, Equatable {
    public var detail: Float = 0.45
    public var outlineEmphasis: Float = 0.8
    public var shadows: Float = 0.3
    public init() {}
    public func parameters(width: Int, height: Int) throws -> Parameters {
        guard width > 1, height > 1, width <= Int.max / height,
              [detail,outlineEmphasis,shadows].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw StencilError.invalidParameters }
        let unit = max(1,Double(max(width,height))/900)
        var p = Parameters()
        p.detail = detail; p.outlineEmphasis = outlineEmphasis
        p.noiseReduction = 0.65-0.3*detail; p.textureSuppression = 0.95-0.4*detail
        p.edgeThreshold = 0.19-0.08*detail
        p.minimumContourLength = (12+Double(1-detail)*24)*unit
        p.minimumRegionArea = max(64,Int(Double(width*height)*(0.0002+Double(1-shadows)*0.0008)))
        p.minimumHighlightArea = p.minimumRegionArea
        p.shadowSpacing = min(16, (3+Double(1-shadows)*3)*unit)
        p.tonalLevels = 3+Int((shadows*3).rounded())
        p.shadowSensitivity = shadows*0.8
        p.regionCoherence = 0.8; p.shadowsEnabled = shadows > 0.01
        return p
    }
}
