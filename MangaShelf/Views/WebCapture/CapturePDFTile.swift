import SwiftUI

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

struct CapturePDFTile: View {
    let renderer: CapturePDFTileRenderer
    let crop: CGRect
    let displaySize: CGSize
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var failed = false

    private struct RenderKey: Hashable {
        let top: CGFloat
        let height: CGFloat
        let pixelWidth: Int
    }

    var body: some View {
        let key = RenderKey(top: crop.minY, height: crop.height,
                            pixelWidth: max(1, Int(ceil(displaySize.width * displayScale))))
        ZStack {
            Color.white
            if let image {
                Image(uiImage: image).resizable()
            } else if failed {
                Label("Preview unavailable", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.black)
            } else {
                ProgressView().tint(.gray)
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .task(id: key) {
            image = nil
            failed = false
            do {
                let result = try await renderer.image(crop: crop, pixelWidth: key.pixelWidth)
                try Task.checkCancellation()
                image = result
            } catch is CancellationError {
            } catch { failed = true }
        }
        .onDisappear { image = nil }
    }
}
