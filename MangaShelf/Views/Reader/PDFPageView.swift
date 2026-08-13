//
//  PDFPageView.swift
//  MangaShelf
//
//  Created by Khoa Phan on 4/24/26.
//

import SwiftUI
import PDFKit

struct PDFPageView: UIViewRepresentable {

    let pdfDocument: PDFDocument?
    @Binding var currentPage: Int
    /// Exact vertical scroll offset (content points) to restore on first load. `0` falls back
    /// to page-based restore (`currentPage`), which is what pre-offset saved data will have.
    let initialOffset: CGFloat
    let onPageChange: (Int) -> Void
    let onTap: () -> Void
    var onCaptureReady: ((@escaping () -> (UIImage, CGFloat)?) -> Void)? = nil
    /// Hands the parent a closure that reads the live `contentOffset.y` on demand, so progress
    /// can be persisted at the exact scroll position without observing every scroll frame.
    var onOffsetReady: ((@escaping () -> CGFloat) -> Void)? = nil
    /// Hands the parent a `scrollToTop(completion:)` closure: it scrolls (animated) to the top
    /// of the current chapter and calls `completion` once the top tiles have finished rendering.
    var onScrollToTopReady: ((@escaping (@escaping () -> Void) -> Void) -> Void)? = nil
    /// Called (main thread) once the restored initial position's tiles have finished rendering.
    var onRestoreComplete: (() -> Void)? = nil

    func makeUIView(context: Context) -> UIView {
        let scrollView = UIScrollView()
        scrollView.backgroundColor = UIColor(Color.appBackground)
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delegate = context.coordinator

        let contentView = PDFContentView()
        contentView.backgroundColor = UIColor(Color.appBackground)
        scrollView.addSubview(contentView)

        context.coordinator.scrollView = scrollView
        context.coordinator.contentView = contentView

        onCaptureReady?({ [weak scrollView] in
            guard let scrollView else { return nil }
            let renderer = UIGraphicsImageRenderer(bounds: scrollView.bounds)
            let image = renderer.image { _ in
                scrollView.drawHierarchy(in: scrollView.bounds, afterScreenUpdates: false)
            }
            return (image, max(0, scrollView.contentOffset.y))
        })

        onOffsetReady?({ [weak scrollView] in
            max(0, scrollView?.contentOffset.y ?? 0)
        })

        onScrollToTopReady?({ [weak coordinator = context.coordinator] completion in
            guard let coordinator else { completion(); return }
            coordinator.scrollToTop()
            coordinator.awaitTargetRendered(completion)
        })

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        if let doc = pdfDocument {
            let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
            let sceneWidth: CGFloat
            if #available(iOS 26, *) {
                sceneWidth = scene?.effectiveGeometry.coordinateSpace.bounds.width ?? 393
            } else {
                sceneWidth = scene?.coordinateSpace.bounds.width ?? 393
            }
            context.coordinator.loadDocument(doc, width: sceneWidth)
            let restoreOffset = initialOffset
            let restorePage = currentPage
            let onRestore = onRestoreComplete
            DispatchQueue.main.async {
                if restoreOffset > 0 {
                    context.coordinator.scrollToOffset(restoreOffset)
                    context.coordinator.awaitTargetRendered { onRestore?() }
                } else {
                    context.coordinator.scrollToPage(restorePage, animated: false)
                    onRestore?()
                }
            }
        }

        return scrollView
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        let coordinator = context.coordinator
        guard let scrollView = uiView as? UIScrollView else { return }

        if pdfDocument == nil && coordinator.pdfDocument != nil {
            coordinator.clearDocument()
            return
        }

        if let doc = pdfDocument, coordinator.pdfDocument !== doc {
            coordinator.loadDocument(doc, width: scrollView.bounds.width)
            DispatchQueue.main.async {
                coordinator.scrollToPage(currentPage, animated: false)
            }
            return
        }

