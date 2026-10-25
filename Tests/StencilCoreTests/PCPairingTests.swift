import XCTest
@testable import StencilCore

final class PCPairingTests: XCTestCase {
    func payload(_ url: String, fingerprint: String = String(repeating:"a",count:64)) throws -> Data {
        try JSONSerialization.data(withJSONObject:["version":1,"url":url,"token":String(repeating:"x",count:43),"fingerprint":fingerprint])
    }
    func testOnlyPrivateHTTPSPairingAccepted() throws {
        for host in ["192.168.1.79","10.0.0.2","172.16.0.5","172.31.255.1","127.0.0.1"] {
            let pairing = try PCPairing(data:payload("https://\(host):8765"))
            XCTAssertNoThrow(try PCPairing(data:JSONEncoder().encode(pairing)))
        }
        for url in ["http://192.168.1.79:8765","https://example.com:8765","https://8.8.8.8:8765",
                    "https://172.32.0.1:8765","https://user@192.168.1.79:8765","https://192.168.1.79:8765/path",
                    "https://192.168.1.79:8765?q=token","https://192.168.1.79:8765#fragment","https://192.168.1.79"] {
            XCTAssertThrowsError(try PCPairing(data:payload(url)),url)
        }
        XCTAssertThrowsError(try PCPairing(data:payload("https://192.168.1.79:8765",fingerprint:"bad")))
    }
}
