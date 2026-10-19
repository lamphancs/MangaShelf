import SwiftUI

/// Coordinates are normalized against the entire document, independent of scrolling or preview size.
struct FullPageCropView: View {
    let document: WebCaptureDocument
    @State private var renderer: CapturePDFTileRenderer
    @Binding var crop: CGRect
    let overview: Bool
    let trimPageHeight: CGFloat?
    @State private var initialViewportHeight: CGFloat?
    @Environment(ThemeManager.self) private var theme
    @AppStorage(StorageKey.captureOverviewZoom) private var overviewZoom = CaptureCrop.defaultOverviewZoom
    @AppStorage(StorageKey.captureDetailZoom) private var detailZoom = CaptureCrop.defaultDetailZoom
    @State private var visibleRect: CGRect = .zero
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var dragOrigin: CGRect?
    @State private var thumbnailTarget: CGFloat?
    @State private var thumbnailPosition = ScrollPosition(edge: .top)
    @State private var thumbnailViewport: CGRect = .zero

    init(document: WebCaptureDocument, crop: Binding<CGRect>, overview: Bool, trimPageHeight: CGFloat? = nil, renderer: CapturePDFTileRenderer? = nil) {
        self.document = document
        self._crop = crop
        self.overview = overview
        self.trimPageHeight = trimPageHeight
        self._renderer = State(initialValue: renderer ?? CapturePDFTileRenderer(document: document))
    }

    var body: some View {
        HStack(spacing: 0) {
            thumbnailRail
                .frame(width: 60)
            cropPreview
        }
    }

