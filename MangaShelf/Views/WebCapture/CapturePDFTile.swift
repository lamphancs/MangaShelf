import SwiftUI

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
