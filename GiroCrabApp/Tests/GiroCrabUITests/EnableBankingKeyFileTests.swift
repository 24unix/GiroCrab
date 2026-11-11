import XCTest
@testable import GiroCrabUI

/// Choosing the downloaded key file fills in key and application ID.
final class EnableBankingKeyFileTests: XCTestCase {
    private let pem = "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASC\n-----END PRIVATE KEY-----\n"

    func testApplicationIDFromTheDownloadedFileName() {
        XCTAssertEqual(EnableBankingKeyFile.applicationID(fromFileName: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee.pem"),
                       "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        // a second download gets a suffix; upper case is normalised
        XCTAssertEqual(EnableBankingKeyFile.applicationID(fromFileName: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE (1).pem"),
                       "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        XCTAssertNil(EnableBankingKeyFile.applicationID(fromFileName: "private.key"))
    }

    func testReadsKeyAndIDAndRejectsOtherFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let keyFile = dir.appendingPathComponent("11111111-2222-4333-8444-555555555555.pem")
        try pem.write(to: keyFile, atomically: true, encoding: .utf8)
        let key = try EnableBankingKeyFile.read(keyFile)
        XCTAssertEqual(key.applicationID, "11111111-2222-4333-8444-555555555555")
        XCTAssertTrue(key.pem.hasPrefix("-----BEGIN PRIVATE KEY-----"))
        // a certificate (public part) or anything else is refused
        let cert = dir.appendingPathComponent("11111111-2222-4333-8444-555555555555.crt")
        try "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n".write(to: cert, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try EnableBankingKeyFile.read(cert))
    }
}
