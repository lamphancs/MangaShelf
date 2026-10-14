//
//  ArtViewerOverlay.swift
//  MangaShelf
//

import SwiftUI
import ImageIO

struct ArtItem: Identifiable {
    let id: String
    /// Downsampled preview for carousels and thumbnails; the viewer loads full resolution on demand.
    let image: UIImage
    var isCover: Bool = false

    /// Longest side of `image`. Reader captures are full-screen at native scale (~14 MB decoded
    /// each), so keeping every one at full resolution quickly exhausts memory.
    nonisolated static let previewMaxPixelSize: CGFloat = 1400

    /// Decodes a downsampled image straight from disk without decoding the full bitmap first.
    nonisolated static func downsampledImage(at url: URL, maxPixelSize: CGFloat = previewMaxPixelSize) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

private struct ClearFullScreenBackground: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = BackgroundRemovalView()
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    private class BackgroundRemovalView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            superview?.superview?.backgroundColor = .clear
        }
    }
}

struct ArtViewerOverlay: View {
    @State private var artImages: [ArtItem]
    @State private var currentIndex: Int
    @State private var controlsVisible = true
    @State private var dragOffset: CGFloat = 0
    @State private var showCropMode = false
    @State private var isDismissing = false
    @State private var appeared = false
    /// Full-resolution image for the current item only, so at most one is held in memory.
    @State private var fullImage: (id: String, image: UIImage)?

    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var theme

    let onDeleteFile: (String) async -> Void
    let onSetCover: (UIImage) async -> Void
    var onOpenInFolder: (() -> Void)?
    /// Returns an action that opens the reader where the art (by filename) was captured,
    /// or `nil` when its position is unknown. The viewer dismisses itself after running it.
    var openInReaderAction: ((String) -> (() -> Void)?)?
    /// Loads the full-resolution image for an art item (by id), or `nil` to keep the preview.
    var loadFullImage: ((String) async -> UIImage?)?

    init(artImages: [ArtItem], initialIndex: Int,
         onDeleteFile: @escaping (String) async -> Void,
         onSetCover: @escaping (UIImage) async -> Void,
         onOpenInFolder: (() -> Void)? = nil,
         openInReaderAction: ((String) -> (() -> Void)?)? = nil,
         loadFullImage: ((String) async -> UIImage?)? = nil) {
        _artImages = State(initialValue: artImages)
        _currentIndex = State(initialValue: min(initialIndex, max(artImages.count - 1, 0)))
        self.onDeleteFile = onDeleteFile
        self.onSetCover = onSetCover
        self.onOpenInFolder = onOpenInFolder
        self.openInReaderAction = openInReaderAction
        self.loadFullImage = loadFullImage
    }

    private var currentItemID: String? {
        artImages.indices.contains(currentIndex) ? artImages[currentIndex].id : nil
    }

    private func displayImage(at index: Int) -> UIImage {
        let item = artImages[index]
        if let fullImage, fullImage.id == item.id { return fullImage.image }
        return item.image
    }

