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

    @State private var keepWholeImage = false
    @State private var cropFraction: CGFloat = 0.9
    @GestureState private var magnification: CGFloat = 1

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button("Done") {
                    onConfirm(renderCover())
                }
                .disabled(previewSize.width <= 0 || previewSize.height <= 0)
                .fontWeight(.semibold)
                .tint(theme.accent)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal)

            GeometryReader { geometry in
                let canvas = CGRect(origin: .zero, size: geometry.size)
                let cover = fittedRect(aspect: Layout.coverAspectRatio, inside: canvas)
                let imageRect = fittedRect(
                    aspect: image.size.width / image.size.height,
                    inside: keepWholeImage ? cover : canvas
                )
                let crop = keepWholeImage ? cover : cropRect(in: imageRect)

                ZStack(alignment: .topLeading) {
                    Color.clear
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: imageRect.width, height: imageRect.height)
                        .position(x: imageRect.midX, y: imageRect.midY)

                    if keepWholeImage {
                        Rectangle()
                            .strokeBorder(.white.opacity(0.4))
                            .frame(width: cover.width, height: cover.height)
                            .position(x: cover.midX, y: cover.midY)
                    } else {
                        Rectangle()
                            .fill(Color.black.opacity(0.55))
                            .overlay {
                                Rectangle()
                                    .frame(width: crop.width, height: crop.height)
                                    .position(x: crop.midX, y: crop.midY)
                                    .blendMode(.destinationOut)
                            }
                            .compositingGroup()
                        cropBoxDecoration(origin: crop.origin, size: crop.size,
                                          center: CGPoint(x: crop.midX, y: crop.midY))
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(DragGesture()
                                .updating($dragTranslation) { value, state, _ in
                                    state = value.translation
                                }
                                .onEnded { value in
                                    boxOffset = clampedOffset(translation: value.translation,
                                                              cropSize: crop.size, imageRect: imageRect)
                                })
                            .simultaneousGesture(MagnifyGesture()
                                .updating($magnification) { value, state, _ in
                                    state = value.magnification
                                }
                                .onEnded { value in
                                    cropFraction = boundedFraction(value.magnification)
                                    let size = cropSize(in: imageRect, fraction: cropFraction)
                                    boxOffset = clampedOffset(translation: .zero, cropSize: size,
                                                              imageRect: imageRect)
                                })
                    }
                }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { previewSize = $0 }
            }
            .padding(.horizontal, 12)

            Text(keepWholeImage ? "Black borders fill any extra space." : "Pinch to resize the frame. Drag to move it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Picker("Cover framing", selection: $keepWholeImage) {
                Text("Crop to Fill").tag(false)
                Text("Keep Whole Image").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
        }
        .background(Color.black.ignoresSafeArea())
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

    @State private var previewSize: CGSize = .zero

    private func fittedRect(aspect: CGFloat, inside bounds: CGRect) -> CGRect {
        let width = min(bounds.width, bounds.height * aspect)
        let height = width / aspect
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2,
                      width: width, height: height)
    }

    private func boundedFraction(_ magnification: CGFloat) -> CGFloat {
        min(1, max(0.1, cropFraction * magnification))
    }

    private func cropSize(in imageRect: CGRect, fraction: CGFloat) -> CGSize {
        let fit = fittedRect(aspect: Layout.coverAspectRatio, inside: imageRect)
        return CGSize(width: fit.width * fraction, height: fit.height * fraction)
    }

    private func clampedOffset(translation: CGSize, cropSize: CGSize, imageRect: CGRect) -> CGSize {
        let dx = max(0, (imageRect.width - cropSize.width) / 2)
        let dy = max(0, (imageRect.height - cropSize.height) / 2)
        return CGSize(width: min(dx, max(-dx, boxOffset.width + translation.width)),
                      height: min(dy, max(-dy, boxOffset.height + translation.height)))
    }

    private func cropRect(in imageRect: CGRect) -> CGRect {
        let size = cropSize(in: imageRect, fraction: boundedFraction(magnification))
        let offset = clampedOffset(translation: dragTranslation, cropSize: size, imageRect: imageRect)
        return CGRect(x: imageRect.midX + offset.width - size.width / 2,
                      y: imageRect.midY + offset.height - size.height / 2,
                      width: size.width, height: size.height)
    }

    private func renderCover() -> UIImage {
        let output = CGRect(origin: .zero, size: Layout.coverSize)
        let aspect = image.size.width / image.size.height
        let drawRect: CGRect
        if keepWholeImage {
            drawRect = fittedRect(aspect: aspect, inside: output)
        } else {
            let imageRect = fittedRect(aspect: aspect, inside: CGRect(origin: .zero, size: previewSize))
            let crop = cropRect(in: imageRect)
            let scale = output.width / crop.width
            drawRect = CGRect(x: (imageRect.minX - crop.minX) * scale,
                              y: (imageRect.minY - crop.minY) * scale,
                              width: imageRect.width * scale, height: imageRect.height * scale)
        }
        return UIGraphicsImageRenderer(size: output.size).image { context in
            UIColor.black.setFill()
            context.fill(output)
            image.draw(in: drawRect)
        }
    }
}
