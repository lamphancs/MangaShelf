//
//  CoverCropOverlay.swift
//  MangaShelf
//

import SwiftUI

struct CoverCropOverlay: View {
    let image: UIImage
    let onConfirm: (UIImage) -> Void
    let onCancel: () -> Void

    @Environment(ThemeManager.self) private var theme

    @State private var boxOffset: CGSize = .zero
    @GestureState private var dragTranslation: CGSize = .zero

    private let coverAspectRatio: CGFloat = 2.0 / 3.0
    private let imageScale: CGFloat = 0.8
    private static let standardCoverSize = CGSize(width: 400, height: 600)

    var body: some View {
        GeometryReader { geometry in
            let containerSize = geometry.size
            let imageDisplay = imageDisplayRect(in: containerSize)
            let boxSize = cropBoxSize(imageDisplay: imageDisplay)
            let totalOffset = CGSize(
                width: boxOffset.width + dragTranslation.width,
                height: boxOffset.height + dragTranslation.height
            )
            let boxCenter = clampedCenter(
                totalOffset: totalOffset,
                imageDisplay: imageDisplay,
                boxSize: boxSize,
                containerSize: containerSize
            )
            let boxOrigin = CGPoint(
                x: boxCenter.x - boxSize.width / 2,
                y: boxCenter.y - boxSize.height / 2
            )

            ZStack {
                Color.black.ignoresSafeArea()

                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scaleEffect(imageScale)

                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture()
                            .updating($dragTranslation) { value, state, _ in
                                state = value.translation
                            }
                            .onEnded { value in
                                let newOffset = CGSize(
                                    width: boxOffset.width + value.translation.width,
                                    height: boxOffset.height + value.translation.height
                                )
                                boxOffset = clampOffset(
                                    newOffset,
                                    imageDisplay: imageDisplay,
                                    boxSize: boxSize,
                                    containerSize: containerSize
                                )
                            }
                    )

                Rectangle()
                    .fill(Color.black.opacity(0.55))
                    .overlay {
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: boxSize.width, height: boxSize.height)
                            .position(boxCenter)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
                    .allowsHitTesting(false)

                cropBoxDecoration(origin: boxOrigin, size: boxSize, center: boxCenter)
                    .allowsHitTesting(false)

                VStack(spacing: 0) {
                    HStack {
                        Button {
                            onCancel()
                        } label: {
                            Text("Cancel")
                                .font(.body)
                                .foregroundStyle(.white)
                                .padding(.vertical, 8)
                                .padding(.horizontal, 14)
                                .background(.ultraThinMaterial, in: Capsule())
                                .contentShape(Capsule())
                        }

                        Spacer()

                        Button {
                            if let cropped = cropImage(
                                boxCenter: boxCenter,
                                boxSize: boxSize,
                                imageDisplay: imageDisplay
                            ) {
                                onConfirm(cropped)
                            }
                        } label: {
                            Text("Done")
                                .font(.body)
                                .fontWeight(.semibold)
                                .foregroundStyle(.white)
                                .padding(.vertical, 8)
                                .padding(.horizontal, 18)
                                .background(theme.accent, in: Capsule())
                                .contentShape(Capsule())
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 4)

                    Spacer()
                }
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
    }

    // MARK: - Crop Box Visuals

    private func cropBoxDecoration(origin: CGPoint, size: CGSize, center: CGPoint) -> some View {
        ZStack {
            Rectangle()
                .strokeBorder(Color.white.opacity(0.4), lineWidth: 1)
                .frame(width: size.width, height: size.height)
                .position(center)

            gridLines(origin: origin, size: size)

            cornerBrackets(origin: origin, size: size)
        }
    }

    private func gridLines(origin: CGPoint, size: CGSize) -> some View {
        let thirdW = size.width / 3
        let thirdH = size.height / 3

        return ZStack {
            ForEach(1..<3, id: \.self) { i in
                Rectangle()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 1, height: size.height)
                    .position(
                        x: origin.x + thirdW * CGFloat(i),
                        y: origin.y + size.height / 2
                    )

                Rectangle()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: size.width, height: 1)
                    .position(
                        x: origin.x + size.width / 2,
                        y: origin.y + thirdH * CGFloat(i)
                    )
            }
        }
    }

