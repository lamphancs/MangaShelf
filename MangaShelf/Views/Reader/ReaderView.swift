//
//  ReaderView.swift
//  MangaShelf
//
//  Created by Khoa Phan on 4/24/26.
//

import SwiftUI
import SwiftData

struct ReaderView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var theme

    let book: Book

    @State private var viewModel: ReaderViewModel
    @State private var showCaptureFlash = false

    init(book: Book) {
        self.book = book
        _viewModel = State(initialValue: ReaderViewModel(book: book))
    }

    var body: some View {
        ZStack {
            Color.appBackground
                .ignoresSafeArea()

            PDFPageView(
                pdfDocument: viewModel.pdfDocument,
                currentPage: $viewModel.currentPage,
                onPageChange: { newPage in
                    viewModel.updatePage(newPage, modelContext: modelContext)
                },
                onTap: {
                    viewModel.toggleOverlay()
                },
                onCaptureReady: { captureFunc in
                    viewModel.captureViewport = captureFunc
                }
            )
            .ignoresSafeArea()

            if viewModel.pdfDocument == nil && !viewModel.isLoadingChapter {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(.yellow)

                    Text("Failed to load PDF")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("This file may be corrupted or in an unsupported format.")
                        .font(.body)
                        .foregroundColor(.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)

                    Button {
                        dismiss()
                    } label: {
                        Text("Go Back")
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 12)
                            .background(theme.accent)
                            .cornerRadius(10)
                    }
                    .padding(.top, 8)
                }
                .onTapGesture {
                    viewModel.toggleOverlay()
                }
            }

            if viewModel.isLoadingChapter {
                Color.black.opacity(0.6)
                    .ignoresSafeArea()
                    .transition(.opacity)

                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .transition(.opacity.combined(with: .scale))
            }

            ReaderOverlayView(
                title: book.title,
                chapterTitle: viewModel.currentChapter?.displayName,
                currentPage: viewModel.currentPage,
                totalPages: viewModel.currentChapterTotalPages,
                isVisible: viewModel.isOverlayVisible,
                isSeries: book.isSeries,
                currentChapterIndex: viewModel.currentChapterIndex,
                chapters: viewModel.sortedChapters,
                canGoToPreviousChapter: viewModel.canGoToPreviousChapter,
                canGoToNextChapter: viewModel.canGoToNextChapter,
                onDismiss: {
                    viewModel.saveProgress(modelContext: modelContext)
                    dismiss()
                },
                onPreviousChapter: {
                    viewModel.goToPreviousChapter(modelContext: modelContext)
                },
                onNextChapter: {
                    viewModel.goToNextChapter(modelContext: modelContext)
                },
                onJumpToChapter: { index in
                    viewModel.goToChapter(index: index, modelContext: modelContext)
                }
            )

            if book.isSeries {
                VStack {
                    Spacer()
                    Spacer()
                    Spacer()
                    Button {
                        captureScreenshot()
                    } label: {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)
                    }
                    .accessibilityLabel("Capture page")
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 12)
                .opacity(viewModel.isOverlayVisible ? 1 : 0)
                .animation(.easeInOut(duration: 0.25), value: viewModel.isOverlayVisible)
            }

            Color.white
                .ignoresSafeArea()
                .opacity(showCaptureFlash ? 0.6 : 0)
                .allowsHitTesting(false)
        }
        .statusBar(hidden: !viewModel.isOverlayVisible)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation {
                    viewModel.isOverlayVisible = false
                }
            }
        }
        .onDisappear {
            viewModel.saveProgress(modelContext: modelContext)
            viewModel.cleanup()
        }
        .preferredColorScheme(.dark)
    }

    private func captureScreenshot() {
        Task {
            let success = await viewModel.captureCurrentPage()
            if success {
                UIImpactFeedbackGenerator.impact(.medium)
                withAnimation(.easeIn(duration: 0.05)) {
                    showCaptureFlash = true
                }
                try? await Task.sleep(for: .milliseconds(100))
                withAnimation(.easeOut(duration: 0.3)) {
                    showCaptureFlash = false
                    viewModel.isOverlayVisible = false
                }
            }
        }
    }
}

#Preview {
    let book = Book(
        title: "Sample Manga",
        filename: "sample.pdf",
        filePath: "/tmp/sample.pdf",
        lastReadPage: 10,
        totalPages: 200
    )

    return ReaderView(book: book)
        .modelContainer(for: [Book.self, Chapter.self], inMemory: true)
        .environment(ThemeManager())
        .preferredColorScheme(.dark)
}
