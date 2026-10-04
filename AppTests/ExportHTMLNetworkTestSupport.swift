import Foundation
import XCTest

struct ExportHTTPProxyClient {
    let port: UInt16

    init() throws {
        guard let value = ProcessInfo.processInfo.environment["PLAINSONG_EXPORT_TEST_PROXY_PORT"],
              let port = UInt16(value)
        else { throw XCTSkip("Run Scripts/run-export-html-hosted-tests.sh for the external loopback recorder") }
        self.port = port
    }

    func requests() async throws -> [String] {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/records"))
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try JSONDecoder().decode([String].self, from: data)
    }
}
