//
//  ReaderViewModel.swift
//  MangaShelf
//
//  Created by Khoa Phan on 4/24/26.
//

import Foundation
import SwiftUI
import SwiftData
import PDFKit

@MainActor
@Observable
final class ReaderViewModel {

    let book: Book
    var currentPage: Int
    var isOverlayVisible = false
    var isLoadingChapter = false
    var pdfDocument: PDFDocument?

    var currentChapterIndex: Int
    private(set) var sortedChapters: [Chapter]

    /// Chapters of the language not currently being read (VN ⇄ EN), used by the language toggle.
    private var otherLanguageChapters: [Chapter]

    var currentChapter: Chapter? {
        guard book.isSeries else { return nil }
        return sortedChapters[safe: currentChapterIndex]
    }

    /// True when the series has chapters in both VN and EN.
    var hasBothLanguages: Bool {
        !sortedChapters.isEmpty && !otherLanguageChapters.isEmpty
    }

    var isReadingEnglish: Bool {
        currentChapter?.isEnglish ?? false
    }

    /// Index (in `otherLanguageChapters`) of the chapter with the same number as the current one.
    private var counterpartChapterIndex: Int? {
        guard let number = currentChapter?.extractedNumber.flatMap({ Int($0) }) else { return nil }
        return otherLanguageChapters.firstIndex { $0.extractedNumber.flatMap { Int($0) } == number }
    }

    var canToggleLanguage: Bool {
        counterpartChapterIndex != nil && !isLoadingChapter
    }

    var currentChapterTotalPages: Int {
        currentChapter?.totalPages ?? book.totalPages
    }

    var canGoToPreviousChapter: Bool {
        book.isSeries && currentChapterIndex > 0
    }

    var canGoToNextChapter: Bool {
        book.isSeries && currentChapterIndex < sortedChapters.count - 1
    }

    var captureViewport: (() -> (UIImage, CGFloat)?)?

    /// Exact scroll offset (content points) to restore when the reader opens, taken from the
    /// last saved position of the initial chapter/book. `0` means fall back to page restore.
    var initialOffset: CGFloat = 0

    /// Reads the live `contentOffset.y` from the scroll view on demand (wired by `PDFPageView`).
    var currentOffsetProvider: (() -> CGFloat)?

    /// Reads how far (0...1) through the current chapter's pages the reader is (wired by `PDFPageView`).
    var currentProgressProvider: (() -> CGFloat?)?

    /// Relative position to open the next loaded chapter at. Set only when switching language,
    /// so the other version opens at the same point (e.g. 40% → 40%); `0` otherwise.
    var restoreProgress: CGFloat = 0

    /// Scrolls (animated) to the top of the current chapter, calling the completion once the
    /// top has finished rendering (wired by `PDFPageView`).
    var scrollToTop: ((@escaping () -> Void) -> Void)?

    /// True while the "go to top" button is waiting for the top of the chapter to render.
    var isScrollingToTop = false
    var scrollToBottom: ((@escaping () -> Void) -> Void)?
    var isScrollingToBottom = false

    /// True while the reader is restoring a saved scroll position and its tiles are still loading.
    var isRestoringPosition = false

    private var accessedURL: URL?
    private var folderURL: URL?
    var artFolderURL: URL? {
        folderURL?.appendingPathComponent("Art", isDirectory: true)
    }
    private var hasSecurityAccess = false
    private var overlayHideTask: Task<Void, Never>?
    private var chapterLoadTask: Task<PDFDocument?, Never>?
    private var bottomLoadingTimeoutTask: Task<Void, Never>?
    private var topLoadingTimeoutTask: Task<Void, Never>?
    private var restoreTimeoutTask: Task<Void, Never>?

