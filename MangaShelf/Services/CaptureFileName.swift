import Foundation

nonisolated enum CaptureFileName {
    /// Prefer the current chapter URL over the title, which may contain a series number.
    static func chapterSuggestion(url: URL?, title: String?) -> String {
        let pattern = #"(?i)(?:^|[^a-z])(?:chapter|chap|chương|chuong)[\s_/#:=\-]*(\d+(?:[.,]\d+)?)"#
        let regex = try! NSRegularExpression(pattern: pattern)
        for candidate in [url?.path.removingPercentEncoding, url?.query, title].compactMap({ $0 }) {
            let range = NSRange(candidate.startIndex..., in: candidate)
            if let match = regex.firstMatch(in: candidate, range: range),
               let number = Range(match.range(at: 1), in: candidate) {
                return "Chapter " + candidate[number].replacingOccurrences(of: ",", with: ".")
            }
        }
        return "Chapter"
    }

    static func filename(_ input: String) throws -> String {
        var stem = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if stem.lowercased().hasSuffix(".pdf") { stem = String(stem.dropLast(4)) }
        stem = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stem.isEmpty, !stem.hasPrefix("."), stem.utf8.count <= 200,
              stem.rangeOfCharacter(from: .controlCharacters) == nil,
              !stem.contains(where: { "/\\:".contains($0) }) else {
            throw WebCaptureError.invalidFilename
        }
        return stem + ".pdf"
    }

    static func suggested(_ title: String) -> String {
        let clean = title.components(separatedBy: CharacterSet(charactersIn: "/\\:").union(.controlCharacters))
            .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        var stem = String(clean.prefix(100))
        while stem.utf8.count > 180 { stem.removeLast() }
        return (try? filename(stem)) ?? "Web Capture.pdf"
    }

    /// Commit by moving a temporary sibling file. moveItem refuses an existing
    /// destination, so even a concurrent filesystem change cannot overwrite a chapter.
    static func write(_ data: Data, filename: String, in folder: URL) throws -> URL {
        let filename = try self.filename(filename)
        let temporary = folder.appendingPathComponent(".capture-\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let stem = String(filename.dropLast(4))
        for number in 1...10_000 {
            let name = number == 1 ? filename : "\(stem) (\(number)).pdf"
            let target = folder.appendingPathComponent(name)
            do {
                try FileManager.default.moveItem(at: temporary, to: target)
                return target
            } catch CocoaError.fileWriteFileExists { continue }
        }
        throw CocoaError(.fileWriteFileExists)
    }
}