    var body: some View {
        let dragProgress = min(abs(dragOffset) / 300, 1.0)
        let backgroundOpacity = isDismissing ? 0.0 : (1.0 - dragProgress * 0.5)

        ZStack {
            Color.black.opacity(backgroundOpacity)
                .ignoresSafeArea()

            if !artImages.isEmpty {
                Image(uiImage: displayImage(at: currentIndex))
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: isDismissing ? 24 : dragProgress * 16))
                    .ignoresSafeArea()
                    .offset(y: isDismissing ? 0 : dragOffset)
                    .scaleEffect(isDismissing ? 0.4 : 1 - dragProgress * 0.15)
                    .opacity(isDismissing ? 0 : 1)
                    .gesture(
                        DragGesture(minimumDistance: 20)
                            .onChanged { value in
                                guard !isDismissing else { return }
                                if abs(value.translation.height) > abs(value.translation.width) {
                                    dragOffset = value.translation.height
                                    if controlsVisible && abs(dragOffset) > 10 {
                                        withAnimation(.easeOut(duration: 0.15)) {
                                            controlsVisible = false
                                        }
                                    }
                                }
                            }
                            .onEnded { value in
                                guard !isDismissing else { return }
                                if abs(value.translation.height) > abs(value.translation.width) {
                                    let velocity = value.predictedEndTranslation.height - value.translation.height
                                    let shouldDismiss = abs(dragOffset) > 120 || abs(velocity) > 800

                                    if shouldDismiss {
                                        performDismiss(direction: dragOffset > 0 ? 1 : -1)
                                    } else if dragOffset != 0 {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                            dragOffset = 0
                                        }
                                        withAnimation(.easeOut(duration: 0.2)) {
                                            controlsVisible = true
                                        }
                                    }
                                } else {
                                    if value.translation.width < -50 && currentIndex < artImages.count - 1 {
                                        withAnimation(.easeInOut(duration: 0.25)) { currentIndex += 1 }
                                    } else if value.translation.width > 50 && currentIndex > 0 {
                                        withAnimation(.easeInOut(duration: 0.25)) { currentIndex -= 1 }
                                    }
                                }
                            }
                    )
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            controlsVisible.toggle()
                        }
                    }
            }

            if controlsVisible && !isDismissing {
                VStack(spacing: 0) {
                    HStack {
                        Button {
                            performDismiss(direction: -1)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(.ultraThinMaterial, in: Circle())
                        }

                        Spacer()

                        if !artImages.isEmpty {
                            Text("\(min(currentIndex + 1, artImages.count)) of \(artImages.count)")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(.white.opacity(0.7))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(.ultraThinMaterial, in: Capsule())
                        }

                        Spacer()

                        Color.clear.frame(width: 32, height: 32)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                    Spacer()

                    if artImages.count > 1 {
                        thumbnailStrip
                    }

                    HStack {
                        let isCoverCurrent = currentIndex >= 0 && currentIndex < artImages.count && artImages[currentIndex].isCover

                        Menu {
                            if !isCoverCurrent,
                               let openInReader = openInReaderAction?(artImages[currentIndex].id) {
                                Button {
                                    openInReader()
                                    performDismiss(direction: -1)
                                } label: {
                                    Label("Open in Reader", systemImage: "book")
                                }
                            }

                            if !isCoverCurrent {
                                Button {
                                    withAnimation(.easeInOut(duration: 0.25)) {
                                        showCropMode = true
                                    }
                                } label: {
                                    Label("Use as Cover Image", systemImage: "book.closed")
                                }
                            }

                            if let onOpenInFolder {
                                Button {
                                    onOpenInFolder()
                                } label: {
                                    Label("Show in Files", systemImage: "folder")
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(.ultraThinMaterial, in: Circle())
                        }

                        Spacer()

                        if !isCoverCurrent {
                            Button(role: .destructive) {
                                Task { await deleteArt() }
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                                    .background(.ultraThinMaterial, in: Circle())
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                }
                .transition(.opacity)
            }

            if showCropMode, currentIndex >= 0, currentIndex < artImages.count {
                CoverCropOverlay(
                    image: displayImage(at: currentIndex),
                    onConfirm: { croppedImage in
                        withAnimation(.easeInOut(duration: 0.25)) {
                            showCropMode = false
                        }
                        Task { await onSetCover(croppedImage) }
                    },
                    onCancel: {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            showCropMode = false
                        }
                    }
                )
                .transition(.opacity)
            }
        }
        .background(ClearFullScreenBackground())
        .preferredColorScheme(.dark)
        .statusBarHidden(!controlsVisible)
        .task(id: currentItemID) {
            guard let id = currentItemID, let loadFullImage else { return }
            let image = await loadFullImage(id)
            guard !Task.isCancelled, id == currentItemID else { return }
            // Replacing the previous full image releases it.
            fullImage = image.map { (id, $0) }
        }
    }

    private var thumbnailStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(Array(artImages.enumerated()), id: \.element.id) { index, art in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                currentIndex = index
                            }
                        } label: {
                            Image(uiImage: art.image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .opacity(currentIndex == index ? 1.0 : 0.35)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .strokeBorder(.white, lineWidth: currentIndex == index ? 1.5 : 0)
                                )
                        }
                        .id(index)
                    }
                }
                .padding(.horizontal, 20)
            }
            .onAppear {
                proxy.scrollTo(currentIndex, anchor: .center)
            }
            .onChange(of: currentIndex) { _, newIndex in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private func performDismiss(direction: CGFloat) {
        withAnimation(.easeInOut(duration: 0.3)) {
            isDismissing = true
            dragOffset = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            dismiss()
        }
    }

    private func deleteArt() async {
        let index = currentIndex
        guard index >= 0, index < artImages.count else { return }
        let item = artImages[index]
        await onDeleteFile(item.id)
        withAnimation {
            artImages.remove(at: index)
            if artImages.isEmpty {
                dismiss()
            } else if currentIndex >= artImages.count {
                currentIndex = artImages.count - 1
            }
        }
    }
}
