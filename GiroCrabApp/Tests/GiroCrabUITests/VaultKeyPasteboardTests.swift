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
    }

    /// Transient would keep the key off Universal Clipboard, the only way to the other device (#1138).
    func testKeyIsNotMarkedTransient() {
        let pb = scratchPasteboard()
        defer { pb.releaseGlobally() }
        VaultKeyManager.copyKeyToPasteboard("c2VjcmV0", pasteboard: pb)
        XCTAssertFalse((pb.types?.map(\.rawValue) ?? []).contains("org.nspasteboard.TransientType"))
    }

    func testPlainTextIsTakenOnlyWhenItIsAKey() {
        let pb = scratchPasteboard()
        defer { pb.releaseGlobally() }
        let key = Data(repeating: 7, count: 32).base64EncodedString()
        pb.clearContents()
        pb.setString(" \(key)\n", forType: .string)
        XCTAssertEqual(VaultKeyManager.keyFromPasteboard(pb), key)
        pb.clearContents()
        pb.setString("Einkaufsliste", forType: .string)
        XCTAssertNil(VaultKeyManager.keyFromPasteboard(pb))
    }

    func testNothingToReadFromAnEmptyPasteboard() {
        let pb = scratchPasteboard()
        defer { pb.releaseGlobally() }
        XCTAssertNil(VaultKeyManager.keyFromPasteboard(pb))
    }
}
#endif
