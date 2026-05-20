//
//  LibraryViewModel.swift
//  MangaShelf
//
//  Created by Khoa Phan on 4/24/26.
//

import Foundation
import SwiftUI
import SwiftData

enum LibraryViewMode: String {
    case grid
    case list
}

enum LibrarySortOption: String, CaseIterable {
    case recentlyAdded = "Recently Added"
    case alphabetical = "A\u{2013}Z"
    case lastRead = "Last Read"
}

@MainActor
@Observable
final class LibraryViewModel {

    var sortOption: LibrarySortOption = .recentlyAdded {
        didSet { invalidateCache() }
    }
    var searchText = "" {
        didSet { invalidateCache() }
    }
    var isSecretMode = false {
        didSet { invalidateCache() }
    }
    /// Full-screen blocking spinner. Reserved for user-initiated full rescans where
    /// the library state may change drastically. Auto-refreshes on launch / scene-active
    /// transitions never set this — they use `isRefreshing` instead.
    var isLoading = false
    /// Subtle inline indicator for background reconciliation. The library remains
    /// fully interactive while this is `true`.
    var isRefreshing = false
    var errorMessage: String?
    var showError = false
    var selectedBook: Book?
    var showRenameDialog = false
    var renameText = ""

    private let importService: ImportService
    private var cachedBooks: [Book] = []
    private var lastBookIDs: [UUID] = []
    private var cacheValid = false

    init(importService: ImportService? = nil) {
        self.importService = importService ?? ImportService()
    }

    private func invalidateCache() {
        cacheValid = false
    }

    func filteredAndSortedBooks(_ books: [Book]) -> [Book] {
        let availableIDs = books.filter(\.isAvailable).map(\.id)
        if cacheValid, availableIDs == lastBookIDs {
            return cachedBooks
        }

        let secretFiltered = books.filter { $0.isSecret == isSecretMode && $0.isAvailable }

        let filtered: [Book]
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            filtered = secretFiltered
        } else {
            filtered = secretFiltered.filter { $0.title.localizedCaseInsensitiveContains(query) }
        }

        let sorted: [Book]
        switch sortOption {
        case .recentlyAdded:
            sorted = filtered.sorted { $0.dateAdded > $1.dateAdded }
        case .alphabetical:
            sorted = filtered.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .lastRead:
            sorted = filtered.sorted { (book1, book2) in
                guard let date1 = book1.lastReadDate else { return false }
                guard let date2 = book2.lastReadDate else { return true }
                return date1 > date2
            }
        }

        cachedBooks = sorted
        lastBookIDs = availableIDs
        cacheValid = true
        return sorted
    }

    /// Background reconciliation between SwiftData and on-disk folders. Cheap thanks to
    /// per-series `folderSignature` short-circuiting in `ImportService`. The library is
    /// rendered from SwiftData throughout — this method only flips `isRefreshing` so an
    /// inline indicator can appear in the toolbar.
    func quickRefresh(modelContext: ModelContext) async {
        await performScan(modelContext: modelContext, force: false, blocking: false)
    }

    /// User-initiated full rescan (Settings → Rescan, new folder pick). Ignores
    /// signatures so every series folder is re-walked. Uses the blocking spinner because
    /// row counts may change visibly.
    func fullRescan(modelContext: ModelContext) async {
        await performScan(modelContext: modelContext, force: true, blocking: true)
    }

    private func performScan(modelContext: ModelContext, force: Bool, blocking: Bool) async {
        let hasRoot = UserDefaults.standard.data(forKey: StorageKey.rootFolderBookmark) != nil
        let hasSecret = UserDefaults.standard.data(forKey: StorageKey.secretFolderBookmark) != nil
        guard hasRoot || hasSecret else { return }

        if blocking {
            isLoading = true
        } else {
            isRefreshing = true
        }
        defer {
            if blocking { isLoading = false } else { isRefreshing = false }
        }

        // Move all app-side per-series state into each folder's `.mangashelf/` before
        // the scan can start deleting missing books. Idempotent across launches.
        await BookDataService.shared.migrateAppDataToFolders(modelContext: modelContext)

        do {
            if hasRoot {
                try await importService.scanRootFolder(modelContext: modelContext, force: force)
            }
            if hasSecret {
                try await importService.scanSecretFolder(modelContext: modelContext, force: force)
            }
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    func showRename(for book: Book) {
        selectedBook = book
        renameText = book.title
        showRenameDialog = true
    }

    func confirmRename(modelContext: ModelContext) async {
        guard let book = selectedBook, !renameText.trimmingCharacters(in: .whitespaces).isEmpty else {
            return
        }

        do {
            try await importService.renameBook(book, to: renameText.trimmingCharacters(in: .whitespaces), modelContext: modelContext)
        } catch {
            errorMessage = "Failed to rename: \(error.localizedDescription)"
            showError = true
        }

        selectedBook = nil
        showRenameDialog = false
    }
}
