import PDFKit

// CropBox is the visible page; the original MediaBox remains available to the crop editor.
extension PDFPage {
    nonisolated var readerDisplayBounds: CGRect {
        let bounds = bounds(for: .cropBox)
        let rotated = abs(rotation) % 180 == 90
        return CGRect(origin: .zero, size: rotated
                      ? CGSize(width: bounds.height, height: bounds.width) : bounds.size)
    }
}
