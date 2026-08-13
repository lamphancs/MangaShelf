//
//  BookCardView.swift
//  MangaShelf
//
//  Created by Khoa Phan on 4/24/26.
//

import SwiftUI

struct BookCardView: View {

    @Environment(ThemeManager.self) private var theme

    let book: Book
    let onTap: () -> Void
    let onRename: () -> Void
    let onSetCover: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BookCoverThumbnail(
                book: book,
                displaySize: Self.displaySize,
                placeholderFont: .system(size: 40),
                width: nil,
                height: 230
            )

            VStack(alignment: .leading, spacing: 8) {
                Text(book.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if book.isSeries {
                    seriesProgressView
                } else {
                    singleBookProgressView
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.cardBorder, lineWidth: 3)
        )
        .compositingGroup()
        .shadow(color: Color.black.opacity(0.3), radius: 8, x: 0, y: 4)
        .contentShape(Rectangle())
        .onTapGesture {
            UIImpactFeedbackGenerator.impact(.light)
            onTap()
        }
        .contextMenu {
            Button {
                onSetCover()
            } label: {
                Label("Set Cover", systemImage: "photo.on.rectangle")
            }

            Button {
                onRename()
            } label: {
                Label("Rename", systemImage: "pencil")
            }
        }
    }

    // MARK: - Series Progress

    @ViewBuilder
    private var seriesProgressView: some View {
        let chapterCount = book.sortedChapters.count
        VStack(alignment: .leading, spacing: 4) {
            BookProgressBar(value: book.readingProgress)

            Label(
                book.readingProgress > 0 ? book.chapterProgressLabel() : "\(chapterCount) chapters",
                systemImage: "book.fill"
            )
            .font(.caption2)
            .foregroundColor(.tertiaryText)
        }
    }

    // MARK: - Single Book Progress

    private var singleBookProgressView: some View {
        VStack(alignment: .leading, spacing: 4) {
            BookProgressBar(value: book.readingProgress)

            Label(
                book.lastReadPage > 0
                    ? "Page \(book.lastReadPage + 1) of \(book.totalPages)"
                    : "\(book.totalPages) pages",
                systemImage: "book.fill"
            )
            .font(.caption2)
            .foregroundColor(.tertiaryText)
        }
    }

    private static let displaySize = CGSize(width: 200, height: 230)
}

#Preview {
    let book = Book(
        title: "One Piece Volume 1",
        filename: "one_piece_vol_1.pdf",
        filePath: "/tmp/test.pdf",
        lastReadPage: 45,
        totalPages: 200
    )

    return BookCardView(
        book: book,
        onTap: {},
        onRename: {},
        onSetCover: {}
    )
    .frame(width: 180)
    .padding()
    .environment(ThemeManager())
    .preferredColorScheme(.dark)
}
