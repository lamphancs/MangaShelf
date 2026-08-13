//
//  BookRowView.swift
//  MangaShelf
//

import SwiftUI

struct BookRowView: View {

    @Environment(ThemeManager.self) private var theme

    let book: Book
    let onTap: () -> Void
    let onRename: () -> Void
    let onSetCover: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            BookCoverThumbnail(
                book: book,
                displaySize: Self.displaySize,
                placeholderFont: .title3,
                width: 60,
                height: 80,
                cornerRadius: 8
            )

            VStack(alignment: .leading, spacing: 6) {
                Text(book.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .lineLimit(1)

                if book.isSeries {
                    seriesLabel
                } else {
                    singleBookLabel
                }

                BookProgressBar(value: book.readingProgress)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.cardBorder, lineWidth: 1)
        )
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

    // MARK: - Labels

    private var seriesLabel: some View {
        let chapterCount = book.sortedChapters.count
        return Label(
            book.readingProgress > 0 ? book.chapterProgressLabel() : "\(chapterCount) chapters",
            systemImage: "book.fill"
        )
        .font(.caption)
        .foregroundColor(.tertiaryText)
    }

    private var singleBookLabel: some View {
        Label(
            book.lastReadPage > 0
                ? "Page \(book.lastReadPage + 1) of \(book.totalPages)"
                : "\(book.totalPages) pages",
            systemImage: "book.fill"
        )
        .font(.caption)
        .foregroundColor(.tertiaryText)
    }

    private static let displaySize = CGSize(width: 60, height: 80)
}

#Preview {
    let book = Book(
        title: "One Piece Volume 1",
        filename: "one_piece_vol_1.pdf",
        filePath: "/tmp/test.pdf",
        lastReadPage: 45,
        totalPages: 200
    )

    return BookRowView(
        book: book,
        onTap: {},
        onRename: {},
        onSetCover: {}
    )
    .padding()
    .environment(ThemeManager())
    .preferredColorScheme(.dark)
}
