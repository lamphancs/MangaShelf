//
//  LibraryCellComponents.swift
//  MangaShelf
//
//  Shared UI used by both the grid card (`BookCardView`) and the list row
//  (`BookRowView`): the async-loading cover thumbnail and the reading-progress bar.
//

import SwiftUI

/// A book cover thumbnail that loads (and caches) its image via `ThumbnailService`,
/// showing a spinner while loading and a placeholder glyph when there is no cover.
///
/// Layout parameters mirror the two call sites exactly:
/// - grid card: `width == nil` (fills available width), `aspectRatio == 2:3`, no corner clip
/// - list row: `width == 60`, `height == 80`, `cornerRadius == 8`
struct BookCoverThumbnail: View {

    @Environment(ThemeManager.self) private var theme
    @Environment(\.displayScale) private var displayScale

    let book: Book
    let displaySize: CGSize
    let placeholderFont: Font
    var width: CGFloat? = nil
    var height: CGFloat? = nil
    /// Width / height of the cover frame, used when `width` is nil and no fixed `height` is given.
    var aspectRatio: CGFloat? = nil
    var cornerRadius: CGFloat? = nil

    @State private var thumbnailImage: UIImage?
    @State private var isLoadingThumbnail = true

    var body: some View {
        sizedFill
            .overlay { overlayContent }
            .clipped()
            .modifier(OptionalCornerClip(cornerRadius: cornerRadius))
            .task(id: "\(book.thumbnailPath ?? "")-\(book.coverVersion)") {
                await loadThumbnail()
            }
    }

    @ViewBuilder
    private var sizedFill: some View {
        if let width {
            Rectangle()
                .fill(theme.cardBackground)
                .frame(width: width, height: height)
        } else if let height {
            Rectangle()
                .fill(theme.cardBackground)
                .frame(maxWidth: .infinity)
                .frame(height: height)
        } else {
            // Fill the available width and derive the height from the cover ratio.
            Rectangle()
                .fill(theme.cardBackground)
                .aspectRatio(aspectRatio ?? Layout.coverSize.width / Layout.coverSize.height, contentMode: .fit)
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var overlayContent: some View {
        if let image = thumbnailImage {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if isLoadingThumbnail {
            ProgressView()
                .tint(theme.accent)
        } else {
            Image(systemName: "book.closed.fill")
                .font(placeholderFont)
                .foregroundStyle(Color.tertiaryText)
        }
    }

    private func loadThumbnail() async {
        guard let thumbnailURL = book.thumbnailURL else {
            isLoadingThumbnail = false
            return
        }

        let scale = displayScale
        let targetSize = CGSize(
            width: displaySize.width * scale,
            height: displaySize.height * scale
        )

        if let image = await ThumbnailService.shared.cachedImage(for: thumbnailURL, targetSize: targetSize) {
            thumbnailImage = image
        }
        isLoadingThumbnail = false
    }
}

/// Slim reading-progress capsule filled to `value` (0.0–1.0) in the accent color.
struct BookProgressBar: View {

    @Environment(ThemeManager.self) private var theme

    let value: Double

    var body: some View {
        Capsule()
            .fill(Color.white.opacity(0.15))
            .frame(height: 3)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(theme.accent)
                    .frame(width: value > 0 ? nil : 0, height: 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .scaleEffect(x: value, anchor: .leading)
            }
            .clipped()
    }
}

/// Applies a continuous rounded-corner clip only when a radius is provided.
private struct OptionalCornerClip: ViewModifier {
    let cornerRadius: CGFloat?

    func body(content: Content) -> some View {
        if let cornerRadius {
            content.clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content
        }
    }
}
