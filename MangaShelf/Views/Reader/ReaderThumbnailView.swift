import SwiftUI
import PDFKit

// MARK: - Floating chapter thumbnail

/// Reuses the reader's bounded tile renderer, including CropBox and very tall PDFs.
struct ReaderThumbnailView: UIViewRepresentable {
    let document: PDFDocument
    let viewport: CGRect
    let accent: UIColor
    let onSeek: (CGFloat) -> Void
    let onInteraction: (Bool) -> Void

    func makeUIView(context: Context) -> ReaderThumbnailScrollView {
        ReaderThumbnailScrollView()
    }

    func updateUIView(_ view: ReaderThumbnailScrollView, context: Context) {
        view.onSeek = onSeek
        view.onInteraction = onInteraction
        view.marker.layer.borderColor = accent.cgColor
        view.marker.backgroundColor = accent.withAlphaComponent(0.12)
        view.configure(document: document, viewport: viewport)
    }

    static func dismantleUIView(_ view: ReaderThumbnailScrollView, coordinator: ()) {
        view.onInteraction(false)
        view.onInteraction = { _ in }
        view.onSeek = { _ in }
        view.clear()
    }
}

final class ReaderThumbnailScrollView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let scrollView = UIScrollView()
    private let content = PDFContentView()
    let marker = UIView()
    private var document: PDFDocument?
    private var renderedDocument: PDFDocument?
    private var renderedWidth: CGFloat = 0
    private var viewport: CGRect = .zero
    private var progress: CGFloat { viewport.minY }
    private var isScrolling = false
    private var isHovering = false
    private var isTouching = false
    private var isSeeking = false
    var onSeek: (CGFloat) -> Void = { _ in }
    var onInteraction: (Bool) -> Void = { _ in }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        scrollView.delegate = self
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.alwaysBounceVertical = true
        scrollView.addSubview(content)
        addSubview(scrollView)
        clipsToBounds = true
        marker.layer.borderWidth = 2
        marker.isUserInteractionEnabled = false
        addSubview(marker)
        scrollView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tap(_:))))
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hover(_:))))
        let touch = UILongPressGestureRecognizer(target: self, action: #selector(touch(_:)))
        touch.minimumPressDuration = 0
        touch.cancelsTouchesInView = false
        touch.delegate = self
        scrollView.addGestureRecognizer(touch)
        isAccessibilityElement = true
        accessibilityLabel = "Chapter thumbnail"
        accessibilityHint = "Swipe up or down to move through the chapter"
        accessibilityTraits = .adjustable
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(document: PDFDocument, viewport: CGRect) {
        self.document = document
        if !isSeeking { self.viewport = viewport }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        guard let document, scrollView.bounds.width > 0, bounds.height > 0 else { return }
        if renderedDocument !== document || renderedWidth != scrollView.bounds.width {
            renderedDocument = document
            renderedWidth = scrollView.bounds.width
            content.configure(document: document, width: renderedWidth,
                              viewportHeight: bounds.height, artwork: [], includesTopInset: false)
            scrollView.contentSize = content.bounds.size
        }
        if !isScrolling && !isSeeking {
            let maxOffset = max(0, content.bounds.height - bounds.height)
            let fraction = progress / max(0.000001, 1 - viewport.height)
            scrollView.setContentOffset(CGPoint(x: 0, y: min(1, max(0, fraction)) * maxOffset), animated: false)
        }
        updateMarker()
        content.updateViewport(scrollView.bounds)
        accessibilityValue = "\(Int(progress * 100)) percent"
    }

    private func updateMarker() {
        marker.isHidden = viewport.height <= 0
        marker.frame = CGRect(x: 0,
                              y: viewport.minY * content.bounds.height - scrollView.contentOffset.y,
                              width: bounds.width,
                              height: viewport.height * content.bounds.height)
    }

    func clear() { content.clearContent() }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        isScrolling = true
        onInteraction(true)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        content.updateViewport(scrollView.bounds)
        updateMarker()
        guard isScrolling else { return }
        let range = content.bounds.height - bounds.height
        guard range > 0 else { return }
        seek(to: scrollView.contentOffset.y / range * max(0, 1 - viewport.height))
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { finishScrolling() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { finishScrolling() }

    private func finishScrolling() {
        isScrolling = false
        onInteraction(isHovering || isTouching)
    }

    private func seek(to value: CGFloat) {
        isSeeking = true
        viewport.origin.y = min(max(0, 1 - viewport.height), max(0, value))
        onSeek(progress)
        updateMarker()
        isSeeking = false
        accessibilityValue = "\(Int(progress * 100)) percent"
    }

    @objc private func tap(_ gesture: UITapGestureRecognizer) {
        onInteraction(true)
        seek(to: gesture.location(in: content).y / max(1, content.bounds.height) - viewport.height / 2)
        setNeedsLayout()
        onInteraction(isScrolling || isHovering || isTouching)
    }

    @objc private func hover(_ gesture: UIHoverGestureRecognizer) {
        isHovering = gesture.state == .began || gesture.state == .changed
        onInteraction(isScrolling || isHovering || isTouching)
    }

    @objc private func touch(_ gesture: UILongPressGestureRecognizer) {
        isTouching = gesture.state == .began || gesture.state == .changed
        onInteraction(isScrolling || isHovering || isTouching)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    override func accessibilityIncrement() { adjust(by: 0.05) }
    override func accessibilityDecrement() { adjust(by: -0.05) }

    private func adjust(by delta: CGFloat) {
        onInteraction(true)
        seek(to: progress + delta)
        setNeedsLayout()
        onInteraction(isScrolling || isHovering || isTouching)
    }
}
