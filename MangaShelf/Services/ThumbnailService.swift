//
//  ThumbnailService.swift
//  MangaShelf
//
//  Created by Khoa Phan on 4/24/26.
//

import Foundation
import PDFKit
import UIKit

/// Service for generating and caching PDF thumbnails
final class ThumbnailService {

    static let shared = ThumbnailService()

    private let fileService = LocalFileService.shared

    /// Standard thumbnail size for book covers
    private let thumbnailSize = Layout.coverSize

    private final class CoverPreview {
        let image: UIImage
        let pixels: CGFloat
        let version: Int

        init(_ image: UIImage, pixels: CGFloat, version: Int) {
            self.image = image
            self.pixels = pixels
            self.version = version
        }
    }

    private let imageCache = NSCache<NSString, CoverPreview>()

    private init() {
        imageCache.countLimit = 100
        imageCache.totalCostLimit = 50 * 1024 * 1024
    }

    func preview(for url: URL, version: Int) -> UIImage? {
        guard let entry = imageCache.object(forKey: url.absoluteString as NSString),
              entry.version == version else { return nil }
        return entry.image
    }

    func cachedImage(for url: URL, targetSize: CGSize, version: Int) async -> UIImage? {
        let key = url.absoluteString as NSString
        let pixels = max(targetSize.width, targetSize.height)
        if let entry = imageCache.object(forKey: key), entry.version == version, entry.pixels >= pixels {
            return entry.image
        }
        let image = await decodePreview(at: url, maxPixels: pixels)
        guard !Task.isCancelled, let image else { return nil }
        if let entry = imageCache.object(forKey: key), entry.version == version, entry.pixels >= pixels {
            return entry.image
        }
        let entry = CoverPreview(image, pixels: pixels, version: version)
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        imageCache.setObject(entry, forKey: key, cost: cost)
        return image
    }

    @concurrent
    private func decodePreview(at url: URL, maxPixels: CGFloat) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        return ArtItem.downsampledImage(at: url, maxPixelSize: maxPixels)
    }

    func evictCachedImage(for url: URL) {
        imageCache.removeObject(forKey: url.absoluteString as NSString)
    }

    /// Generate a thumbnail from the first page of a PDF
    /// - Parameters:
    ///   - pdfURL: URL of the PDF file
    ///   - identifier: Optional custom identifier for the thumbnail filename (defaults to PDF filename)
    /// - Returns: URL of the cached thumbnail image, or nil if generation failed
    func generateThumbnail(for pdfURL: URL, identifier: String? = nil) async -> URL? {
        // Create a unique filename for the thumbnail
        let thumbnailFilename = (identifier ?? pdfURL.deletingPathExtension().lastPathComponent) + ".jpg"
        let thumbnailURL = fileService.urlForThumbnail(named: thumbnailFilename)

        // Check if thumbnail already exists
        if fileService.fileExists(at: thumbnailURL) {
            return thumbnailURL
        }

        // Generate thumbnail on a background thread
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: nil)
                    return
                }

                guard let pdfDocument = PDFDocument(url: pdfURL),
                      let firstPage = pdfDocument.page(at: 0) else {
                    continuation.resume(returning: nil)
                    return
                }

                // Get the page bounds
                let pageRect = firstPage.readerDisplayBounds

                // Calculate scale to fit thumbnail size while maintaining aspect ratio
                let scale = min(
                    self.thumbnailSize.width / pageRect.width,
                    self.thumbnailSize.height / pageRect.height
                )

                let scaledSize = CGSize(
                    width: pageRect.width * scale,
                    height: pageRect.height * scale
                )

                // Render the page to an image
                let renderer = UIGraphicsImageRenderer(size: scaledSize)
                let image = renderer.image { context in
                    UIColor.white.setFill()
                    context.fill(CGRect(origin: .zero, size: scaledSize))

                    context.cgContext.saveGState()
                    context.cgContext.translateBy(x: 0, y: scaledSize.height)
                    context.cgContext.scaleBy(x: scale, y: -scale)
                    if let page = firstPage.pageRef {
                        context.cgContext.concatenate(page.getDrawingTransform(.cropBox,
                            rect: pageRect, rotate: 0, preserveAspectRatio: true))
                        context.cgContext.drawPDFPage(page)
                    }
                    context.cgContext.restoreGState()
                }

                // Save as JPEG
                guard let jpegData = image.jpegData(compressionQuality: 0.85) else {
                    continuation.resume(returning: nil)
                    return
                }

                do {
                    try jpegData.write(to: thumbnailURL)
                    continuation.resume(returning: thumbnailURL)
                } catch {
                    print("Failed to save thumbnail: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Get the number of pages in a PDF
    /// - Parameter pdfURL: URL of the PDF file
    /// - Returns: Number of pages, or 0 if the PDF couldn't be opened
    func getPageCount(for pdfURL: URL) -> Int {
        guard let pdfDocument = PDFDocument(url: pdfURL) else {
            return 0
        }
        return pdfDocument.pageCount
    }
}
