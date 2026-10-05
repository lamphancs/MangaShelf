import Foundation
import CoreGraphics

/// Covers only image/page joins with tiny losslessly encoded bands, rendered using
/// the reader's no-edge-antialiasing path. Original images and PDF text remain below
/// the bands; the chapter is never flattened or resized as a whole.
nonisolated enum PDFSeamRepair {
    struct Result {
        let data: Data
        let repaired: Bool
        let skippedForSize: Bool
    }

    /// A repaired PDF may exceed the source by at most this many bytes.
    static let repairSizeAllowance = 5 * 1024 * 1024

    static func export(_ source: Data) throws -> Result {
        try Task.checkCancellation()
        guard let provider = CGDataProvider(data: source as CFData),
              let document = CGPDFDocument(provider), document.numberOfPages == 1,
              let page = document.page(at: 1) else {
            return Result(data: source, repaired: false, skippedForSize: false)
        }
        let bounds = page.getBoxRect(.mediaBox)
        guard page.rotationAngle == 0, bounds.origin == .zero,
              bounds.width > 0, bounds.width <= 4096 else {
            return Result(data: source, repaired: false, skippedForSize: false)
        }
        let seams = ImageJoins.find(in: page)
        let patches = try bands(page: page, bounds: bounds, seams: seams)
        // Append bands to the original object graph, retaining annotations, links,
        // text, metadata, and original image streams instead of redrawing the PDF.
        // Accept a repair that grows the file by up to `repairSizeAllowance`.
        if let compact = try? PDFLosslessWriter.compact(source, patches: patches),
           compact.count <= source.count + repairSizeAllowance,
           valid(compact, bounds: bounds) {
            try Task.checkCancellation()
            return Result(data: compact, repaired: !seams.isEmpty, skippedForSize: false)
        }
        try Task.checkCancellation()
        // Repair bands would exceed the size allowance; don't grow the file further
        // just to remove a viewing artifact.
        let compact = try? PDFLosslessWriter.compact(source)
        try Task.checkCancellation()
        let fallback = compact.flatMap { $0.count < source.count && valid($0, bounds: bounds) ? $0 : nil } ?? source
        return Result(data: fallback, repaired: false, skippedForSize: !seams.isEmpty)
    }

    private static func valid(_ data: Data, bounds: CGRect) -> Bool {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider), document.numberOfPages == 1,
              let page = document.page(at: 1) else { return false }
        return page.getBoxRect(.mediaBox) == bounds
    }

    private static func bands(page: CGPDFPage, bounds: CGRect, seams: [CGFloat]) throws -> [PDFLosslessWriter.Patch] {
        var patches: [PDFLosslessWriter.Patch] = []
        // Matches the reader at iPhone 3x. Only ~2 points around each boundary are
        // rasterized, with Flate (not JPEG) encoding. Text elsewhere stays vector.
        let scale: CGFloat = 3
        let width = Int(ceil(bounds.width * scale))
        for seam in seams {
            try Task.checkCancellation()
            try autoreleasepool {
                let low = max(0, floor((seam - 1) * scale) / scale)
                let high = min(bounds.height, ceil((seam + 1) * scale) / scale)
                let height = max(1, Int(ceil((high - low) * scale)))
                guard let bitmap = CGContext(data: nil, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                    throw Failure.render
                }
                bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
                bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
                bitmap.setShouldAntialias(false)
                bitmap.scaleBy(x: scale, y: scale)
                bitmap.translateBy(x: 0, y: -low)
                bitmap.drawPDFPage(page)
                guard let pixels = bitmap.data?.assumingMemoryBound(to: UInt8.self) else { throw Failure.render }
                var rgb = Data(count: width * height * 3)
                rgb.withUnsafeMutableBytes { bytes in
                    let target = bytes.bindMemory(to: UInt8.self)
                    for index in 0..<(width * height) {
                        target[index * 3] = pixels[index * 4]
                        target[index * 3 + 1] = pixels[index * 4 + 1]
                        target[index * 3 + 2] = pixels[index * 4 + 2]
                    }
                }
                patches.append(PDFLosslessWriter.Patch(
                    rect: CGRect(x: 0, y: low, width: CGFloat(width) / scale, height: CGFloat(height) / scale),
                    width: width, height: height, rgb: rgb))
            }
        }
        return patches
    }

    private enum Failure: Error { case render }

    /// Walks graphics state instead of guessing from dark scanlines, which could
    /// erase genuine panel borders. Only touching, full-width tall-image regions
    /// qualify. Complex clips/forms are skipped conservatively.
    private final class ImageJoins {
        private struct State {
            var transform = CGAffineTransform.identity
            var clip: CGRect
        }
        private let bounds: CGRect
        private var state: State
        private var stack: [State] = []
        private var path: CGRect?
        private var complexPath = false
        private var clipsPath = false
        private var regions: [CGRect] = []
        private var invalid = false

        init(bounds: CGRect) {
            self.bounds = bounds
            state = State(clip: bounds)
        }

        static func find(in page: CGPDFPage) -> [CGFloat] {
            let visitor = ImageJoins(bounds: page.getBoxRect(.mediaBox))
            let stream = CGPDFContentStreamCreateWithPage(page)
            defer { CGPDFContentStreamRelease(stream) }
            guard let table = CGPDFOperatorTableCreate() else { return [] }
            defer { CGPDFOperatorTableRelease(table) }
            CGPDFOperatorTableSetCallback(table, "q", { _, info in ImageJoins.get(info).stack.append(ImageJoins.get(info).state) })
            CGPDFOperatorTableSetCallback(table, "Q", { _, info in
                let v = ImageJoins.get(info)
                if let state = v.stack.popLast() { v.state = state } else { v.invalid = true }
            })
            CGPDFOperatorTableSetCallback(table, "cm", { scanner, info in
                let v = ImageJoins.get(info)
                guard let numbers = ImageJoins.numbers(scanner, count: 6) else { v.invalid = true; return }
                let t = CGAffineTransform(a: numbers[0], b: numbers[1], c: numbers[2],
                                          d: numbers[3], tx: numbers[4], ty: numbers[5])
                v.state.transform = t.concatenating(v.state.transform)
            })
            CGPDFOperatorTableSetCallback(table, "re", { scanner, info in
                let v = ImageJoins.get(info)
                guard let n = ImageJoins.numbers(scanner, count: 4) else { v.invalid = true; return }
                if v.path != nil { v.complexPath = true }
                v.path = CGRect(x: n[0], y: n[1], width: n[2], height: n[3]).standardized.applying(v.state.transform)
            })
            for operation in ["m", "l", "c", "v", "y", "h"] {
                CGPDFOperatorTableSetCallback(table, operation, { _, info in ImageJoins.get(info).complexPath = true })
            }
            for operation in ["W", "W*"] {
                CGPDFOperatorTableSetCallback(table, operation, { _, info in ImageJoins.get(info).clipsPath = true })
            }
            for operation in ["n", "f", "F", "f*", "S", "s", "B", "B*", "b", "b*"] {
                CGPDFOperatorTableSetCallback(table, operation, { _, info in
                    let v = ImageJoins.get(info)
                    if v.clipsPath {
                        v.state.clip = !v.complexPath && v.path != nil
                            ? v.state.clip.intersection(v.path!) : .null
                    }
                    v.path = nil; v.complexPath = false; v.clipsPath = false
                })
            }
            CGPDFOperatorTableSetCallback(table, "Do", { scanner, info in ImageJoins.get(info).image(scanner) })
            let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(visitor).toOpaque())
            defer { CGPDFScannerRelease(scanner) }
            guard CGPDFScannerScan(scanner), !visitor.invalid, visitor.stack.isEmpty else { return [] }
            return visitor.joins()
        }

        private static func get(_ context: UnsafeMutableRawPointer?) -> ImageJoins {
            Unmanaged<ImageJoins>.fromOpaque(context!).takeUnretainedValue()
        }

        private static func numbers(_ scanner: CGPDFScannerRef, count: Int) -> [CGFloat]? {
            var result = [CGFloat](repeating: 0, count: count)
            for index in (0..<count).reversed() {
                var value: CGPDFReal = 0
                guard CGPDFScannerPopNumber(scanner, &value), value.isFinite else { return nil }
                result[index] = value
            }
            return result
        }

        private func image(_ scanner: CGPDFScannerRef) {
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name,
                  let resource = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "XObject", name) else { return }
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(resource, .stream, &stream), let stream,
                  let dictionary = CGPDFStreamGetDictionary(stream) else { return }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype,
                  String(cString: subtype) == "Image" else { return }
            let t = state.transform
            guard abs(t.b) < 0.0001, abs(t.c) < 0.0001, t.a > 0, t.d > 0 else { return }
            let image = CGRect(x: 0, y: 0, width: 1, height: 1).applying(t)
            guard image.height >= image.width else { return }
            let region = image.intersection(state.clip).intersection(bounds)
            guard !region.isNull, region.width >= bounds.width - 0.01, region.height > 0 else { return }
            regions.append(region)
            if regions.count > 10_000 { invalid = true }
        }

        private func joins() -> [CGFloat] {
            let sorted = regions.sorted { $0.minY < $1.minY }
            var seams: [CGFloat] = []
            for (lower, upper) in zip(sorted, sorted.dropFirst()) {
                let gap = upper.minY - lower.maxY
                // Subpixel clips in WebKit exports differ by up to one CSS pixel.
                // Leave intentional spacing and substantial overlaps untouched.
                guard abs(gap) <= 0.5 else { continue }
                let y = (upper.minY + lower.maxY) / 2
                guard y > 1, y < bounds.height - 1,
                      seams.last.map({ abs(y - $0) > 2 }) ?? true else { continue }
                seams.append(y)
            }
            return seams
        }
    }
}
