//
//  ImportService.swift
//  MangaShelf
//
//  Created by Khoa Phan on 4/24/26.
//

import Foundation
import SwiftData

/// Service for scanning a root manga folder and syncing the library.
///
/// The library DB is a derived cache of the on-disk folder contents. Every piece of
/// persistent series data lives inside `<series_folder>/.mangashelf/` (see
/// `BookDataService`). A folder rename/move is therefore a no-op at the data layer:
/// the DB row for the old name is deleted and a fresh row is built from the new
/// folder, with all metadata, progress, bookmarks, and the custom cover restored
/// from the folder.
final class ImportService {

    private let fileService: FileSourceProtocol
    private let thumbnailService: ThumbnailService

    init(
        fileService: FileSourceProtocol = LocalFileService.shared,
        thumbnailService: ThumbnailService = ThumbnailService.shared
    ) {
        self.fileService = fileService
        self.thumbnailService = thumbnailService
    }

    // MARK: - Root Folder Scanning

    /// Scan the configured root folder and sync all series into SwiftData.
    /// - Parameter force: When `true`, every series folder is fully re-synced regardless
    ///   of its cached signature. Used by Settings → Rescan and the first-folder-pick path.
    /// - Returns: Number of series found
    @discardableResult
    func scanRootFolder(modelContext: ModelContext, force: Bool = false) async throws -> Int {
        try await scanFolder(
            bookmarkKey: StorageKey.rootFolderBookmark,
            isSecret: false,
            force: force,
            modelContext: modelContext
        )
    }

    /// Scan the secret folder and sync all secret series into SwiftData.
    @discardableResult
    func scanSecretFolder(modelContext: ModelContext, force: Bool = false) async throws -> Int {
        try await scanFolder(
            bookmarkKey: StorageKey.secretFolderBookmark,
            isSecret: true,
            force: force,
            modelContext: modelContext
        )
    }

