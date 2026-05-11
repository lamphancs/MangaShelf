//
//  Book.swift
//  MangaShelf
//
//  Created by Khoa Phan on 4/24/26.
//

import Foundation
import SwiftData

/// Represents a manga/comic book in the user's library
@Model
final class Book {
    /// Unique identifier
    var id: UUID

    /// Display title (cleaned filename without extension)
    var title: String

    /// Original filename
    var filename: String

    /// DEPRECATED: Legacy absolute path (no longer used)
    /// Kept for backwards compatibility with existing data
    var filePath: String

    /// Path to the cached cover thumbnail image
    var thumbnailPath: String?

    /// Last page the user was reading (0-indexed) — used for single-PDF books
    var lastReadPage: Int

    /// Total number of pages in the PDF (or sum of all chapters for series)
    var totalPages: Int

    /// Date when the book was added to the library
    var dateAdded: Date

    /// Date when the book was last opened
    var lastReadDate: Date?

    /// File size in bytes
    var fileSize: Int64

    /// Whether this book is a multi-chapter series (folder import)
    var isSeries: Bool = false

    /// Folder name in Documents directory (set for series)
    var folderName: String?

    /// Index of the chapter the user is currently reading (series only)
    var currentChapterIndex: Int = 0

    /// Security-scoped bookmark data for accessing the original file/folder
    var bookmarkData: Data? = nil

    /// Whether the user manually picked a cover (don't overwrite on rescan)
    var hasManualCover: Bool = false

    /// Incremented when cover image changes, used to invalidate cached views
    var coverVersion: Int = 0

    /// Whether this book belongs to the secret library
    var isSecret: Bool = false

    /// Whether this book's source files are present in the current root folder
    var isAvailable: Bool = true

    /// URL link to the series (e.g. manga website)
    var seriesURL: String?

    /// User note for this series
    var seriesNote: String?

    /// Chapters in this series
    @Relationship(deleteRule: .cascade, inverse: \Chapter.book) var chapters: [Chapter]?

    /// User bookmarks for chapters
    @Relationship(deleteRule: .cascade, inverse: \Bookmark.book) var bookmarks: [Bookmark]?

    init(
        id: UUID = UUID(),
        title: String,
        filename: String,
        filePath: String,
        thumbnailPath: String? = nil,
        lastReadPage: Int = 0,
        totalPages: Int = 0,
        dateAdded: Date = Date(),
        lastReadDate: Date? = nil,
        fileSize: Int64 = 0,
        isSeries: Bool = false,
        folderName: String? = nil,
        currentChapterIndex: Int = 0,
        bookmarkData: Data? = nil
    ) {
        self.id = id
        self.title = title
        self.filename = filename
        self.filePath = filePath
        self.thumbnailPath = thumbnailPath
        self.lastReadPage = lastReadPage
        self.totalPages = totalPages
        self.dateAdded = dateAdded
        self.lastReadDate = lastReadDate
        self.fileSize = fileSize
        self.isSeries = isSeries
        self.folderName = folderName
        self.currentChapterIndex = currentChapterIndex
        self.bookmarkData = bookmarkData
    }

    /// Chapters sorted by natural file order
    var sortedChapters: [Chapter] {
        (chapters ?? []).sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Reading progress as a percentage (0.0 to 1.0)
    var readingProgress: Double {
        if isSeries {
            let count = chapters?.count ?? 0
            guard count > 0 else { return 0.0 }
            return Double(currentChapterIndex) / Double(count)
        }
        guard totalPages > 0 else { return 0.0 }
        return Double(lastReadPage) / Double(totalPages)
    }

    /// Sorted bookmarks by chapter index
    var sortedBookmarks: [Bookmark] {
        (bookmarks ?? []).sorted { $0.chapterIndex < $1.chapterIndex }
    }

    /// Get the actual thumbnail URL (dynamically constructed)
    var thumbnailURL: URL? {
        guard let thumbnailPath = thumbnailPath else { return nil }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let thumbnailDir = appSupport.appendingPathComponent("Thumbnails", isDirectory: true)
        if !thumbnailPath.contains("/") {
            return thumbnailDir.appendingPathComponent(thumbnailPath)
        }
        let filename = URL(fileURLWithPath: thumbnailPath).lastPathComponent
        return thumbnailDir.appendingPathComponent(filename)
    }

}
