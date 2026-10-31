import Foundation

nonisolated enum SeriesLinks {
    /// Older EN links could point to either a series or an individual chapter.
    static func migrateEnglish(homepage: inout String?, latest: inout String?, number: inout String?) {
        guard let value = homepage, let url = URL(string: value),
              CaptureFileName.chapterSuggestion(url: URL(string: url.lastPathComponent), title: nil) != "Chapter" else { return }
        if latest == nil {
            latest = value
            let suggestion = CaptureFileName.chapterSuggestion(url: url, title: nil)
            number = String(suggestion.dropFirst("Chapter ".count))
        }
        let parent = url.deletingLastPathComponent()
        homepage = parent.pathComponents.count >= 3 ? parent.absoluteString : nil
    }
}
