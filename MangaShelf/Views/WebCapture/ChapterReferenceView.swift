import SwiftUI
import PDFKit

/// A read-only PDF reference; CropBox keeps previously trimmed content hidden.
struct ChapterReferenceView: View {
    let bookmarkKey: String
    let folderName: String?
    let filename: String
    let initialContentWidth: CGFloat
    @State private var document: PDFDocument?
    @State private var failed = false

    var body: some View {
        Group {
            if let document {
                ReferencePDFView(document: document, initialContentWidth: initialContentWidth)
            } else if failed {
                ContentUnavailableView("Cannot open reference", systemImage: "doc.questionmark",
                                       description: Text("Choose another saved chapter or reconnect the series folder."))
            } else {
                ProgressView("Loading reference…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            do {
                guard let folderName,
                      let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else {
                    throw WebCaptureError.unavailableFolder
                }
                let (root, _) = try LocalFileService.shared.resolveBookmark(bookmark)
                guard root.startAccessingSecurityScopedResource() else {
                    throw WebCaptureError.unavailableFolder
                }
                defer { root.stopAccessingSecurityScopedResource() }
                let url = root.appendingPathComponent(folderName).appendingPathComponent(filename)
                let data = try await Task.detached(priority: .userInitiated) {
                    try Data(contentsOf: url)
                }.value
                try Task.checkCancellation()
                guard let pdf = PDFDocument(data: data), pdf.pageCount > 0 else {
                    throw WebCaptureError.invalidDocument
                }
                document = pdf
            } catch is CancellationError {
            } catch {
                failed = true
            }
        }
    }
}

private struct ReferencePDFView: UIViewRepresentable {
    let document: PDFDocument
    let initialContentWidth: CGFloat

    func makeUIView(context: Context) -> BottomReferencePDFView {
        let view = BottomReferencePDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displayBox = .cropBox
        view.autoScales = false
        view.document = document
        view.initialContentWidth = initialContentWidth
        return view
    }

    func updateUIView(_ uiView: BottomReferencePDFView, context: Context) {
        uiView.initialContentWidth = initialContentWidth
        uiView.setNeedsLayout()
    }
}

/// Apply the initial zoom only once, after both the PDF and crop pane have laid out.
/// Later SwiftUI updates must preserve the user's independent zoom and scroll.
private final class BottomReferencePDFView: PDFView {
    var initialContentWidth: CGFloat = 0
    private var positioned = false
    private var positioningScheduled = false

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !positioned, !positioningScheduled, bounds.width > 0, bounds.height > 0,
              initialContentWidth > 0, document != nil else { return }
        positioningScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.positioningScheduled = false
            guard !self.positioned, self.bounds.width > 0, self.bounds.height > 0,
                  let document = self.document,
                  let page = document.page(at: document.pageCount - 1) else { return }
            self.positioned = true
            let pageBounds = page.bounds(for: .cropBox)
            let width = abs(page.rotation) % 180 == 90 ? pageBounds.height : pageBounds.width
            let scale = max(0.01, self.initialContentWidth / max(1, width))
            self.minScaleFactor = min(0.01, scale * 0.5)
            self.maxScaleFactor = max(4, scale * 4)
            self.scaleFactor = scale
            self.layoutIfNeeded()
            // Use visual coordinates so rotated PDFs also open at their bottom.
            let displayedPage = self.convert(pageBounds, from: page)
            let bottom = CGRect(x: displayedPage.minX,
                                y: displayedPage.maxY - min(self.bounds.height, displayedPage.height),
                                width: displayedPage.width,
                                height: min(self.bounds.height, displayedPage.height))
            self.go(to: self.convert(bottom, to: page), on: page)
        }
    }
}
