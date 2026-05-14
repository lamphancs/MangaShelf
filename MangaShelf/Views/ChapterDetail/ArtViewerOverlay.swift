//
//  ArtViewerOverlay.swift
//  MangaShelf
//

import SwiftUI

struct ArtItem: Identifiable {
    let id: String
    let image: UIImage
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

    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var theme

    let onDeleteFile: (String) async -> Void
    let onSetCover: (UIImage) async -> Void
    var onOpenInFolder: (() -> Void)?

    init(artImages: [ArtItem], initialIndex: Int,
         onDeleteFile: @escaping (String) async -> Void,
         onSetCover: @escaping (UIImage) async -> Void,
         onOpenInFolder: (() -> Void)? = nil) {
        _artImages = State(initialValue: artImages)
        _currentIndex = State(initialValue: min(initialIndex, max(artImages.count - 1, 0)))
        self.onDeleteFile = onDeleteFile
        self.onSetCover = onSetCover
        self.onOpenInFolder = onOpenInFolder
    }

    var body: some View {
        let dragProgress = min(abs(dragOffset) / 300, 1.0)
        let backgroundOpacity = isDismissing ? 0.0 : (1.0 - dragProgress * 0.5)

        ZStack {
            Color.black.opacity(backgroundOpacity)
                .ignoresSafeArea()

            if !artImages.isEmpty {
                Image(uiImage: artImages[currentIndex].image)
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
                        Menu {
                            Button {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    showCropMode = true
                                }
                            } label: {
                                Label("Use as Cover Image", systemImage: "book.closed")
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
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                }
                .transition(.opacity)
            }

            if showCropMode, currentIndex >= 0, currentIndex < artImages.count {
                CoverCropOverlay(
                    image: artImages[currentIndex].image,
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
