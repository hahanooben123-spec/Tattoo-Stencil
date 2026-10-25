import Foundation
import Security
import CryptoKit
import ImageIO
import UIKit
import StencilCore

private final class PinnedPCSession: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    let pairing: PCPairing
    init(_ pairing: PCPairing) { self.pairing = pairing }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == URL(string: pairing.url)?.host,
              let trust = challenge.protectionSpace.serverTrust,
              let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let certificate = certificates.first
        else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        let digest = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x",$0) }.joined()
        guard digest == pairing.fingerprint else { completionHandler(.cancelAuthenticationChallenge,nil); return }
        completionHandler(.useCredential,URLCredential(trust: trust))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct PCJob: Decodable, Sendable {
    let id: String
    let status: String
    let progress: Double
    let message: String
}
struct PCStencilFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class PCStencilClient: @unchecked Sendable {
    private let pairing: PCPairing
    private let delegate: PinnedPCSession
    private let session: URLSession
    init(_ pairing: PCPairing) throws {
        try pairing.validate()
        self.pairing = pairing
        delegate = PinnedPCSession(pairing)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.urlCache = nil
        session = URLSession(configuration: config,delegate: delegate,delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    private func request(_ path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        guard let url = URL(string: pairing.url + path) else { throw PCPairingError.invalid }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body
        request.setValue("Bearer " + pairing.token,forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue("application/octet-stream",forHTTPHeaderField: "Content-Type") }
        let (data,response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String:Any])?["detail"] as? String
            throw PCStencilFailure(message: detail ?? "PC'en kunne ikke svare. Kontrollér forbindelsen og parringskoden.")
        }
        guard data.count <= 20*1024*1024 else { throw PCStencilFailure(message: "Svaret fra PC'en er for stort.") }
        return data
    }
    func check() async throws { _ = try await request("/v1/health") }
    func submit(_ data: Data) async throws -> PCJob {
        try JSONDecoder().decode(PCJob.self,from: await request("/v1/jobs",method: "POST",body: data))
    }
    func status(_ id: String) async throws -> PCJob {
        try validateID(id)
        return try JSONDecoder().decode(PCJob.self,from: await request("/v1/jobs/" + id))
    }
    func image(_ id: String) async throws -> Data { try validateID(id); return try await request("/v1/jobs/" + id + "/image") }
    func cancel(_ id: String) async { guard (try? validateID(id)) != nil else { return }; _ = try? await request("/v1/jobs/"+id,method: "DELETE") }
    private func validateID(_ id: String) throws {
        guard id.count == 32, id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw PCPairingError.invalid }
    }
    static func upload(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData,nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source,0,[
                kCGImageSourceCreateThumbnailFromImageAlways:true,
                kCGImageSourceCreateThumbnailWithTransform:true,
                kCGImageSourceThumbnailMaxPixelSize:1600] as CFDictionary),
              let png = UIImage(cgImage:image).pngData() else { throw ImportError.allocation }
        return png
    }
}

enum PCConnectionStore {
    private static let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,
        kSecAttrService as String:"StencilStudio.PC",kSecAttrAccount as String:"pairing"]
    static func load() -> PCPairing? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary,&result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? PCPairing(data:data)
    }
    static func save(_ pairing: PCPairing) throws {
        let data = try JSONEncoder().encode(pairing)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let update = SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        let status = update == errSecItemNotFound ? SecItemAdd(attributes as CFDictionary,nil) : update
        guard status == errSecSuccess else { throw PCStencilFailure(message:"Parringen kunne ikke gemmes sikkert.") }
    }
    static func remove() { SecItemDelete(query as CFDictionary) }
}
