// Appended to PDFPageView.swift in a disposable test build to exercise file-private rendering.
@MainActor
func runReaderArtworkChecks() async throws -> String {
    struct CheckFailure: Error { let message: String }
    var passed = 0
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw CheckFailure(message: message) }
        passed += 1
    }
    let testViewport = CGRect(x: 0, y: 5000, width: 390, height: 800)
    let still = ReaderRenderWindow(viewport: testViewport, velocity: 0)
    let down = ReaderRenderWindow(viewport: testViewport, velocity: 12000)
    let up = ReaderRenderWindow(viewport: testViewport, velocity: -12000)
    try check(still.top == 3800 && still.bottom == 7000, "Idle prefetch stays symmetric")
    try check(down.top == 4600 && down.bottom == 7800, "Fast downward fling keeps 2.5 screens ahead")
    try check(up.top == 3000 && up.bottom == 6200, "Direction reversal mirrors prefetch immediately")
    try check(down.bottom - down.top == still.bottom - still.top
              && up.bottom - up.top == still.bottom - still.top,
              "Fling prefetch does not grow the decoded-image window")
    let ahead = CGRect(x: 0, y: 6000, width: 390, height: 384)
    let behind = CGRect(x: 0, y: 4500, width: 390, height: 384)
    try check(down.priority(for: testViewport) == .veryHigh
              && down.priority(for: ahead) == .high && down.priority(for: behind) == .low,
              "Visible work wins over forward prefetch and trailing work")
    try check(up.priority(for: behind) == .high && up.priority(for: ahead) == .low,
              "Reverse fling promotes work in the new direction")
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try check(ChapterArtwork.load(from: nil).isEmpty, "Standalone PDF has no separators")
    try check(ChapterArtwork.load(from: folder).isEmpty, "Empty gallery has no separators")
    try Data("invalid image".utf8).write(to: folder.appendingPathComponent("broken.jpg"))
    try check(ChapterArtwork.load(from: folder).isEmpty, "Corrupt images are skipped")
    func image(_ color: UIColor, size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
    let red = image(.red, size: CGSize(width: 100, height: 200))
    try red.pngData()!.write(to: folder.appendingPathComponent("one.PNG"))
    let single = ChapterArtwork.load(from: folder)
    try check(single.count == 2 && single[0] === single[1], "One image reused at both ends")
    try image(.blue, size: CGSize(width: 200, height: 100)).pngData()!
        .write(to: folder.appendingPathComponent("two.png"))
    let pair = ChapterArtwork.load(from: folder)
    try check(pair.count == 2 && pair[0].size != pair[1].size, "Two distinct gallery images selected")

    let doc = PDFDocument()
    doc.insert(PDFPage(image: red)!, at: 0)
    doc.insert(PDFPage(image: red)!, at: 1)
    let content = PDFContentView()
    content.configure(document: doc, width: 300, viewportHeight: 400, artwork: [])
    let original = content.pageRects
    let originalHeight = content.bounds.height
    content.configure(document: doc, width: 300, viewportHeight: 400, artwork: pair)
    try check(doc.pageCount == 2 && content.pageRects.count == 2, "Separators do not change PDF page count")
    try check(content.bounds.height == originalHeight + 800 - original[0].offset, "Separate full artwork pages bracket the PDF")
    try check(content.pageRects[1].offset == original[1].offset + 400 - original[0].offset, "PDF page offsets account for opening art")
    let views = content.subviews.compactMap { $0 as? UIImageView }
    try check(views.count == 2 && views.allSatisfy { $0.contentMode == .scaleAspectFill && $0.clipsToBounds && $0.bounds.height == 400 }, "Art fills and clips to the viewport")
    try check(views[0].frame.maxY == content.pageRects[0].offset, "PDF starts after the opening artwork rather than underneath it")
    try check(views.allSatisfy { view in
        guard let mask = view.layer.mask as? CAGradientLayer else { return false }
        return mask.frame == view.bounds
    }, "Edge masks reveal the live PDF instead of painting color strips")
    try check(views[0].frame.minY == 0, "Opening artwork starts at the screen edge")
    try check(views.allSatisfy { $0.layer.zPosition > 0 }, "Artwork uses its own compositing layer")
    func edgeAlpha(_ index: Int, opening: Bool) -> CGFloat {
        let colors = (views[index].layer.mask as! CAGradientLayer).colors as! [CGColor]
        return (opening ? colors.last! : colors.first!).alpha
    }

    func viewport(_ y: CGFloat) -> CGRect { CGRect(x: 0, y: y, width: 300, height: 400) }
    content.updateViewport(viewport(0))
    try check(views[0].alpha == 1 && edgeAlpha(0, opening: true) == 1,
              "Opening art starts fully visible without a gradient")
    content.updateViewport(viewport(100))
    let earlyAlpha = views[0].alpha
    content.updateViewport(viewport(110))
    try check(views[0].alpha < earlyAlpha, "Fade updates even below the tile scheduling threshold")
    content.updateViewport(viewport(200))
    try check(abs(views[0].alpha - 0.5) < 0.001 && edgeAlpha(0, opening: true) < 1,
              "Opening art and gradient respond to partial scroll")
    try check(views[0].frame.minY - 200 == 0 && views[0].frame.height == 400,
              "Opening artwork is stationary in screen coordinates halfway through fade")
    content.updateViewport(viewport(400))
    try check(views[0].alpha == 0, "Opening art disappears when PDF fills viewport")
    let closingY = content.bounds.height - 400
    content.updateViewport(viewport(closingY - 200))
    try check(abs(views[1].alpha - 0.5) < 0.001, "Closing art fades symmetrically")
    try check(views[1].frame.minY == closingY - 200, "Closing artwork is pinned to viewport too")
    content.updateViewport(viewport(closingY))
    try check(views[1].alpha == 1 && edgeAlpha(1, opening: false) == 1,
              "Closing art is fully visible without a gradient at bottom")
    content.updateViewport(viewport(closingY - 400))
    try check(views[1].alpha == 0, "Closing art disappears when returning to the PDF")
    content.updateViewport(viewport(-30))
    try check(views[0].alpha == 1, "Overscroll restores opening art without flicker")

    let shortDoc = PDFDocument()
    shortDoc.insert(PDFPage(image: red)!, at: 0)
    let shortContent = PDFContentView()
    shortContent.configure(document: shortDoc, width: 300, viewportHeight: 400, artwork: pair)
    shortContent.updateViewport(viewport(400))
    let shortArt = shortContent.subviews.compactMap { $0 as? UIImageView }
    try check(shortArt.allSatisfy { $0.alpha == 0 }, "Short chapter has a fully uncovered reading position")
    let pdfLayer = shortContent.layer.sublayers!.first { !($0.delegate is UIImageView) && $0.zPosition == 2 }!
    try check(pdfLayer.transform.m42 == 0 && shortContent.pageRects[0].offset == 400, "Short chapter keeps a separate opening page without moving the PDF")
    shortContent.configure(document: shortDoc, width: 300, viewportHeight: 400, artwork: [])
    try check(shortContent.subviews.isEmpty && pdfLayer.transform.m42 == 0 && pdfLayer.opacity == 1,
              "PDF-only layout resets pinned artwork and PDF transforms")
    shortContent.clearContent()

    let parent = PDFPageView(pdfDocument: doc, artFolderURL: folder, currentPage: .constant(0),
                             initialOffset: 0, onPageChange: { _ in }, onTap: {})
    let coordinator = parent.makeCoordinator()
    let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
    scroll.addSubview(content)
    coordinator.scrollView = scroll
    coordinator.contentView = content
    scroll.delegate = coordinator
    var restored = false
    coordinator.loadDocument(doc, width: 300, artFolderURL: folder, restorePage: 0,
                             restoreOffset: 200, onRestore: { restored = true })
    try check(coordinator.pendingRestoreOffset == 200, "Saved position preserved while artwork is loading")
    for _ in 0..<100 where !restored { try await Task.sleep(for: .milliseconds(50)) }
    try check(restored && scroll.contentOffset.y == 200 + content.openingContentOffset, "Existing saved position restores with opening art")
    let renderedViews = content.subviews.compactMap { $0 as? UIImageView }
    renderedViews[0].image = image(.blue, size: CGSize(width: 300, height: 400))
    coordinator.scrollToOffset(200)
    var ready = false
    coordinator.awaitTargetRendered { ready = true }
    for _ in 0..<100 where !ready { try await Task.sleep(for: .milliseconds(50)) }
    try check(ready, "Live PDF behind artwork is rendered")
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let snapshot = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 400), format: format).image { context in
        context.cgContext.translateBy(x: 0, y: -200)
        content.layer.render(in: context.cgContext)
    }
    let pixel = snapshot.cgImage!.cropping(to: CGRect(x: 150, y: 100, width: 1, height: 1))!
    var rgba = [UInt8](repeating: 0, count: 4)
    rgba.withUnsafeMutableBytes { bytes in
        let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    try check(rgba[0] > 80 && rgba[2] > 80 && rgba[1] < 30,
              "Whole artwork fades into the PDF edge backdrop instead of black")
    let boundaryPixel = snapshot.cgImage!.cropping(to: CGRect(x: 150, y: 300, width: 1, height: 1))!
    rgba.withUnsafeMutableBytes { bytes in
        let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(boundaryPixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    try check(rgba[0] > 150 && rgba[0] < 220 && rgba[2] > 30 && rgba[2] < 100 && rgba[1] < 30,
              "Story and artwork both participate in the halfway crossfade: \(rgba)")
    let livePDF = content.layer.sublayers!.first { $0.zPosition == 2 }!
    try check(abs(livePDF.opacity - 0.5) < 0.001 && livePDF.sublayers!.allSatisfy { $0.opacity == 1 },
              "PDF fades uniformly as one layer during the opening transition")
    coordinator.scrollToOffset(400)
    try check(livePDF.opacity == 1, "PDF is fully opaque while reading chapter content")
    let endOffset = scroll.contentSize.height - scroll.bounds.height
    coordinator.scrollToOffset(endOffset - 200)
    try check(abs(livePDF.opacity - 0.5) < 0.001,
              "PDF fades symmetrically into closing artwork")
    coordinator.scrollToOffset(endOffset)
    try check(livePDF.opacity == 0, "PDF is hidden at the full closing artwork")
    coordinator.scrollToOffset(0)
    try check(livePDF.opacity == 0, "PDF starts hidden before the opening transition")
    coordinator.scrollToOffset(400)
    try check(renderedViews[0].alpha == 0 && content.pageRects[0].offset == scroll.contentOffset.y,
              "First PDF page starts fully uncovered when opening artwork finishes")
    // Switching effects must preserve document geometry and saved positions.
    let previousOffset = scroll.contentOffset
    let previousSize = scroll.contentSize
    content.artworkTransition = .continuous
    coordinator.scrollToOffset(200)
    try check(livePDF.opacity == 1 && renderedViews[0].alpha == 1,
              "Continuous mode preserves full opacity for artwork and story")
    try check(renderedViews[0].frame.minY == 0 && renderedViews[0].frame.maxY == content.pageRects[0].offset,
              "Continuous opening artwork scrolls in document coordinates with no gap")
    coordinator.scrollToOffset(endOffset - 200)
    let storyEnd = content.pageRects.last!.offset + content.pageRects.last!.height
    try check(renderedViews[1].frame.minY == storyEnd && livePDF.opacity == 1,
              "Continuous closing artwork meets the story without fading its text")
    let continuousMask = renderedViews[1].layer.mask as! CAGradientLayer
    try check((continuousMask.colors!.first as! CGColor).alpha == 0 &&
              (continuousMask.colors!.last as! CGColor).alpha == 1,
              "Closing seam feathers only the artwork edge")
    coordinator.scrollToOffset(200)
    try check(renderedViews[0].frame.minY == 0 && scroll.contentSize == previousSize,
              "Reverse scrolling and mode changes preserve continuous layout")
    for effect in [ArtworkTransition.parallax] {
        content.artworkTransition = effect
        coordinator.scrollToOffset(200)
        let openingFrame = renderedViews[0].frame
        let expectedY: CGFloat = 50
        try check(openingFrame.minY == expectedY && livePDF.opacity == 1,
                  "\(effect.title) has distinct opening motion and opaque story pixels")
        let openingMask = renderedViews[0].layer.mask as! CAGradientLayer
        let openingStops = openingMask.locations!.map { $0.doubleValue }
        try check(openingStops == openingStops.sorted() && openingStops.allSatisfy { (0...1).contains($0) },
                  "\(effect.title) keeps gradient stops ordered within artwork")
        let band = (openingStops.last! - openingStops.first!) * 400
        try check(abs(band - 80) < 0.01,
                  "\(effect.title) uses the intended seam width")
        coordinator.scrollToOffset(endOffset - 200)
        let expectedClosingY = storyEnd - 50
        try check(renderedViews[1].frame.minY == expectedClosingY && livePDF.opacity == 1,
                  "\(effect.title) mirrors the effect at the closing seam")
        coordinator.scrollToOffset(endOffset)
        try check(renderedViews[1].alpha == 1 && renderedViews[0].alpha == 0,
                  "\(effect.title) ends on closing artwork alone")
        coordinator.scrollToOffset(200)
        try check(renderedViews[0].frame == openingFrame && scroll.contentSize == previousSize,
                  "\(effect.title) reverses without changing layout or progress coordinates")
        coordinator.scrollToOffset(-30)
        try check(renderedViews[0].alpha == 1 && livePDF.opacity == 1,
                  "\(effect.title) tolerates top overscroll")
    }
    // Hybrid must use the existing effects exactly, including reverse scrolling.
    for (offset, index, reference): (CGFloat, Int, ArtworkTransition) in [
        (0, 0, .parallax), (200, 0, .parallax), (400, 0, .parallax),
        (endOffset - 400, 1, .continuous), (endOffset - 200, 1, .continuous),
        (endOffset, 1, .continuous), (endOffset - 200, 1, .continuous), (200, 0, .parallax)
    ] {
        content.artworkTransition = reference
        coordinator.scrollToOffset(offset)
        let expectedFrame = renderedViews[index].frame
        let expectedAlpha = renderedViews[index].alpha
        let expectedStops = (renderedViews[index].layer.mask as! CAGradientLayer).locations
        content.artworkTransition = .parallaxContinuous
        coordinator.scrollToOffset(offset)
        try check(renderedViews[index].frame == expectedFrame && renderedViews[index].alpha == expectedAlpha &&
                  (renderedViews[index].layer.mask as! CAGradientLayer).locations == expectedStops &&
                  livePDF.opacity == 1 && scroll.contentSize == previousSize,
                  "Hybrid matches \(reference.title) at offset \(offset) without altering story or layout")
    }
    content.artworkTransition = .fade
    coordinator.scrollToOffset(200)
    try check(abs(livePDF.opacity - 0.5) < 0.001 && renderedViews[0].frame.minY == 200,
              "Switching back restores pinned fade behavior")
    coordinator.scrollToOffset(previousOffset.y)

    let snapshotURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("pinned-fade.png")
    try snapshot.pngData()!.write(to: snapshotURL)
    coordinator.scrollToPage(1, animated: false)
    try check(scroll.contentOffset.y == content.pageRects[1].offset, "Page navigation uses original PDF indices")
    coordinator.scrollToBottom(animated: false)
    try check(scroll.contentOffset.y == scroll.contentSize.height - scroll.bounds.height
              && coordinator.reportedPage == doc.pageCount - 1,
              "Go to bottom reaches closing art and reports the final PDF page")
    try check(renderedViews.last?.alpha == 1, "Go to bottom updates artwork effect immediately")
    coordinator.scrollToOffset(400)
    var projectedOffset = CGPoint(x: 0, y: 2_000)
    coordinator.scrollViewWillEndDragging(scroll, withVelocity: CGPoint(x: 0, y: 10),
                                          targetContentOffset: &projectedOffset)
    try check(projectedOffset.y == 900, "Native flick projection is capped at 5/4 viewport height")
    coordinator.scrollToOffset(900)
    projectedOffset = CGPoint(x: 0, y: 0)
    coordinator.scrollViewWillEndDragging(scroll, withVelocity: CGPoint(x: 0, y: -10),
                                          targetContentOffset: &projectedOffset)
    try check(projectedOffset.y == 400, "Reverse native flick projection uses the same 5/4 viewport cap")
    coordinator.scrollToTop()
    try check(coordinator.reportedPage == 0, "Go to top retains original first page index")
    coordinator.loadDocument(doc, width: 300, artFolderURL: folder, restorePage: 0)
    coordinator.clearDocument()
    try await Task.sleep(for: .milliseconds(200))
    try check(content.subviews.isEmpty && content.pageRects.isEmpty, "Cancelled chapter load cannot restore stale artwork")
    // Source capture must remain sharp and correctly aligned even while display tiles
    // are absent or affected by the chapter transition.
    let sourceData = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 1200)).pdfData { context in
        context.beginPage()
        UIColor.red.setFill()
        context.cgContext.fill(CGRect(x: 0, y: 0, width: 300, height: 1200))
        UIColor.green.setFill()
        context.cgContext.fill(CGRect(x: 0, y: 0, width: 300, height: 100))
        context.beginPage()
        UIColor.blue.setFill()
        context.cgContext.fill(CGRect(x: 0, y: 0, width: 300, height: 1200))
    }
    let captureContent = PDFContentView()
    captureContent.configure(document: PDFDocument(data: sourceData)!, width: 300,
                             viewportHeight: 400, artwork: pair)
    let capturePDFLayer = captureContent.layer.sublayers!.first { $0.zPosition == 2 }!
    let firstY = captureContent.pageRects[0].offset
    captureContent.updateViewport(viewport(firstY + 50))
    capturePDFLayer.opacity = 0.05
    capturePDFLayer.sublayers?.forEach { $0.contents = nil }
    let captured = captureContent.captureViewport(viewport(firstY + 50))!
    func rgb(_ image: UIImage, x: CGFloat, y: CGFloat) -> [UInt8] {
        let pixel = image.cgImage!.cropping(to: CGRect(x: x * image.scale, y: y * image.scale, width: 1, height: 1))!
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }
    // A PDF need not paint its paper. Model adjacent web images with an
    // unpainted one-point gap, plus a genuine black rule that must stay black.
    let paperData = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 1200)).pdfData { context in
        context.beginPage()
        UIColor.white.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        context.fill(CGRect(x: 0, y: 201, width: 300, height: 999))
        UIColor.black.setFill()
        context.fill(CGRect(x: 0, y: 210, width: 300, height: 2))
    }
    let paperContent = PDFContentView()
    paperContent.configure(document: PDFDocument(data: paperData)!, width: 300,
                           viewportHeight: 400, artwork: [])
    let paperY = paperContent.pageRects[0].offset
    let paperViewport = CGRect(x: 0, y: paperY, width: 300, height: 400)
    paperContent.updateViewport(paperViewport)
    await withCheckedContinuation { continuation in
        paperContent.awaitViewportRendered(paperViewport) { continuation.resume() }
    }
    let paperLayer = paperContent.layer.sublayers!.first { $0.zPosition == 2 }!
    let paperTile = UIImage(cgImage: paperLayer.sublayers!.first!.contents as! CGImage,
                            scale: paperContent.traitCollection.displayScale, orientation: .up)
    let paperCapture = paperContent.captureViewport(paperViewport)!
    for image in [paperTile, paperCapture] {
        try check(rgb(image, x: 150, y: 200.5).prefix(3).allSatisfy { $0 > 245 },
                  "Unpainted PDF image seam uses white paper in tiles and gallery captures")
        try check(rgb(image, x: 150, y: 211).prefix(3).allSatisfy { $0 < 10 },
                  "Real black comic lines remain intact")
    }
    paperContent.clearContent()
    // Reproduce WebKit's fractional image clip over a dark background embedded
    // in the PDF (white reader paper alone cannot fix this seam).
    let seamData = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 1200)).pdfData { context in
        context.beginPage()
        UIColor(white: 0.035, alpha: 1).setFill()
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 1200))
        let white = image(.white, size: CGSize(width: 300, height: 600))
        let cg = context.cgContext
        cg.saveGState()
        cg.clip(to: CGRect(x: 0, y: 0, width: 300, height: 599.567))
        white.draw(in: CGRect(x: 0, y: 0, width: 300, height: 599.9))
        cg.restoreGState()
        white.draw(in: CGRect(x: 0, y: 599.9, width: 300, height: 600.1))
        UIColor.black.setFill()
        context.fill(CGRect(x: 0, y: 610, width: 300, height: 2))
    }
    let clippedContent = PDFContentView()
    clippedContent.configure(document: PDFDocument(data: seamData)!, width: 300,
                             viewportHeight: 400, artwork: [])
    let clippedY = clippedContent.pageRects[0].offset
    let clippedViewport = CGRect(x: 0, y: clippedY + 500, width: 300, height: 400)
    clippedContent.updateViewport(clippedViewport)
    await withCheckedContinuation { continuation in
        clippedContent.awaitViewportRendered(clippedViewport) { continuation.resume() }
    }
    let clippedLayer = clippedContent.layer.sublayers!.first { $0.zPosition == 2 }!
    let seamTile = clippedLayer.sublayers!.first { $0.frame.minY <= clippedY + 600 && $0.frame.maxY > clippedY + 600 }!
    let tileImage = UIImage(cgImage: seamTile.contents as! CGImage,
                            scale: clippedContent.traitCollection.displayScale, orientation: .up)
    let seamCapture = clippedContent.captureViewport(clippedViewport)!
    for (image, seamY) in [(tileImage, clippedY + 599.9 - seamTile.frame.minY), (seamCapture, CGFloat(99.9))] {
        for delta in [-0.5, 0.0, 0.5] {
            try check(rgb(image, x: 150, y: seamY + delta).prefix(3).allSatisfy { $0 > 245 },
                      "Fractional image clips do not reveal the PDF's embedded dark background")
        }
        try check(rgb(image, x: 150, y: seamY + 11.1).prefix(3).allSatisfy { $0 < 10 },
                  "Seam handling preserves an actual black line beside the join")
    }
    let preview = try WebCaptureDocument(data: seamData).render(
        crop: CGRect(x: 0, y: 500.0 / 1200, width: 1, height: 400.0 / 1200), pixelWidth: 900)
    try check(rgb(preview, x: 450, y: 299).prefix(3).allSatisfy { $0 > 245 },
              "Capture preview uses the same seam-free rasterization as the reader")
    clippedContent.clearContent()
    let top = rgb(captured, x: 150, y: 10)
    let lower = rgb(captured, x: 150, y: 100)
    try check(top[1] > 240 && top[0] < 15 && lower[0] > 240 && lower[1] < 15,
              "Source capture preserves sharp top content at a nonzero offset without tile cache or opacity effects")
    try check(captured.size == CGSize(width: 300, height: 400)
              && captured.cgImage!.width == Int(300 * captured.scale),
              "Capture uses viewport dimensions at display resolution")
    let saved = UIImage(data: captured.jpegData(compressionQuality: 0.9)!)!
    let savedTop = rgb(saved, x: 150 * captured.scale, y: 10 * captured.scale)
    try check(savedTop[1] > 230 && savedTop[0] < 25,
              "Top remains sharp after the gallery JPEG encoding round trip")
    let seam = captureContent.captureViewport(viewport(firstY + 1100))!
    try check(rgb(seam, x: 150, y: 50)[0] > 240 && rgb(seam, x: 150, y: 150)[2] > 240,
              "Capture composites consecutive PDF pages without a blurred or missing seam")
    captureContent.clearContent()
    try check(captureContent.captureViewport(viewport(0)) == nil,
              "Capture fails safely after chapter cleanup")
    // Exercise cancellation/replacement using real background renders of a tall PDF.
    let tallBounds = CGRect(x: 0, y: 0, width: 300, height: 12000)
    func tallDocument(_ color: UIColor) -> PDFDocument {
        let data = UIGraphicsPDFRenderer(bounds: tallBounds).pdfData { context in
            context.beginPage()
            color.setFill()
            context.fill(tallBounds)
        }
        return PDFDocument(data: data)!
    }
    let flingContent = PDFContentView()
    flingContent.configure(document: tallDocument(.red), width: 300, viewportHeight: 400, artwork: [])
    for y in [800, 2400, 4800, 8000, 10000, 7800, 4500, 2200, 900] {
        flingContent.updateViewport(viewport(CGFloat(y)))
        try await Task.sleep(for: .milliseconds(12))
    }
    // Replace the chapter while work from the fling may still be pending.
    flingContent.configure(document: tallDocument(.blue), width: 300, viewportHeight: 400, artwork: [])
    let destination = viewport(6000)
    flingContent.updateViewport(destination)
    var settled = false
    flingContent.awaitViewportRendered(destination) { settled = true }
    for _ in 0..<100 where !settled { try await Task.sleep(for: .milliseconds(20)) }
    try check(settled, "Visible tiles finish after rapid scrolling, reversal and chapter replacement")
    // Let pending layer commits run before inspecting actual displayed pixels.
    try await Task.sleep(for: .milliseconds(100))
    let flingLayer = flingContent.layer.sublayers!.first { $0.zPosition == 2 }!
    let visibleTiles = flingLayer.sublayers!.filter { $0.frame.intersects(destination) }
    try check(!visibleTiles.isEmpty && visibleTiles.allSatisfy { tile in
        guard let contents = tile.contents else { return false }
        let pixel = rgb(UIImage(cgImage: contents as! CGImage), x: 1, y: 1)
        return pixel[2] > 240 && pixel[0] < 15
    }, "Only the replacement chapter appears; no blank visible tiles or stale red pixels")
    try check(flingLayer.sublayers!.filter { $0.contents != nil }.count <= 6,
              "Tall chapters retain only the bounded viewport window after a fling")
    flingContent.clearContent()
    // Optional private chapter repro; the supplied PDF is never committed to the repo.
    // READER_SEAM_Y identifies a known white gutter, measured from the PDF's top.
    if let coordinate = ProcessInfo.processInfo.environment["READER_SEAM_Y"],
       let seamY = Double(coordinate) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let data = try Data(contentsOf: documents.appendingPathComponent("seam-regression.pdf"))
        let document = PDFDocument(data: data)!
        let sourceSize = document.page(at: 0)!.bounds(for: .mediaBox).size
        for width: CGFloat in [300, 390, 430] {
            let reader = PDFContentView()
            reader.configure(document: document, width: width, viewportHeight: 400, artwork: [])
            let ratio = width / sourceSize.width
            let join = reader.pageRects[0].offset + seamY * ratio
            let target = CGRect(x: 0, y: join - 120, width: width, height: 400)
            reader.updateViewport(target)
            await withCheckedContinuation { continuation in
                reader.awaitViewportRendered(target) { continuation.resume() }
            }
            let layer = reader.layer.sublayers!.first { $0.zPosition == 2 }!
            let tile = layer.sublayers!.first { $0.frame.minY <= join && $0.frame.maxY > join }!
            let scale = reader.traitCollection.displayScale
            let rendered = UIImage(cgImage: tile.contents as! CGImage, scale: scale, orientation: .up)
            for delta: CGFloat in [-1, -0.5, 0, 0.5, 1] {
                try check(rgb(rendered, x: width * 0.05, y: join - tile.frame.minY + delta).prefix(3).allSatisfy { $0 > 245 },
                          "Private chapter's displayed seam is white at width \(width), delta \(delta)")
            }
            for offset: CGFloat in [0, 0.25, 0.5, 0.75] {
                let shot = reader.captureViewport(target.offsetBy(dx: 0, dy: offset))!
                for delta: CGFloat in [-1, -0.5, 0, 0.5, 1] {
                    try check(rgb(shot, x: width * 0.05, y: 120 - offset + delta).prefix(3).allSatisfy { $0 > 245 },
                              "Private chapter's captured seam stays white at fractional scroll offsets")
                }
                if width == 430 && offset == 0 {
                    try shot.pngData()!.write(to: documents.appendingPathComponent("seam-fixed.png"))
                }
            }
            reader.clearContent()
        }
        let captureDocument = try WebCaptureDocument(data: data)
        for pixelWidth: CGFloat in [430, 860, 1290] {
            let shot = try captureDocument.render(crop: CGRect(x: 0, y: (seamY - 120) / sourceSize.height,
                width: 1, height: 240 / sourceSize.height), pixelWidth: pixelWidth)
            let ratio = pixelWidth / sourceSize.width
            for delta: CGFloat in [-1, -0.5, 0, 0.5, 1] {
                try check(rgb(shot, x: pixelWidth * 0.05, y: (120 + delta) * ratio).prefix(3).allSatisfy { $0 > 245 },
                          "Private chapter's capture preview stays white at \(pixelWidth) pixels")
            }
        }
    }
    return "PASS: \(passed) reader artwork checks"
}
