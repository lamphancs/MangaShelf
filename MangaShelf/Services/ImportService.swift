//
//  ImportService.swift
//  MangaShelf
//
//  Created by Khoa Phan on 4/24/26.
//

import Foundation
import SwiftData

/// Service for scanning a root manga folder and syncing the library
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

    /// Scan the configured root folder and sync all series into SwiftData
    /// - Returns: Number of series found
    @discardableResult
    func scanRootFolder(modelContext: ModelContext) async throws -> Int {
        try await scanFolder(
            bookmarkKey: StorageKey.rootFolderBookmark,
            isSecret: false,
            modelContext: modelContext
        )
    }

    /// Scan the secret folder and sync all secret series into SwiftData
    @discardableResult
    func scanSecretFolder(modelContext: ModelContext) async throws -> Int {
        try await scanFolder(
            bookmarkKey: StorageKey.secretFolderBookmark,
            isSecret: true,
            modelContext: modelContext
        )
    }

    private func scanFolder(bookmarkKey: String, isSecret: Bool, modelContext: ModelContext) async throws -> Int {
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

        let seriesByFolder = Dictionary(
            existingBooks.compactMap { book -> (String, Book)? in
                guard book.isSeries, let fn = book.folderName else { return nil }
                return (fn, book)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let singlesByFilename = Dictionary(
            existingBooks.compactMap { book -> (String, Book)? in
                guard !book.isSeries else { return nil }
                return (book.filename, book)
            },
            uniquingKeysWith: { first, _ in first }
        )

        let currentSeriesNames = Set(seriesFolders.map { $0.lastPathComponent })
        let currentSingleNames = Set(singlePDFs.map { $0.lastPathComponent })

        for book in existingBooks {
            let isMissing: Bool
            if book.isSeries {
                isMissing = book.folderName.map { !currentSeriesNames.contains($0) } ?? true
            } else {
                isMissing = !currentSingleNames.contains(book.filename)
            }
            book.isAvailable = !isMissing
        }

        // Sync series
        for folderURL in seriesFolders {
            let folderName = folderURL.lastPathComponent
            if let existing = seriesByFolder[folderName] {
                try await syncChapters(existing, folderURL: folderURL, modelContext: modelContext)
            } else {
                try await createSeries(from: folderURL, isSecret: isSecret, modelContext: modelContext)
            }
        }

        // Sync single PDFs
        for pdfURL in singlePDFs {
            let filename = pdfURL.lastPathComponent
            if let existing = singlesByFilename[filename] {
                if existing.totalPages == 0 {
                    let pageCount = thumbnailService.getPageCount(for: pdfURL)
                    existing.totalPages = pageCount
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
        try modelContext.save()
    }

    // MARK: - Rename

    func renameBook(_ book: Book, to newTitle: String, modelContext: ModelContext) async throws {
        book.title = newTitle
        try modelContext.save()
    }

    // MARK: - Cover

    func setCustomCover(for book: Book, jpegData: Data, modelContext: ModelContext) throws {
        let filename = customCoverName(for: book.folderName ?? book.filename)
        let thumbnailDir = LocalFileService.shared.thumbnailsDirectory
        let fileURL = thumbnailDir.appendingPathComponent(filename)

        if let oldPath = book.thumbnailPath {
            let oldURL = thumbnailDir.appendingPathComponent(oldPath)
            try? FileManager.default.removeItem(at: oldURL)
            thumbnailService.evictCachedImage(for: oldURL)
        }

        try jpegData.write(to: fileURL)
        thumbnailService.evictCachedImage(for: fileURL)
        book.thumbnailPath = filename
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

        let customCoverFilename = customCoverName(for: folderName)
        let customCoverURL = LocalFileService.shared.urlForThumbnail(named: customCoverFilename)
        let hasCustomCover = FileManager.default.fileExists(atPath: customCoverURL.path)

        let thumbnailPath: String?
        if hasCustomCover {
            thumbnailPath = customCoverFilename
        } else {
            let thumbnailURL = await thumbnailService.generateThumbnail(for: pdfFiles[0], identifier: folderName)
            thumbnailPath = thumbnailURL?.lastPathComponent
        }

        var chapters: [Chapter] = []
        var totalPagesAll = 0
        var totalSizeAll: Int64 = 0

        for (index, pdfFile) in pdfFiles.enumerated() {
            let pageCount = thumbnailService.getPageCount(for: pdfFile)
            let chapter = Chapter(filename: pdfFile.lastPathComponent, sortOrder: index, totalPages: pageCount)
            chapters.append(chapter)
            totalPagesAll += pageCount
            totalSizeAll += (try? fileService.fileSize(at: pdfFile)) ?? 0
        }

        let title = cleanTitle(from: folderName, removeExtension: false)
        let book = Book(
            title: title,
            filename: folderName,
            filePath: folderName,
            thumbnailPath: thumbnailPath,
            totalPages: totalPagesAll,
            fileSize: totalSizeAll,
            isSeries: true,
            folderName: folderName
        )
        book.hasManualCover = hasCustomCover
        book.isSecret = isSecret

        modelContext.insert(book)
        for chapter in chapters {
            chapter.book = book
            modelContext.insert(chapter)
        }
    }

    private func createSingleBook(from pdfURL: URL, isSecret: Bool = false, modelContext: ModelContext) async throws {
        let filename = pdfURL.lastPathComponent
        let title = cleanTitle(from: filename)
        let pageCount = thumbnailService.getPageCount(for: pdfURL)
        let fileSize = (try? fileService.fileSize(at: pdfURL)) ?? 0

        let customCoverFilename = customCoverName(for: filename)
        let customCoverURL = LocalFileService.shared.urlForThumbnail(named: customCoverFilename)
        let hasCustomCover = FileManager.default.fileExists(atPath: customCoverURL.path)

        let thumbnailPath: String?
        if hasCustomCover {
            thumbnailPath = customCoverFilename
        } else {
            let thumbnailURL = await thumbnailService.generateThumbnail(for: pdfURL)
            thumbnailPath = thumbnailURL?.lastPathComponent
        }

        let book = Book(
            title: title,
            filename: filename,
            filePath: filename,
            thumbnailPath: thumbnailPath,
            totalPages: pageCount,
            fileSize: fileSize
        )
        book.hasManualCover = hasCustomCover
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

    func customCoverName(for identifier: String) -> String {
        let safeId = identifier
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return "custom_\(safeId).jpg"
    }

    private func cleanTitle(from filename: String, removeExtension: Bool = true) -> String {
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
