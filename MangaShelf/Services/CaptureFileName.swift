import Foundation

nonisolated enum CaptureFileName {
    private static let chapterPattern = try! NSRegularExpression(pattern: #"(?i)(?:^|[^a-z])(?:chapter|chap|chương|chuong)[\s_/#:=\-]*(\d+(?:[.,]\d+)?)"#)

    /// Prefer the current chapter URL over the title, which may contain a series number.
    static func chapterSuggestion(url: URL?, title: String?) -> String {
        for candidate in [url?.path.removingPercentEncoding, url?.query, title].compactMap({ $0 }) {
            let range = NSRange(candidate.startIndex..., in: candidate)
            if let match = chapterPattern.firstMatch(in: candidate, range: range),
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

    /// Commit by moving a temporary sibling file. moveItem refuses an existing
    /// destination, so even a concurrent filesystem change cannot overwrite a chapter.
    static func write(_ data: Data, filename: String, in folder: URL) throws -> URL {
        let filename = try self.filename(filename)
        let stem = String(filename.dropLast(4))
        return try UniqueFileWriter.write(data, in: folder) { number in
            number == 1 ? filename : "\(stem) (\(number)).pdf"
        }
    }
}
