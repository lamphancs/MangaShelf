import UIKit
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
