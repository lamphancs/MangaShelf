//
//  FileSourceProtocol.swift
//  MangaShelf
//
//  Created by Khoa Phan on 4/24/26.
//

import Foundation

/// Protocol defining file access operations using security-scoped bookmarks
protocol FileSourceProtocol {
    /// Create a security-scoped bookmark for a URL
    func createBookmark(for url: URL) throws -> Data

    /// Resolve a security-scoped bookmark back to a URL
    func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool)

    /// Delete a file from storage
    func deleteFile(at fileURL: URL) async throws

    /// Check if a file exists at the given path
    func fileExists(at fileURL: URL) -> Bool

    /// Get the size of a file in bytes
    func fileSize(at fileURL: URL) throws -> Int64
}
