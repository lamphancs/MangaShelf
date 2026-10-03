//
//  PDFPageView.swift
//  MangaShelf
//
//  Created by Khoa Phan on 4/24/26.
//

import SwiftUI
import PDFKit
import ImageIO

struct PDFPageView: UIViewRepresentable {

    let pdfDocument: PDFDocument?
    let artFolderURL: URL?
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
    var onScrollToBottomReady: ((@escaping (@escaping () -> Void) -> Void) -> Void)? = nil
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

        onOffsetReady?({ [weak coordinator = context.coordinator] in
            guard let coordinator else { return 0 }
            if let pendingOffset = coordinator.pendingRestoreOffset { return pendingOffset }
            // Persist in original PDF coordinates so gallery changes never shift progress.
            return max(0, (coordinator.scrollView?.contentOffset.y ?? 0)
                       - (coordinator.contentView?.openingContentOffset ?? 0))
        })

        onScrollToTopReady?({ [weak coordinator = context.coordinator] completion in
            guard let coordinator else { completion(); return }
            coordinator.scrollToTop()
            coordinator.awaitTargetRendered(completion)
        })

        onScrollToBottomReady?({ [weak coordinator = context.coordinator] completion in
            guard let coordinator else { completion(); return }
            coordinator.scrollToBottom()
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
            context.coordinator.loadDocument(
                doc, width: sceneWidth, artFolderURL: artFolderURL,
                restorePage: currentPage, restoreOffset: initialOffset,
                onRestore: onRestoreComplete
            )
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
            coordinator.loadDocument(
                doc, width: scrollView.bounds.width, artFolderURL: artFolderURL,
                restorePage: currentPage
            )
            return
        }

        if !coordinator.isAnimatingScroll, coordinator.reportedPage != currentPage {
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
        var isAnimatingScroll = false
        var reportedPage = 0
        var pendingRestoreOffset: CGFloat?
        private var pageOffsets: [CGFloat] = []
        private var pageCount = 0
        private var documentLoadTask: Task<Void, Never>?
        /// The viewport rect of the most recent deliberate jump (restore / go-to-top), used to
        /// wait for that exact position to finish rendering rather than any scrolled-through one.
        private var pendingTargetRect: CGRect = .zero

        init(_ parent: PDFPageView) {
            self.parent = parent
        }

        func loadDocument(
            _ doc: PDFDocument, width: CGFloat, artFolderURL: URL?,
            restorePage: Int, restoreOffset: CGFloat = 0,
            onRestore: (() -> Void)? = nil
        ) {
            clearDocument()
            pdfDocument = doc
            pendingRestoreOffset = restoreOffset
            documentLoadTask = Task { @MainActor [weak self] in
                let artwork = await Task.detached(priority: .userInitiated) {
                    ChapterArtwork.load(from: artFolderURL)
                }.value
                guard !Task.isCancelled, let self, let contentView = self.contentView else { return }
                contentView.configure(
                    document: doc, width: max(self.scrollView?.bounds.width ?? width, 1),
                    viewportHeight: self.scrollView?.bounds.height ?? 0, artwork: artwork
                )
                self.pageOffsets = contentView.pageRects.map { $0.offset }
                self.pageCount = contentView.pageRects.count
                self.scrollView?.contentSize = contentView.bounds.size
                self.pendingRestoreOffset = nil
                if restoreOffset > 0 {
                    self.scrollToOffset(restoreOffset + contentView.openingContentOffset)
                    self.awaitTargetRendered { onRestore?() }
                } else {
                    self.scrollToPage(restorePage, animated: false)
                    onRestore?()
                }
            }
        }

        func clearDocument() {
            isAnimatingScroll = false
            documentLoadTask?.cancel()
            documentLoadTask = nil
            pdfDocument = nil
            contentView?.clearContent()
            pageOffsets = []
            pageCount = 0
            scrollView?.contentSize = .zero
        }

        func scrollToPage(_ page: Int, animated: Bool) {
            guard page >= 0, page < pageOffsets.count else { return }
            let y: CGFloat = page == 0 ? 0 : pageOffsets[page]
            isAnimatingScroll = animated && scrollView?.contentOffset.y != y
            scrollView?.setContentOffset(CGPoint(x: 0, y: y), animated: animated)
            reportedPage = page
            if let scrollView {
                contentView?.updateViewport(
                    CGRect(x: 0, y: y, width: scrollView.bounds.width, height: scrollView.bounds.height),
                    updateEffects: !isAnimatingScroll
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

        func scrollToBottom(animated: Bool = true) {
            guard let scrollView, pageCount > 0 else { return }
            let y = max(0, scrollView.contentSize.height - scrollView.bounds.height)
            pendingTargetRect = CGRect(x: 0, y: y, width: scrollView.bounds.width, height: scrollView.bounds.height)
            isAnimatingScroll = animated && scrollView.contentOffset.y != y
            scrollView.setContentOffset(CGPoint(x: 0, y: y), animated: animated)
            reportedPage = pageCount - 1
            parent.currentPage = reportedPage
            contentView?.updateViewport(pendingTargetRect, updateEffects: !isAnimatingScroll)
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

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            isAnimatingScroll = false
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            isAnimatingScroll = false
            flushPageReport()
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

/// Decode only two bounded-size images, off the main thread. Invalid gallery entries are
/// skipped; a gallery with one usable image reuses it for both ends.
private enum ChapterArtwork {
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

// MARK: - PDF Content View

fileprivate class PDFContentView: UIView {
    var pdfDocument: PDFDocument?
    var pageRects: [(offset: CGFloat, height: CGFloat)] = []
    private var contentWidth: CGFloat = 0
    private(set) var openingArtHeight: CGFloat = 0
    /// Difference from the original PDF-only layout, which includes a top safe-area inset.
    private(set) var openingContentOffset: CGFloat = 0
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

    func configure(document: PDFDocument, width: CGFloat, viewportHeight: CGFloat, artwork: [UIImage]) {
        generation += 1
        pdfDocument = document
        contentWidth = width
        let scale = traitCollection.displayScale
        cachedScreenScale = scale > 0 ? scale : 2.0

        renderQueue.cancelAllOperations()
        scheduleQueue.async { [weak self] in self?.inflightOps.removeAll() }
        tileLayers.forEach { $0.removeFromSuperlayer() }
        tileLayers.removeAll()
        if pdfLayer.superlayer == nil { layer.addSublayer(pdfLayer) }
        // Keep story pixels above artwork while both layers crossfade at chapter boundaries.
        pdfLayer.zPosition = 2
        pdfLayer.opacity = 1
        pdfLayer.transform = CATransform3DIdentity
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
        updateArtEffects(CGRect(x: 0, y: 0, width: width, height: visibleHeight))
        scheduleRender(top: 0, bottom: visibleHeight * overscanFactor)
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
    func updateViewport(_ rect: CGRect, updateEffects: Bool = true) {
        // Opacity follows every scroll frame, independently of throttled PDF tile rendering.
        if updateEffects { updateArtEffects(rect) }
        let overscan = max(rect.height, 1) * overscanFactor
        let top = rect.minY - overscan
        let bottom = rect.maxY + overscan

        // Skip near-duplicate schedules; the serial render queue coalesces the rest.
        if abs(top - lastScheduledTop) < tileHeightPoints * 0.5 { return }
        lastScheduledTop = top

        scheduleRender(top: top, bottom: bottom)
    }

    private func updateArtEffects(_ viewport: CGRect) {
        guard artViews.count == 2, artTransitions.count == 2 else { return }
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
                        self.updateArtBackdrop(image: cgImage, tileIndex: tileIdx)
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
