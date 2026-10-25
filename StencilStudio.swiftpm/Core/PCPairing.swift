import Foundation

/// QR/pasted pairing payload. Only private IPv4 destinations are accepted.
public struct PCPairing: Codable, Equatable, Sendable {
    public let version: Int
    public let url: String
    public let token: String
    public let fingerprint: String

    public init(data: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: data)
        try validate()
    }
    public func validate() throws {
        guard version == 1, let parts = URLComponents(string: url), parts.scheme == "https",
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty, let host = parts.host, let port = parts.port, (1...65535).contains(port),
              token.count >= 32, token.count <= 128,
              token.utf8.allSatisfy({ (45...122).contains($0) && (CharacterSet.alphanumerics.contains(UnicodeScalar($0)) || $0 == 45 || $0 == 95) }),
              fingerprint.count == 64, fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw PCPairingError.invalid }
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = components.compactMap { UInt8($0) }
        guard components.count == 4, octets.count == 4,
              zip(components,octets).allSatisfy({ String($0.1) == $0.0 }),
              octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1])) ||
              (octets[0] == 192 && octets[1] == 168) || octets[0] == 127
        else { throw PCPairingError.invalid }
    }
}

public enum PCPairingError: LocalizedError {
    case invalid
    public var errorDescription: String? { "Ugyldig parringskode. Brug koden fra Stencil PC på dit private netværk." }
}
