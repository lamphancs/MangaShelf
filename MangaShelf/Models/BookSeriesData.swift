import Foundation

struct BookSeriesData: Codable {
    var note: String?
    var url: String?
    var englishLatestChapterURL: String?
    var englishLatestChapterNumber: String?
    var englishSeriesURL: String?
    var latestChapterURL: String?
    var latestChapterNumber: String?
    var currentChapterIndex: Int = 0
    var lastReadDate: Date?
    var bookmarks: [BookmarkEntry] = []
    var chapterProgress: [String: Int] = [:]
    /// Exact scroll offset (content points) keyed by chapter filename, for pixel-accurate
    /// reading-position restore across reinstalls.
    var chapterOffsets: [String: Double] = [:]
    /// Cached PDF page count keyed by chapter filename. Lets `ImportService.createSeries`
    /// rebuild rows without reopening every PDF via PDFKit on every scan.
    var chapterPageCounts: [String: Int] = [:]
    var dateAdded: Date?
    var title: String?

    struct BookmarkEntry: Codable {
        var chapterIndex: Int
        var note: String
        var color: String
    }

    init(
        currentChapterIndex: Int = 0,
        lastReadDate: Date? = nil
    ) {
        self.currentChapterIndex = currentChapterIndex
        self.lastReadDate = lastReadDate
    }

    private enum CodingKeys: String, CodingKey {
        case latestChapterURL, latestChapterNumber, englishSeriesURL, englishLatestChapterURL, englishLatestChapterNumber
        case note, url, currentChapterIndex, lastReadDate, bookmarks
        case chapterProgress, chapterOffsets, chapterPageCounts, dateAdded, title
    }

    /// Hand-rolled decoder so older `.mangashelf/data.json` files (written before fields
    /// like `chapterPageCounts` existed) decode successfully and use the property defaults
    /// for missing keys. Swift's auto-synthesized decoder ignores `= default` for
    /// non-Optional properties and would otherwise throw — silently nuking the file's
    /// bookmarks/progress on read.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        englishSeriesURL = try c.decodeIfPresent(String.self, forKey: .englishSeriesURL)
        englishLatestChapterURL = try c.decodeIfPresent(String.self, forKey: .englishLatestChapterURL)
        englishLatestChapterNumber = try c.decodeIfPresent(String.self, forKey: .englishLatestChapterNumber)
        SeriesLinks.migrateEnglish(homepage: &englishSeriesURL, latest: &englishLatestChapterURL, number: &englishLatestChapterNumber)
        latestChapterURL = try c.decodeIfPresent(String.self, forKey: .latestChapterURL)
        latestChapterNumber = try c.decodeIfPresent(String.self, forKey: .latestChapterNumber)
        currentChapterIndex = try c.decodeIfPresent(Int.self, forKey: .currentChapterIndex) ?? 0
        lastReadDate = try c.decodeIfPresent(Date.self, forKey: .lastReadDate)
        bookmarks = try c.decodeIfPresent([BookmarkEntry].self, forKey: .bookmarks) ?? []
        chapterProgress = try c.decodeIfPresent([String: Int].self, forKey: .chapterProgress) ?? [:]
        chapterOffsets = try c.decodeIfPresent([String: Double].self, forKey: .chapterOffsets) ?? [:]
        chapterPageCounts = try c.decodeIfPresent([String: Int].self, forKey: .chapterPageCounts) ?? [:]
        dateAdded = try c.decodeIfPresent(Date.self, forKey: .dateAdded)
        title = try c.decodeIfPresent(String.self, forKey: .title)
    }
}
