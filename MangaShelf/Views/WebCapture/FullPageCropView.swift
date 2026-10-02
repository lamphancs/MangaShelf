import SwiftUI

/// Coordinates are normalized against the entire document, independent of scrolling or preview size.
struct FullPageCropView: View {
    let document: WebCaptureDocument
    @State private var renderer: CapturePDFTileRenderer
    @Binding var crop: CGRect
    let overview: Bool
    @Environment(ThemeManager.self) private var theme
    @State private var visibleRect: CGRect = .zero
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var dragOrigin: CGRect?

    init(document: WebCaptureDocument, crop: Binding<CGRect>, overview: Bool, renderer: CapturePDFTileRenderer? = nil) {
        self.document = document
        self._crop = crop
        self.overview = overview
        self._renderer = State(initialValue: renderer ?? CapturePDFTileRenderer(document: document))
    }

    var body: some View {
        GeometryReader { geometry in
            let available = CGSize(width: max(1, geometry.size.width - 48), height: max(1, geometry.size.height - 48))
            // Fitting an entire 100,000-point chapter into one screen makes its
            // width almost zero. Keep Overview usable and scroll it when necessary.
            let fittedWidth = available.height * document.size.width / document.size.height
            let width = overview ? min(available.width, max(100, fittedWidth)) : available.width
            let size = CGSize(width: width, height: document.size.height * width / document.size.width)
            let canvasTop = max(24, (geometry.size.height - size.height) / 2)
            let viewport = visibleRect.isEmpty ? CGRect(origin: .zero, size: geometry.size) : visibleRect
            let first = max(0, Int(floor((viewport.minY - canvasTop) / 384)) - 1)
            let last = min(Int(ceil(size.height / 384)), max(first, Int(ceil((viewport.maxY - canvasTop) / 384)) + 1))
            ScrollView([.horizontal, .vertical]) {
                canvas(size: size, visibleTiles: first..<max(first, last))
                    .padding(24)
                    .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
            }
            .defaultScrollAnchor(.top)
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: CGRect.self) { $0.visibleRect } action: { _, rect in
                visibleRect = rect
            }
            .overlay(alignment: .bottomTrailing) {
                VStack(spacing: 8) {
                    Button {
                        scrollPosition.scrollTo(edge: .top)
                    } label: {
                        Image(systemName: "arrow.up.to.line")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Go to top")
                    Button {
                        // Keep the lower crop handles visible above the viewport edge.
                        let cropBottom = canvasTop + crop.maxY * size.height
                        let maxOffset = max(0, size.height + 48 - geometry.size.height)
                        let offset = min(maxOffset, max(0, cropBottom - geometry.size.height + 80))
                        scrollPosition.scrollTo(y: offset)
                    } label: {
                        Image(systemName: "arrow.down.to.line")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Go to crop bottom")
                }
                .font(.system(size: 18, weight: .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(theme.accent)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(12)
            }
        }
    }

    private func canvas(size: CGSize, visibleTiles: Range<Int>) -> some View {
        let rect = CGRect(x: crop.minX * size.width, y: crop.minY * size.height,
                          width: crop.width * size.width, height: crop.height * size.height)
        return ZStack(alignment: .topLeading) {
            // Absolute tile placement avoids LazyVStack's estimated offsets on
            // very tall canvases. Pixels and crop handles share this exact origin.
            Color.white
                .frame(width: size.width, height: size.height)
                .overlay(alignment: .topLeading) {
                    ForEach(visibleTiles, id: \.self) { index in
                        let top = CGFloat(index) * 384
                        let height = min(384, size.height - top)
                        CapturePDFTile(renderer: renderer,
                                       crop: CGRect(x: 0, y: top / size.height, width: 1, height: height / size.height),
                                       displaySize: CGSize(width: size.width, height: height))
                            .offset(y: top)
                    }
                }
            Path { path in
                path.addRect(CGRect(origin: .zero, size: size))
                path.addRect(rect)
            }
            .fill(.black.opacity(0.6), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
            Rectangle()
                .strokeBorder(theme.accent, lineWidth: 2)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
            ForEach(0..<4) { corner in
                let right = corner % 2 == 1
                let bottom = corner >= 2
                Circle()
                    .fill(theme.accent)
                    .frame(width: 14, height: 14)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .position(x: right ? rect.maxX : rect.minX, y: bottom ? rect.maxY : rect.minY)
                    .highPriorityGesture(resizeGesture(corner: corner, size: size))
                    .accessibilityLabel("Crop \(bottom ? "bottom" : "top") \(right ? "right" : "left") corner")
            }
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.65), in: Circle())
                .position(x: rect.midX, y: rect.midY)
                .highPriorityGesture(moveGesture(size: size))
                .accessibilityLabel("Move crop selection")
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: "captureCanvas")
    }

    private func resizeGesture(corner: Int, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("captureCanvas"))
            .onChanged { value in
                if dragOrigin == nil { dragOrigin = crop }
                guard let start = dragOrigin else { return }
                let dx = value.translation.width / size.width
                let dy = value.translation.height / size.height
                // Keep a nonempty selection without imposing an aspect ratio.
                let minWidth = min(0.1, 24 / document.size.width)
                let minHeight = min(0.1, 24 / document.size.height)
                var left = start.minX, right = start.maxX, top = start.minY, bottom = start.maxY
                if corner % 2 == 0 { left = max(0, min(start.minX + dx, right - minWidth)) }
                else { right = min(1, max(start.maxX + dx, left + minWidth)) }
                if corner < 2 { top = max(0, min(start.minY + dy, bottom - minHeight)) }
                else { bottom = min(1, max(start.maxY + dy, top + minHeight)) }
                crop = CGRect(x: left, y: top, width: right - left, height: bottom - top)
            }
            .onEnded { _ in dragOrigin = nil }
    }

    private func moveGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("captureCanvas"))
            .onChanged { value in
                if dragOrigin == nil { dragOrigin = crop }
                guard let start = dragOrigin else { return }
                crop.origin = CGPoint(
                    x: max(0, min(1 - start.width, start.minX + value.translation.width / size.width)),
                    y: max(0, min(1 - start.height, start.minY + value.translation.height / size.height))
                )
            }
            .onEnded { _ in dragOrigin = nil }
    }
}
