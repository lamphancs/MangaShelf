import Foundation

/// Atomically stages bytes, then exclusively moves them to the first available name.
/// Callers supply their existing suffix convention; existing files are never replaced.
nonisolated enum UniqueFileWriter {
    static func write(_ data: Data, in folder: URL, filename: (Int) -> String) throws -> URL {
        let temporary = folder.appendingPathComponent(".capture-\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporary) }
        for number in 1...10_000 {
            let target = folder.appendingPathComponent(filename(number))
            do {
                try FileManager.default.moveItem(at: temporary, to: target)
                return target
            } catch CocoaError.fileWriteFileExists { continue }
        }
        throw CocoaError(.fileWriteFileExists)
    }
}
