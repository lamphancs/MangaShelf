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
    static let libraryViewMode = "libraryViewMode"
}
