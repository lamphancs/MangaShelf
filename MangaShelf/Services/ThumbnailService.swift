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
    private let thumbnailSize = CGSize(width: 400, height: 600)

    private let imageCache = NSCache<NSString, UIImage>()

    private init() {
        imageCache.countLimit = 100
        imageCache.totalCostLimit = 50 * 1024 * 1024
    }

    func cachedImage(for url: URL, targetSize: CGSize) async -> UIImage? {
        let key = url.absoluteString as NSString
        if let cached = imageCache.object(forKey: key) {
            return cached
        }
        let image = await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url),
                  let original = UIImage(data: data) else { return nil as UIImage? }
            let renderer = UIGraphicsImageRenderer(size: targetSize)
            return renderer.image { _ in
                let widthRatio = targetSize.width / original.size.width
                let heightRatio = targetSize.height / original.size.height
                let scale = max(widthRatio, heightRatio)
                let scaledSize = CGSize(width: original.size.width * scale, height: original.size.height * scale)
                let x = (targetSize.width - scaledSize.width) / 2
                let y = (targetSize.height - scaledSize.height) / 2
                original.draw(in: CGRect(origin: CGPoint(x: x, y: y), size: scaledSize))
            }
        }.value
        if let image {
            imageCache.setObject(image, forKey: key, cost: Int(targetSize.width * targetSize.height * 4))
        }
        return image
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
                let pageRect = firstPage.bounds(for: .mediaBox)

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
                    firstPage.draw(with: .mediaBox, to: context.cgContext)
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
