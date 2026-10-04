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
    return "PASS: \(passed) reader artwork checks"
}
