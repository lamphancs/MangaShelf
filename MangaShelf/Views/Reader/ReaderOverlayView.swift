//
//  ReaderOverlayView.swift
//  MangaShelf
//
//  Created by Khoa Phan on 4/24/26.
//

import SwiftUI

struct ReaderOverlayView: View {

    @Environment(ThemeManager.self) private var theme

    let title: String
    let chapterTitle: String?
    let currentPage: Int
    let totalPages: Int
    let isVisible: Bool
    let isSeries: Bool
    let currentChapterIndex: Int
    let chapters: [Chapter]
    let canGoToPreviousChapter: Bool
    let canGoToNextChapter: Bool
    let onDismiss: () -> Void
    let onPreviousChapter: () -> Void
    let onNextChapter: () -> Void
    let onJumpToChapter: (Int) -> Void

    @State private var showChapterPicker = false

    var body: some View {
        ZStack {
            Color.clear
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar

                Spacer()

                bottomBar
            }
        }
        .opacity(isVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.25), value: isVisible)
        .sheet(isPresented: $showChapterPicker) {
            chapterPickerSheet
        }
    }

    private var chapterPickerLabel: String {
        let currentNum = chapters[safe: currentChapterIndex]?.extractedNumber ?? "\(currentChapterIndex + 1)"
        let lastNum = chapters.last?.extractedNumber ?? "\(chapters.count)"
        return "Ch. \(currentNum)/\(lastNum)"
    }

    private var chapterPickerSheet: some View {
        ScrollViewReader { proxy in
            List(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                Button {
                    showChapterPicker = false
                    onJumpToChapter(index)
                } label: {
                    HStack {
                        Text(chapter.displayName)
                            .foregroundColor(index == currentChapterIndex ? theme.accent : .white)
                            .fontWeight(index == currentChapterIndex ? .semibold : .regular)

                        Spacer()

                        if index == currentChapterIndex {
                            Image(systemName: "checkmark")
                                .foregroundColor(theme.accent)
                                .font(.subheadline)
                        }
                    }
                }
                .id(index)
            }
            .listStyle(.plain)
            .onAppear {
                proxy.scrollTo(currentChapterIndex, anchor: .center)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            if let chapterTitle = chapterTitle {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.title3)
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))

                    Text(chapterTitle)
                        .font(.headline)
                        .foregroundColor(.white.opacity(0.8))
                        .lineLimit(1)
                }
                .shadow(color: .black.opacity(0.5), radius: 6, x: 0, y: 3)
            } else {
                Text(title)
                    .font(.title3)
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.5), radius: 6, x: 0, y: 3)
            }

            Spacer()

            Button {
                UIImpactFeedbackGenerator.impact(.medium)
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.black.opacity(0.5))
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .background(
            LinearGradient(
                colors: [
                    Color.black.opacity(0.7),
                    Color.black.opacity(0.4),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 16) {
            if isSeries {
                Button {
                    UIImpactFeedbackGenerator.impact(.medium)
                    onPreviousChapter()
                } label: {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(canGoToPreviousChapter ? .white : .white.opacity(0.3))
                        .frame(width: 42, height: 42)
                        .background(Color.black.opacity(0.5))
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)
                }
                .disabled(!canGoToPreviousChapter)

                Spacer()

                Button {
                    showChapterPicker = true
                } label: {
                    HStack(spacing: 6) {
                        Text(chapterPickerLabel)
                            .font(.headline)
                            .fontWeight(.medium)
                            .foregroundColor(.white)

                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.5))
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)
                }

                Spacer()

                Button {
                    UIImpactFeedbackGenerator.impact(.medium)
                    onNextChapter()
                } label: {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(canGoToNextChapter ? .white : .white.opacity(0.3))
                        .frame(width: 42, height: 42)
                        .background(Color.black.opacity(0.5))
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)
                }
                .disabled(!canGoToNextChapter)
            } else {
                Spacer()

                Text("Page \(currentPage + 1) / \(totalPages)")
                    .font(.headline)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.5))
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)

                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background(
            LinearGradient(
                colors: [
                    Color.clear,
                    Color.black.opacity(0.4),
                    Color.black.opacity(0.7)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

#Preview {
    ZStack {
        Color.appBackground
            .ignoresSafeArea()

        Rectangle()
            .fill(Color.white)
            .overlay(
                Text("Manga Page Content")
                    .font(.title)
                    .foregroundColor(.black)
            )
            .ignoresSafeArea()

        ReaderOverlayView(
            title: "One Piece",
            chapterTitle: "Volume 1",
            currentPage: 42,
            totalPages: 200,
            isVisible: true,
            isSeries: true,
            currentChapterIndex: 2,
            chapters: [],
            canGoToPreviousChapter: true,
            canGoToNextChapter: true,
            onDismiss: {},
            onPreviousChapter: {},
            onNextChapter: {},
            onJumpToChapter: { _ in }
        )
    }
    .environment(ThemeManager())
    .preferredColorScheme(.dark)
}
