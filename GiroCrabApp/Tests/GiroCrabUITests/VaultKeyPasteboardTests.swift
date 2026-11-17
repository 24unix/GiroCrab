#if os(macOS)
import AppKit
import XCTest
@testable import GiroCrabUI

@MainActor
final class VaultKeyPasteboardTests: XCTestCase {
    private func scratchPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("de.girocrab.test.\(UUID().uuidString)"))
    }

    func testKeyIsNeverOfferedAsPlainText() {
        let pb = scratchPasteboard()
        defer { pb.releaseGlobally() }
        VaultKeyManager.copyKeyToPasteboard("c2VjcmV0", pasteboard: pb)
        XCTAssertNil(pb.string(forType: .string), "the key must not be readable as text")
        XCTAssertEqual(VaultKeyManager.keyFromPasteboard(pb), "c2VjcmV0")
    }

    func testKeyIsMarkedConcealedForClipboardManagers() {
        let pb = scratchPasteboard()
        defer { pb.releaseGlobally() }
        VaultKeyManager.copyKeyToPasteboard("c2VjcmV0", pasteboard: pb)
        let types = pb.types?.map(\.rawValue) ?? []
        XCTAssertTrue(types.contains("org.nspasteboard.ConcealedType"))
        XCTAssertTrue(types.contains("org.nspasteboard.TransientType"))
    }

    func testNothingToReadFromAnEmptyPasteboard() {
        let pb = scratchPasteboard()
        defer { pb.releaseGlobally() }
        XCTAssertNil(VaultKeyManager.keyFromPasteboard(pb))
    }
}
#endif
