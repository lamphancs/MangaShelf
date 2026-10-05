//
//  Constants.swift
//  MangaShelf
//

import Foundation
import CoreGraphics

enum Layout {
    /// Standard pixel size for generated cover thumbnails and cropped custom covers (2:3).
    static let coverSize = CGSize(width: 400, height: 600)
}

enum StorageKey {
    static let rootFolderBookmark = "rootFolderBookmark"
    static let secretFolderBookmark = "secretFolderBookmark"
    static let rootFolderName = "rootFolderName"
    static let secretFolderName = "secretFolderName"
    static let thumbnailsMigrated = "thumbnailsMigratedToAppSupport"
    static let folderDataMigrated = "folderDataMigratedToSeriesFolders"
    static let appTheme = "appTheme"
    static let accentTheme = "accentTheme"
    static let artworkTransition = "artworkTransition"
    static let libraryViewMode = "libraryViewMode"
}

/// Raw values are persisted in UserDefaults; keep them stable across releases.
enum ArtworkTransition: String, CaseIterable, Identifiable {
    case fade
    case continuous
    case parallax

    var id: String { rawValue }
    var title: String {
        switch self {
        case .fade: "Fade"
        case .continuous: "Continuous"
        case .parallax: "Parallax"
        }
    }
    var symbol: String {
        switch self {
        case .fade: "circle.lefthalf.filled"
        case .continuous: "arrow.down"
        case .parallax: "square.3.layers.3d"
        }
    }
    var description: String {
        switch self {
        case .fade: "Artwork stays in place and fades into the story as you scroll."
        case .continuous: "Artwork and story scroll together, joined by a soft edge."
        case .parallax: "Artwork scrolls a little slower than the story for a gentle sense of depth."
        }
    }
}
