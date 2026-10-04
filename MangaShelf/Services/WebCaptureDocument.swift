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

    /// Trim five browser viewports from the bottom, retaining at least one on short pages.
    func defaultCaptureCrop(viewportHeight: CGFloat) -> CGRect {
        guard viewportHeight.isFinite, viewportHeight > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let retainedHeight = min(size.height, max(viewportHeight, size.height - 5 * viewportHeight))
        return CGRect(x: 0, y: 0, width: 1, height: retainedHeight / size.height)
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

    /// Repack PDF objects with PDFKit's lossy image options explicitly disabled.
    /// Already-efficient source data wins if rewriting would increase its size.
    func exportPDF(crop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) throws -> Data {
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
