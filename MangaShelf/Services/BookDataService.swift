//
//  BookDataService.swift
//  MangaShelf
//

import Foundation
import SwiftData
import UIKit

struct BookSeriesData: Codable {
    var note: String?
    var url: String?
    var currentChapterIndex: Int = 0
    var lastReadDate: Date?
    var bookmarks: [BookmarkEntry] = []
    var chapterProgress: [String: Int] = [:]
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
        case note, url, currentChapterIndex, lastReadDate, bookmarks
        case chapterProgress, chapterPageCounts, dateAdded, title
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
        currentChapterIndex = try c.decodeIfPresent(Int.self, forKey: .currentChapterIndex) ?? 0
        lastReadDate = try c.decodeIfPresent(Date.self, forKey: .lastReadDate)
        bookmarks = try c.decodeIfPresent([BookmarkEntry].self, forKey: .bookmarks) ?? []
        chapterProgress = try c.decodeIfPresent([String: Int].self, forKey: .chapterProgress) ?? [:]
        chapterPageCounts = try c.decodeIfPresent([String: Int].self, forKey: .chapterPageCounts) ?? [:]
        dateAdded = try c.decodeIfPresent(Date.self, forKey: .dateAdded)
        title = try c.decodeIfPresent(String.self, forKey: .title)
    }
}

final class BookDataService {

    static let shared = BookDataService()
    private init() {}

    private static let directoryName = ".mangashelf"
    private static let dataFileName = "data.json"
    private static let coverFileName = "cover.jpg"

    // MARK: - Path Helpers

    /// URL of the `.mangashelf` directory inside a series folder.
    static func seriesDataDirectory(in seriesFolderURL: URL) -> URL {
        seriesFolderURL.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// URL of the portable cover image inside a series folder.
    static func coverImageURL(in seriesFolderURL: URL) -> URL {
        seriesDataDirectory(in: seriesFolderURL).appendingPathComponent(coverFileName)
    }

    /// URL of the metadata JSON inside a series folder.
    static func dataFileURL(in seriesFolderURL: URL) -> URL {
        seriesDataDirectory(in: seriesFolderURL).appendingPathComponent(dataFileName)
    }

    /// Whether a custom cover currently exists inside a series folder.
    static func hasCoverImage(in seriesFolderURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: coverImageURL(in: seriesFolderURL).path)
    }

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
        let dataDir = Self.seriesDataDirectory(in: seriesFolderURL)
        let fileURL = Self.dataFileURL(in: seriesFolderURL)

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
        let fileURL = Self.dataFileURL(in: seriesFolderURL)

        let readResult = await Task.detached(priority: .userInitiated) {
            try? Data(contentsOf: fileURL)
        }.value
        guard let jsonData = readResult else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BookSeriesData.self, from: jsonData)
    }

    // MARK: - Cover Image (folder-side)

    /// Writes a custom cover JPEG into `<seriesFolderURL>/.mangashelf/cover.jpg` atomically.
    func saveCoverImage(jpegData: Data, seriesFolderURL: URL) async -> Bool {
        let dataDir = Self.seriesDataDirectory(in: seriesFolderURL)
        let coverURL = Self.coverImageURL(in: seriesFolderURL)

        return await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            if !fm.fileExists(atPath: dataDir.path) {
                try? fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
            }
            do {
                try jpegData.write(to: coverURL, options: .atomic)
                return true
            } catch {
                return false
            }
        }.value
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

    // MARK: - One-time Migration: App Data → Series Folders

    /// Writes every existing series book's metadata into its folder's `.mangashelf/data.json`
    /// and relocates any app-side custom cover into `.mangashelf/cover.jpg`.
    /// Idempotent and gated by `StorageKey.folderDataMigrated`.
    @MainActor
    func migrateAppDataToFolders(modelContext: ModelContext) async {
        guard !UserDefaults.standard.bool(forKey: StorageKey.folderDataMigrated) else { return }

        await migrate(bookmarkKey: StorageKey.rootFolderBookmark, isSecret: false, modelContext: modelContext)
        await migrate(bookmarkKey: StorageKey.secretFolderBookmark, isSecret: true, modelContext: modelContext)

        UserDefaults.standard.set(true, forKey: StorageKey.folderDataMigrated)
    }

    @MainActor
    private func migrate(bookmarkKey: String, isSecret: Bool, modelContext: ModelContext) async {
        guard let bookmarkData = UserDefaults.standard.data(forKey: bookmarkKey),
              let (rootURL, _) = try? LocalFileService.shared.resolveBookmark(bookmarkData),
              rootURL.startAccessingSecurityScopedResource() else { return }
        defer { rootURL.stopAccessingSecurityScopedResource() }

        let descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.isSecret == isSecret })
        guard let books = try? modelContext.fetch(descriptor) else { return }

        let thumbnailDir = LocalFileService.shared.thumbnailsDirectory

        for book in books where book.isSeries {
            guard let folderName = book.folderName else { continue }
            let seriesFolder = rootURL.appendingPathComponent(folderName)
            guard FileManager.default.fileExists(atPath: seriesFolder.path) else { continue }

            await save(book: book, seriesFolderURL: seriesFolder)

            if book.hasManualCover {
                let legacyCoverFilename = legacyCustomCoverName(for: folderName)
                let legacyCoverURL = thumbnailDir.appendingPathComponent(legacyCoverFilename)
                let folderCoverURL = Self.coverImageURL(in: seriesFolder)
                let dataDir = Self.seriesDataDirectory(in: seriesFolder)

                await Task.detached(priority: .utility) {
                    let fm = FileManager.default
                    guard fm.fileExists(atPath: legacyCoverURL.path) else { return }
                    guard !fm.fileExists(atPath: folderCoverURL.path) else { return }
                    if !fm.fileExists(atPath: dataDir.path) {
                        try? fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
                    }
                    try? fm.copyItem(at: legacyCoverURL, to: folderCoverURL)
                }.value
            }
        }
    }

    private func legacyCustomCoverName(for identifier: String) -> String {
        let safeId = identifier
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return "custom_\(safeId).jpg"
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
        data.dateAdded = book.dateAdded

        if let folderName = book.folderName {
            let autoTitle = autoDerivedTitle(from: folderName)
            if book.title != autoTitle {
                data.title = book.title
            }
        }

        for chapter in book.sortedChapters {
            if chapter.lastReadPage > 0 {
                data.chapterProgress[chapter.filename] = chapter.lastReadPage
            }
            if chapter.totalPages > 0 {
                data.chapterPageCounts[chapter.filename] = chapter.totalPages
            }
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

    private func autoDerivedTitle(from folderName: String) -> String {
        var title = folderName
        title = title.replacingOccurrences(of: "_", with: " ")
        title = title.replacingOccurrences(of: "-", with: " ")
        title = title.trimmingCharacters(in: .whitespaces)
        title = title.replacingOccurrences(of: "  ", with: " ")
        if title == title.lowercased() || title == title.uppercased() {
            title = title.capitalized
        }
        return title.isEmpty ? "Untitled" : title
    }
}
