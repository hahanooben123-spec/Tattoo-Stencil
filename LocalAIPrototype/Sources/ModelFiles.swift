import Foundation
import CryptoKit

enum ModelFiles {
    // Pinned upstream ModelZoo.swift hashes; VAE from the official hash catalog.
    // These are the three dependencies of the 6-bit distilled checkpoint.
    static let hashes: [String:String] = [
        "flux_2_klein_4b_q6p.ckpt":"ba42005a6d4e6c48430787db98ae8913aced4654682b59d0d0f1d9ccf820fe30",
        "qwen_3_4b_q8p.ckpt":"a24e3f832917aafe7f6186e6dfb96ab19a4a0729cdf60a875b5da20024333350",
        "flux_2_vae_f16.ckpt":"48369d4b1495aec3df0579591f4bf9c199a73cc288130df2359c4a173c5ae864"
    ]
    struct VerifiedFile: Codable {
        let sha256: String
        let size: UInt64
        let modified: Date
    }
    static func folder() throws -> URL {
        var url = try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,
            appropriateFor:nil,create:true).appendingPathComponent("LocalStencilModels",isDirectory:true)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        return url
    }
    static func preflightStorage() throws {
        let values = try folder().resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage, available >= 12_000_000_000 else {
            throw LocalAIError.storage
        }
    }
    static func isVerified() throws -> Bool {
        let root = try folder()
        guard let data = try? Data(contentsOf:root.appendingPathComponent("verified-model.json")),
              let files = try? JSONDecoder().decode([String:VerifiedFile].self,from:data) else { return false }
        for (file,hash) in hashes {
            guard let verified = files[file], verified.sha256 == hash,
                  let attributes = try? FileManager.default.attributesOfItem(atPath:root.appendingPathComponent(file).path),
                  let modified = attributes[.modificationDate] as? Date,
                  let size = attributes[.size] as? NSNumber,
                  size.uint64Value == verified.size, modified == verified.modified else { return false }
        }
        return true
    }
    static func verifyAndRecord(progress: @escaping @Sendable (Double,String) -> Void) throws {
        let root = try folder()
        var verified: [String:VerifiedFile] = [:]
        for (index,file) in hashes.keys.sorted().enumerated() {
            try Task.checkCancellation()
            progress(Double(index)/Double(hashes.count),"SHA-256-kontrol · \(index+1)/\(hashes.count)")
            let url = root.appendingPathComponent(file)
            let handle = try FileHandle(forReadingFrom:url)
            defer { try? handle.close() }
            var digest = SHA256()
            while let chunk = try handle.read(upToCount:4*1024*1024), !chunk.isEmpty {
                try Task.checkCancellation()
                digest.update(data:chunk)
            }
            let hash = digest.finalize().map { String(format:"%02x",$0) }.joined()
            guard hash == hashes[file] else {
                // Only this app's known model-cache file is removed, so the next
                // explicit install can repair it instead of reusing a corrupt file.
                try? FileManager.default.removeItem(at:url)
                try? FileManager.default.removeItem(at:root.appendingPathComponent("verified-model.json"))
                throw LocalAIError.checksum(file)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath:url.path)
            guard let size = attributes[.size] as? NSNumber, let date = attributes[.modificationDate] as? Date else {
                throw LocalAIError.checksum(file)
            }
            verified[file] = VerifiedFile(sha256:hash,size:size.uint64Value,modified:date)
        }
        try Task.checkCancellation()
        try JSONEncoder().encode(verified).write(to:root.appendingPathComponent("verified-model.json"),options:.atomic)
    }
}
