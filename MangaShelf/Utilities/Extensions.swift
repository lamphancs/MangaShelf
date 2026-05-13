//
//  Extensions.swift
//  MangaShelf
//
//  Created by Khoa Phan on 4/24/26.
//

import SwiftUI

// MARK: - Color Extensions

extension Color {
    /// Primary background color for reader views (pure black to hide Dynamic Island)
    static let appBackground = Color.black

    /// Secondary text color
    static let secondaryText = Color(white: 0.7)

    /// Tertiary text color
    static let tertiaryText = Color(white: 0.5)
}

// MARK: - Chapter Extensions

extension Chapter {
    var extractedNumber: String? {
        let numbers = displayName.components(separatedBy: .decimalDigits.inverted).filter { !$0.isEmpty }
        return numbers.last
    }
}

// MARK: - UIImage Dominant Color

extension UIImage {
    nonisolated func dominantColor() -> UIColor? {
        guard let cgImage = cgImage else { return nil }

        let size = 50
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var rawData = [UInt8](repeating: 0, count: size * size * 4)

        guard let context = CGContext(
            data: &rawData,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        var bestR: Double = 0
        var bestG: Double = 0
        var bestB: Double = 0
        var bestScore: Double = 0

        for y in 0..<size {
            for x in 0..<size {
                let i = (y * size + x) * 4
                let r = Double(rawData[i])
                let g = Double(rawData[i + 1])
                let b = Double(rawData[i + 2])

                let maxC = max(r, g, b)
                let minC = min(r, g, b)
                guard maxC > 0 else { continue }

                let saturation = (maxC - minC) / maxC
                let brightness = maxC / 255.0

                if brightness < 0.15 || brightness > 0.95 { continue }
                if saturation < 0.15 { continue }

                let score = saturation * (0.5 + brightness * 0.5)

                if score > bestScore {
                    bestScore = score
                    bestR = r
                    bestG = g
                    bestB = b
                }
            }
        }

        guard bestScore > 0 else { return nil }

        let boost = min(1.0 / (max(bestR, bestG, bestB) / 255.0), 1.5)
        return UIColor(
            red: min(bestR * boost / 255.0, 1.0),
            green: min(bestG * boost / 255.0, 1.0),
            blue: min(bestB * boost / 255.0, 1.0),
            alpha: 1.0
        )
    }
}

// MARK: - Book Display Helpers

extension Book {
    func chapterProgressLabel() -> String {
        let chapters = sortedChapters
        let currentChapter = chapters[safe: currentChapterIndex]
        let lastChapter = chapters.last
        let currentNum = currentChapter?.extractedNumber ?? "\(currentChapterIndex + 1)"
        let lastNum = lastChapter?.extractedNumber ?? "\(chapters.count)"
        return "Ch. \(currentNum)/\(lastNum)"
    }
}

// MARK: - Haptic Feedback

extension UIImpactFeedbackGenerator {
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.impactOccurred()
    }
}

// MARK: - Collection Extensions

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
