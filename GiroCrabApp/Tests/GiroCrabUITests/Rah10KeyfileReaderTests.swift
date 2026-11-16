import XCTest
import Foundation
import Darwin
@testable import GiroCrabUI

final class Rah10KeyfileReaderTests: XCTestCase {
    func testReadsRegularFileAndRejectsSymlinkFifoAndDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let regular = directory.appendingPathComponent("test.key")
        let expected = Data("invented test data".utf8)
        try expected.write(to: regular)
        XCTAssertEqual(try Rah10KeyfileReader.read(regular), expected)
        let symlink = directory.appendingPathComponent("link.key")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: regular)
        XCTAssertThrowsError(try Rah10KeyfileReader.read(symlink))
        let fifo = directory.appendingPathComponent("fifo.key")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try Rah10KeyfileReader.read(fifo))
        XCTAssertThrowsError(try Rah10KeyfileReader.read(directory))
        XCTAssertThrowsError(try Rah10KeyfileReader.read(URL(string: "https://example.invalid/key")!))
    }

    func testRejectsEmptyAndOversizedFiles() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data().write(to: file)
        XCTAssertThrowsError(try Rah10KeyfileReader.read(file))
        try Data(repeating: 0, count: 4 * 1024 * 1024).write(to: file)
        XCTAssertEqual(try Rah10KeyfileReader.read(file).count, 4 * 1024 * 1024)
        try Data(repeating: 0, count: 4 * 1024 * 1024 + 1).write(to: file)
        XCTAssertThrowsError(try Rah10KeyfileReader.read(file))
    }
}