        if coordinator.reportedPage != currentPage {
            coordinator.scrollToPage(currentPage, animated: false)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, UIScrollViewDelegate {
        let parent: PDFPageView
        weak var scrollView: UIScrollView?
        fileprivate weak var contentView: PDFContentView?
        var pdfDocument: PDFDocument?
        var reportedPage = 0
        private var pageOffsets: [CGFloat] = []
        private var pageCount = 0
        /// The viewport rect of the most recent deliberate jump (restore / go-to-top), used to
        /// wait for that exact position to finish rendering rather than any scrolled-through one.
        private var pendingTargetRect: CGRect = .zero

        init(_ parent: PDFPageView) {
            self.parent = parent
        }

        func loadDocument(_ doc: PDFDocument, width: CGFloat) {
            pdfDocument = doc
            guard let contentView = contentView else { return }
            contentView.configure(document: doc, width: width)
            pageOffsets = contentView.pageRects.map { $0.offset }
            pageCount = contentView.pageRects.count
            scrollView?.contentSize = contentView.bounds.size
        }

        func clearDocument() {
            pdfDocument = nil
            contentView?.clearContent()
            pageOffsets = []
            pageCount = 0
            scrollView?.contentSize = .zero
        }

        func scrollToPage(_ page: Int, animated: Bool) {
            guard page < pageOffsets.count else { return }
            let y: CGFloat = page == 0 ? 0 : pageOffsets[page]
            scrollView?.setContentOffset(CGPoint(x: 0, y: y), animated: animated)
            reportedPage = page
            if let scrollView {
                contentView?.updateViewport(
                    CGRect(x: 0, y: y, width: scrollView.bounds.width, height: scrollView.bounds.height)
                )
            }
        }

        /// Restores an exact scroll position (content points), clamped to the scrollable range,
        /// and syncs `reportedPage`/`currentPage` so the overlay and the page-restore fallback
        /// in `updateUIView` agree and don't snap back to a page top.
        func scrollToOffset(_ y: CGFloat) {
            guard let scrollView else { return }
            let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
            let clamped = min(max(0, y), maxY)
            scrollView.setContentOffset(CGPoint(x: 0, y: clamped), animated: false)
            reportedPage = pageIndex(forViewportY: clamped + scrollView.bounds.height * 0.3)
            parent.currentPage = reportedPage
            let target = CGRect(x: 0, y: clamped, width: scrollView.bounds.width, height: scrollView.bounds.height)
            pendingTargetRect = target
            contentView?.updateViewport(target)
        }

        /// Scrolls (animated) to the very top of the current chapter and syncs the reported
        /// page so the overlay stays in agreement. Driven by the overlay's "go to top" button.
        func scrollToTop() {
            scrollToPage(0, animated: true)
            parent.currentPage = 0
            if let scrollView {
                pendingTargetRect = CGRect(x: 0, y: 0, width: scrollView.bounds.width, height: scrollView.bounds.height)
            }
        }

        /// Fires `completion` (on the main thread) once every tile intersecting the last
        /// deliberate target viewport has been rendered — or immediately if already rendered.
        func awaitTargetRendered(_ completion: @escaping () -> Void) {
            contentView?.awaitViewportRendered(pendingTargetRect, completion)
        }

        /// Index of the page whose top is at or above `y` (a point in content space).
        private func pageIndex(forViewportY y: CGFloat) -> Int {
            guard pageCount > 0 else { return 0 }
            var lo = 0, hi = pageCount - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if pageOffsets[mid] <= y {
                    lo = mid
                } else {
                    hi = mid - 1
                }
            }
            return lo
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard pageCount > 0 else { return }
            let y = scrollView.contentOffset.y + scrollView.bounds.height * 0.3
            reportedPage = pageIndex(forViewportY: y)

            contentView?.updateViewport(
                CGRect(x: 0, y: scrollView.contentOffset.y, width: scrollView.bounds.width, height: scrollView.bounds.height)
            )
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            flushPageReport()
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { flushPageReport() }
        }

        private func flushPageReport() {
            let page = reportedPage
            DispatchQueue.main.async { [self] in
                parent.currentPage = page
                parent.onPageChange(page)
            }
        }

        @objc func handleDoubleTap() {
            parent.onTap()
        }
    }
}

// MARK: - PDF Content View

