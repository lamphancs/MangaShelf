import SwiftUI
import ImageIO

/// Freeform image crop. Coordinates stay normalized when the device rotates.
struct ArtImageCropOverlay: View {
    let image: UIImage
    let onSave: (CGRect) async throws -> Void
    let onCancel: () -> Void

    @State private var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var dragStart: CGRect?
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button("Reset") { crop = CGRect(x: 0, y: 0, width: 1, height: 1) }
                Spacer()
                Button {
                    isSaving = true
                    Task {
                        do { try await onSave(crop) }
                        catch { errorMessage = error.localizedDescription }
                        isSaving = false
                    }
                } label: {
                    if isSaving { ProgressView() } else { Text("Save").bold() }
                }
            }
            .padding()
            .disabled(isSaving)

            GeometryReader { geometry in
                let scale = min(geometry.size.width / image.size.width,
                                geometry.size.height / image.size.height)
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                let selection = CGRect(x: crop.minX * size.width, y: crop.minY * size.height,
                                       width: crop.width * size.width, height: crop.height * size.height)
                ZStack(alignment: .topLeading) {
                    Image(uiImage: image).resizable().frame(width: size.width, height: size.height)
                    Path { path in
                        path.addRect(CGRect(origin: .zero, size: size))
                        path.addRect(selection)
                    }
                    .fill(.black.opacity(0.6), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)

                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .overlay { Rectangle().strokeBorder(.white, lineWidth: 2) }
                        .frame(width: selection.width, height: selection.height)
                        .position(x: selection.midX, y: selection.midY)
                        .gesture(moveGesture(size: size))

                    ForEach(0..<4) { corner in
                        let right = corner % 2 == 1
                        let bottom = corner >= 2
                        Circle().fill(.white).frame(width: 12, height: 12)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                            .position(x: right ? selection.maxX : selection.minX,
                                      y: bottom ? selection.maxY : selection.minY)
                            .gesture(resizeGesture(size: size, right: right, bottom: bottom))
                            .accessibilityLabel("Crop corner \(corner + 1)")
                    }
                }
                .frame(width: size.width, height: size.height)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                .allowsHitTesting(!isSaving)
            }
            .padding(24)
            Text("Drag the corners to crop. Save replaces the original image.")
                .font(.footnote).foregroundStyle(.secondary).padding(.bottom)
        }
        .background(.black)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(isSaving)
        .alert("Couldn't Crop Image", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func moveGesture(size: CGSize) -> some Gesture {
        DragGesture().onChanged { value in
            let start = dragStart ?? crop
            dragStart = start
            crop.origin.x = min(1 - start.width, max(0, start.minX + value.translation.width / size.width))
            crop.origin.y = min(1 - start.height, max(0, start.minY + value.translation.height / size.height))
        }.onEnded { _ in dragStart = nil }
    }

    private func resizeGesture(size: CGSize, right: Bool, bottom: Bool) -> some Gesture {
        DragGesture().onChanged { value in
            let start = dragStart ?? crop
            dragStart = start
            let dx = value.translation.width / size.width
            let dy = value.translation.height / size.height
            let minWidth = min(1, 32 / size.width)
            let minHeight = min(1, 32 / size.height)
            let left = right ? start.minX : min(start.maxX - minWidth, max(0, start.minX + dx))
            let top = bottom ? start.minY : min(start.maxY - minHeight, max(0, start.minY + dy))
            let endX = right ? max(start.minX + minWidth, min(1, start.maxX + dx)) : start.maxX
            let endY = bottom ? max(start.minY + minHeight, min(1, start.maxY + dy)) : start.maxY
            crop = CGRect(x: left, y: top, width: endX - left, height: endY - top)
        }.onEnded { _ in dragStart = nil }
    }
}

/// Keeps pixel resolution, corrects UIImage orientation, and atomically replaces the same file.
enum ArtImageCropper {
    nonisolated static func crop(_ image: UIImage, to selection: CGRect) throws -> UIImage {
        let rect = selection.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { throw CropError.invalidSelection }
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let output = CGSize(width: max(1, floor(pixels.width * rect.width)),
                            height: max(1, floor(pixels.height * rect.height)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: output, format: format).image { _ in
            image.draw(in: CGRect(x: -rect.minX * pixels.width, y: -rect.minY * pixels.height,
                                  width: pixels.width, height: pixels.height))
        }
    }

    nonisolated static func replaceImage(at url: URL, with image: UIImage) throws -> UIImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source), let cgImage = image.cgImage else {
            throw CropError.unreadableImage
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else {
            throw CropError.unsupportedFormat
        }
        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CropError.encodingFailed }
        // Decode the result before committing so a failed conversion never damages the original.
        guard UIImage(data: data as Data) != nil else { throw CropError.encodingFailed }
        try (data as Data).write(to: url, options: .atomic)
        return ArtItem.downsampledImage(at: url) ?? image
    }

    enum CropError: LocalizedError {
        case invalidSelection, unreadableImage, unsupportedFormat, encodingFailed, unavailableFolder
        var errorDescription: String? {
            switch self {
            case .invalidSelection: "Choose a non-empty crop area."
            case .unreadableImage: "The original image could not be read."
            case .unsupportedFormat: "This image format cannot be saved by this device. The original is unchanged."
            case .encodingFailed: "The cropped image could not be encoded. The original is unchanged."
            case .unavailableFolder: "The album folder could not be accessed."
            }
        }
    }
}
