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
    let onPageChange: (Int) -> Void
    let onTap: () -> Void

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
            DispatchQueue.main.async {
                context.coordinator.scrollToPage(currentPage, animated: false)
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
            contentView?.updateCenter(page: page)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard pageCount > 0 else { return }
            let y = scrollView.contentOffset.y + scrollView.bounds.height * 0.3

            var lo = 0, hi = pageCount - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if pageOffsets[mid] <= y {
                    lo = mid
                } else {
                    hi = mid - 1
                }
            }

            contentView?.updateCenter(page: lo)
            reportedPage = lo
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
    private var pageLayers: [CALayer] = []

    private var pageImages: [Int: CGImage] = [:]
    private var inflightPages = Set<Int>()
    private var unfairLock = os_unfair_lock()
    private let renderQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "pdf.render"
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private let scheduleQueue = DispatchQueue(label: "pdf.schedule")
    private var currentCenter: Int = 0
    private var previousCenter: Int = 0
    private let activeRadius = 4
    private var generation: Int = 0
    private static let bgColor: CGColor = UIColor.black.cgColor
    private var cachedScreenScale: CGFloat = 0

    func configure(document: PDFDocument, width: CGFloat) {
        generation += 1
        pdfDocument = document
        contentWidth = width
        let scale = traitCollection.displayScale
        cachedScreenScale = scale > 0 ? scale : 2.0

        pageLayers.forEach { $0.removeFromSuperlayer() }
        pageLayers.removeAll()
        os_unfair_lock_lock(&unfairLock)
        pageImages.removeAll()
        inflightPages.removeAll()
        os_unfair_lock_unlock(&unfairLock)
        currentCenter = 0
        previousCenter = 0

        let topInset: CGFloat = {
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
            return scene?.keyWindow?.safeAreaInsets.top ?? 59
        }()

        var offset = topInset
        pageRects = []

        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            let pageRect = page.bounds(for: .mediaBox)
            let scale = width / pageRect.width
            let height = pageRect.height * scale
            pageRects.append((offset: offset, height: height))

            let pageLayer = CALayer()
            pageLayer.frame = CGRect(x: 0, y: offset, width: width, height: height)
            pageLayer.contentsScale = cachedScreenScale
            pageLayer.contentsGravity = .resize
            pageLayer.backgroundColor = Self.bgColor
            layer.addSublayer(pageLayer)
            pageLayers.append(pageLayer)

            offset += height
        }

        frame = CGRect(x: 0, y: 0, width: width, height: offset)
        backgroundColor = UIColor.black

        scheduleRender(center: 0)
    }

    func clearContent() {
        generation += 1
        pdfDocument = nil
        pageLayers.forEach { $0.removeFromSuperlayer() }
        pageLayers.removeAll()
        os_unfair_lock_lock(&unfairLock)
        pageImages.removeAll()
        inflightPages.removeAll()
        os_unfair_lock_unlock(&unfairLock)
        pageRects.removeAll()
        frame = .zero
    }

    func updateCenter(page: Int) {
        guard page != currentCenter else { return }
        previousCenter = currentCenter
        currentCenter = page
        scheduleRender(center: page)
    }

    // MARK: - Rendering

    private func scheduleRender(center: Int) {
        scheduleQueue.async { [weak self] in
            self?.renderPages(around: center)
        }
    }

    private func renderPages(around center: Int) {
        guard let doc = pdfDocument else { return }
        let count = pageRects.count
        guard count > 0 else { return }

        let scrollForward = center >= previousCenter
        let behind = scrollForward ? activeRadius / 3 : activeRadius
        let ahead = scrollForward ? activeRadius : activeRadius / 3
        let lo = max(0, center - behind)
        let hi = min(count - 1, center + ahead)
        let desiredSet = Set(lo...hi)
        let currentGen = generation
        let width = contentWidth
        let screenScale = cachedScreenScale
        let rects = pageRects

        os_unfair_lock_lock(&unfairLock)
        let existing = Set(pageImages.keys)
        let inflight = inflightPages
        let toEvict = existing.subtracting(desiredSet)
        for key in toEvict {
            pageImages.removeValue(forKey: key)
        }
        os_unfair_lock_unlock(&unfairLock)

        if !toEvict.isEmpty {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                for key in toEvict where key < self.pageLayers.count {
                    self.pageLayers[key].contents = nil
                }
                CATransaction.commit()
            }
        }

        let toRender = desiredSet
            .subtracting(existing)
            .subtracting(inflight)
            .sorted { abs($0 - center) < abs($1 - center) }

        guard !toRender.isEmpty else { return }

        os_unfair_lock_lock(&unfairLock)
        for i in toRender { inflightPages.insert(i) }
        os_unfair_lock_unlock(&unfairLock)

        for i in toRender {
            renderQueue.addOperation { [weak self, weak doc] in
                autoreleasepool {
                    guard let self, let doc, self.generation == currentGen else {
                        self?.removeInflight(i)
                        return
                    }
                    guard let page = doc.page(at: i), i < rects.count else {
                        self.removeInflight(i)
                        return
                    }

                    let pageRect = page.bounds(for: .mediaBox)
                    let scale = width / pageRect.width
                    let pixelW = Int(width * screenScale)
                    let pixelH = Int(rects[i].height * screenScale)

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
                        cgContext.translateBy(x: 0, y: CGFloat(pixelH))
                        cgContext.scaleBy(x: scale * screenScale, y: -scale * screenScale)
                        page.draw(with: .mediaBox, to: cgContext)
                    }

                    guard let cgImage = uiImage.cgImage, self.generation == currentGen else {
                        self.removeInflight(i)
                        return
                    }

                    os_unfair_lock_lock(&self.unfairLock)
                    self.pageImages[i] = cgImage
                    self.inflightPages.remove(i)
                    os_unfair_lock_unlock(&self.unfairLock)

                    DispatchQueue.main.async {
                        guard self.generation == currentGen, i < self.pageLayers.count else { return }
                        CATransaction.begin()
                        CATransaction.setDisableActions(true)
                        self.pageLayers[i].contents = cgImage
                        CATransaction.commit()
                    }
                }
            }
        }
    }

    private func removeInflight(_ index: Int) {
        os_unfair_lock_lock(&unfairLock)
        inflightPages.remove(index)
        os_unfair_lock_unlock(&unfairLock)
    }
}