fileprivate class PDFContentView: UIView {
    var pdfDocument: PDFDocument?
    var pageRects: [(offset: CGFloat, height: CGFloat)] = []
    private var contentWidth: CGFloat = 0

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
    private var inflightTiles = Set<Int>()
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
    private static let bgColor: CGColor = UIColor.black.cgColor
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
    /// How far beyond the viewport (in multiples of viewport height) tiles are kept warm.
    private let overscanFactor: CGFloat = 1.5

    private var lastScheduledTop: CGFloat = .greatestFiniteMagnitude

    /// One-shot completion + its target viewport, used to notify when a deliberate jump's tiles
    /// have all rendered. Touched only on the main thread.
    private var renderTargetRect: CGRect = .zero
    private var renderCompletion: (() -> Void)?

    func configure(document: PDFDocument, width: CGFloat) {
        generation += 1
        pdfDocument = document
        contentWidth = width
        let scale = traitCollection.displayScale
        cachedScreenScale = scale > 0 ? scale : 2.0

        renderQueue.cancelAllOperations()
        scheduleQueue.async { [weak self] in self?.inflightOps.removeAll() }
        tileLayers.forEach { $0.removeFromSuperlayer() }
        tileLayers.removeAll()
        os_unfair_lock_lock(&unfairLock)
        tileImages.removeAll()
        inflightTiles.removeAll()
        os_unfair_lock_unlock(&unfairLock)
        lastScheduledTop = .greatestFiniteMagnitude

        let topInset: CGFloat = {
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
            return scene?.keyWindow?.safeAreaInsets.top ?? 59
        }()

        var offset = topInset
        pageRects = []

        var tilePageIndex: [Int] = []
        var tileFrames: [CGRect] = []
        var tileBandTop: [CGFloat] = []
        var tileBandHeight: [CGFloat] = []

        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            let pageRect = page.bounds(for: .mediaBox)
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
                layer.addSublayer(tileLayer)

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

        frame = CGRect(x: 0, y: 0, width: width, height: offset)
        backgroundColor = UIColor.black

        // Prime the first viewport so the top of the chapter is ready before the first scroll.
        let viewportHeight = screenHeight()
        scheduleRender(top: 0, bottom: viewportHeight * overscanFactor)
    }

    func clearContent() {
        generation += 1
        pdfDocument = nil
        renderQueue.cancelAllOperations()
        scheduleQueue.async { [weak self] in self?.inflightOps.removeAll() }
        tileLayers.forEach { $0.removeFromSuperlayer() }
        tileLayers.removeAll()
        tileLayout = TileLayout(pageIndex: [], frame: [], bandTop: [], bandHeight: [])
        os_unfair_lock_lock(&unfairLock)
        tileImages.removeAll()
        inflightTiles.removeAll()
        os_unfair_lock_unlock(&unfairLock)
        pageRects.removeAll()
        lastScheduledTop = .greatestFiniteMagnitude
        frame = .zero
    }

    /// Called on the main thread for every scroll event. Determines which tiles must be
    /// rendered/kept for the given viewport and (throttled) schedules the work off-main.
    func updateViewport(_ rect: CGRect) {
        let overscan = max(rect.height, 1) * overscanFactor
        let top = rect.minY - overscan
        let bottom = rect.maxY + overscan

        // Skip near-duplicate schedules; the serial render queue coalesces the rest.
        if abs(top - lastScheduledTop) < tileHeightPoints * 0.5 { return }
        lastScheduledTop = top

        scheduleRender(top: top, bottom: bottom)
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

    private func scheduleRender(top: CGFloat, bottom: CGFloat) {
        let currentGen = generation
        let layout = tileLayout
        let rects = pageRects
        let width = contentWidth
        let screenScale = cachedScreenScale
        scheduleQueue.async { [weak self] in
            self?.renderTiles(
                top: top,
                bottom: bottom,
                gen: currentGen,
                layout: layout,
                rects: rects,
                width: width,
                screenScale: screenScale
            )
        }
    }

    private func renderTiles(
        top: CGFloat,
        bottom: CGFloat,
        gen: Int,
        layout: TileLayout,
        rects: [(offset: CGFloat, height: CGFloat)],
        width: CGFloat,
        screenScale: CGFloat
    ) {
        guard gen == generation, let doc = pdfDocument else { return }
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

        // Drop finished ops, then cancel any still-running render whose tile has scrolled
        // out of the desired range — this is what keeps a fast fling from backlogging the
        // render queue with pages that are no longer on screen.
        for (idx, op) in inflightOps where op.isFinished { inflightOps[idx] = nil }
        for (idx, op) in inflightOps where !desiredSet.contains(idx) {
            op.cancel()
            inflightOps[idx] = nil
            removeInflight(idx)
        }

        os_unfair_lock_lock(&unfairLock)
        let existing = Set(tileImages.keys)
        let inflight = inflightTiles
        let toEvict = existing.subtracting(desiredSet)
        for key in toEvict {
            tileImages.removeValue(forKey: key)
        }
        os_unfair_lock_unlock(&unfairLock)

        if !toEvict.isEmpty {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                for key in toEvict where key < self.tileLayers.count {
                    self.tileLayers[key].contents = nil
                }
                CATransaction.commit()
            }
        }

        let viewportMid = (top + bottom) / 2
        let toRender = desiredSet
            .subtracting(existing)
            .subtracting(inflight)
            .sorted { abs(layout.frame[$0].midY - viewportMid) < abs(layout.frame[$1].midY - viewportMid) }

        guard !toRender.isEmpty else { return }

        os_unfair_lock_lock(&unfairLock)
        for i in toRender { inflightTiles.insert(i) }
        os_unfair_lock_unlock(&unfairLock)

        for tileIdx in toRender {
            let operation = BlockOperation()
            operation.addExecutionBlock { [weak self, weak doc, weak operation] in
                autoreleasepool {
                    guard let self else { return }

                    // Bail before the expensive draw if this tile was cancelled (scrolled
                    // away) or belongs to a superseded chapter.
                    guard operation?.isCancelled == false, let doc, self.generation == currentGen else {
                        self.removeInflight(tileIdx)
                        return
                    }

                    let pageIdx = layout.pageIndex[tileIdx]
                    guard let page = doc.page(at: pageIdx), pageIdx < rects.count else {
                        self.removeInflight(tileIdx)
                        return
                    }

                    let pageRect = page.bounds(for: .mediaBox)
                    guard pageRect.width > 0 else {
                        self.removeInflight(tileIdx)
                        return
                    }
                    let scale = width / pageRect.width
                    let bandTop = layout.bandTop[tileIdx]
                    let bandHeight = layout.bandHeight[tileIdx]

                    let pixelW = Int((width * screenScale).rounded())
                    let pixelH = Int((bandHeight * screenScale).rounded())
                    guard pixelW > 0, pixelH > 0 else {
                        self.removeInflight(tileIdx)
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
                        page.draw(with: .mediaBox, to: cgContext)
                    }

                    // If the tile was cancelled or the chapter changed while drawing, drop the
                    // result instead of caching/committing a page the user has scrolled past.
                    guard let cgImage = uiImage.cgImage,
                          operation?.isCancelled == false,
                          self.generation == currentGen else {
                        self.removeInflight(tileIdx)
                        return
                    }

                    os_unfair_lock_lock(&self.unfairLock)
                    self.tileImages[tileIdx] = cgImage
                    self.inflightTiles.remove(tileIdx)
                    os_unfair_lock_unlock(&self.unfairLock)

                    DispatchQueue.main.async {
                        guard self.generation == currentGen, tileIdx < self.tileLayers.count else { return }
                        CATransaction.begin()
                        CATransaction.setDisableActions(true)
                        self.tileLayers[tileIdx].contents = cgImage
                        CATransaction.commit()
                        self.checkRenderCompletion()
                    }
                }
            }
            inflightOps[tileIdx] = operation
            renderQueue.addOperation(operation)
        }
    }

    private func removeInflight(_ index: Int) {
        os_unfair_lock_lock(&unfairLock)
        inflightTiles.remove(index)
        os_unfair_lock_unlock(&unfairLock)
    }
}
