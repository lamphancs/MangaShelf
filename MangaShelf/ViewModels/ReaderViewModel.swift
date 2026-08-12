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
    let sortedChapters: [Chapter]

    var currentChapter: Chapter? {
        guard book.isSeries else { return nil }
        return sortedChapters[safe: currentChapterIndex]
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

    /// Scrolls (animated) to the top of the current chapter, calling the completion once the
    /// top has finished rendering (wired by `PDFPageView`).
    var scrollToTop: ((@escaping () -> Void) -> Void)?

    /// True while the "go to top" button is waiting for the top of the chapter to render.
    var isScrollingToTop = false

    /// True while the reader is restoring a saved scroll position and its tiles are still loading.
    var isRestoringPosition = false

    private var accessedURL: URL?
    private var folderURL: URL?
    private var hasSecurityAccess = false
    private var overlayHideTask: Task<Void, Never>?
    private var chapterLoadTask: Task<PDFDocument?, Never>?
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
            let chapters = book.sortedChapters
            self.sortedChapters = chapters
            let chapterIdx = chapters.isEmpty ? 0 : min(book.currentChapterIndex, chapters.count - 1)
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

    private func navigateToChapter(index: Int, modelContext: ModelContext) {
        guard let chapter = sortedChapters[safe: index],
              let folder = folderURL else { return }

        if let current = currentChapter {
            current.lastReadPage = currentPage
            if let offset = currentOffsetProvider?() {
                current.lastReadOffset = Double(offset)
            }
        }

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

            currentChapterIndex = index
            pdfDocument = doc
            book.currentChapterIndex = currentChapterIndex
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
            book.currentChapterIndex = currentChapterIndex
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
