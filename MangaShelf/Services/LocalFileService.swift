//
//  LocalFileService.swift
//  MangaShelf
//
//  Created by Khoa Phan on 4/24/26.
//

import Foundation

/// Service for managing file access via security-scoped bookmarks
final class LocalFileService: FileSourceProtocol {

    static let shared = LocalFileService()

    private let fileManager = FileManager.default

    /// Directory where thumbnails are stored (Application Support, included in backups)
    var thumbnailsDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let thumbnailDir = appSupport.appendingPathComponent("Thumbnails", isDirectory: true)

        if !fileManager.fileExists(atPath: thumbnailDir.path) {
            try? fileManager.createDirectory(at: thumbnailDir, withIntermediateDirectories: true)
        }

        return thumbnailDir
    }

    /// Migrate thumbnails from old Caches location to Application Support
    func migrateThumbnailsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: StorageKey.thumbnailsMigrated) else { return }

        let cacheDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let oldDir = cacheDir.appendingPathComponent("Thumbnails", isDirectory: true)

        guard fileManager.fileExists(atPath: oldDir.path),
              let files = try? fileManager.contentsOfDirectory(at: oldDir, includingPropertiesForKeys: nil),
              !files.isEmpty else {
            UserDefaults.standard.set(true, forKey: StorageKey.thumbnailsMigrated)
            return
        }

        let newDir = thumbnailsDirectory
        for file in files {
            let dest = newDir.appendingPathComponent(file.lastPathComponent)
            if !fileManager.fileExists(atPath: dest.path) {
                try? fileManager.moveItem(at: file, to: dest)
            }
        }

        try? fileManager.removeItem(at: oldDir)
        UserDefaults.standard.set(true, forKey: StorageKey.thumbnailsMigrated)
    }

    private init() {}

    // MARK: - Bookmark Operations

    func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
        return (url, isStale)
    }

    // MARK: - File Operations

    func fileExists(at fileURL: URL) -> Bool {
        fileManager.fileExists(atPath: fileURL.path)
    }

    func fileSize(at fileURL: URL) throws -> Int64 {
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        return attributes[.size] as? Int64 ?? 0
    }

    // MARK: - Thumbnail Helpers

    func urlForThumbnail(named filename: String) -> URL {
        thumbnailsDirectory.appendingPathComponent(filename)
    }

}

// MARK: - Error Types

enum FileServiceError: LocalizedError {
    case bookmarkResolutionFailed

    var errorDescription: String? {
        switch self {
        case .bookmarkResolutionFailed:
            return NSLocalizedString("Could not access the file. Try re-importing it.", comment: "")
        }
    }
}