    init(book: Book) {
        self.book = book

        var resolvedRoot: URL?
        let bookmarkKey = book.bookmarkKey
        if let data = UserDefaults.standard.data(forKey: bookmarkKey),
           let (url, _) = try? LocalFileService.shared.resolveBookmark(data) {
            if url.startAccessingSecurityScopedResource() {
                resolvedRoot = url
            }
        }

        if let rootURL = resolvedRoot {
            self.accessedURL = rootURL
            self.hasSecurityAccess = true
        }

        if book.isSeries {
            let allChapters = book.sortedChapters
            let selected = allChapters[safe: book.currentChapterIndex] ?? allChapters.first
            let isEnglish = selected?.isEnglish ?? false
            let chapters = allChapters.filter { $0.isEnglish == isEnglish }
            self.sortedChapters = chapters
            self.otherLanguageChapters = allChapters.filter { $0.isEnglish != isEnglish }
            let chapterIdx = chapters.firstIndex { $0.id == selected?.id } ?? 0
            self.currentChapterIndex = chapterIdx

            if let rootURL = resolvedRoot {
                let seriesFolder = rootURL.appendingPathComponent(book.folderName ?? book.filename)
                self.folderURL = seriesFolder

                if let chapter = chapters[safe: chapterIdx] {
                    self.currentPage = min(chapter.lastReadPage, max(0, chapter.totalPages - 1))
                    self.initialOffset = CGFloat(chapter.lastReadOffset)
                    self.pdfDocument = PDFDocument(url: chapter.pdfURL(folderURL: seriesFolder))
                } else {
                    self.currentPage = 0
                }
            } else {
                self.currentPage = 0
            }
        } else {
            self.sortedChapters = []
            self.otherLanguageChapters = []
            self.currentChapterIndex = 0
            self.currentPage = book.lastReadPage
            self.initialOffset = CGFloat(book.lastReadOffset)

            if let rootURL = resolvedRoot {
                let pdfURL = rootURL.appendingPathComponent(book.filename)
                self.pdfDocument = PDFDocument(url: pdfURL)
            }
        }

        self.isRestoringPosition = self.initialOffset > 0
    }

    func cleanup() {
        chapterLoadTask?.cancel()
        chapterLoadTask = nil
        topLoadingTimeoutTask?.cancel()
        topLoadingTimeoutTask = nil
        bottomLoadingTimeoutTask?.cancel()
        bottomLoadingTimeoutTask = nil
        restoreTimeoutTask?.cancel()
        restoreTimeoutTask = nil
        if hasSecurityAccess, let url = accessedURL {
            url.stopAccessingSecurityScopedResource()
            hasSecurityAccess = false
            accessedURL = nil
        }
        cancelOverlayHide()
    }

    // MARK: - Overlay

    func toggleOverlay() {
        isOverlayVisible.toggle()
        UIImpactFeedbackGenerator.impact(.light)

        if isOverlayVisible {
            scheduleOverlayHide()
        } else {
            cancelOverlayHide()
        }
    }

    // MARK: - Bookmarks

    private var storedChapterIndex: Int {
        book.sortedChapters.firstIndex { $0.id == currentChapter?.id } ?? 0
    }

    var currentBookmark: Bookmark? {
        book.bookmarks?.first { $0.chapterIndex == storedChapterIndex }
    }

    var canBookmarkCurrentChapter: Bool {
        book.isSeries && currentChapter != nil && pdfDocument != nil && !isLoadingChapter
    }

    func beginBookmarkEditing() {
        cancelOverlayHide()
    }

    func endBookmarkEditing() {
        if isOverlayVisible { scheduleOverlayHide() }
    }

    func removeCurrentBookmark(modelContext: ModelContext) {
        guard canBookmarkCurrentChapter, let bookmark = currentBookmark else { return }
        UIImpactFeedbackGenerator.impact(.medium)
        // Update the inverse relationship immediately; deletion must not depend on a disk
        // save before the button (or a subsequent tap) sees the new bookmark state.
        book.bookmarks?.removeAll { $0.id == bookmark.id }
        modelContext.delete(bookmark)
        // Flush at reader lifecycle boundaries, just like reading position. A synchronous
        // SwiftData save plus a full series snapshot here stalls the tap/scroll interaction.
        if isOverlayVisible { scheduleOverlayHide() }
    }

