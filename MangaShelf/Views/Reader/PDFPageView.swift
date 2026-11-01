//
//  PDFPageView.swift
//  MangaShelf
//
//  Created by Khoa Phan on 4/24/26.
//

import SwiftUI
import PDFKit

struct PDFPageView: UIViewRepresentable {

    @AppStorage(StorageKey.artworkTransition) private var artworkTransition: ArtworkTransition = .fade

    let pdfDocument: PDFDocument?
    let artFolderURL: URL?
    @Binding var currentPage: Int
    /// Exact vertical scroll offset (content points) to restore on first load. `0` falls back
    /// to page-based restore (`currentPage`), which is what pre-offset saved data will have.
    let initialOffset: CGFloat
    /// Fraction (0...1) of the PDF content to open the next loaded document at, used when
    /// switching the same chapter between languages. `0` = open at the top.
    var restoreProgress: CGFloat = 0
    let onPageChange: (Int) -> Void
    let onTap: () -> Void
    var onCaptureReady: ((@escaping () -> (UIImage, CGFloat)?) -> Void)? = nil
    /// Hands the parent a closure that reads the live `contentOffset.y` on demand, so progress
    /// can be persisted at the exact scroll position without observing every scroll frame.
    var onOffsetReady: ((@escaping () -> CGFloat) -> Void)? = nil
    /// Hands the parent a closure that reads how far through the PDF content (0...1) the
    /// viewport is, or `nil` while no document is laid out.
    var onProgressReady: ((@escaping () -> CGFloat?) -> Void)? = nil
    /// Hands the parent a `scrollToTop(completion:)` closure: it scrolls (animated) to the top
    /// of the current chapter and calls `completion` once the top tiles have finished rendering.
    var onScrollToTopReady: ((@escaping (@escaping () -> Void) -> Void) -> Void)? = nil
    var onScrollToBottomReady: ((@escaping (@escaping () -> Void) -> Void) -> Void)? = nil
    /// Called (main thread) once the restored initial position's tiles have finished rendering.
    var onRestoreComplete: (() -> Void)? = nil

    var onSeekReady: ((@escaping (CGFloat) -> Void, @escaping () -> CGRect) -> Void)? = nil
    var onThumbnailViewportChange: ((CGRect) -> Void)? = nil

