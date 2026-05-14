//
//  BookDataService.swift
//  MangaShelf
//

import Foundation
import SwiftData

struct BookSeriesData: Codable {
    var note: String?
    var url: String?
    var currentChapterIndex: Int = 0
    var lastReadDate: Date?
    var bookmarks: [BookmarkEntry] = []
    var chapterProgress: [String: Int] = [:]

    struct BookmarkEntry: Codable {
        var chapterIndex: Int
        var note: String
        var color: String
    }
}

final class BookDataService {

    static let shared = BookDataService()
    private init() {}

    private static let directoryName = ".mangashelf"
    private static let fileName = "data.json"

    // MARK: - Save (resolves bookmark internally)

    @MainActor
    func save(book: Book) async {
        guard book.isSeries, let folderName = book.folderName else { return }
        guard let bookmarkData = UserDefaults.standard.data(forKey: book.bookmarkKey),
              let (rootURL, _) = try? LocalFileService.shared.resolveBookmark(bookmarkData),
              rootURL.startAccessingSecurityScopedResource() else { return }
        defer { rootURL.stopAccessingSecurityScopedResource() }

        let seriesFolder = rootURL.appendingPathComponent(folderName)
        await save(book: book, seriesFolderURL: seriesFolder)
    }

    // MARK: - Save (pre-resolved URL, used by ReaderViewModel)

    @MainActor
    func save(book: Book, seriesFolderURL: URL) async {
        guard book.isSeries else { return }

        let data = buildData(from: book)
        let dataDir = seriesFolderURL.appendingPathComponent(Self.directoryName)
        let fileURL = dataDir.appendingPathComponent(Self.fileName)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let jsonData = try? encoder.encode(data) else { return }

        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            if !fm.fileExists(atPath: dataDir.path) {
                try? fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
            }
            try? jsonData.write(to: fileURL, options: .atomic)
        }.value
    }

    // MARK: - Load (from folder URL)

    func load(seriesFolderURL: URL) async -> BookSeriesData? {
        let fileURL = seriesFolderURL
            .appendingPathComponent(Self.directoryName)
            .appendingPathComponent(Self.fileName)

        let readResult = await Task.detached(priority: .userInitiated) {
            try? Data(contentsOf: fileURL)
        }.value
        guard let jsonData = readResult else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BookSeriesData.self, from: jsonData)
    }

    // MARK: - Restore (merges disk data into SwiftData when SwiftData fields are empty)

    @MainActor
    func restoreIfNeeded(book: Book, modelContext: ModelContext) async {
        guard book.isSeries, let folderName = book.folderName else { return }
        guard let bookmarkData = UserDefaults.standard.data(forKey: book.bookmarkKey),
              let (rootURL, _) = try? LocalFileService.shared.resolveBookmark(bookmarkData),
              rootURL.startAccessingSecurityScopedResource() else { return }
        defer { rootURL.stopAccessingSecurityScopedResource() }

        let seriesFolder = rootURL.appendingPathComponent(folderName)
        guard let seriesData = await load(seriesFolderURL: seriesFolder) else { return }

        var changed = false

        if (book.seriesNote ?? "").isEmpty, let note = seriesData.note, !note.isEmpty {
            book.seriesNote = note
            changed = true
        }

        if (book.seriesURL ?? "").isEmpty, let url = seriesData.url, !url.isEmpty {
            book.seriesURL = url
            changed = true
        }

        for chapter in book.sortedChapters {
            if let savedPage = seriesData.chapterProgress[chapter.filename],
               chapter.lastReadPage == 0, savedPage > 0 {
                chapter.lastReadPage = savedPage
                changed = true
            }
        }

        if book.currentChapterIndex == 0, seriesData.currentChapterIndex > 0 {
            let maxIndex = max(0, (book.chapters?.count ?? 1) - 1)
            book.currentChapterIndex = min(seriesData.currentChapterIndex, maxIndex)
            changed = true
        }

        if (book.bookmarks ?? []).isEmpty, !seriesData.bookmarks.isEmpty {
            for entry in seriesData.bookmarks {
                let bookmark = Bookmark(
                    chapterIndex: entry.chapterIndex,
                    note: entry.note,
                    colorName: entry.color
                )
                bookmark.book = book
                modelContext.insert(bookmark)
            }
            changed = true
        }

        if book.lastReadDate == nil, let date = seriesData.lastReadDate {
            book.lastReadDate = date
            changed = true
        }

        if changed {
            try? modelContext.save()
        }
    }

    // MARK: - Private

    @MainActor
    private func buildData(from book: Book) -> BookSeriesData {
        var data = BookSeriesData(
            currentChapterIndex: book.currentChapterIndex,
            lastReadDate: book.lastReadDate
        )
        data.note = book.seriesNote
        data.url = book.seriesURL

        for chapter in book.sortedChapters where chapter.lastReadPage > 0 {
            data.chapterProgress[chapter.filename] = chapter.lastReadPage
        }

        data.bookmarks = (book.bookmarks ?? []).map { bm in
            BookSeriesData.BookmarkEntry(
                chapterIndex: bm.chapterIndex,
                note: bm.note,
                color: bm.colorName
            )
        }

        return data
    }
}
