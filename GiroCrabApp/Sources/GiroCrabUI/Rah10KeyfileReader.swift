import Foundation
import Darwin

/// Open only a bounded regular file, without following a final symlink or
/// blocking on a FIFO. fstat checks the opened descriptor, avoiding a path race.
enum Rah10KeyfileReader {
    enum ReadError: LocalizedError {
        case invalidFile, invalidSize

        var errorDescription: String? {
            switch self {
            case .invalidFile: "Bitte eine reguläre Schlüsseldatei auswählen. Verknüpfungen und Sonderdateien werden nicht unterstützt."
            case .invalidSize: "Die Datei ist leer oder größer als 4 MiB."
            }
        }
    }

    static func read(_ url: URL) throws -> Data {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard url.isFileURL else { throw ReadError.invalidFile }
        let fd = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard fd >= 0 else { throw ReadError.invalidFile }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG else { throw ReadError.invalidFile }
        let limit = 4 * 1024 * 1024
        guard metadata.st_size > 0, metadata.st_size <= limit else { throw ReadError.invalidSize }
        let data: Data
        do { data = try file.read(upToCount: limit + 1) ?? Data() }
        catch { throw ReadError.invalidFile }
        guard !data.isEmpty, data.count <= limit else { throw ReadError.invalidSize }
        return data
    }
}