    private func cornerBrackets(origin: CGPoint, size: CGSize) -> some View {
        let length: CGFloat = 20
        let weight: CGFloat = 3

        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: origin.x, y: origin.y), 1, 1),
            (CGPoint(x: origin.x + size.width, y: origin.y), -1, 1),
            (CGPoint(x: origin.x, y: origin.y + size.height), 1, -1),
            (CGPoint(x: origin.x + size.width, y: origin.y + size.height), -1, -1),
        ]

        return ForEach(Array(corners.enumerated()), id: \.offset) { _, item in
            let (pt, hDir, vDir) = item
            ZStack {
                RoundedRectangle(cornerRadius: weight / 2)
                    .fill(Color.white)
                    .frame(width: length, height: weight)
                    .position(x: pt.x + hDir * length / 2, y: pt.y)

                RoundedRectangle(cornerRadius: weight / 2)
                    .fill(Color.white)
                    .frame(width: weight, height: length)
                    .position(x: pt.x, y: pt.y + vDir * length / 2)
            }
        }
    }

    // MARK: - Layout Calculations

    private func imageDisplayRect(in containerSize: CGSize) -> CGRect {
        let imageAspect = image.size.width / image.size.height
        let containerAspect = containerSize.width / containerSize.height

        var displayedWidth: CGFloat
        var displayedHeight: CGFloat

        if imageAspect > containerAspect {
            displayedWidth = containerSize.width
            displayedHeight = containerSize.width / imageAspect
        } else {
            displayedHeight = containerSize.height
            displayedWidth = containerSize.height * imageAspect
        }

        displayedWidth *= imageScale
        displayedHeight *= imageScale

        let originX = (containerSize.width - displayedWidth) / 2
        let originY = (containerSize.height - displayedHeight) / 2

        return CGRect(x: originX, y: originY, width: displayedWidth, height: displayedHeight)
    }

    private func cropBoxSize(imageDisplay: CGRect) -> CGSize {
        let widthFit = CGSize(
            width: imageDisplay.width * 0.9,
            height: imageDisplay.width * 0.9 / coverAspectRatio
        )

        if widthFit.height <= imageDisplay.height {
            return widthFit
        }

        let fittedHeight = imageDisplay.height * 0.9
        return CGSize(
            width: fittedHeight * coverAspectRatio,
            height: fittedHeight
        )
    }

    private func clampedCenter(
        totalOffset: CGSize,
        imageDisplay: CGRect,
        boxSize: CGSize,
        containerSize: CGSize
    ) -> CGPoint {
        let centerX = containerSize.width / 2 + totalOffset.width
        let centerY = containerSize.height / 2 + totalOffset.height

        let minX = imageDisplay.minX + boxSize.width / 2
        let maxX = imageDisplay.maxX - boxSize.width / 2
        let minY = imageDisplay.minY + boxSize.height / 2
        let maxY = imageDisplay.maxY - boxSize.height / 2

        return CGPoint(
            x: min(max(centerX, minX), maxX),
            y: min(max(centerY, minY), maxY)
        )
    }

    private func clampOffset(
        _ offset: CGSize,
        imageDisplay: CGRect,
        boxSize: CGSize,
        containerSize: CGSize
    ) -> CGSize {
        let centerX = containerSize.width / 2 + offset.width
        let centerY = containerSize.height / 2 + offset.height

        let minX = imageDisplay.minX + boxSize.width / 2
        let maxX = imageDisplay.maxX - boxSize.width / 2
        let minY = imageDisplay.minY + boxSize.height / 2
        let maxY = imageDisplay.maxY - boxSize.height / 2

        let clampedX = min(max(centerX, minX), maxX)
        let clampedY = min(max(centerY, minY), maxY)

        return CGSize(
            width: clampedX - containerSize.width / 2,
            height: clampedY - containerSize.height / 2
        )
    }

    // MARK: - Image Cropping

    private func cropImage(
        boxCenter: CGPoint,
        boxSize: CGSize,
        imageDisplay: CGRect
    ) -> UIImage? {
        let scale = image.size.width / imageDisplay.width

        let cropX = (boxCenter.x - boxSize.width / 2 - imageDisplay.minX) * scale
        let cropY = (boxCenter.y - boxSize.height / 2 - imageDisplay.minY) * scale
        let cropWidth = boxSize.width * scale
        let cropHeight = boxSize.height * scale

        let cropRect = CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight)

        let outputSize = Self.standardCoverSize
        let renderer = UIGraphicsImageRenderer(size: outputSize)
        return renderer.image { _ in
            let drawRect = CGRect(
                x: -cropRect.origin.x * (outputSize.width / cropRect.width),
                y: -cropRect.origin.y * (outputSize.height / cropRect.height),
                width: image.size.width * (outputSize.width / cropRect.width),
                height: image.size.height * (outputSize.height / cropRect.height)
            )
            image.draw(in: drawRect)
        }
    }
}