    private var cropPreview: some View {
        GeometryReader { geometry in
            let available = CGSize(width: max(1, geometry.size.width - 104), height: max(1, geometry.size.height - 48))
            // Fitting an entire 100,000-point chapter into one screen makes its
            // width almost zero. Keep Overview usable and scroll it when necessary.
            let fittedWidth = available.height * document.size.width / document.size.height
            // Overview scales the fitted width (never wider than the screen);
            // Detail scales the screen width and scrolls horizontally when zoomed in.
            let width = overview
                ? min(available.width, max(100, fittedWidth) * overviewZoom)
                : available.width * detailZoom
            let size = CGSize(width: width, height: document.size.height * width / document.size.width)
            let canvasTop = max(24, (geometry.size.height - size.height) / 2)
            let viewport = visibleRect.isEmpty ? CGRect(origin: .zero, size: geometry.size) : visibleRect
            let first = max(0, Int(floor((viewport.minY - canvasTop) / 384)) - 1)
            let last = min(Int(ceil(size.height / 384)), max(first, Int(ceil((viewport.maxY - canvasTop) / 384)) + 1))
            ScrollView([.horizontal, .vertical]) {
                canvas(size: size, visibleTiles: first..<max(first, last))
                    .padding(.vertical, 24)
                    .padding(.leading, 24)
                    .padding(.trailing, 80)
                    .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
            }
            .onAppear {
                if initialViewportHeight == nil { initialViewportHeight = geometry.size.height }
            }
            .defaultScrollAnchor(.top)
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: CGRect.self) { $0.visibleRect } action: { _, rect in
                visibleRect = rect
                let top = min(1, max(0, (rect.minY - canvasTop) / size.height))
                let bottom = min(1, max(top, (rect.maxY - canvasTop) / size.height))
                thumbnailViewport = CGRect(x: 0, y: top, width: 1, height: bottom - top)
            }
            .onChange(of: thumbnailTarget) { _, target in
                guard let target else { return }
                let maxOffset = max(0, size.height + 48 - geometry.size.height)
                scrollPosition.scrollTo(y: min(maxOffset, max(0, canvasTop + target * size.height - geometry.size.height / 2)))
                thumbnailTarget = nil
            }
            .task(id: overview) {
                // Open on the crop area rather than the page top, keeping the upper
                // crop handles visible below the viewport edge.
                let cropTop = canvasTop + crop.minY * size.height
                let maxOffset = max(0, size.height + 48 - geometry.size.height)
                scrollPosition.scrollTo(y: min(maxOffset, max(0, cropTop - 80)))
            }
            .overlay(alignment: .trailing) {
                ScrollView(.vertical) {
                    VStack(spacing: 8) {
                        trimControls(top: true, canvasSize: size, canvasTop: canvasTop,
                                     viewportHeight: geometry.size.height)
                        Spacer(minLength: 16)
                        VStack(spacing: 16) {
                            trimControls(top: false, canvasSize: size, canvasTop: canvasTop,
                                         viewportHeight: geometry.size.height)
                            VStack(spacing: 8) {
                                Button {
                                    scrollPosition.scrollTo(edge: .top)
                                } label: {
                                    Image(systemName: "arrow.up.to.line")
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .accessibilityLabel("Go to top")
                                Button {
                                    let cropBottom = canvasTop + crop.maxY * size.height
                                    let maxOffset = max(0, size.height + 48 - geometry.size.height)
                                    let offset = min(maxOffset, max(0, cropBottom - geometry.size.height + 80))
                                    scrollPosition.scrollTo(y: offset)
                                } label: {
                                    Image(systemName: "arrow.down.to.line")
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .accessibilityLabel("Go to crop bottom")
                            }
                            .buttonStyle(CropAdjustmentButtonStyle(accent: theme.accent))
                            .foregroundStyle(theme.accent)
                            .padding(4)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                        }
                    }
                    .frame(minHeight: max(0, geometry.size.height - 16))
                    .padding(.vertical, 8)
                }
                .scrollIndicators(.hidden)
                .frame(width: 60)
            }
        }
    }

    /// A separately tiled thumbnail keeps even very long chapters bounded in memory.
    private var thumbnailRail: some View {
        GeometryReader { geometry in
            let width: CGFloat = 48
            let height = document.size.height * width / document.size.width * 0.64
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(0..<Int(ceil(height / 192)), id: \.self) { index in
                        let y = CGFloat(index) * 192
                        let tileHeight = min(192, height - y)
                        CapturePDFTile(renderer: renderer,
                                       crop: CGRect(x: 0, y: y / height, width: 1, height: tileHeight / height),
                                       displaySize: CGSize(width: width, height: tileHeight))
                            .onTapGesture { location in
                                thumbnailTarget = (y + location.y) / height
                            }
                            .accessibilityLabel("PDF thumbnail section \(index + 1)")
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { thumbnailTarget = y / height }
                    }
                }
                .frame(width: width)
                .overlay(alignment: .topLeading) {
                    ZStack(alignment: .topLeading) {
                        Path { path in
                            path.addRect(CGRect(x: 0, y: 0, width: width, height: height))
                            path.addRect(CGRect(x: crop.minX * width, y: crop.minY * height,
                                                width: crop.width * width, height: crop.height * height))
                        }
                        .fill(.black.opacity(0.6), style: FillStyle(eoFill: true))
                        .allowsHitTesting(false)
                        Rectangle()
                            .strokeBorder(theme.accent, lineWidth: 2)
                            .frame(width: crop.width * width, height: max(2, crop.height * height))
                            .offset(x: crop.minX * width, y: crop.minY * height)
                            .allowsHitTesting(false)
                        Rectangle()
                            .strokeBorder(.white.opacity(0.8), lineWidth: 1)
                            .frame(width: width, height: max(2, min(1 - thumbnailViewport.minY, thumbnailViewport.height) * height))
                            .offset(y: thumbnailViewport.minY * height)
                            .allowsHitTesting(false)
                    }
                    .frame(width: width, height: height, alignment: .topLeading)
                    .allowsHitTesting(false)
                }
                .clipped()
                // Extra space lets the viewed region stay centered even at either document edge.
                .padding(.vertical, geometry.size.height / 2)
            }
            .scrollPosition($thumbnailPosition)
            .task(id: geometry.size.height) {
                centerThumbnailOnViewport(height: height)
            }
            .onChange(of: thumbnailViewport) { _, _ in
                centerThumbnailOnViewport(height: height)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity)
            .background(theme.cardBackground)
            .accessibilityLabel("PDF thumbnail")
        }
    }

    private func centerThumbnailOnViewport(height: CGFloat) {
        let center = thumbnailViewport.isEmpty ? crop.minY : thumbnailViewport.midY
        // Half-viewport padding cancels the half-viewport centering offset.
        thumbnailPosition.scrollTo(y: min(1, max(0, center)) * height)
    }

    private func trimControls(top: Bool, canvasSize: CGSize, canvasTop: CGFloat,
                              viewportHeight: CGFloat) -> some View {
        let trimmed = (top ? crop.minY : 1 - crop.maxY) * document.size.height
        // Settings defines one page as one browser viewport in PDF coordinates.
        // Freeze the fallback viewport so rotating or zooming does not change the unit.
        let pageHeight = max(1, trimPageHeight ?? initialViewportHeight ?? viewportHeight)
        let pages = Double(trimmed / pageHeight)
        return VStack(spacing: 6) {
            trimButton(top: top, increase: !top, pageHeight: pageHeight,
                       canvasSize: canvasSize, canvasTop: canvasTop, viewportHeight: viewportHeight)
            Text(pages, format: .number.precision(.fractionLength(0...1)))
                .font(.caption2.weight(.bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(width: 44)
                .accessibilityLabel("\(pages.formatted(.number.precision(.fractionLength(0...1)))) pages trimmed")
            trimButton(top: top, increase: top, pageHeight: pageHeight,
                       canvasSize: canvasSize, canvasTop: canvasTop, viewportHeight: viewportHeight)
        }
        .buttonStyle(CropAdjustmentButtonStyle(accent: theme.accent))
        .foregroundStyle(theme.accent)
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func trimButton(top: Bool, increase: Bool, pageHeight: CGFloat,
                            canvasSize: CGSize, canvasTop: CGFloat, viewportHeight: CGFloat) -> some View {
        let trimmed = (top ? crop.minY : 1 - crop.maxY) * document.size.height
        return Button {
            adjustTrim(top: top, points: increase ? pageHeight : -pageHeight, canvasSize: canvasSize,
                       canvasTop: canvasTop, viewportHeight: viewportHeight)
        } label: {
            Image(systemName: increase ? "plus" : "minus").frame(width: 44, height: 44)
        }
        .disabled(increase
                  ? crop.height * document.size.height <= min(24, document.size.height) + 0.001
                  : trimmed < 0.001)
        .accessibilityLabel("\(increase ? "Increase" : "Decrease") \(top ? "top" : "bottom") trim")
    }

    private func adjustTrim(top: Bool, points: CGFloat, canvasSize: CGSize,
                            canvasTop: CGFloat, viewportHeight: CGFloat) {
        let minimum = min(1, 24 / document.size.height)
        let delta = points / document.size.height
        if top {
            let bottom = crop.maxY
            let newTop = max(0, min(bottom - minimum, crop.minY + delta))
            crop = CGRect(x: crop.minX, y: newTop, width: crop.width, height: bottom - newTop)
        } else {
            let bottom = min(1, max(crop.minY + minimum, crop.maxY - delta))
            crop.size.height = bottom - crop.minY
        }
        let edge = canvasTop + (top ? crop.minY : crop.maxY) * canvasSize.height
        let offset = top ? edge - 80 : edge - viewportHeight + 80
        scrollPosition.scrollTo(y: max(0, min(max(0, canvasSize.height + 48 - viewportHeight), offset)))
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

/// Give the entire 44-point square a hit target, including the space around “−”.
private struct CropAdjustmentButtonStyle: ButtonStyle {
    let accent: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(isEnabled ? accent : .secondary)
            .background(accent.opacity(isEnabled ? (configuration.isPressed ? 0.3 : 0.14) : 0.04),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(accent.opacity(isEnabled ? 0.35 : 0.08), lineWidth: 1)
            }
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}
