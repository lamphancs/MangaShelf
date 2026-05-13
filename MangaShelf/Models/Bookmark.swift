//
//  Bookmark.swift
//  MangaShelf
//
//  Created by Khoa Phan on 4/27/26.
//

import Foundation
import SwiftData
import SwiftUI

enum BookmarkColor: String, CaseIterable {
    case red
    case orange
    case yellow
    case green
    case mint
    case teal
    case cyan
    case blue
    case indigo
    case purple
    case pink

    var color: Color {
        switch self {
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .mint: return .mint
        case .teal: return .teal
        case .cyan: return .cyan
        case .blue: return .blue
        case .indigo: return .indigo
        case .purple: return .purple
        case .pink: return .pink
        }
    }
}

@Model
final class Bookmark {
    var id: UUID
    var chapterIndex: Int
    var note: String
    var colorName: String
    var dateCreated: Date
    var book: Book?

    init(
        id: UUID = UUID(),
        chapterIndex: Int,
        note: String = "",
        colorName: String = "red",
        dateCreated: Date = Date()
    ) {
        self.id = id
        self.chapterIndex = chapterIndex
        self.note = note
        self.colorName = colorName
        self.dateCreated = dateCreated
    }

    var bookmarkColor: BookmarkColor {
        BookmarkColor(rawValue: colorName) ?? .red
    }
}
