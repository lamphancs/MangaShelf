import SwiftUI
import WebKit
import PDFKit
import SwiftData

@main
struct CaptureSmokeApp: App {
    var body: some Scene { WindowGroup { CaptureSmokeView().environment(ThemeManager()) } }
}

struct SmokeBrowser: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct CaptureSmokeView: View {
    @State private var model = WebPageCaptureModel()
    @State private var crop = CGRect(x: 0.1, y: 0.25, width: 0.8, height: 0.65)
    @State private var report = "Running…"
    @State private var tested = false
    @State private var browsingStarted = false
    @State private var longCaptureStarted: Date?
    @State private var stressDocument: WebCaptureDocument?
    @State private var stressRenderer: CapturePDFTileRenderer?
    @State private var browsingChecks: [String] = []
    var body: some View {
        VStack {
            Text(report).font(.caption).padding()
            ZStack {
                SmokeBrowser(webView: model.webView)
                if let stressDocument, let stressRenderer {
                    FullPageCropView(document: stressDocument, crop: $crop, overview: false, renderer: stressRenderer)
                        .background(.black)
                } else if let document = model.document {
                    FullPageCropView(document: document, crop: $crop, overview: true)
                        .background(.black)
                }
            }
        }
        .task {
            if ProcessInfo.processInfo.environment["CAPTURE_TEST_ONLY"] == "crop" {
                do { write(try checkCropAlignment().joined(separator: "\n")) }
                catch { write("FAIL: \(error)") }
                return
            }
            model.load(URL(string: ProcessInfo.processInfo.environment["CAPTURE_SMOKE_URL"] ?? "http://127.0.0.1:8765/")!) }
        .onChange(of: model.isLoading) { _, loading in
            guard !loading, !browsingStarted else { return }
            browsingStarted = true
            Task { await checkBrowsing() }
        }
        .onChange(of: model.document != nil) { _, ready in
            guard ready, !tested else { return }
            tested = true
            Task { await checkCapture() }
        }
        .onChange(of: model.errorMessage) { _, error in
            if let error { write("FAIL: \(error)") }
        }
    }

