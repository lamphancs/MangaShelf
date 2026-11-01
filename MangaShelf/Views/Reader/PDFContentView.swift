import UIKit
import PDFKit

/// Shift a fixed prefetch budget toward travel, without increasing decoded-image memory.
fileprivate struct ReaderRenderWindow {
    let viewport: CGRect
    let top: CGFloat
    let bottom: CGFloat
    let direction: CGFloat

    init(viewport: CGRect, velocity: CGFloat) {
        self.viewport = viewport
        direction = velocity == 0 ? 0 : (velocity > 0 ? 1 : -1)
        let height = max(viewport.height, 1)
        let bias = min(abs(velocity) * 0.35, height) * direction
        top = viewport.minY - height * 1.5 + bias
        bottom = viewport.maxY + height * 1.5 + bias
    }

    func priority(for frame: CGRect) -> Operation.QueuePriority {
        if frame.intersects(viewport) { return .veryHigh }
        if (direction > 0 && frame.minY >= viewport.maxY)
            || (direction < 0 && frame.maxY <= viewport.minY) { return .high }
        return .low
    }
}

// MARK: - PDF Content View

class PDFContentView: UIView {
    var pdfDocument: PDFDocument?
    var pageRects: [(offset: CGFloat, height: CGFloat)] = []
    private var contentWidth: CGFloat = 0
    private(set) var openingArtHeight: CGFloat = 0
    /// Difference from the original PDF-only layout, which includes a top safe-area inset.
    private(set) var openingContentOffset: CGFloat = 0
    var artworkTransition: ArtworkTransition = .fade
    private var artViews: [UIImageView] = []
    private var artTransitions: [CAGradientLayer] = []
    private var artBackdrops: [CALayer] = []
    private var artworkFadeDistance: CGFloat = 0
    private var artworkScrollEnd: CGFloat = 0
    private let pdfLayer = CALayer()

    /// Immutable snapshot of the tile layout, captured on the main thread and handed to the
    /// render queue so the background renderer never races against `configure`/`clearContent`.
    private struct TileLayout {
        let pageIndex: [Int]
        let frame: [CGRect]
        let bandTop: [CGFloat]
        let bandHeight: [CGFloat]
        var count: Int { pageIndex.count }
    }

    // Tile model. Every PDF page is split into bounded-height vertical bands ("tiles") so no
    // single texture ever exceeds the GPU limit — the root cause of the scroll stutter on tall
    // webtoon-style pages (e.g. 430×14400pt). Only tiles near the viewport are rendered/kept.
    private var tileLayers: [CALayer] = []
    private var tileLayout = TileLayout(pageIndex: [], frame: [], bandTop: [], bandHeight: [])

