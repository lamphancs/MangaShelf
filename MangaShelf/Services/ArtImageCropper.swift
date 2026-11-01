import UIKit
import ImageIO

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
