//
//  Chapter.swift
//  MangaShelf
//
//  Created by Khoa Phan on 4/24/26.
//

import Foundation
import SwiftData

/// Represents a single chapter (PDF) within a manga series
@Model
final class Chapter {
    var id: UUID
    var filename: String
    var sortOrder: Int
    var totalPages: Int
    var lastReadPage: Int
    var book: Book?

    init(
        id: UUID = UUID(),
        filename: String,
        sortOrder: Int,
        totalPages: Int = 0,
        lastReadPage: Int = 0
    ) {
        self.id = id
        self.filename = filename
        self.sortOrder = sortOrder
        self.totalPages = totalPages
        self.lastReadPage = lastReadPage
    }

    var displayName: String {
        var name = filename
        if let lastDot = name.lastIndex(of: ".") {
            name = String(name[..<lastDot])
        }
        name = name.replacingOccurrences(of: "_", with: " ")
        name = name.replacingOccurrences(of: "-", with: " ")
        return name.trimmingCharacters(in: .whitespaces)
    }

    func pdfURL(folderURL: URL) -> URL {
        folderURL.appendingPathComponent(filename)
    }
}