    private var tileImages: [Int: CGImage] = [:]
    private var imageGeneration = 0 // Protected by unfairLock with tileImages.
    private var unfairLock = os_unfair_lock()
    private let renderQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "pdf.render"
        // Fewer concurrent decodes + a QoS below the main (scroll) thread. Heavy PDF/JPEG
        // decoding at .userInitiated across 4 cores starves the scroll runloop and causes
        // micro-stutter; .utility lets scrolling win and keeps the frame rate steady.
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility
        return queue
    }()
    private let scheduleQueue = DispatchQueue(label: "pdf.schedule")
    /// Outstanding render operations keyed by tile index. Touched only on `scheduleQueue`,
    /// so it needs no lock. Lets us cancel renders for tiles that scroll out of view during
    /// a fling instead of decoding pages the user will never see.
    private var inflightOps: [Int: Operation] = [:]
    private var generation: Int = 0
    private var scheduledGeneration = 0
    private var pendingSchedule: DispatchWorkItem?
    // PDF paper is white: unpainted areas and antialiased image edges must not
    // reveal the reader's black surround as horizontal seams between images.
    // Shared by display tiles and viewport captures used for gallery artwork.
    private static let bgColor: CGColor = UIColor.white.cgColor
    /// Placeholder shown for a tile that hasn't finished rendering yet. A neutral
    /// gray instead of black so scrolling into not-yet-rendered pages reads as
    /// "loading" rather than a jarring black gap against light manga pages.
    private static let placeholderColor: CGColor = UIColor(white: 0.25, alpha: 1).cgColor
    private var cachedScreenScale: CGFloat = 0

    /// Max height of a single tile, in content points. Keeps each rendered texture small
    /// (≈384pt × screenScale ≈ 1152px tall). Smaller tiles mean smaller CGImages committed to
    /// layer.contents, so each GPU texture upload is cheap and doesn't hitch the scroll runloop.
    /// At 384pt an opaque tile is ~5.3MB at 3× vs ~14MB at 1024pt.
    private let tileHeightPoints: CGFloat = 384
    private var lastScheduledViewport: CGRect = .null
    private var lastScheduledDirection: CGFloat = 0
    private var lastViewportSample: (y: CGFloat, time: CFTimeInterval)?

    /// One-shot completion + its target viewport, used to notify when a deliberate jump's tiles
    /// have all rendered. Touched only on the main thread.
    private var renderTargetRect: CGRect = .zero
    private var renderCompletion: (() -> Void)?

    func configure(document: PDFDocument, width: CGFloat, viewportHeight: CGFloat, artwork: [UIImage], includesTopInset: Bool = true) {
        generation += 1
        pdfDocument = document
        contentWidth = width
        let scale = traitCollection.displayScale
        cachedScreenScale = scale > 0 ? scale : 2.0

        pendingSchedule?.cancel()
        let newGeneration = generation
        scheduleQueue.async { [weak self] in
            guard let self else { return }
            self.scheduledGeneration = newGeneration
            self.renderQueue.cancelAllOperations()
            self.inflightOps.removeAll()
            os_unfair_lock_lock(&self.unfairLock)
            self.tileImages.removeAll()
            os_unfair_lock_unlock(&self.unfairLock)
        }
        renderCompletion = nil
        tileLayers.forEach { $0.removeFromSuperlayer() }
        tileLayers.removeAll()
        if pdfLayer.superlayer == nil { layer.addSublayer(pdfLayer) }
        // Keep story pixels above artwork while both layers crossfade at chapter boundaries.
        pdfLayer.zPosition = 2
        pdfLayer.opacity = 1
        pdfLayer.transform = CATransform3DIdentity
        os_unfair_lock_lock(&unfairLock)
        tileImages.removeAll()
        imageGeneration = generation
        os_unfair_lock_unlock(&unfairLock)
        lastScheduledViewport = .null
        lastScheduledDirection = 0
        lastViewportSample = nil

        let topInset: CGFloat = {
            guard includesTopInset else { return 0 }
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
            return scene?.keyWindow?.safeAreaInsets.top ?? 59
        }()

        artViews.forEach { $0.removeFromSuperview() }
        artViews.removeAll()
        artTransitions.removeAll()
        artBackdrops.forEach { $0.removeFromSuperlayer() }
        artBackdrops.removeAll()
        // Each artwork page fills the viewport, independently of the image aspect ratio.
        openingArtHeight = artwork.isEmpty ? 0 : (viewportHeight > 0 ? viewportHeight : screenHeight())
        if let opening = artwork.first {
            addArtPage(opening, y: 0, width: width)
        }
        // Keep a complete artwork page before the PDF. Only the boundary transition
        // may overlap content; no chapter content sits underneath the initial cover.
        openingContentOffset = artwork.isEmpty ? 0 : openingArtHeight - topInset
        var offset = artwork.isEmpty ? topInset : openingArtHeight
        pageRects = []

        var tilePageIndex: [Int] = []
        var tileFrames: [CGRect] = []
        var tileBandTop: [CGFloat] = []
        var tileBandHeight: [CGFloat] = []

        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            let pageRect = page.readerDisplayBounds
            guard pageRect.width > 0 else { continue }
            let scale = width / pageRect.width
            let height = pageRect.height * scale
            pageRects.append((offset: offset, height: height))

            // Split the page into vertical tiles.
            var bandTop: CGFloat = 0
            while bandTop < height {
                let bandHeight = min(tileHeightPoints, height - bandTop)
                let frame = CGRect(x: 0, y: offset + bandTop, width: width, height: bandHeight)

                let tileLayer = CALayer()
                tileLayer.frame = frame
                tileLayer.contentsScale = cachedScreenScale
                tileLayer.contentsGravity = .resize
                tileLayer.backgroundColor = Self.placeholderColor
                pdfLayer.addSublayer(tileLayer)

                tileLayers.append(tileLayer)
                tilePageIndex.append(i)
                tileFrames.append(frame)
                tileBandTop.append(bandTop)
                tileBandHeight.append(bandHeight)

                bandTop += bandHeight
            }

            offset += height
        }

        tileLayout = TileLayout(
            pageIndex: tilePageIndex,
            frame: tileFrames,
            bandTop: tileBandTop,
            bandHeight: tileBandHeight
        )

        if let closing = artwork.last {
            addArtPage(closing, y: offset, width: width)
            offset += openingArtHeight
        }
        // Keep physical layer order consistent with zPosition, including viewport captures.
        pdfLayer.removeFromSuperlayer()
        layer.addSublayer(pdfLayer)
        let visibleHeight = viewportHeight > 0 ? viewportHeight : screenHeight()
        artworkScrollEnd = max(0, offset - visibleHeight)
        artworkFadeDistance = openingArtHeight
        frame = CGRect(x: 0, y: 0, width: width, height: offset)
        backgroundColor = UIColor.black

        // Prime the first viewport so the top of the chapter is ready before the first scroll.
        updateViewport(CGRect(x: 0, y: 0, width: width, height: visibleHeight))
    }

    private func addArtPage(_ image: UIImage, y: CGFloat, width: CGFloat) {
        let backdrop = CALayer()
        backdrop.zPosition = 0.5
        backdrop.contentsGravity = .resize
        layer.addSublayer(backdrop)
        artBackdrops.append(backdrop)
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.backgroundColor = .black
        imageView.frame = CGRect(x: 0, y: y, width: width, height: openingArtHeight)
        imageView.isUserInteractionEnabled = false
        // A mask reveals live PDF pixels at the edge; it never paints a sampled color strip.
        let mask = CAGradientLayer()
        mask.frame = imageView.bounds
        mask.colors = [UIColor.black.cgColor, UIColor.black.cgColor]
        imageView.layer.mask = mask
        imageView.layer.zPosition = 1
        artTransitions.append(mask)
        addSubview(imageView)
        artViews.append(imageView)
    }

    private func updateArtBackdrop(image: CGImage, tileIndex: Int) {
        guard artBackdrops.count == 2 else { return }
        // Extend the adjoining page's edge only into the artwork area. Actual PDF tiles
        // crossfade above both this backdrop and the fading artwork.
        if tileIndex == 0 {
            artBackdrops[0].contents = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: 1))
        }
        if tileIndex == tileLayout.count - 1 {
            artBackdrops[1].contents = image.cropping(to: CGRect(x: 0, y: image.height - 1, width: image.width, height: 1))
        }
    }

    func clearContent() {
        artViews.forEach { $0.removeFromSuperview() }
        artViews.removeAll()
        artTransitions.removeAll()
        artBackdrops.forEach { $0.removeFromSuperlayer() }
        artBackdrops.removeAll()
        openingArtHeight = 0
        openingContentOffset = 0
        artworkFadeDistance = 0
        artworkScrollEnd = 0
        pdfLayer.transform = CATransform3DIdentity
        pdfLayer.opacity = 1
        generation += 1
        pdfDocument = nil
        pendingSchedule?.cancel()
        let newGeneration = generation
        scheduleQueue.async { [weak self] in
            guard let self else { return }
            self.scheduledGeneration = newGeneration
            self.renderQueue.cancelAllOperations()
            self.inflightOps.removeAll()
            os_unfair_lock_lock(&self.unfairLock)
            self.tileImages.removeAll()
            os_unfair_lock_unlock(&self.unfairLock)
        }
        renderCompletion = nil
        tileLayers.forEach { $0.removeFromSuperlayer() }
        tileLayers.removeAll()
        tileLayout = TileLayout(pageIndex: [], frame: [], bandTop: [], bandHeight: [])
        os_unfair_lock_lock(&unfairLock)
        tileImages.removeAll()
        imageGeneration = generation
        os_unfair_lock_unlock(&unfairLock)
        pageRects.removeAll()
        lastScheduledViewport = .null
        lastScheduledDirection = 0
        lastViewportSample = nil
        frame = .zero
    }

    /// Called on the main thread for every scroll event. Determines which tiles must be
    /// rendered/kept for the given viewport and (throttled) schedules the work off-main.
    func updateViewport(_ rect: CGRect, updateEffects: Bool = true) {
        // Opacity follows every scroll frame, independently of throttled PDF tile rendering.
        if updateEffects { updateArtEffects(rect) }
        let now = CACurrentMediaTime()
        var velocity: CGFloat = 0
        if updateEffects, let sample = lastViewportSample {
            let elapsed = now - sample.time
            // Ignore duplicate callbacks and old samples; flings supply frequent events.
            if elapsed > 0.001 && elapsed < 0.15 {
                velocity = (rect.minY - sample.y) / elapsed
            }
        }
        lastViewportSample = updateEffects ? (rect.minY, now) : nil
        let window = ReaderRenderWindow(viewport: rect, velocity: velocity)
        // A direction change must reprioritize immediately, even within the same tile.
        if !lastScheduledViewport.isNull,
           abs(rect.minY - lastScheduledViewport.minY) < tileHeightPoints * 0.25,
           rect.size == lastScheduledViewport.size,
           window.direction == lastScheduledDirection { return }
        lastScheduledViewport = rect
        lastScheduledDirection = window.direction
        scheduleRender(window)
    }

    private func updateArtEffects(_ viewport: CGRect) {
        guard artViews.count == 2, artTransitions.count == 2 else { return }
        if artworkTransition != .fade {
            updateScrollingArtEffects(viewport)
            return
        }
        func smooth(_ value: CGFloat) -> CGFloat {
            let t = min(1, max(0, value))
            return t * t * (3 - 2 * t)
        }
        let distance = max(artworkFadeDistance, 1)
        let openingProgress = min(1, max(0, viewport.minY / distance))
        let closingProgress = min(1, max(0,
            (viewport.minY - (artworkScrollEnd - distance)) / distance))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Counter the scroll offset so the artwork stays at the same screen coordinates.
        for view in artViews { view.frame = viewport }
        artViews[0].alpha = 1 - smooth(openingProgress)
        artViews[1].alpha = smooth(closingProgress)
        // The PDF becomes fully visible after the opening transition, then fades out
        // into the closing artwork. Scrolling back reverses both effects continuously.
        pdfLayer.opacity = Float(min(smooth(openingProgress), 1 - smooth(closingProgress)))
        for index in artViews.indices {
            let view = artViews[index]
            let backdrop = artBackdrops[index]
            backdrop.frame = viewport
            backdrop.isHidden = view.alpha == 0
            let progress = index == 0 ? openingProgress : 1 - closingProgress
            let mask = artTransitions[index]
            mask.frame = view.bounds
            let edgeAlpha = 1 - smooth(progress / 0.2)
            let edgeColor = UIColor.black.withAlphaComponent(edgeAlpha).cgColor
            let band = min(72 / max(viewport.height, 1), 0.12)
            mask.locations = index == 0
                ? [NSNumber(value: Double(1 - band)), 1]
                : [0, NSNumber(value: Double(band))]
            mask.colors = index == 0
                ? [UIColor.black.cgColor, edgeColor]
                : [edgeColor, UIColor.black.cgColor]
        }
        CATransaction.commit()
    }

    /// All spatial effects preserve PDF geometry and opacity. Masks stay on the
    /// artwork side of each seam, so text never sits under a gradient or moving image.
    private func updateScrollingArtEffects(_ viewport: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pdfLayer.opacity = 1
        let height = max(openingArtHeight, 1)
        let closingY = pageRects.last.map { $0.offset + $0.height } ?? height
        for index in artViews.indices {
            let opening = index == 0
            let origin: CGFloat = opening ? 0 : closingY
            let seam = opening ? height : closingY
            let view = artViews[index]
            var y = origin
            if artworkTransition == .parallax || (artworkTransition == .parallaxContinuous && opening) {
                // Move 25% with the viewport: on screen the art travels at 75%
                // of story speed and arrives at its original position at each end.
                let travel = min(height, max(0, viewport.minY - (opening ? 0 : closingY - height)))
                y += (travel - (opening ? 0 : height)) * 0.25
            }
            view.frame = CGRect(x: 0, y: y, width: contentWidth, height: height)
            let visible = opening ? viewport.minY < seam : viewport.maxY > seam
            view.alpha = visible ? 1 : 0
            let backdrop = artBackdrops[index]
            backdrop.frame = CGRect(x: 0, y: origin, width: contentWidth, height: height)
            backdrop.isHidden = !visible
            let mask = artTransitions[index]
            mask.frame = view.bounds
            let band = min(96, height * 0.2)
            // Clamp stops during overscroll; stop order remains monotonic.
            let boundary = seam - y
            let start = opening ? boundary - band : boundary
            let alphas: [CGFloat] = opening ? [1, 0.85, 0.5, 0.15, 0] : [0, 0.15, 0.5, 0.85, 1]
            mask.locations = (0..<5).map { step in
                NSNumber(value: Double(min(1, max(0, (start + band * CGFloat(step) / 4) / height))))
            }
            mask.colors = alphas.map { UIColor.black.withAlphaComponent($0).cgColor }
        }
        CATransaction.commit()
    }

    /// Render source content, never the transient composited screen (fades, edge backdrops,
    /// or partially loaded tiles). Keep output at display resolution with a zero-based origin.
    func captureViewport(_ viewport: CGRect) -> UIImage? {
        guard let document = pdfDocument, viewport.width > 0, viewport.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = cachedScreenScale > 0 ? cachedScreenScale : 2
        format.opaque = true
        return UIGraphicsImageRenderer(size: viewport.size, format: format).image { context in
            let cg = context.cgContext
            cg.setFillColor(Self.bgColor)
            cg.fill(CGRect(origin: .zero, size: viewport.size))
            cg.translateBy(x: -viewport.minX, y: -viewport.minY)
            cg.clip(to: viewport)

            // Preserve artwork visible outside the PDF, but export its original sharp image.
            for view in artViews where view.alpha > 0 {
                guard let image = view.image, image.size.width > 0, image.size.height > 0 else { continue }
                let scale = max(view.bounds.width / image.size.width, view.bounds.height / image.size.height)
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                let rect = CGRect(x: view.frame.midX - size.width / 2, y: view.frame.midY - size.height / 2,
                                  width: size.width, height: size.height)
                cg.saveGState()
                cg.clip(to: view.frame)
                image.draw(in: rect)
                cg.restoreGState()
            }

            for (index, layout) in pageRects.enumerated() {
                let rect = CGRect(x: 0, y: layout.offset, width: contentWidth, height: layout.height)
                guard rect.intersects(viewport), let page = document.page(at: index),
                      let pageRef = page.pageRef else { continue }
                let bounds = page.readerDisplayBounds
                guard bounds.width > 0 else { continue }
                let scale = contentWidth / bounds.width
                cg.saveGState()
                cg.clip(to: rect)
                cg.setFillColor(Self.bgColor)
                cg.fill(rect)
                cg.translateBy(x: 0, y: rect.maxY)
                cg.scaleBy(x: scale, y: -scale)
                // WebKit PDFs clip adjacent images at fractional coordinates. Edge
                // antialiasing blends those cuts with the PDF's own dark background,
                // even when our paper is white. Keep image interpolation enabled.
                cg.setShouldAntialias(false)
                cg.concatenate(pageRef.getDrawingTransform(.cropBox,
                    rect: CGRect(origin: .zero, size: bounds.size), rotate: 0, preserveAspectRatio: true))
                // PDFKit's draw method overrides the edge-antialiasing setting.
                cg.drawPDFPage(pageRef)
                cg.restoreGState()
            }
        }
    }

    // MARK: - Render Completion

    /// Calls `completion` once every tile intersecting `rect` (the visible viewport, no
    /// overscan) has a rendered image — or synchronously right now if that's already true.
    func awaitViewportRendered(_ rect: CGRect, _ completion: @escaping () -> Void) {
        if isRectFullyRendered(rect) {
            completion()
            return
        }
        renderTargetRect = rect
        renderCompletion = completion
    }

    /// Whether every tile that intersects `rect` currently has a cached image.
    private func isRectFullyRendered(_ rect: CGRect) -> Bool {
        let layout = tileLayout
        let count = layout.count
        guard count > 0 else { return true }

        var lo = 0, hi = count - 1, firstIdx = count
        while lo <= hi {
            let mid = (lo + hi) / 2
            if layout.frame[mid].maxY > rect.minY {
                firstIdx = mid
                hi = mid - 1
            } else {
                lo = mid + 1
            }
        }

        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        var i = firstIdx
        while i < count && layout.frame[i].minY < rect.maxY {
            if tileImages[i] == nil { return false }
            i += 1
        }
        return true
    }

    /// Fires a pending `awaitViewportRendered` completion if its target is now fully rendered.
    /// Called on the main thread after each tile commit.
    private func checkRenderCompletion() {
        guard let completion = renderCompletion else { return }
        if isRectFullyRendered(renderTargetRect) {
            renderCompletion = nil
            completion()
        }
    }

    // MARK: - Rendering

    private func screenHeight() -> CGFloat {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        return scene?.keyWindow?.bounds.height ?? 852
    }

    private func scheduleRender(_ window: ReaderRenderWindow) {
        guard let document = pdfDocument else { return }
        pendingSchedule?.cancel()
        let currentGen = generation
        let layout = tileLayout
        let rects = pageRects
        let width = contentWidth
        let screenScale = cachedScreenScale
        let work = DispatchWorkItem { [weak self] in
            self?.renderTiles(
                window: window,
                doc: document,
                gen: currentGen,
                layout: layout,
                rects: rects,
                width: width,
                screenScale: screenScale
            )
        }
        pendingSchedule = work
        scheduleQueue.async(execute: work)
    }

    private func renderTiles(
        window: ReaderRenderWindow,
        doc: PDFDocument,
        gen: Int,
        layout: TileLayout,
        rects: [(offset: CGFloat, height: CGFloat)],
        width: CGFloat,
        screenScale: CGFloat
    ) {
        guard gen == scheduledGeneration else { return }
        let top = window.top
        let bottom = window.bottom
        let count = layout.count
        guard count > 0 else { return }

        // Tiles are contiguous and sorted by minY. Binary-search the first tile that
        // intersects the range, then walk forward.
        var lo = 0, hi = count - 1, firstIdx = count
        while lo <= hi {
            let mid = (lo + hi) / 2
            if layout.frame[mid].maxY > top {
                firstIdx = mid
                hi = mid - 1
            } else {
                lo = mid + 1
            }
        }

        var desiredSet = Set<Int>()
        var i = firstIdx
        while i < count && layout.frame[i].minY < bottom {
            desiredSet.insert(i)
            i += 1
        }

        let currentGen = gen

        // Cancel any queued or running render whose tile has scrolled
        // out of the desired range — this is what keeps a fast fling from backlogging the
        // render queue with pages that are no longer on screen.
        for (idx, op) in inflightOps where !desiredSet.contains(idx) {
            op.cancel()
            inflightOps[idx] = nil
        }

        os_unfair_lock_lock(&unfairLock)
        let existing = Set(tileImages.keys)
        let inflight = Set(inflightOps.keys)
        let toEvict = existing.subtracting(desiredSet)
        for key in toEvict {
            tileImages.removeValue(forKey: key)
        }
        os_unfair_lock_unlock(&unfairLock)

        if !toEvict.isEmpty {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == currentGen else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                for key in toEvict where key < self.tileLayers.count {
                    self.tileLayers[key].contents = nil
                }
                CATransaction.commit()
            }
        }

        // Existing queued work also needs promotion when it enters the visible viewport.
        for (idx, op) in inflightOps {
            op.queuePriority = window.priority(for: layout.frame[idx])
        }
        let viewportMid = window.viewport.midY
        let toRender = desiredSet
            .subtracting(existing)
            .subtracting(inflight)
            .sorted {
                let lhs = window.priority(for: layout.frame[$0]).rawValue
                let rhs = window.priority(for: layout.frame[$1]).rawValue
                return lhs == rhs
                    ? abs(layout.frame[$0].midY - viewportMid) < abs(layout.frame[$1].midY - viewportMid)
                    : lhs > rhs
            }

        guard !toRender.isEmpty else { return }

        for tileIdx in toRender {
            let operation = BlockOperation()
            operation.queuePriority = window.priority(for: layout.frame[tileIdx])
            operation.completionBlock = { [weak self, weak operation] in
                guard let self, let operation else { return }
                self.scheduleQueue.async {
                    // A cancelled old render must never remove a replacement for the same tile.
                    if self.inflightOps[tileIdx] === operation {
                        self.inflightOps[tileIdx] = nil
                    }
                }
            }
            operation.addExecutionBlock { [weak self, doc, weak operation] in
                autoreleasepool {
                    guard let self else { return }

                    // Bail before the expensive draw if this tile was cancelled (scrolled
                    // away) or belongs to a superseded chapter.
                    guard operation?.isCancelled == false else {
                        return
                    }

                    let pageIdx = layout.pageIndex[tileIdx]
                    guard let page = doc.page(at: pageIdx), let pageRef = page.pageRef,
                          pageIdx < rects.count else {
                        return
                    }

                    let pageRect = page.readerDisplayBounds
                    guard pageRect.width > 0 else {
                        return
                    }
                    let scale = width / pageRect.width
                    let bandTop = layout.bandTop[tileIdx]
                    let bandHeight = layout.bandHeight[tileIdx]

                    let pixelW = Int((width * screenScale).rounded())
                    let pixelH = Int((bandHeight * screenScale).rounded())
                    guard pixelW > 0, pixelH > 0 else {
                        return
                    }

                    // Full page height in pixels; the band is carved out of this by shifting up.
                    let fullPixelH = rects[pageIdx].height * screenScale

                    let format = UIGraphicsImageRendererFormat()
                    format.scale = 1
                    format.opaque = true
                    let renderer = UIGraphicsImageRenderer(
                        size: CGSize(width: pixelW, height: pixelH),
                        format: format
                    )
                    let uiImage = renderer.image { ctx in
                        let cgContext = ctx.cgContext
                        cgContext.setFillColor(Self.bgColor)
                        cgContext.fill(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))
                        // Shift the full-page drawing up so this band lands at the image top.
                        cgContext.translateBy(x: 0, y: -(bandTop * screenScale))
                        cgContext.translateBy(x: 0, y: fullPixelH)
                        cgContext.scaleBy(x: scale * screenScale, y: -(scale * screenScale))
                        // Match viewport capture: do not blend fractional WebKit
                        // clipping edges with the background embedded in the PDF.
                        cgContext.setShouldAntialias(false)
                        cgContext.concatenate(pageRef.getDrawingTransform(.cropBox,
                            rect: CGRect(origin: .zero, size: pageRect.size), rotate: 0, preserveAspectRatio: true))
                        cgContext.drawPDFPage(pageRef)
                    }

                    // If the tile was cancelled or the chapter changed while drawing, drop the
                    // result instead of caching/committing a page the user has scrolled past.
                    guard let cgImage = uiImage.cgImage, let operation,
                          !operation.isCancelled else { return }

                    self.scheduleQueue.async {
                        guard self.scheduledGeneration == currentGen,
                              self.inflightOps[tileIdx] === operation,
                              !operation.isCancelled else { return }
                        os_unfair_lock_lock(&self.unfairLock)
                        if self.imageGeneration == currentGen {
                            self.tileImages[tileIdx] = cgImage
                        }
                        os_unfair_lock_unlock(&self.unfairLock)

                        DispatchQueue.main.async {
                            guard self.generation == currentGen, !operation.isCancelled,
                                  tileIdx < self.tileLayers.count else { return }
                            CATransaction.begin()
                            CATransaction.setDisableActions(true)
                            self.tileLayers[tileIdx].contents = cgImage
                            self.updateArtBackdrop(image: cgImage, tileIndex: tileIdx)
                            CATransaction.commit()
                            self.checkRenderCompletion()
                        }
                    }
                }
            }
            inflightOps[tileIdx] = operation
            renderQueue.addOperation(operation)
        }
    }
}
