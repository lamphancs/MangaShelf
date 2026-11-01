import UIKit

/// Serial background renderer with a bounded cache. A chapter's total length never
/// determines the resolution of a visible tile, and offscreen views release images.
actor CapturePDFTileRenderer {
    private(set) var renderedTileCount = 0
    private let document: WebCaptureDocument
    private let cache = NSCache<NSString, UIImage>()

    init(document: WebCaptureDocument) {
        self.document = document
        cache.totalCostLimit = 24 * 1024 * 1024
        cache.countLimit = 24
    }

    func image(crop: CGRect, pixelWidth: Int) throws -> UIImage {
        try Task.checkCancellation()
        let key = "\(crop.minY):\(crop.height):\(pixelWidth)" as NSString
        if let image = cache.object(forKey: key) { return image }
        renderedTileCount += 1
        let image = try document.render(crop: crop, pixelWidth: CGFloat(pixelWidth))
        try Task.checkCancellation()
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        cache.setObject(image, forKey: key, cost: cost)
        return image
    }
}
