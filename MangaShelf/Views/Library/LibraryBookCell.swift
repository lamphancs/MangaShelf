import SwiftData
import SwiftUI

nonisolated struct LibrarySeriesSummary: Sendable {
    var label = " "
    var language = 0.0
    var largestLanguage = 0.0
    var latestEnglish: Double?
    var latestVietnamese: Double?
}

nonisolated struct LibrarySummaryKey: Hashable {
    let bookID: UUID
    let signature: String?
    let chapterIndex: Int
    let needsChapterNumbers: Bool
}

/// Cells share small values across grid/list switches and scrolling. Each cache miss
/// reads committed chapter rows in its own context, away from the UI's model context.
actor LibrarySummaryStore {
    private var entries: [UUID: (LibrarySummaryKey, LibrarySeriesSummary)] = [:]

    func summary(for key: LibrarySummaryKey, in container: ModelContainer) throws -> LibrarySeriesSummary {
        if let (savedKey, summary) = entries[key.bookID], savedKey == key { return summary }
        try Task.checkCancellation()
        let context = ModelContext(container)
        let id = key.bookID
        var query = FetchDescriptor<Chapter>(predicate: #Predicate { $0.book?.id == id },
                                             sortBy: [SortDescriptor(\.sortOrder)])
        var result = LibrarySeriesSummary()
        if key.chapterIndex == 0 && !key.needsChapterNumbers {
            result.label = "\(try context.fetchCount(query)) chapters"
        } else {
            query.propertiesToFetch = [\.filename, \.sortOrder]
            let chapters = try context.fetch(query)
            result = LibrarySeriesSummary.progress(in: chapters, index: key.chapterIndex)
            if key.needsChapterNumbers {
                result.latestEnglish = Self.latest(in: chapters, english: true)
                result.latestVietnamese = Self.latest(in: chapters, english: false)
            }
        }
        entries[id] = (key, result)
        return result
    }

    static func latest(in chapters: [Chapter], english: Bool) -> Double? {
        var latest: Double?
        var found = false
        for chapter in chapters where chapter.isEnglish == english {
            found = true
            if let number = ChapterUpdateSource.chapterNumber(chapter.displayName) ?? chapter.chapterNumber {
                latest = max(latest ?? number, number)
            }
        }
        return found ? latest : -1
    }
}

struct LibraryBookCell: View {
    @Environment(\.modelContext) private var context
    let book: Book
    let mode: LibraryViewMode
    let store: LibrarySummaryStore
    let onlineEnglish: Double?
    let onlineVietnamese: Double?
    let onTap: () -> Void
    let onRename: () -> Void
    let onSetCover: () -> Void
    @State private var summary = LibrarySeriesSummary()

    var body: some View {
        let key = LibrarySummaryKey(bookID: book.id, signature: book.folderSignature,
                                    chapterIndex: book.currentChapterIndex,
                                    needsChapterNumbers: onlineEnglish != nil || onlineVietnamese != nil)
        let updated = isNewer(onlineEnglish, than: summary.latestEnglish)
            || isNewer(onlineVietnamese, than: summary.latestVietnamese)
        Group {
            switch mode {
            case .grid:
                BookCardView(book: book, hasUpdate: updated, progress: summary,
                             onTap: onTap, onRename: onRename, onSetCover: onSetCover)
            case .list:
                BookRowView(book: book, hasUpdate: updated, progress: summary,
                            onTap: onTap, onRename: onRename, onSetCover: onSetCover)
            }
        }
        .task(id: key) {
            guard book.isSeries,
                  let value = try? await store.summary(for: key, in: context.container),
                  !Task.isCancelled else { return }
            summary = value
        }
    }

    private func isNewer(_ remote: Double?, than local: Double?) -> Bool {
        guard let remote, let local else { return false }
        return remote > local
    }
}