    func checkBrowsing() async {
        if ProcessInfo.processInfo.environment["CAPTURE_TEST_ONLY"] == "long" {
            do {
                _ = try await model.webView.evaluateJavaScript("""
                    document.body.style.margin = '0';
                    document.body.innerHTML = Array.from({length: 220}, (_, i) =>
                        `<div class="lazy" style="height:1000px;background:red">${i}</div>`).join('');
                    const observer = new IntersectionObserver(entries => {
                        entries.forEach(entry => {
                            if (entry.isIntersecting) {
                                entry.target.dataset.loaded = 'true';
                                entry.target.style.background = 'magenta';
                                entry.target.textContent = 'LOADED SECTION ' + entry.target.textContent;
                            }
                        });
                    });
                    document.querySelectorAll('.lazy').forEach(node => observer.observe(node));
                    """)
                try await Task.sleep(for: .milliseconds(500))
                longCaptureStarted = Date()
                model.capture(loadEntirePage: true)
            } catch { write("FAIL: Long chapter setup: \(error)") }
            return
        }
        if ProcessInfo.processInfo.environment["CAPTURE_TEST_ONLY"] == "live" {
            try? await Task.sleep(for: .seconds(5))
            guard let title = model.webView.title, !title.localizedCaseInsensitiveContains("just a moment") else {
                write("FAIL: Live site returned an access challenge; no chapter PDF measurement available")
                return
            }
            model.capture(loadEntirePage: true)
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(500))
            browsingChecks.append("\(model.document == nil && !model.isCapturing ? "PASS" : "FAIL"): Opening link only browses; no automatic capture")
            let nextChapter = try await model.findNextChapterURL()
            browsingChecks.append("\(nextChapter?.query == "chapter=2" ? "PASS" : "FAIL"): Detect explicit next-chapter link")
            _ = try await model.webView.evaluateJavaScript("const duplicateNext = document.createElement('a'); duplicateNext.id = 'ambiguous-next'; duplicateNext.href = '?chapter=3'; duplicateNext.textContent = 'Next chapter'; document.body.append(duplicateNext)")
            let ambiguousNext = try await model.findNextChapterURL()
            browsingChecks.append("\(ambiguousNext == nil ? "PASS" : "FAIL"): Ambiguous chapter links do not guess a destination")
            _ = try await model.webView.evaluateJavaScript("document.querySelector('#ambiguous-next').remove()")
            _ = try await model.webView.evaluateJavaScript("document.querySelector('#next').textContent = '›'; document.querySelector('#next').className = 'button next-chapter primary'")
            let iconNext = try await model.findNextChapterURL()
            browsingChecks.append("\(iconNext == nextChapter ? "PASS" : "FAIL"): Icon-only chapter link recognized by class")
            _ = try await model.webView.evaluateJavaScript("document.querySelector('#next').textContent = 'Next chapter'; document.querySelector('#next').className = ''")
            for prefix in ["truyen", "series"] {
                _ = try await model.webView.evaluateJavaScript("""
                    window.originalChapterURL = location.href;
                    history.replaceState(null, '', '/\(prefix)/fixture/chapter-42');
                    document.querySelector('#next').removeAttribute('id');
                    document.querySelector('a').textContent = 'Contents';
                    window.chapterFixture = document.createElement('div');
                    chapterFixture.innerHTML = '<a href="/\(prefix)/fixture/chapter-41">Previous</a><a href="/\(prefix)/fixture/chapter-42.5">›</a><a href="/\(prefix)/fixture/chapter-43">43</a><a href="/\(prefix)/other/chapter-43">Other series</a>';
                    document.body.append(chapterFixture);
                    """)
                let detected = try await model.findNextChapterURL()
                browsingChecks.append("\(detected?.path == "/\(prefix)/fixture/chapter-42.5" ? "PASS" : "FAIL"): Detect nearest linked chapter under /\(prefix)/")
                _ = try await model.webView.evaluateJavaScript("chapterFixture.remove(); history.replaceState(null, '', originalChapterURL); document.querySelector('a').id = 'next'; document.querySelector('#next').textContent = 'Next chapter'")
            }
            model.nextChapterURL = nextChapter
            let advanced = model.goToNextChapter()
            try await waitForPage(query: "chapter=2")
            browsingChecks.append("\(advanced && model.document == nil && !model.isCapturing ? "PASS" : "FAIL"): Next chapter opens for browsing without automatic capture")
            let absentNext = try await model.findNextChapterURL()
            browsingChecks.append("\(absentNext == nil ? "PASS" : "FAIL"): Current chapter is not reused as next chapter")
            model.goBack()
            try await waitForPage(query: nil)
            model.nextChapterURL = nextChapter
            let automaticAdvance = model.goToNextChapter(automaticallyCapture: true)
            try await waitForPage(query: "chapter=2")
            browsingChecks.append("\(automaticAdvance && model.isCapturing ? "PASS" : "FAIL"): Next chapter capture starts after navigation finishes")
            model.cancelCapture()
            model.goBack()
            try await waitForPage(query: nil)
            browsingChecks.append("\(!model.isCapturing && model.document == nil ? "PASS" : "FAIL"): Automatic capture is consumed once and can be cancelled")
            let pageBeforePopup = model.currentURL
            browsingChecks.append("\(!model.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically ? "PASS" : "FAIL"): Automatic JavaScript windows disabled")
            // Allow the request through WebKit's preference to exercise the delegate guard too.
            model.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
            _ = try await model.webView.evaluateJavaScript("window.open('?advert=popup', '_blank'); void 0")
            try await Task.sleep(for: .milliseconds(500))
            browsingChecks.append("\(model.currentURL == pageBeforePopup && !model.isLoading ? "PASS" : "FAIL"): Script popup cannot replace the chapter")
            model.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
            _ = try await model.webView.evaluateJavaScript("document.querySelector('#next').target = '_blank'; document.querySelector('#next').click()")
            try await waitForPage(query: "chapter=2")
            browsingChecks.append("\(model.currentURL?.query == "chapter=2" ? "PASS" : "FAIL"): Target-blank chapter link opens in the existing browser")
            model.goBack()
            try await waitForPage(query: nil)
            _ = try await model.webView.evaluateJavaScript("document.querySelector('#next').click()")
            try await waitForPage(query: "chapter=2")
            browsingChecks.append("\(model.document == nil && model.canGoBack ? "PASS" : "FAIL"): Navigate to chapter before capture")
            model.goBack()
            try await waitForPage(query: nil)
            browsingChecks.append("\(model.canGoForward ? "PASS" : "FAIL"): Browser back navigation")
            model.goForward()
            try await waitForPage(query: "chapter=2")
            model.reload()
            try await waitForPage(query: "chapter=2")
            browsingChecks.append("\(model.document == nil && !model.isCapturing ? "PASS" : "FAIL"): Reload current page without capturing")
            let chapterURL = model.currentURL!
            model.nextChapterURL = URL(string: "/challenge", relativeTo: chapterURL)!.absoluteURL
            model.goToNextChapter(automaticallyCapture: true)
            try await waitForPage(query: nil)
            browsingChecks.append("\(model.isVerificationRequired && !model.canCapture ? "PASS" : "FAIL"): Cloudflare response blocks capture but keeps verification page available")
            model.capture(loadEntirePage: true)
            browsingChecks.append("\(!model.isCapturing && model.document == nil ? "PASS" : "FAIL"): Verification page cannot be exported as chapter")
            model.load(chapterURL)
            try await waitForPage(query: "chapter=2")
            browsingChecks.append("\(!model.isVerificationRequired && model.canCapture ? "PASS" : "FAIL"): Normal page restores capture after verification")
            let normalSession = WebPageCaptureModel(isPrivate: false)
            browsingChecks.append("\(normalSession.webView.configuration.websiteDataStore.isPersistent && !model.webView.configuration.websiteDataStore.isPersistent ? "PASS" : "FAIL"): Normal sessions persist while private sessions remain ephemeral")
            normalSession.close()
            model.capture(loadEntirePage: true)
        } catch { write("FAIL: Browser navigation: \(error)") }
    }

    func waitForPage(query: String?) async throws {
        try await Task.sleep(for: .milliseconds(300))
        for _ in 0..<100 {
            if !model.isLoading && model.currentURL?.query == query { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw URLError(.timedOut)
    }

    func write(_ result: String) {
        report = result
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? result.write(to: directory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
    }

    func checkCapture() async {
        if ProcessInfo.processInfo.environment["CAPTURE_TEST_ONLY"] == "long" {
            do {
                guard let document = model.document else { throw WebCaptureError.invalidDocument }
                let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                try document.data.write(to: folder.appendingPathComponent("full.pdf"))
                let bottom = try document.pdfData(crop: CGRect(x: 0, y: 219000.0 / 220000, width: 1, height: 1000.0 / 220000))
                try bottom.write(to: folder.appendingPathComponent("bottom.pdf"))
                let pdf = PDFDocument(data: document.data)
                let loaded = try await model.webView.evaluateJavaScript("document.querySelectorAll('[data-loaded=true]').length") as? Int
                let complete = abs(document.size.height - 220000) < 2 && (pdf?.string?.contains("LOADED SECTION 219") == true) && loaded == 220
                let elapsed = Date().timeIntervalSince(longCaptureStarted ?? Date())
                write("\(complete ? "PASS" : "FAIL"): 220,000-point chapter, all 220 lazy sections visited, final PDF text present; height=\(document.size.height), capture=\(String(format: "%.1f", elapsed))s")
            } catch { write("FAIL: Long chapter capture: \(error)") }
            return
        }
        if ProcessInfo.processInfo.environment["CAPTURE_TEST_ONLY"] == "live" {
            do {
                guard let document = model.document else { return }
                let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                try document.data.write(to: folder.appendingPathComponent("full.pdf"))
                let compact = try await Task.detached { try document.exportPDF() }.value
                try compact.write(to: folder.appendingPathComponent("bottom.pdf"))
                let images = try await model.webView.evaluateJavaScript("JSON.stringify(Array.from(document.images).map(i=>({src:i.currentSrc,w:i.naturalWidth,h:i.naturalHeight,complete:i.complete})))")
                write("LIVE: title=\(model.webView.title ?? "") size=\(document.size) original=\(document.data.count) exported=\(compact.count) warning=\(model.captureWarning ?? "none")\n\(images)")
            } catch { write("FAIL: Live capture: \(error)") }
            return
        }
        do {
            guard let document = model.document else { throw WebCaptureError.invalidDocument }
            var checks: [String] = browsingChecks
            func check(_ condition: Bool, _ label: String) {
                checks.append("\(condition ? "PASS" : "FAIL"): \(label)")
            }
            let initialCrop = document.defaultCaptureCrop(viewportHeight: 800)
            check(abs(initialCrop.height * document.size.height - 1000) < 2 && initialCrop.minY == 0,
                  "Default crop removes five viewports from bottom only")
            check(document.defaultCaptureCrop(viewportHeight: 6000).height == 1,
                  "Short page default crop preserves the full page")
            check(document.defaultCaptureCrop(viewportHeight: 3000).height == 0.6,
                  "Default crop retains at least one viewport")
            check(model.nextChapterURL == nil, "Capture freezes next-chapter availability for the captured page")
            check(abs(document.size.height - 5000) < 2, "Full document height = \(document.size.height), viewport = \(model.webView.bounds.height)")
            let top = try document.render(crop: CGRect(x: 0, y: 0, width: 1, height: 0.2))
            let bottom = try document.render(crop: CGRect(x: 0, y: 0.8, width: 1, height: 0.2))
            let topPixel = pixel(top)
            let bottomPixel = pixel(bottom)
            check(topPixel[0] > 240 && topPixel[1] < 15 && topPixel[2] < 15, "Top crop is red (correct PDF orientation): \(topPixel)")
            check(bottomPixel[0] > 240 && bottomPixel[1] < 15 && bottomPixel[2] > 240, "Offscreen lazy content is magenta: \(bottomPixel)")
            let fullPDF = try document.pdfData()
            let bottomPDF = try document.pdfData(crop: CGRect(x: 0.1, y: 0.8, width: 0.8, height: 0.2))
            let cropped = try WebCaptureDocument(data: bottomPDF)
            let croppedPixel = pixel(try cropped.render(preview: true))
            check(fullPDF == document.data, "Full PDF preserves original WebKit bytes")
            check(abs(cropped.size.width - document.size.width * 0.8) < 0.1 && abs(cropped.size.height - 1000) < 0.1,
                  "Cropped PDF uses selected media box without resampling")
            check(croppedPixel[0] > 240 && croppedPixel[1] < 15 && croppedPixel[2] > 240, "Cropped PDF preserves bottom content and orientation")
            let croppedText = PDFDocument(data: bottomPDF)?.string?
                .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            check(croppedText?.contains("LAZY CONTENT LOADED") == true,
                  "Cropped PDF retains searchable text, not a flattened bitmap")
            check(PDFDocument(data: fullPDF)?.pageCount == 1, "PDFKit reader can open full-page PDF")
            let longSource = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 30000)).pdfData { context in
                context.beginPage()
                UIColor.red.setFill()
                context.cgContext.fill(CGRect(x: 0, y: 0, width: 400, height: 30000))
            }
            let longDocument = try WebCaptureDocument(data: longSource)
            let longExport = try longDocument.pdfData(crop: CGRect(x: 0, y: 0.1, width: 1, height: 0.8))
            check(try WebCaptureDocument(data: longExport).size.height == 24000, "PDF export is not limited to 16000-pixel bitmap dimensions")
            let tileRenderer = CapturePDFTileRenderer(document: document)
            let tile = try await tileRenderer.image(crop: CGRect(x: 0, y: 0, width: 1, height: 0.1), pixelWidth: 1200)
            check(tile.cgImage?.width == 1200, "Detail renders visible PDF region at screen pixel width")
            do {
                _ = try WebCaptureDocument(data: Data())
                check(false, "Invalid PDF rejected")
            } catch { check(true, "Invalid PDF rejected") }
            do {
                _ = try document.pdfData(crop: .zero)
                check(false, "Empty crop rejected")
            } catch { check(true, "Empty crop rejected") }
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try fullPDF.write(to: directory.appendingPathComponent("full.pdf"))
            try bottomPDF.write(to: directory.appendingPathComponent("bottom.pdf"))
            let container = try ModelContainer(for: Book.self, Chapter.self, Bookmark.self,
                                              configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            let context = container.mainContext
            let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let book = Book(title: "Fixture", filename: "Fixture", filePath: "", totalPages: 1,
                            isSeries: true, folderName: folder.lastPathComponent)
            context.insert(book)
            let legacy = try JSONDecoder().decode(BookSeriesData.self, from: Data(#"{"url":"https://example.com/series","note":"Legacy note"}"#.utf8))
            check(legacy.url == "https://example.com/series" && legacy.latestChapterURL == nil && legacy.latestChapterNumber == nil,
                  "Legacy series metadata preserves original link and defaults new chapter fields")
            book.seriesURL = legacy.url
            book.latestChapterURL = "https://example.com/series/chapter-42.5"
            book.latestChapterNumber = "42.5"
            check(BookLinkKind.webURL(book.latestChapterURL!) != nil && BookLinkKind.webURL("javascript:alert(1)") == nil && BookLinkKind.webURL("https://") == nil,
                  "Link editor accepts web links and rejects invalid/non-web URLs")
            check(BookLinkKind.webURL(" example.com/series/title ")?.absoluteString == "https://example.com/series/title"
                  && BookLinkKind.webURL("http://example.com/chapter-1")?.scheme == "http"
                  && BookLinkKind.webURL("//example.com/en")?.absoluteString == "https://example.com/en"
                  && BookLinkKind.webURL("bad address") == nil,
                  "Scheme-free links default to HTTPS and explicit HTTP is preserved")
            let original = Chapter(filename: "Z Existing.pdf", sortOrder: 0, totalPages: 1, lastReadPage: 0)
            original.lastReadOffset = 123
            original.book = book
            context.insert(original)
            let bookmark = Bookmark(chapterIndex: 0, note: "Keep my place")
            bookmark.book = book
            context.insert(bookmark)
            try fullPDF.write(to: folder.appendingPathComponent(original.filename))
            try context.save()
            let savedURL = try await ImportService().saveCapturedChapter(bottomPDF, for: book, filename: "Chapter 42", seriesFolderURL: folder, sourceURL: URL(string: "https://example.com/series/chapter-43.5"), chapterTitle: "Chapter 99", modelContext: context)
            let metadata = await BookDataService.shared.load(seriesFolderURL: folder)
            check(metadata?.url == book.seriesURL && metadata?.latestChapterURL == book.latestChapterURL && metadata?.latestChapterNumber == "43.5" && book.latestChapterURL == "https://example.com/series/chapter-43.5",
                  "Saving a captured chapter updates its URL and number in portable metadata while preserving the series link")
            do {
                _ = try await ImportService().saveCapturedChapter(Data(), for: book, seriesFolderURL: folder,
                    sourceURL: URL(string: "https://example.com/chapter-999"), modelContext: context)
                check(false, "Invalid PDF save must fail")
            } catch {
                check(book.latestChapterURL == "https://example.com/series/chapter-43.5" && book.latestChapterNumber == "43.5",
                      "Failed PDF save leaves latest chapter link unchanged")
            }
            book.latestChapterURL = nil
            book.latestChapterNumber = nil
            await BookDataService.shared.save(book: book, seriesFolderURL: folder)
            let removedMetadata = await BookDataService.shared.load(seriesFolderURL: folder)
            check(removedMetadata != nil && removedMetadata?.latestChapterURL == nil && removedMetadata?.latestChapterNumber == nil && removedMetadata?.url == legacy.url,
                  "Removing latest chapter persists without removing the series link")
            check(savedURL.lastPathComponent == "Chapter 42.pdf", "User-supplied filename used for saved chapter")
            check(book.sortedChapters.count == 2 && book.totalPages == 2, "Saved capture is imported as a chapter immediately")
            check(book.sortedChapters[book.currentChapterIndex].filename == original.filename && original.lastReadOffset == 123,
                  "Adding capture preserves reading position")
            check(book.sortedChapters[bookmark.chapterIndex].filename == original.filename, "Adding capture preserves bookmarks after sorting")
            let capturedChapter = book.sortedChapters.first { $0.filename != original.filename }!
            let savedPDF = PDFDocument(url: capturedChapter.pdfURL(folderURL: folder))
            check(savedPDF?.page(at: 0)?.bounds(for: .mediaBox).height == 1000, "Reader chapter URL opens saved cropped PDF")
            check(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("Art").path), "Chapter PDF saved in series folder, not Art")
            model.capture(loadEntirePage: true)
            model.cancelCapture()
            try await Task.sleep(for: .milliseconds(500))
            check(!model.isCapturing, "Cancellation restores idle state")
            let fastCaptureStart = Date()
            model.capture(loadEntirePage: false)
            for _ in 0..<100 {
                if !model.isCapturing { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            check(!model.isCapturing && model.errorMessage == nil, "Capture Now succeeds after cancellation (\(Int(Date().timeIntervalSince(fastCaptureStart) * 1000)) ms)")
            checks += try await checkRobustness()
            checks += try await checkLargeChapter()
            checks += try checkCropAlignment()
            checks += try checkNamedAndOptimizedExport()
            write(checks.joined(separator: "\n"))
        } catch { write("FAIL: \(error)") }
    }

    func checkRobustness() async throws -> [String] {
        var checks: [String] = []
        func check(_ condition: Bool, _ label: String) {
            checks.append("\(condition ? "PASS" : "FAIL"): \(label)")
        }
        let pageBox = CGRect(x: 0, y: 0, width: 400, height: 1000)
        let source = UIGraphicsPDFRenderer(bounds: pageBox).pdfData { context in
            for color in [UIColor.red, .green, .blue] {
                context.beginPage()
                color.setFill()
                context.cgContext.fill(pageBox)
            }
        }
        let multi = try WebCaptureDocument(data: source)
        check(multi.pageCount == 3 && multi.size == CGSize(width: 400, height: 3000),
              "Multi-page PDF accepted as continuous document (regression for invalidDocument)")
        let joined = try WebCaptureDocument(data: multi.pdfData())
        check(joined.pageCount == 1 && joined.size == multi.size, "Full export joins source pages without a page separator")
        let crossPage = try multi.pdfData(crop: CGRect(x: 0.1, y: 1.0 / 6, width: 0.8, height: 2.0 / 3))
        let cropped = try WebCaptureDocument(data: crossPage)
        let pdf = PDFDocument(data: crossPage)!
        check(pdf.pageCount == 1 && abs(cropped.size.height - 2000) < 0.1 && abs(cropped.size.width - 320) < 0.1,
              "Crop across three PDF pages preserves all selected content")
        let first = pixel(try cropped.render(crop: CGRect(x: 0, y: 0, width: 1, height: 0.2)))
        let last = pixel(try cropped.render(crop: CGRect(x: 0, y: 0.8, width: 1, height: 0.2)))
        check(first[0] > 240 && first[2] < 15 && last[2] > 240 && last[0] < 15,
              "Continuous PDF preview preserves first/last page orientation")
        // Exercise callback timeout/cancellation without waiting for a real WebKit hang.
        do {
            let _: Int = try await WebCaptureRequest<Int>().run(timeout: .milliseconds(20)) { _ in }
            check(false, "Missing WebKit callback times out")
        } catch WebCaptureError.operationTimedOut { check(true, "Missing WebKit callback times out") }
        let pending = Task { try await WebCaptureRequest<Int>().run(timeout: .seconds(5)) { _ in } }
        try await Task.sleep(for: .milliseconds(20))
        pending.cancel()
        do { _ = try await pending.value; check(false, "Pending WebKit callback cancels immediately") }
        catch is CancellationError { check(true, "Pending WebKit callback cancels immediately") }
        var late: (@MainActor @Sendable (Result<Int, Error>) -> Void)?
        do {
            let _: Int = try await WebCaptureRequest<Int>().run(timeout: .milliseconds(20)) { late = $0 }
        } catch WebCaptureError.operationTimedOut { }
        late?(.success(1))
        check(true, "Late WebKit callback after timeout is ignored safely")

        let base = URL(string: ProcessInfo.processInfo.environment["CAPTURE_SMOKE_URL"]!)!
        for mode in ["broken", "stalled", "deferred", "retained", "ignored", "placeholder"] {
            model.returnToPage()
            model.load(URL(string: "?images=\(mode)", relativeTo: base)!.absoluteURL)
            try await Task.sleep(for: .milliseconds(300))
            for _ in 0..<100 {
                if model.canCapture && model.currentURL?.query == "images=\(mode)" { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            if mode == "stalled" {
                check(model.isLoading && model.canCapture, "Capture available after commit while a resource keeps loading")
            }
            model.capture(loadEntirePage: true)
            for _ in 0..<500 {
                if !model.isCapturing { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            check(model.document != nil && model.errorMessage == nil && !model.isCapturing,
                  "Capture completes with \(mode) image")
            if mode == "deferred" {
                let loaded = try await model.webView.evaluateJavaScript("Array.from(document.images).every(i => i.complete && i.naturalWidth > 0 && !i.dataset.src)") as? Bool
                check(loaded == true && model.captureWarning == nil,
                      "Second pass recovers delayed lazy image with no initial src")
                if let document = model.document {
                    let position = try await model.webView.evaluateJavaScript("(() => { const r = document.images[0].getBoundingClientRect(); return {x: r.x + scrollX, y: r.y + scrollY}; })()") as! [String: NSNumber]
                    let region = try document.render(crop: CGRect(x: (position["x"]!.doubleValue + 10) / document.size.width,
                        y: (position["y"]!.doubleValue + 10) / document.size.height,
                        width: 50 / document.size.width, height: 50 / document.size.height))
                    let color = pixel(region)
                    check(color[0] < 20 && color[1] > 230 && color[2] > 230,
                          "Recovered lazy image is present in captured PDF")
                }
            } else if mode == "retained" || mode == "ignored" {
                check(model.captureWarning == nil, "No false warning for \(mode) images")
            } else {
                check(model.captureWarning != nil, "\(mode) image warning shown instead of silently claiming completeness")
            }
        }
        return checks
    }

    func checkLargeChapter() async throws -> [String] {
        var checks: [String] = []
        func check(_ condition: Bool, _ label: String) {
            checks.append("\(condition ? "PASS" : "FAIL"): \(label)")
        }
        let data = await Task.detached(priority: .userInitiated) { Self.largePDFFixture() }.value
        let document = try WebCaptureDocument(data: data)
        check(data.count >= 40_000_000 && document.size.height == 140_000,
              "Stress fixture: \(data.count / 1_000_000) MB PDF, 140000-point chapter")
        let joinedData = try document.pdfData()
        let joined = try WebCaptureDocument(data: joinedData)
        check(joined.pageCount == 1 && joined.size == document.size, "Large PDF joins into one 140000-point page")
        let optimizedData = try document.exportPDF()
        let optimizedDocument = try WebCaptureDocument(data: optimizedData)
        check(optimizedData.count <= joinedData.count, "Large export never grows after optimization (\(data.count) → \(optimizedData.count) bytes)")
        let renderer = CapturePDFTileRenderer(document: document)
        for top: CGFloat in [0, 70_000, 139_500] {
            let image = try await renderer.image(crop: CGRect(x: 0, y: top / document.size.height,
                                                          width: 1, height: 400 / document.size.height), pixelWidth: 1200)
            let optimizedTile = try optimizedDocument.render(crop: CGRect(x: 0, y: top / document.size.height, width: 1, height: 400 / document.size.height), pixelWidth: 1200)
            check((image.cgImage!.dataProvider!.data! as Data) == (optimizedTile.cgImage!.dataProvider!.data! as Data),
                  "Large optimized PDF retains exact pixels at \(Int(top)) pt")
            check(image.cgImage?.width == 1200 && image.cgImage?.height == 1200,
                  "Long chapter region at \(Int(top)) pt renders at 1200px, independent of total length")
        }
        // Mount the real SwiftUI crop view, not only the rendering function, to
        // detect accidental eager rendering of hundreds of offscreen tiles.
        crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        let uiRenderer = CapturePDFTileRenderer(document: document)
        stressDocument = document
        stressRenderer = uiRenderer
        try await Task.sleep(for: .seconds(3))
        let count = await uiRenderer.renderedTileCount
        check(count > 0 && count < 16, "Long chapter UI renders only visible/prefetched tiles (\(count) tiles)")
        return checks
    }

    nonisolated static func largePDFFixture() -> Data {
        let box = CGRect(x: 0, y: 0, width: 400, height: 10000)
        return UIGraphicsPDFRenderer(bounds: box).pdfData { context in
            var seed: UInt32 = 42
            for pageIndex in 0..<14 {
                autoreleasepool {
                    var pixels = [UInt32](repeating: 0, count: 1024 * 1024)
                    for i in pixels.indices {
                        seed = seed &* 1664525 &+ 1013904223
                        pixels[i] = 0xff000000 | (seed & 0x00ffffff)
                    }
                    let bytes = pixels.withUnsafeBytes { Data($0) }
                    let provider = CGDataProvider(data: bytes as CFData)!
                    let image = CGImage(width: 1024, height: 1024, bitsPerComponent: 8, bitsPerPixel: 32,
                                        bytesPerRow: 4096, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
                    context.beginPage()
                    context.cgContext.draw(image, in: box)
                    UIColor.white.setFill()
                    context.cgContext.fill(CGRect(x: 0, y: 0, width: 400, height: 100))
                    ("Full-resolution PDF / Page \(pageIndex + 1)" as NSString).draw(
                        at: CGPoint(x: 12, y: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 16), .foregroundColor: UIColor.black])
                }
            }
        }
    }

    func checkCropAlignment() throws -> [String] {
        let source = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 1000)).pdfData { context in
            for page in 0..<3 {
                context.beginPage()
                for y in 0..<50 {
                    for x in 0..<20 {
                        UIColor(red: CGFloat(x) / 20, green: CGFloat(page) / 3, blue: CGFloat(y) / 50, alpha: 1).setFill()
                        context.cgContext.fill(CGRect(x: x * 20, y: y * 20, width: 20, height: 20))
                    }
                }
            }
        }
        let document = try WebCaptureDocument(data: source)
        var checks: [String] = []
        for rect in [CGRect(x: 0, y: 0, width: 1, height: 1),
                     CGRect(x: 0.2, y: 0.14, width: 0.6, height: 0.72),
                     CGRect(x: 0.3, y: 0.72, width: 0.4, height: 0.18)] {
            let expected = try document.render(crop: rect, pixelWidth: 480)
            let output = try WebCaptureDocument(data: document.pdfData(crop: rect))
            checks.append("\(output.pageCount == 1 ? "PASS" : "FAIL"): Export has one continuous page")
            let actual = try output.render(pixelWidth: 480)
            let a = expected.cgImage!.dataProvider!.data! as Data
            let b = actual.cgImage!.dataProvider!.data! as Data
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let prefix = "crop-\(Int(rect.minY * 100))"
            try expected.pngData()!.write(to: directory.appendingPathComponent(prefix + "-expected.png"))
            try actual.pngData()!.write(to: directory.appendingPathComponent(prefix + "-actual.png"))
            let same = a == b
            checks.append("\(same ? "PASS" : "FAIL"): Asymmetric crop matches preview pixel-for-pixel at \(rect) expected=\(expected.size) actual=\(actual.size)")
        }
        return checks
    }

    func checkNamedAndOptimizedExport() throws -> [String] {
        var checks: [String] = []
        func check(_ condition: Bool, _ label: String) {
            checks.append("\(condition ? "PASS" : "FAIL"): \(label)")
        }
        check(CaptureFileName.chapterSuggestion(url: URL(string: "https://truyenqq.com.vn/toa-thap-bi-an/chapter-641"), title: "Other Chapter 12") == "Chapter 641", "Chapter URL takes priority over title")
        check(CaptureFileName.chapterSuggestion(url: nil, title: "Truyện - Chapter 636.5") == "Chapter 636.5", "Fractional chapter title suggestion")
        check(CaptureFileName.chapterSuggestion(url: nil, title: "Series 123") == "Chapter", "Missing chapter does not guess a series number")
        check(try CaptureFileName.filename("  Chương 42.PDF ") == "Chương 42.pdf", "Filename preserves Unicode and normalizes extension")
        for name in ["", "../chapter", "bad/name", "bad:name", "\n", ".hidden"] {
            do { _ = try CaptureFileName.filename(name); check(false, "Invalid filename rejected") }
            catch WebCaptureError.invalidFilename { check(true, "Invalid filename rejected: \(name.debugDescription)") }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try CaptureFileName.write(Data([1, 2, 3]), filename: "Chapter 42.pdf", in: folder)
        let second = try CaptureFileName.write(Data([4, 5, 6]), filename: "Chapter 42.pdf", in: folder)
        let firstData = try Data(contentsOf: first)
        check(second.lastPathComponent == "Chapter 42 (2).pdf" && firstData == Data([1, 2, 3]),
              "Duplicate filename is numbered without overwriting original")
        var data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600)).pdfData { context in
            context.beginPage()
            UIColor.blue.setFill()
            context.cgContext.fill(CGRect(x: 25, y: 80, width: 180, height: 210))
            ("Lossless PDF text" as NSString).draw(at: CGPoint(x: 30, y: 30), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }
        // Redundant trailing data models a valid PDF that benefits from repacking.
        data.append(Data(repeating: 0x20, count: 1_000_000))
        let source = try WebCaptureDocument(data: data)
        let optimized = try source.exportPDF()
        let result = try WebCaptureDocument(data: optimized)
        check(optimized.count < data.count / 2, "Lossless repacking removes redundant bytes (\(data.count) → \(optimized.count))")
        let before = try source.render(pixelWidth: 800)
        let after = try result.render(pixelWidth: 800)
        check((before.cgImage!.dataProvider!.data! as Data) == (after.cgImage!.dataProvider!.data! as Data),
              "Optimized PDF matches original pixels")
        check(PDFDocument(data: optimized)?.string?.contains("Lossless PDF text") == true, "Optimization preserves searchable text")
        return checks
    }

    func pixel(_ image: UIImage) -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        rgba.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                    bytesPerRow: 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let source = image.cgImage!
            let center = source.cropping(to: CGRect(x: source.width / 2, y: source.height / 2, width: 1, height: 1))!
            context.draw(center, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return rgba
    }
}
