import UIKit
import ImageIO

/// Decode only two bounded-size images, off the main thread. Invalid gallery entries are
/// skipped; a gallery with one usable image reuses it for both ends.
enum ChapterArtwork {
    nonisolated static func load(from folder: URL?) -> [UIImage] {
        guard let folder,
              let files = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
              ) else { return [] }
        let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "webp", "gif"]
        var images: [UIImage] = []
        for file in files.filter({ extensions.contains($0.pathExtension.lowercased()) }).shuffled() {
            autoreleasepool {
                guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 2048
                      ] as CFDictionary) else { return }
                images.append(UIImage(cgImage: image))
            }
            if images.count == 2 { break }
        }
        if images.count == 1 { images.append(images[0]) }
        return images
    }
}
