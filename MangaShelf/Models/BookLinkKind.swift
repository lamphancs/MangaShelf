import Foundation

enum BookLinkKind: String, Identifiable {
    case series, latestChapter, englishSeries, englishLatestChapter
    var id: String { rawValue }
    var isEnglish: Bool { self == .englishSeries || self == .englishLatestChapter }
    var isLatestChapter: Bool { self == .latestChapter || self == .englishLatestChapter }
    var title: String { (isLatestChapter ? "Latest Chapter" : "Series Homepage") + (isEnglish ? " · EN" : " · VN") }
    var addLabel: String { isLatestChapter ? "Add latest chapter link" : "Add series homepage" }
    var sectionTitle: String { isLatestChapter ? "Latest chapter" : "Series homepage" }
    var icon: String { isLatestChapter ? "book.pages.fill" : "house.fill" }
    var numberKeyPath: ReferenceWritableKeyPath<Book, String?> {
        if isEnglish { return \Book.englishLatestChapterNumber }
        return \Book.latestChapterNumber
    }
    var urlKeyPath: ReferenceWritableKeyPath<Book, String?> {
        switch self {
        case .series: \Book.seriesURL
        case .latestChapter: \Book.latestChapterURL
        case .englishSeries: \Book.englishSeriesURL
        case .englishLatestChapter: \Book.englishLatestChapterURL
        }
    }

    nonisolated static func webURL(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isWhitespace }),
              !trimmed.contains("\\") else { return nil }
        let candidate: String
        if trimmed.hasPrefix("//") {
            candidate = "https:" + trimmed
        } else if trimmed.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*:"#, options: .regularExpression) != nil {
            candidate = trimmed
        } else {
            candidate = "https://" + trimmed
        }
        guard let url = URL(string: candidate),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}
