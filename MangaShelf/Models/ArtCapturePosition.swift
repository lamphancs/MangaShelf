import Foundation

// MARK: - Capture Position

/// Reader position encoded in a screenshot's filename, e.g. `ch012_p0005_o00123450_en.jpg`.
///
/// `o` offsets are in the same PDF coordinates as saved reading progress. Legacy `y` offsets
/// were raw scroll offsets that also included the chapter's opening artwork page.
nonisolated struct ArtCapturePosition {
    /// Decimal chapters (e.g. 12.5) are written as `ch012.5`.
    let chapterNumber: Double
    /// Zero-based page index.
    let page: Int
    let offset: Double
    /// `nil` for legacy captures, which didn't record the language.
    let isEnglish: Bool?
    var isLegacyOffset = false

    var filename: String {
        var chapterKey = String(format: "%03d", Int(chapterNumber))
        if chapterNumber != chapterNumber.rounded(.down),
           let decimals = String(chapterNumber).split(separator: ".").last {
            chapterKey += "." + decimals
        }
        let base = "ch" + chapterKey + String(format: "_p%04d_o%08d", page + 1, Int(offset * 10))
        return base + (isEnglish == true ? "_en" : "") + ".jpg"
    }

    init(chapterNumber: Double, page: Int, offset: Double, isEnglish: Bool?) {
        self.chapterNumber = chapterNumber
        self.page = page
        self.offset = offset
        self.isEnglish = isEnglish
    }

    /// Offset in saved-progress PDF coordinates, excluding the opening artwork page.
    /// Legacy offsets subtract `legacyArtworkOffset`, the estimated height of that page.
    func pdfOffset(legacyArtworkOffset: Double) -> Double {
        isLegacyOffset ? max(0, offset - legacyArtworkOffset) : offset
    }

    /// Reading order (chapter, page, position), regardless of language.
    func isBefore(_ other: ArtCapturePosition, legacyArtworkOffset: Double) -> Bool {
        if chapterNumber != other.chapterNumber { return chapterNumber < other.chapterNumber }
        if page != other.page { return page < other.page }
        return pdfOffset(legacyArtworkOffset: legacyArtworkOffset)
            < other.pdfOffset(legacyArtworkOffset: legacyArtworkOffset)
    }

    /// A temporary sibling plus exclusive move keeps both concurrent captures.
    func writeJPEG(_ data: Data, in folder: URL) throws -> URL {
        let stem = String(filename.dropLast(4))
        return try UniqueFileWriter.write(data, in: folder) { number in
            number == 1 ? filename : "\(stem)_\(number).jpg"
        }
    }

    init?(filename: String) {
        guard let match = filename.wholeMatch(of: /ch(\d+(?:\.\d+)?)_p(\d+)_([oy])(\d+)(_en)?(?:_\d+)?\.[A-Za-z]+/),
              let chapter = Double(match.1),
              let page = Int(match.2), page > 0,
              let offsetKey = Int(match.4) else { return nil }
        chapterNumber = chapter
        self.page = page - 1
        offset = Double(offsetKey) / 10
        isLegacyOffset = match.3 == "y"
        isEnglish = isLegacyOffset ? nil : match.5 != nil
    }
}
