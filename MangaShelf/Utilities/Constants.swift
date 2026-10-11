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
    static let captureCropTrimPages = "captureCropTrimPages"
    static let captureCropTopTrimPages = "captureCropTopTrimPages"
    static let captureOverviewZoom = "captureOverviewZoom"
    static let captureDetailZoom = "captureDetailZoom"
}

nonisolated enum CaptureCrop {
    /// Browser viewports trimmed from the bottom of a capture by default.
    static let defaultTrimPages = 5
    /// Browser viewports trimmed from the top of a capture by default.
    static let defaultTopTrimPages = 0
    static let trimPagesRange = 0...50
    /// Overview width multiplier over the fit-to-height width (capped at the screen width).
    static let defaultOverviewZoom = 2.25
    static let overviewZoomRange = 1.0...10.0
    /// Detail width multiplier over the screen width.
    static let defaultDetailZoom = 1.0
    static let detailZoomRange = 1.0...4.0
    static let zoomStep = 0.25
}

/// Raw values are persisted in UserDefaults; keep them stable across releases.
enum ArtworkTransition: String, CaseIterable, Identifiable {
    case fade
    case continuous
    case parallax
    case parallaxContinuous

    var id: String { rawValue }
    var title: String {
        switch self {
        case .fade: "Fade"
        case .continuous: "Continuous"
        case .parallax: "Parallax"
        case .parallaxContinuous: "Parallax + Continuous"
        }
    }
    var symbol: String {
        switch self {
        case .fade: "circle.lefthalf.filled"
        case .continuous: "arrow.down"
        case .parallax: "square.3.layers.3d"
        case .parallaxContinuous: "arrow.triangle.branch"
        }
    }
    var description: String {
        switch self {
        case .fade: "Artwork stays in place and fades into the story as you scroll."
        case .continuous: "Artwork and story scroll together, joined by a soft edge."
        case .parallax: "Artwork scrolls a little slower than the story for a gentle sense of depth."
        case .parallaxContinuous: "Parallax at the beginning, continuous scrolling at the end."
        }
    }
}