    func saveBookmark(note: String, color: BookmarkColor, modelContext: ModelContext) {
        guard canBookmarkCurrentChapter else { return }

        if let bookmark = currentBookmark {
            bookmark.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
            bookmark.colorName = color.rawValue
        } else {
            let bookmark = Bookmark(
                chapterIndex: storedChapterIndex,
                note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                colorName: color.rawValue
            )
            bookmark.book = book
            modelContext.insert(bookmark)
        }
        // Persist with progress on chapter change, reader dismissal, or backgrounding.
        UIImpactFeedbackGenerator.impact(.medium)
    }

    // MARK: - Page Navigation

    func updatePage(_ page: Int, modelContext: ModelContext) {
        // Page position is kept in memory only while reading — no disk write here. A periodic
        // save used to run 2s after each scroll stop, but its main-thread SwiftData + JSON
        // write caused a stutter when resuming scroll. Progress is now persisted on reader
        // dismiss/disappear, chapter change, and when the app enters the background.
        currentPage = page
    }

    // MARK: - Scroll Actions

    /// Triggered by the overlay's "go to top" button. Shows a spinner on the button until the
    /// top of the chapter has rendered, with a timeout so it can never spin forever.
    func goToTop() {
        guard let scrollToTop else { return }
        UIImpactFeedbackGenerator.impact(.medium)
        isScrollingToTop = true
        scrollToTop { [weak self] in
            guard let self else { return }
            self.topLoadingTimeoutTask?.cancel()
            withAnimation(.easeInOut(duration: 0.2)) { self.isScrollingToTop = false }
        }
        topLoadingTimeoutTask?.cancel()
        topLoadingTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled, self.isScrollingToTop else { return }
            withAnimation(.easeInOut(duration: 0.2)) { self.isScrollingToTop = false }
        }
    }

    func goToBottom() {
        guard let scrollToBottom else { return }
        UIImpactFeedbackGenerator.impact(.medium)
        isScrollingToBottom = true
        scrollToBottom { [weak self] in
            guard let self else { return }
            self.bottomLoadingTimeoutTask?.cancel()
            withAnimation(.easeInOut(duration: 0.2)) { self.isScrollingToBottom = false }
        }
        bottomLoadingTimeoutTask?.cancel()
        bottomLoadingTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled, self.isScrollingToBottom else { return }
            withAnimation(.easeInOut(duration: 0.2)) { self.isScrollingToBottom = false }
        }
    }

    /// Called by `PDFPageView` once the restored position's tiles have finished rendering.
    func restoreDidComplete() {
        restoreTimeoutTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) { isRestoringPosition = false }
    }

    /// Safety net: clears the restore spinner after a few seconds even if the render-complete
    /// callback never arrives (e.g. a page that fails to render).
    func beginRestoreTimeout() {
        guard isRestoringPosition else { return }
        restoreTimeoutTask?.cancel()
        restoreTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled, self.isRestoringPosition else { return }
            withAnimation(.easeInOut(duration: 0.2)) { self.isRestoringPosition = false }
        }
    }

    // MARK: - Chapter Navigation

    func goToNextChapter(modelContext: ModelContext) {
        guard canGoToNextChapter else { return }
        navigateToChapter(index: currentChapterIndex + 1, modelContext: modelContext)
    }

    func goToChapter(index: Int, modelContext: ModelContext) {
        guard index >= 0, index < sortedChapters.count, index != currentChapterIndex else { return }
        navigateToChapter(index: index, modelContext: modelContext)
    }

    func goToPreviousChapter(modelContext: ModelContext) {
        guard canGoToPreviousChapter else { return }
        navigateToChapter(index: currentChapterIndex - 1, modelContext: modelContext)
    }

    /// Switches to the same chapter number in the other language (VN ⇄ EN).
    func toggleLanguage(modelContext: ModelContext) {
        guard !isLoadingChapter, let index = counterpartChapterIndex else { return }
        let progress = currentProgressProvider?() ?? 0
        navigateToChapter(index: index, switchingLanguage: true, progress: progress, modelContext: modelContext)
    }

    /// Loads the chapter at `index`. When `switchingLanguage` is true, `index` refers to
    /// `otherLanguageChapters`, and the two lists are swapped once the new chapter has loaded.
    /// `progress` (0...1) is the relative position to open the new chapter at.
    private func navigateToChapter(index: Int, switchingLanguage: Bool = false, progress: CGFloat = 0,
                                   modelContext: ModelContext) {
        let targetChapters = switchingLanguage ? otherLanguageChapters : sortedChapters
        guard let chapter = targetChapters[safe: index],
              let folder = folderURL else { return }

        // Flush pending bookmark changes to both SwiftData and portable series metadata
        // along with the outgoing chapter's position before loading the next chapter.
        saveProgress(modelContext: modelContext)

        pdfDocument = nil
        currentPage = 0
        isLoadingChapter = true

        let chapterURL = chapter.pdfURL(folderURL: folder)
        chapterLoadTask?.cancel()
        chapterLoadTask = Task.detached { [chapterURL] in
            let doc = PDFDocument(url: chapterURL)
            return doc
        }

        Task {
            let doc = await chapterLoadTask?.value
            guard !Task.isCancelled else { return }

            if switchingLanguage {
                otherLanguageChapters = sortedChapters
                sortedChapters = targetChapters
            }
            currentChapterIndex = index
            // Must be set before `pdfDocument`: `PDFPageView` reads it when the new document loads.
            restoreProgress = doc == nil ? 0 : progress
            if restoreProgress > 0 {
                isRestoringPosition = true
                beginRestoreTimeout()
            }
            pdfDocument = doc
            book.currentChapterIndex = storedChapterIndex
            book.lastReadDate = Date()
            try? modelContext.save()

            withAnimation(.easeInOut(duration: 0.3)) {
                isLoadingChapter = false
            }
        }
    }

    // MARK: - Progress

    func saveProgress(modelContext: ModelContext) {
        let offset = currentOffsetProvider?()
        if book.isSeries {
            if let chapter = currentChapter {
                chapter.lastReadPage = currentPage
                if let offset { chapter.lastReadOffset = Double(offset) }
            }
            book.currentChapterIndex = storedChapterIndex
        } else {
            book.lastReadPage = currentPage
            if let offset { book.lastReadOffset = Double(offset) }
        }
        book.lastReadDate = Date()
        try? modelContext.save()

        if let folderURL {
            Task { await BookDataService.shared.save(book: book, seriesFolderURL: folderURL) }
        }
    }

    // MARK: - Screenshot Capture

    func captureCurrentPage() async -> Bool {
        guard book.isSeries,
              let folder = folderURL,
              let (image, scrollOffset) = captureViewport?() else { return false }

        let chapterNum: Int
        if let chapter = currentChapter,
           let numStr = chapter.extractedNumber,
           let n = Int(numStr) {
            chapterNum = n
        } else {
            chapterNum = currentChapterIndex + 1
        }

        let offsetKey = Int(scrollOffset * 10)
        let filename = String(format: "ch%03d_p%04d_y%08d.jpg", chapterNum, currentPage + 1, offsetKey)
        let artFolder = folder.appendingPathComponent("Art")

        guard let jpegData = image.jpegData(compressionQuality: 0.9) else { return false }

        return await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            if !fm.fileExists(atPath: artFolder.path) {
                try? fm.createDirectory(at: artFolder, withIntermediateDirectories: true)
            }
            let fileURL = artFolder.appendingPathComponent(filename)
            do {
                try jpegData.write(to: fileURL)
                return true
            } catch {
                return false
            }
        }.value
    }

    // MARK: - Private

    private func scheduleOverlayHide() {
        cancelOverlayHide()

        overlayHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isOverlayVisible = false
                }
            }
        }
    }

    private func cancelOverlayHide() {
        overlayHideTask?.cancel()
        overlayHideTask = nil
    }
}