    private func scanFolder(bookmarkKey: String, isSecret: Bool, force: Bool, modelContext: ModelContext) async throws -> Int {
        guard let bookmarkData = UserDefaults.standard.data(forKey: bookmarkKey) else {
            return 0
        }

        let (rootURL, isStale) = try LocalFileService.shared.resolveBookmark(bookmarkData)

        guard rootURL.startAccessingSecurityScopedResource() else {
            throw FileServiceError.bookmarkResolutionFailed
        }
        defer { rootURL.stopAccessingSecurityScopedResource() }

        if isStale {
            let refreshed = try? rootURL.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            if let refreshed {
                UserDefaults.standard.set(refreshed, forKey: bookmarkKey)
            }
        }

        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey])

        var seriesFolders: [URL] = []
        var singlePDFs: [URL] = []

        for item in contents {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                let pdfs = (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil))?.filter { $0.pathExtension.lowercased() == "pdf" } ?? []
                if !pdfs.isEmpty {
                    seriesFolders.append(item)
                }
            } else if item.pathExtension.lowercased() == "pdf" {
                singlePDFs.append(item)
            }
        }

        seriesFolders.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        singlePDFs.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        let existingDescriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.isSecret == isSecret })
        let existingBooks = try modelContext.fetch(existingDescriptor)

        let currentSeriesNames = Set(seriesFolders.map { $0.lastPathComponent })
        let currentSingleNames = Set(singlePDFs.map { $0.lastPathComponent })

        // 1) Collapse any pre-existing duplicate rows that older buggy versions left behind
        //    (same `folderName` repeated across rows). One survivor per folder, picked by
        //    user-data richness. After one scan with this code, the invariant
        //    "1 folder = 1 book" holds permanently.
        var seriesByFolder: [String: Book] = [:]
        var singlesByFilename: [String: Book] = [:]
        for book in existingBooks {
            if book.isSeries {
                guard let folderName = book.folderName else {
                    modelContext.delete(book)
                    continue
                }
                if let prior = seriesByFolder[folderName] {
                    let keeper = pickRicherBook(lhs: book, rhs: prior)
                    let loser = keeper === book ? prior : book
                    modelContext.delete(loser)
                    seriesByFolder[folderName] = keeper
                } else {
                    seriesByFolder[folderName] = book
                }
            } else {
                if let prior = singlesByFilename[book.filename] {
                    let keeper = pickRicherBook(lhs: book, rhs: prior)
                    let loser = keeper === book ? prior : book
                    modelContext.delete(loser)
                    singlesByFilename[book.filename] = keeper
                } else {
                    singlesByFilename[book.filename] = book
                }
            }
        }

        // 2) Delete rows whose folder/file is no longer on disk. NEVER touch a row whose
        //    folder is still present — even if loading data.json fails — to avoid the
        //    `nil load + save() overwrite` data-loss bug.
        for (folderName, book) in seriesByFolder where !currentSeriesNames.contains(folderName) {
            modelContext.delete(book)
            seriesByFolder[folderName] = nil
        }
        for (filename, book) in singlesByFilename where !currentSingleNames.contains(filename) {
            if let oldThumb = book.thumbnailPath {
                let oldURL = LocalFileService.shared.urlForThumbnail(named: oldThumb)
                try? FileManager.default.removeItem(at: oldURL)
                thumbnailService.evictCachedImage(for: oldURL)
            }
            modelContext.delete(book)
            singlesByFilename[filename] = nil
        }

        // 3) Sync or create series. Existing rows are updated in place — their bookmarks,
        //    progress, and other relationships stay intact even if data.json is unreadable.
        //    When `force` is false, a matching `folderSignature` means the on-disk folder
        //    is byte-equivalent (mtime + pdf count) to the last scan, so the expensive
        //    `syncChapters` + cover refresh are skipped entirely.
        for folderURL in seriesFolders {
            let folderName = folderURL.lastPathComponent
            if let existing = seriesByFolder[folderName] {
                let signature = folderSignature(at: folderURL)
                if !force, let signature, signature == existing.folderSignature {
                    continue
                }
                try await syncChapters(existing, folderURL: folderURL, modelContext: modelContext)
                await refreshCustomCover(for: existing, folderURL: folderURL)
                existing.folderSignature = signature
            } else {
                try await createSeries(from: folderURL, isSecret: isSecret, modelContext: modelContext)
            }
        }

        // Sync single PDFs.
        for pdfURL in singlePDFs {
            let filename = pdfURL.lastPathComponent
            if let existing = singlesByFilename[filename] {
                if existing.totalPages == 0 {
                    existing.totalPages = thumbnailService.getPageCount(for: pdfURL)
                }
                existing.fileSize = (try? fileService.fileSize(at: pdfURL)) ?? existing.fileSize
            } else {
                try await createSingleBook(from: pdfURL, isSecret: isSecret, modelContext: modelContext)
            }
        }

        try modelContext.save()
        return seriesFolders.count + singlePDFs.count
    }

    // MARK: - Sync Series From Root

    /// Sync a single series by resolving the root folder bookmark
    func syncSeriesFromRoot(_ book: Book, modelContext: ModelContext) async throws {
        guard book.isSeries, let folderName = book.folderName else { return }
        guard let bookmarkData = UserDefaults.standard.data(forKey: book.bookmarkKey) else { return }

        let (rootURL, _) = try LocalFileService.shared.resolveBookmark(bookmarkData)

        guard rootURL.startAccessingSecurityScopedResource() else {
            throw FileServiceError.bookmarkResolutionFailed
        }
        defer { rootURL.stopAccessingSecurityScopedResource() }

        let folderURL = rootURL.appendingPathComponent(folderName)
        try await syncChapters(book, folderURL: folderURL, modelContext: modelContext)
        await refreshCustomCover(for: book, folderURL: folderURL)
        book.folderSignature = folderSignature(at: folderURL)
        try modelContext.save()
    }

    // MARK: - Rename

    func renameBook(_ book: Book, to newTitle: String, modelContext: ModelContext) async throws {
        book.title = newTitle
        try modelContext.save()
        await BookDataService.shared.save(book: book)
    }

    // MARK: - Cover

    /// Sets a custom cover for a series. The JPEG is written into
    /// `<folder>/.mangashelf/cover.jpg` (source of truth) and mirrored into the
    /// app-side thumbnail cache for fast cell rendering.
    @MainActor
    func setCustomCover(for book: Book, jpegData: Data, modelContext: ModelContext) async throws {
        let thumbnailDir = LocalFileService.shared.thumbnailsDirectory

        // 1) Write into the series folder when possible.
        if book.isSeries,
           let folderName = book.folderName,
           let bookmarkData = UserDefaults.standard.data(forKey: book.bookmarkKey),
           let (rootURL, _) = try? LocalFileService.shared.resolveBookmark(bookmarkData),
           rootURL.startAccessingSecurityScopedResource() {
            defer { rootURL.stopAccessingSecurityScopedResource() }
            let folderURL = rootURL.appendingPathComponent(folderName)
            _ = await BookDataService.shared.saveCoverImage(jpegData: jpegData, seriesFolderURL: folderURL)
        }

        // 2) Mirror into the app-side thumbnail cache.
        let cacheFilename = thumbnailCacheName(for: book)
        let cacheURL = thumbnailDir.appendingPathComponent(cacheFilename)

        if let oldPath = book.thumbnailPath, oldPath != cacheFilename {
            let oldURL = thumbnailDir.appendingPathComponent(oldPath)
            try? FileManager.default.removeItem(at: oldURL)
            thumbnailService.evictCachedImage(for: oldURL)
        }

        try jpegData.write(to: cacheURL)
        thumbnailService.evictCachedImage(for: cacheURL)

        book.thumbnailPath = cacheFilename
        book.hasManualCover = true
        book.coverVersion += 1
        try modelContext.save()
    }

    // MARK: - Private: Create

    private func createSeries(from folderURL: URL, isSecret: Bool = false, modelContext: ModelContext) async throws {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)
        let pdfFiles = contents
            .filter { $0.pathExtension.lowercased() == "pdf" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        guard !pdfFiles.isEmpty else { return }

        let folderName = folderURL.lastPathComponent
        let seriesData = await BookDataService.shared.load(seriesFolderURL: folderURL)

        var chapters: [Chapter] = []
        var totalPagesAll = 0
        var totalSizeAll: Int64 = 0
        let cachedPageCounts = seriesData?.chapterPageCounts ?? [:]

        for (index, pdfFile) in pdfFiles.enumerated() {
            let filename = pdfFile.lastPathComponent
            // Cached count from data.json avoids re-opening every PDF on every scan
            // (a major scan-time cost on libraries with many chapters).
            let pageCount = cachedPageCounts[filename] ?? thumbnailService.getPageCount(for: pdfFile)
            let chapter = Chapter(filename: filename, sortOrder: index, totalPages: pageCount)
            chapters.append(chapter)
            totalPagesAll += pageCount
            totalSizeAll += (try? fileService.fileSize(at: pdfFile)) ?? 0
        }

        let title = seriesData?.title ?? defaultTitle(from: folderName)
        let dateAdded = seriesData?.dateAdded ?? Date()

        let book = Book(
            title: title,
            filename: folderName,
            filePath: folderName,
            thumbnailPath: nil,
            totalPages: totalPagesAll,
            dateAdded: dateAdded,
            fileSize: totalSizeAll,
            isSeries: true,
            folderName: folderName
        )
        book.isSecret = isSecret
        book.folderSignature = folderSignature(at: folderURL)

        modelContext.insert(book)
        for chapter in chapters {
            chapter.book = book
            modelContext.insert(chapter)
        }

        // Cover: prefer the folder's `.mangashelf/cover.jpg`. Fall back to first PDF.
        let cacheFilename = thumbnailCacheName(for: book)
        if BookDataService.hasCoverImage(in: folderURL) {
            _ = await syncFolderCoverToCache(folderURL: folderURL, cacheFilename: cacheFilename)
            let cacheURL = LocalFileService.shared.thumbnailsDirectory.appendingPathComponent(cacheFilename)
            if FileManager.default.fileExists(atPath: cacheURL.path) {
                book.thumbnailPath = cacheFilename
                book.hasManualCover = true
            }
        }
        if book.thumbnailPath == nil {
            let thumbnailURL = await thumbnailService.generateThumbnail(for: pdfFiles[0], identifier: folderName)
            book.thumbnailPath = thumbnailURL?.lastPathComponent
            book.hasManualCover = false
        }

        if let seriesData {
            book.seriesNote = seriesData.note
            book.seriesURL = seriesData.url
            if seriesData.currentChapterIndex > 0 {
                book.currentChapterIndex = min(seriesData.currentChapterIndex, max(0, chapters.count - 1))
            }
            book.lastReadDate = seriesData.lastReadDate
            for chapter in chapters {
                if let savedPage = seriesData.chapterProgress[chapter.filename] {
                    chapter.lastReadPage = savedPage
                }
            }
            for entry in seriesData.bookmarks {
                let bookmark = Bookmark(chapterIndex: entry.chapterIndex, note: entry.note, colorName: entry.color)
                bookmark.book = book
                modelContext.insert(bookmark)
            }
        }

        // Only seed `.mangashelf/data.json` for brand-new folders that have nothing on disk.
        // NEVER write here when load() failed for an existing file — that would overwrite
        // an unreadable-but-recoverable data.json with empty contents.
        let dataFileURL = BookDataService.dataFileURL(in: folderURL)
        if !FileManager.default.fileExists(atPath: dataFileURL.path) {
            await BookDataService.shared.save(book: book, seriesFolderURL: folderURL)
        }
    }

    private func createSingleBook(from pdfURL: URL, isSecret: Bool = false, modelContext: ModelContext) async throws {
        let filename = pdfURL.lastPathComponent
        let title = defaultTitle(from: filename, removeExtension: true)
        let pageCount = thumbnailService.getPageCount(for: pdfURL)
        let fileSize = (try? fileService.fileSize(at: pdfURL)) ?? 0

        let thumbnailURL = await thumbnailService.generateThumbnail(for: pdfURL)
        let thumbnailPath = thumbnailURL?.lastPathComponent

        let book = Book(
            title: title,
            filename: filename,
            filePath: filename,
            thumbnailPath: thumbnailPath,
            totalPages: pageCount,
            fileSize: fileSize
        )
        book.isSecret = isSecret

        modelContext.insert(book)
    }

    // MARK: - Private: Sync Chapters

    private func syncChapters(_ book: Book, folderURL: URL, modelContext: ModelContext) async throws {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)
        let pdfFiles = contents
            .filter { $0.pathExtension.lowercased() == "pdf" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        let existingChapters = book.sortedChapters
        let existingByFilename = Dictionary(
            existingChapters.map { ($0.filename, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let currentFilenames = Set(pdfFiles.map { $0.lastPathComponent })

        for chapter in existingChapters {
            if !currentFilenames.contains(chapter.filename) {
                modelContext.delete(chapter)
            }
        }

        var totalPagesAll = 0
        var totalSizeAll: Int64 = 0

        for (index, pdfFile) in pdfFiles.enumerated() {
            let filename = pdfFile.lastPathComponent
            if let existing = existingByFilename[filename] {
                existing.sortOrder = index
                if existing.totalPages == 0 {
                    existing.totalPages = thumbnailService.getPageCount(for: pdfFile)
                }
                totalPagesAll += existing.totalPages
            } else {
                let pageCount = thumbnailService.getPageCount(for: pdfFile)
                let chapter = Chapter(filename: filename, sortOrder: index, totalPages: pageCount)
                chapter.book = book
                modelContext.insert(chapter)
                totalPagesAll += pageCount
            }
            totalSizeAll += (try? fileService.fileSize(at: pdfFile)) ?? 0
        }

        book.totalPages = totalPagesAll
        book.fileSize = totalSizeAll

        if book.currentChapterIndex >= pdfFiles.count {
            book.currentChapterIndex = max(0, pdfFiles.count - 1)
        }

        if book.thumbnailPath == nil, let firstPDF = pdfFiles.first {
            let thumbnailURL = await thumbnailService.generateThumbnail(for: firstPDF, identifier: book.folderName ?? book.filename)
            book.thumbnailPath = thumbnailURL?.lastPathComponent
        }
    }

    // MARK: - Private: Helpers

    /// Returns whichever of two duplicate rows has the richer user data
    /// (newer `lastReadDate`, more bookmarks, more chapters, earlier `dateAdded`).
    private func pickRicherBook(lhs: Book, rhs: Book) -> Book {
        switch (lhs.lastReadDate, rhs.lastReadDate) {
        case let (l?, r?) where l != r: return l > r ? lhs : rhs
        case (_?, nil): return lhs
        case (nil, _?): return rhs
        default: break
        }
        let lB = lhs.bookmarks?.count ?? 0
        let rB = rhs.bookmarks?.count ?? 0
        if lB != rB { return lB > rB ? lhs : rhs }
        let lC = lhs.chapters?.count ?? 0
        let rC = rhs.chapters?.count ?? 0
        if lC != rC { return lC > rC ? lhs : rhs }
        return lhs.dateAdded <= rhs.dateAdded ? lhs : rhs
    }

    // MARK: - Private: Cover Mirror

    /// Reconciles the app-side thumbnail cache with `<folder>/.mangashelf/cover.jpg`.
    /// Called on every scan so an externally-edited cover propagates to the UI.
    @MainActor
    private func refreshCustomCover(for book: Book, folderURL: URL) async {
        guard book.isSeries else { return }
        let cacheFilename = thumbnailCacheName(for: book)
        let thumbnailDir = LocalFileService.shared.thumbnailsDirectory

        if BookDataService.hasCoverImage(in: folderURL) {
            let updated = await syncFolderCoverToCache(folderURL: folderURL, cacheFilename: cacheFilename)

            if book.thumbnailPath != cacheFilename {
                if let oldPath = book.thumbnailPath, oldPath != cacheFilename {
                    let oldURL = thumbnailDir.appendingPathComponent(oldPath)
                    try? FileManager.default.removeItem(at: oldURL)
                    thumbnailService.evictCachedImage(for: oldURL)
                }
                book.thumbnailPath = cacheFilename
            }
            if !book.hasManualCover {
                book.hasManualCover = true
            }

            if updated {
                let cacheURL = thumbnailDir.appendingPathComponent(cacheFilename)
                thumbnailService.evictCachedImage(for: cacheURL)
                book.coverVersion += 1
            }
        } else if book.hasManualCover {
            book.hasManualCover = false
        }
    }

    /// Copies `<folder>/.mangashelf/cover.jpg` into the thumbnail cache as `cacheFilename`
    /// when missing or stale. Returns `true` only if the cache file was actually written.
    private func syncFolderCoverToCache(folderURL: URL, cacheFilename: String) async -> Bool {
        let source = BookDataService.coverImageURL(in: folderURL)
        let dest = LocalFileService.shared.thumbnailsDirectory.appendingPathComponent(cacheFilename)

        return await Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard fm.fileExists(atPath: source.path) else { return false }

            if fm.fileExists(atPath: dest.path),
               let srcAttrs = try? fm.attributesOfItem(atPath: source.path),
               let destAttrs = try? fm.attributesOfItem(atPath: dest.path),
               let srcDate = srcAttrs[.modificationDate] as? Date,
               let destDate = destAttrs[.modificationDate] as? Date,
               destDate >= srcDate {
                return false
            }

            try? fm.removeItem(at: dest)
            do {
                try fm.copyItem(at: source, to: dest)
                return true
            } catch {
                return false
            }
        }.value
    }

    // MARK: - Private: Helpers

    /// Cheap fingerprint of a series folder: `"{folder mtime epoch}_{pdf count}"`.
    /// Used by the launch-time scan to skip per-series reconciliation when nothing on
    /// disk has changed since the last scan. Returns `nil` only when the folder cannot
    /// be stat'd or enumerated — in which case the caller treats it as "changed" and
    /// falls back to the full sync path.
    private func folderSignature(at folderURL: URL) -> String? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: folderURL.path),
              let mtime = attrs[.modificationDate] as? Date else {
            return nil
        }
        let pdfCount = (try? fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "pdf" }
            .count ?? 0
        return "\(Int(mtime.timeIntervalSince1970))_\(pdfCount)"
    }

    /// Filename used inside `Application Support/Thumbnails/` for a book's cached cover.
    private func thumbnailCacheName(for book: Book) -> String {
        let identifier = book.folderName ?? book.filename
        let safeId = identifier
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return "custom_\(safeId).jpg"
    }

    private func defaultTitle(from filename: String, removeExtension: Bool = false) -> String {
        var title = filename

        if removeExtension, let lastDot = title.lastIndex(of: ".") {
            title = String(title[..<lastDot])
        }

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
