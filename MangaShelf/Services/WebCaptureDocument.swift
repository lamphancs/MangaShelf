import UIKit
import CoreGraphics
import PDFKit

/// Keeps WebKit's PDF intact; multiple PDF pages form one continuous crop canvas.
nonisolated struct WebCaptureDocument: Sendable {
    let data: Data
    let size: CGSize
    let pageCount: Int
    private let pageRects: [CGRect]

    init(data: Data) throws {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider), document.numberOfPages > 0 else {
            throw WebCaptureError.invalidDocument
        }
        var rects: [CGRect] = []
        var totalHeight: CGFloat = 0
        var maxWidth: CGFloat = 0
        for index in 1...document.numberOfPages {
            guard let page = document.page(at: index) else { throw WebCaptureError.invalidDocument }
            let box = page.getBoxRect(.mediaBox)
            let rotated = abs(page.rotationAngle) % 180 == 90
            let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
                throw WebCaptureError.invalidDocument
            }
            rects.append(CGRect(x: 0, y: totalHeight, width: size.width, height: size.height))
            totalHeight += size.height
            maxWidth = max(maxWidth, size.width)
        }
        guard totalHeight.isFinite else { throw WebCaptureError.invalidDocument }
        self.data = data
        self.size = CGSize(width: maxWidth, height: totalHeight)
        self.pageCount = document.numberOfPages
        self.pageRects = rects
    }

    /// Trim browser viewports from the top and bottom, retaining at least one on short pages.
    func defaultCaptureCrop(viewportHeight: CGFloat,
                            topTrimPages: Int = CaptureCrop.defaultTopTrimPages,
                            trimPages: Int = CaptureCrop.defaultTrimPages) -> CGRect {
        guard viewportHeight.isFinite, viewportHeight > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let topTrim = CGFloat(max(0, topTrimPages)) * viewportHeight
        let bottomTrim = CGFloat(max(0, trimPages)) * viewportHeight
        let retainedHeight = min(size.height, max(viewportHeight, size.height - topTrim - bottomTrim))
        // When both trims overlap on a short page, the top trim shrinks to keep the retained viewport.
        let top = min(topTrim, size.height - retainedHeight)
        return CGRect(x: 0, y: top / size.height, width: 1, height: retainedHeight / size.height)
    }

    /// Join source pages into one continuous PDF page, without rasterizing content.
    func pdfData(crop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) throws -> Data {
        let rect = try cropRect(crop)
        if pageCount == 1 && rect == CGRect(origin: .zero, size: size) { return data }
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider) else { throw WebCaptureError.invalidDocument }
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw WebCaptureError.invalidDocument
        }
        var box = CGRect(origin: .zero, size: rect.size)
        let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
        context.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
        for (index, pageRect) in pageRects.enumerated() {
            let top = max(rect.minY, pageRect.minY)
            let bottom = min(rect.maxY, pageRect.maxY)
            guard bottom > top, let page = document.page(at: index + 1) else { continue }
            context.saveGState()
            // PDF coordinates start at the bottom. Clip each source to its own
            // band so drawing outside its media box cannot cover a neighbour.
            context.clip(to: CGRect(x: 0, y: rect.maxY - bottom,
                                    width: rect.width, height: bottom - top))
            context.translateBy(x: -rect.minX, y: rect.maxY - pageRect.maxY)
            context.concatenate(page.getDrawingTransform(.mediaBox,
                rect: CGRect(origin: .zero, size: pageRect.size), rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(page)
            context.restoreGState()
        }
        context.endPDFPage()
        context.closePDF()
        return output as Data
    }

    func exportPDF(crop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) throws -> Data {
        try exportResult(crop: crop).data
    }

    /// Repair image joins only within the byte budget of the existing native export.
    /// Stronger lossless compression funds the small repair bands without enlarging
    /// the file or recompressing the chapter's JPEG images.
    func exportResult(crop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) throws -> PDFSeamRepair.Result {
        try PDFSeamRepair.export(nativeExportPDF(crop: crop))
    }

    /// Baseline export, with PDFKit's lossy image options explicitly disabled.
    private func nativeExportPDF(crop: CGRect) throws -> Data {
        let original = try pdfData(crop: crop)
        guard let pdf = PDFDocument(data: original),
              let compact = pdf.dataRepresentation(options: [
                PDFDocumentWriteOption.saveImagesAsJPEGOption: false,
                PDFDocumentWriteOption.optimizeImagesForScreenOption: false
              ]), compact.count < original.count,
              let verified = PDFDocument(data: compact), verified.pageCount == pdf.pageCount else { return original }
        for index in 0..<pdf.pageCount {
            guard verified.page(at: index)?.bounds(for: .mediaBox) == pdf.page(at: index)?.bounds(for: .mediaBox) else {
                return original
            }
        }
        return compact
    }

    /// Reconstruct the visible selection within the media bounds still in this file.
    /// No backup PDF is needed: CropBox controls reading, MediaBox bounds the editor.
    func existingChapterCrop() throws -> CGRect {
        guard let provider = CGDataProvider(data: data as CFData),
              let pdf = CGPDFDocument(provider) else { throw WebCaptureError.invalidDocument }
        var selection = CGRect.null
        for (index, layout) in pageRects.enumerated() {
            guard let page = pdf.page(at: index + 1) else { throw WebCaptureError.invalidDocument }
            let transform = page.getDrawingTransform(.mediaBox,
                rect: CGRect(origin: .zero, size: layout.size), rotate: 0, preserveAspectRatio: true)
            let visible = page.getBoxRect(.cropBox).intersection(page.getBoxRect(.mediaBox))
                .applying(transform)
            guard !visible.isNull, visible.width > 0, visible.height > 0 else { continue }
            selection = selection.union(CGRect(x: visible.minX, y: layout.maxY - visible.maxY,
                                               width: visible.width, height: visible.height))
        }
        guard !selection.isNull else { throw WebCaptureError.invalidDocument }
        selection = selection.intersection(CGRect(origin: .zero, size: size))
        return CGRect(x: selection.minX / size.width, y: selection.minY / size.height,
                      width: selection.width / size.width, height: selection.height / size.height)
    }

    /// Overlay-only crop: preserve the retained pages' media bounds and content,
    /// change CropBox, and remove pages wholly outside the selection.
    func croppedChapterPDF(crop: CGRect) throws -> Data {
        let rect = try cropRect(crop)
        guard let pdf = PDFDocument(data: data), pdf.pageCount == pageCount else {
            throw WebCaptureError.invalidDocument
        }
        for (index, pageRect) in pageRects.enumerated().reversed() {
            guard let page = pdf.page(at: index) else { throw WebCaptureError.invalidDocument }
            let top = max(rect.minY, pageRect.minY)
            let bottom = min(rect.maxY, pageRect.maxY)
            let left = max(rect.minX, 0)
            let right = min(rect.maxX, pageRect.width)
            guard bottom > top, right > left else {
                pdf.removePage(at: index)
                continue
            }
            guard let pageRef = page.pageRef else { throw WebCaptureError.invalidDocument }
            let transform = pageRef.getDrawingTransform(.mediaBox,
                rect: CGRect(origin: .zero, size: pageRect.size), rotate: 0, preserveAspectRatio: true)
            let displayedCrop = CGRect(x: left, y: pageRect.maxY - bottom,
                                       width: right - left, height: bottom - top)
            let cropped = displayedCrop.applying(transform.inverted())
                .intersection(page.bounds(for: .mediaBox))
            page.setBounds(cropped, for: .cropBox)
        }
        guard pdf.pageCount > 0,
              let output = pdf.dataRepresentation(options: [
                PDFDocumentWriteOption.saveImagesAsJPEGOption: false,
                PDFDocumentWriteOption.optimizeImagesForScreenOption: false
              ]),
              let verified = PDFDocument(data: output), verified.pageCount == pdf.pageCount else {
            throw WebCaptureError.invalidDocument
        }
        return output
    }

    /// Render the continuous document for display only; exported PDF has no bitmap cap.
    func render(crop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1), preview: Bool = false, pixelWidth: CGFloat? = nil) throws -> UIImage {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider) else { throw WebCaptureError.invalidDocument }
        let rect = try cropRect(crop)
        let pixelBudget: CGFloat = preview ? 4_000_000 : 20_000_000
        let scale = min(pixelWidth.map { $0 / rect.width } ?? (preview ? 1 : 3), sqrt(pixelBudget / (rect.width * rect.height)),
                        16_000 / max(rect.width, rect.height))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let output = CGSize(width: max(1, (rect.width * scale).rounded()), height: max(1, (rect.height * scale).rounded()))
        return UIGraphicsImageRenderer(size: output, format: format).image { renderer in
            UIColor.white.setFill()
            renderer.fill(CGRect(origin: .zero, size: output))
            let context = renderer.cgContext
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -rect.minX, y: -rect.minY)
            for (index, pageRect) in pageRects.enumerated() {
                guard pageRect.intersects(rect), let page = document.page(at: index + 1) else { continue }
                context.saveGState()
                context.translateBy(x: pageRect.minX, y: pageRect.maxY)
                context.scaleBy(x: 1, y: -1)
                context.concatenate(page.getDrawingTransform(.mediaBox,
                    rect: CGRect(origin: .zero, size: pageRect.size), rotate: 0, preserveAspectRatio: true))
                // Avoid dark hairlines where WebKit clips touching chapter images.
                // This is a raster-preview setting; it does not rewrite the PDF.
                context.setShouldAntialias(false)
                context.drawPDFPage(page)
                context.restoreGState()
            }
        }
    }

    private func cropRect(_ crop: CGRect) throws -> CGRect {
        guard crop.origin.x.isFinite, crop.origin.y.isFinite,
              crop.width.isFinite, crop.height.isFinite else { throw WebCaptureError.invalidDocument }
        let crop = crop.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !crop.isNull, crop.width > 0, crop.height > 0 else { throw WebCaptureError.invalidDocument }
        return CGRect(x: crop.minX * size.width, y: crop.minY * size.height,
                      width: crop.width * size.width, height: crop.height * size.height)
    }
}

nonisolated enum WebCaptureError: LocalizedError {
    case invalidDocument, unavailableFolder, pageTooLong, loadingLimit, operationTimedOut, invalidFilename

    var errorDescription: String? {
        switch self {
        case .invalidFilename: "Enter a file name of up to 200 bytes without /, \\, :, control characters, or a leading dot."
        case .operationTimedOut: "WebKit did not finish the capture operation. Reload the page and try again."
        case .invalidDocument: "WebKit returned an unreadable PDF or invalid page dimensions. Reload the page and try again."
        case .unavailableFolder: "The series folder is unavailable. Reconnect it in Settings, or use Share PDF to save the document."
        case .pageTooLong: "This page is too large to capture safely. Open a shorter page and try again."
        case .loadingLimit: "This page keeps growing or is taking too long to load. Wait for the page to finish loading, then try Capture again."
        }
    }
}