    func makeUIView(context: Context) -> UIView {
        let scrollView = UIScrollView()
        scrollView.backgroundColor = UIColor(Color.appBackground)
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delegate = context.coordinator

        let contentView = PDFContentView()
        contentView.artworkTransition = artworkTransition
        contentView.backgroundColor = UIColor(Color.appBackground)
        scrollView.addSubview(contentView)

        context.coordinator.scrollView = scrollView
        context.coordinator.contentView = contentView

        onCaptureReady?({ [weak coordinator = context.coordinator] in
            guard let coordinator, let scrollView = coordinator.scrollView,
                  let image = coordinator.contentView?.captureViewport(scrollView.bounds) else { return nil }
            // Same PDF coordinates as saved progress, so a capture can be reopened in place.
            return (image, max(0, scrollView.contentOffset.y
                                - (coordinator.contentView?.openingContentOffset ?? 0)))
        })

        onOffsetReady?({ [weak coordinator = context.coordinator] in
            guard let coordinator else { return 0 }
            if let pendingOffset = coordinator.pendingRestoreOffset { return pendingOffset }
            // Persist in original PDF coordinates so gallery changes never shift progress.
            return max(0, (coordinator.scrollView?.contentOffset.y ?? 0)
                       - (coordinator.contentView?.openingContentOffset ?? 0))
        })

        onSeekReady?({ [weak coordinator = context.coordinator] progress in
            coordinator?.isAnimatingScroll = false
            coordinator?.seekThumbnail(progress)
        }, { [weak coordinator = context.coordinator] in
            coordinator?.thumbnailViewport() ?? .zero
        })

        onProgressReady?({ [weak coordinator = context.coordinator] in
            coordinator?.scrollProgress()
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
        coordinator.parent = self
        guard let scrollView = uiView as? UIScrollView else { return }

        coordinator.contentView?.artworkTransition = artworkTransition
        coordinator.contentView?.updateViewport(scrollView.bounds)

        if pdfDocument == nil && coordinator.pdfDocument != nil {
            coordinator.clearDocument()
            return
        }

        if let doc = pdfDocument, coordinator.pdfDocument !== doc {
            coordinator.loadDocument(
                doc, width: scrollView.bounds.width, artFolderURL: artFolderURL,
                restorePage: currentPage, restoreProgress: restoreProgress,
                onRestore: restoreProgress > 0 ? onRestoreComplete : nil
            )
            return
        }

        if !coordinator.isAnimatingScroll, !scrollView.isTracking,
           !scrollView.isDragging, !scrollView.isDecelerating,
           coordinator.reportedPage != currentPage {
            coordinator.scrollToPage(currentPage, animated: false)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: PDFPageView
        weak var scrollView: UIScrollView?
        weak var contentView: PDFContentView?
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
            restorePage: Int, restoreOffset: CGFloat = 0, restoreProgress: CGFloat = 0,
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
                if restoreProgress > 0 {
                    self.scrollToProgress(restoreProgress)
                    self.awaitTargetRendered { onRestore?() }
                } else if restoreOffset > 0 {
                    self.scrollToOffset(restoreOffset + contentView.openingContentOffset)
                    self.awaitTargetRendered { onRestore?() }
                } else {
                    self.scrollToPage(restorePage, animated: false)
                    onRestore?()
                }
                self.parent.onThumbnailViewportChange?(self.thumbnailViewport())
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
            let clamped = y.isFinite ? min(max(0, y), maxY) : 0
            scrollView.setContentOffset(CGPoint(x: 0, y: clamped), animated: false)
            reportedPage = pageIndex(forViewportY: clamped + scrollView.bounds.height * 0.3)
            parent.currentPage = reportedPage
            let target = CGRect(x: 0, y: clamped, width: scrollView.bounds.width, height: scrollView.bounds.height)
            pendingTargetRect = target
            contentView?.updateViewport(target)
        }

        /// Scrollable range of the PDF pages alone (excluding opening/closing artwork), so a
        /// progress fraction maps between two documents of different lengths.
        private var pdfScrollRange: (start: CGFloat, length: CGFloat)? {
            guard let scrollView, let first = contentView?.pageRects.first,
                  let last = contentView?.pageRects.last else { return nil }
            let end = last.offset + last.height
            return (first.offset, max(0, end - scrollView.bounds.height - first.offset))
        }

        /// How far through the PDF content (0...1) the viewport's top edge is.
        func scrollProgress() -> CGFloat? {
            guard let scrollView, let range = pdfScrollRange else { return nil }
            guard range.length > 0 else { return 0 }
            return min(1, max(0, (scrollView.contentOffset.y - range.start) / range.length))
        }

        /// Thumbnail coordinates span the full PDF, independent of decorative artwork.
        func thumbnailProgress() -> CGFloat {
            guard let scrollView, let first = contentView?.pageRects.first,
                  let last = contentView?.pageRects.last else { return 0 }
            let height = last.offset + last.height - first.offset
            return min(1, max(0, (scrollView.contentOffset.y - first.offset) / max(1, height)))
        }

        func thumbnailViewport() -> CGRect {
            guard let scrollView, let first = contentView?.pageRects.first,
                  let last = contentView?.pageRects.last else { return .zero }
            let height = max(1, last.offset + last.height - first.offset)
            let top = min(1, max(0, (scrollView.bounds.minY - first.offset) / height))
            let bottom = min(1, max(0, (scrollView.bounds.maxY - first.offset) / height))
            return CGRect(x: 0, y: top, width: 1, height: max(0, bottom - top))
        }

        func seekThumbnail(_ progress: CGFloat) {
            guard let range = pdfScrollRange, let first = contentView?.pageRects.first,
                  let last = contentView?.pageRects.last else { return }
            let height = last.offset + last.height - first.offset
            scrollToOffset(range.start + min(range.length, max(0, progress) * height))
        }

        /// Jumps to the same relative position (0...1) within the PDF content.
        func scrollToProgress(_ progress: CGFloat) {
            guard let range = pdfScrollRange else { return }
            scrollToOffset(range.start + min(1, max(0, progress)) * range.length)
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
            if pageCount > 0 { parent.onThumbnailViewportChange?(thumbnailViewport()) }
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

        func scrollViewWillEndDragging(
            _ scrollView: UIScrollView, withVelocity velocity: CGPoint,
            targetContentOffset: UnsafeMutablePointer<CGPoint>
        ) {
            let maxDrift = scrollView.bounds.height * 1.25
            let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
            let currentY = scrollView.contentOffset.y
            let proposedY = targetContentOffset.pointee.y
            let limitedY = min(currentY + maxDrift, max(currentY - maxDrift, proposedY))
            targetContentOffset.pointee.y = min(maxY, max(0, limitedY))
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
