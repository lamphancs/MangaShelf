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

    private var accessedURL: URL?
    private var folderURL: URL?
    private var hasSecurityAccess = false
    private var overlayHideTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var chapterLoadTask: Task<PDFDocument?, Never>?

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

            if let rootURL = resolvedRoot {
                let pdfURL = rootURL.appendingPathComponent(book.filename)
                self.pdfDocument = PDFDocument(url: pdfURL)
            }
        }
    }

    func cleanup() {
        chapterLoadTask?.cancel()
        chapterLoadTask = nil
        saveTask?.cancel()
        saveTask = nil
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
        currentPage = page
        debounceSave(modelContext: modelContext)
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
        if book.isSeries {
            if let chapter = currentChapter {
                chapter.lastReadPage = currentPage
            }
            book.currentChapterIndex = currentChapterIndex
        } else {
            book.lastReadPage = currentPage
        }
        book.lastReadDate = Date()
        try? modelContext.save()
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

    private func debounceSave(modelContext: ModelContext) {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            saveProgress(modelContext: modelContext)
        }
    }
}
