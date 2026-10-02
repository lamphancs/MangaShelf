import SwiftUI
import WebKit

@MainActor
@Observable
final class WebPageCaptureModel: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    var document: WebCaptureDocument?
    var defaultCrop = CGRect(x: 0, y: 0, width: 1, height: 1)
    var nextChapterURL: URL?
    var isLoading = true
    var canCapture = false
    var isVerificationRequired = false
    var captureWarning: String?
    var isCapturing = false
    var status = "Loading page…"
    var errorMessage: String?
    var suggestedFilename = "Chapter"
    private(set) var capturedPageURL: URL?
    var currentURL: URL?
    var canGoBack = false
    var canGoForward = false
    private var captureTask: Task<Void, Never>?
    private var captureID: UUID?
    private var originalOffset: CGPoint?
    private var navigation: WKNavigation?
    private var requestedURL: URL?
    private var automaticCaptureNavigation: WKNavigation?

    var chapterTitle: String {
        if isCapturing || document != nil { return suggestedFilename }
        return CaptureFileName.chapterSuggestion(
            url: isLoading ? (requestedURL ?? currentURL) : currentURL,
            title: isLoading ? nil : webView.title
        )
    }

    init(isPrivate: Bool = true) {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Retain normal browsing sessions, including legitimate verification cookies.
        // Secret Library sessions remain isolated and are discarded on close.
        configuration.websiteDataStore = isPrivate ? .nonPersistent() : .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.scrollView.contentInsetAdjustmentBehavior = .never
    }

    func load(_ url: URL) {
        requestedURL = url
        navigation = webView.load(URLRequest(url: url, timeoutInterval: 45))
    }

    func reload() {
        if let url = requestedURL ?? currentURL { load(url) }
    }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    private func updateNavigationState() {
        currentURL = webView.url
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if navigation !== automaticCaptureNavigation { automaticCaptureNavigation = nil }
        self.navigation = navigation
        cancelCapture()
        isLoading = true
        nextChapterURL = nil
        isVerificationRequired = false
        canCapture = false
        status = "Loading page…"
        errorMessage = nil
        updateNavigationState()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard navigation === self.navigation else { return }
        // A page can be usable while ads/subresources keep didFinish pending.
        canCapture = !isVerificationRequired
        updateNavigationState()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === self.navigation else { return }
        isLoading = false
        canCapture = !isVerificationRequired
        requestedURL = webView.url ?? requestedURL
        updateNavigationState()
        if let automaticCaptureNavigation, navigation === automaticCaptureNavigation {
            self.automaticCaptureNavigation = nil
            if canCapture { capture(loadEntirePage: true) }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(navigation, error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(navigation, error: error)
    }

    private func navigationFailed(_ navigation: WKNavigation?, error: Error) {
        guard navigation === self.navigation, (error as NSError).code != NSURLErrorCancelled else { return }
        automaticCaptureNavigation = nil
        isLoading = false
        cancelCapture()
        updateNavigationState()
        errorMessage = error.localizedDescription
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        automaticCaptureNavigation = nil
        cancelCapture()
        isLoading = false
        canCapture = false
        errorMessage = "The web page process stopped, possibly while decoding an image. Reload the page, then try Capture again."
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame,
           let response = navigationResponse.response as? HTTPURLResponse {
            isVerificationRequired = response.value(forHTTPHeaderField: "cf-mitigated")?.lowercased() == "challenge"
            if isVerificationRequired {
                canCapture = false
                automaticCaptureNavigation = nil
            }
        }
        // Let the user complete the site's verification in the actual web view.
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Do not let a scripted popup replace the chapter in our single web view.
        if navigationAction.targetFrame == nil && navigationAction.navigationType != .linkActivated {
            decisionHandler(.cancel)
            return
        }
        let scheme = navigationAction.request.url?.scheme?.lowercased()
        if navigationAction.targetFrame?.isMainFrame == true, scheme == "http" || scheme == "https" {
            requestedURL = navigationAction.request.url
        }
        decisionHandler(scheme == "http" || scheme == "https" ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil,
           navigationAction.navigationType == .linkActivated,
           let scheme = navigationAction.request.url?.scheme?.lowercased(), ["http", "https"].contains(scheme) {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func findNextChapterURL() async throws -> URL? {
        let value = try await WebCaptureRequest<Any?>().run(timeout: .seconds(5)) { completion in
            self.webView.evaluateJavaScript(#"""
                (() => {
                    const normalize = text => text.normalize('NFD').replace(/[\u0300-\u036f]/g, '')
                        .toLowerCase().replace(/\s+/g, ' ').trim();
                    const candidates = Array.from(document.querySelectorAll('a[href], link[rel~="next"][href]'))
                        .filter(a => !a.matches('[aria-disabled="true"], [disabled], .disabled'))
                        .map(a => {
                            let url;
                            try { url = new URL(a.href, document.baseURI); } catch { return null; }
                            if (!['http:', 'https:'].includes(url.protocol) || url.origin !== location.origin ||
                                url.pathname + url.search === location.pathname + location.search) return null;
                            const labels = [a.textContent, a.getAttribute('aria-label'), a.title].filter(Boolean).map(normalize);
                            const chapterLabel = labels.some(t => /^(next\s+(chapter|chap)|chuong\s+(tiep|sau)|chap\s+(tiep|sau))\b/.test(t));
                            const relNext = a.rel.split(/\s+/).includes('next');
                            const identifier = /(^|[\s_-])(next[-_]?(chapter|chap)|(chapter|chap)[-_]?next)([\s_-]|$)/i.test(a.id + ' ' + a.className);
                            const score = chapterLabel ? 3 : relNext ? 2 : identifier ? 1 : 0;
                            return score ? {url: url.href, score} : null;
                        }).filter(Boolean).sort((a, b) => b.score - a.score);
                    if (!candidates.length) return null;
                    const best = candidates.filter(a => a.score === candidates[0].score);
                    return new Set(best.map(a => a.url)).size === 1 ? best[0].url : null;
                })()
                """#) { result, error in
                    if let error { completion(.failure(error)) }
                    else { completion(.success(result)) }
                }
        }
        try Task.checkCancellation()
        return (value as? String).flatMap(URL.init(string:))
    }

    @discardableResult
    func goToNextChapter(automaticallyCapture: Bool = false) -> Bool {
        guard let nextChapterURL else { return false }
        returnToPage()
        self.nextChapterURL = nil
        load(nextChapterURL)
        automaticCaptureNavigation = automaticallyCapture ? navigation : nil
        return true
    }

    func capture(loadEntirePage: Bool) {
        guard canCapture, !isCapturing else { return }
        automaticCaptureNavigation = nil
        capturedPageURL = webView.url
        suggestedFilename = CaptureFileName.chapterSuggestion(url: capturedPageURL, title: webView.title)
        isCapturing = true
        errorMessage = nil
        captureWarning = nil
        let id = UUID()
        captureID = id
        originalOffset = webView.scrollView.contentOffset
        captureTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if captureID == id {
                    if let originalOffset { webView.scrollView.setContentOffset(originalOffset, animated: false) }
                    originalOffset = nil
                    captureID = nil
                    captureTask = nil
                    isCapturing = false
                }
            }
            do {
                if loadEntirePage { try await preparePage() }
                try Task.checkCancellation()
                status = "Capturing full page…"
                webView.scrollView.setContentOffset(.zero, animated: false)
                try await Task.sleep(for: .milliseconds(250))
                let configuration = WKPDFConfiguration()
                let size = webView.scrollView.contentSize
                guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
                    throw WebCaptureError.invalidDocument
                }
                configuration.rect = CGRect(origin: .zero, size: size)
                // Freeze diagnostics immediately before the PDF request. Later browser
                // loads cannot repair pixels already missing from the captured PDF.
                try await inspectImages(waitForLoading: false)
                status = "Capturing full page…"
                let data = try await WebCaptureRequest<Data>().run(timeout: .seconds(45)) { completion in
                    self.webView.createPDF(configuration: configuration, completionHandler: completion)
                }
                try Task.checkCancellation()
                let result = try await Task.detached(priority: .userInitiated) {
                    try WebCaptureDocument(data: data)
                }.value
                try Task.checkCancellation()
                defaultCrop = result.defaultCaptureCrop(viewportHeight: webView.bounds.height)
                nextChapterURL = try? await findNextChapterURL()
                try Task.checkCancellation()
                document = result
            } catch is CancellationError {
                // Closing the screen or navigating cancels this capture.
            } catch {
                if captureID == id {
                    let detail = error as NSError
                    errorMessage = "\(status)\n\(error.localizedDescription)\n(\(detail.domain): \(detail.code))"
                }
            }
        }
    }

    private func preparePage() async throws {
        status = "Loading images…"
        // Do not make every image eager: long WebP chapters can exhaust the web
        // process when all images are downloaded/decoded at once. Visit viewports instead.
        var y: CGFloat = 0
        var stableBottom = 0
        // A finite chapter can take minutes to visit. Keep walking until its bottom
        // settles; Stop Loading and navigation can cancel at every viewport.
        // Scroll each viewport to trigger IntersectionObserver-based images and expanding content.
        while stableBottom < 3 {
            try Task.checkCancellation()
            let height = webView.scrollView.contentSize.height
            guard height.isFinite, height > 0 else { throw WebCaptureError.invalidDocument }
            let viewport = max(webView.bounds.height, 1)
            let bottom = max(0, height - viewport)
            y = min(y, bottom)
            webView.scrollView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
            status = "Loading full page… \(Int(min(1, (y + viewport) / max(height, 1)) * 100))%"
            // Give WebKit several frames to deliver scroll/IntersectionObserver events.
            // Loaded viewports need no network delay; apply backpressure only where
            // visible images are still loading instead of racing through all decodes.
            try await Task.sleep(for: .milliseconds(150))
            let pending = try await WebCaptureRequest<Any?>().run(timeout: .seconds(5)) { completion in
                self.webView.evaluateJavaScript("""
                    Array.from(document.images).some(image => {
                        if (image.complete) return false;
                        const rect = image.getBoundingClientRect();
                        return rect.width > 0 && rect.height > 0 &&
                            rect.bottom > 0 && rect.top < innerHeight;
                    })
                    """) { result, error in
                        if let error { completion(.failure(error)) }
                        else { completion(.success(result)) }
                    }
            }
            if (pending as? Bool == true) || y >= bottom - 1 {
                try await Task.sleep(for: .milliseconds(200))
            }
            let newBottom = max(0, webView.scrollView.contentSize.height - viewport)
            if y >= newBottom - 1 {
                stableBottom += 1
            } else {
                stableBottom = 0
                y = min(y + viewport * 0.85, newBottom)
            }
        }
        try await recoverMissingImages()
        try await inspectImages()
    }

    // Inspect lazy placeholders as well as requests which already have a source.
    // Revisit their elements so the site's own loader selects the correct resource.
    private func imageState(target: Int? = nil, retry: Bool = false) async throws -> [String: Any] {
        let value = try await WebCaptureRequest<Any?>().run(timeout: .seconds(5)) { completion in
            self.webView.evaluateJavaScript("""
                (() => {
                    const target = \(target ?? -1);
                    const images = Array.from(document.images);
                    const image = images[target];
                    if (image) {
                        image.scrollIntoView({block: 'center', behavior: 'instant'});
                        if (\(retry ? "true" : "false") && image.complete && image.naturalWidth === 0) {
                            const src = image.getAttribute('src');
                            const srcset = image.getAttribute('srcset');
                            if (src) image.removeAttribute('src');
                            if (srcset) image.removeAttribute('srcset');
                            if (srcset) image.setAttribute('srcset', srcset);
                            if (src) image.setAttribute('src', src);
                        }
                    }
                    const missing = [];
                    let failed = 0;
                    images.forEach((image, index) => {
                        const rect = image.getBoundingClientRect();
                        // Include offscreen chapter pages, but not hidden elements or
                        // tracking pixels which cannot contribute useful PDF content.
                        if (rect.width <= 0 || rect.height <= 0 ||
                            (rect.width <= 1 && rect.height <= 1)) return;
                        if (getComputedStyle(image).visibility !== 'visible') return;
                        for (let node = image; node; node = node.parentElement) {
                            const style = getComputedStyle(node);
                            if (style.display === 'none' || Number(style.opacity) === 0 ||
                                style.contentVisibility === 'hidden') return;
                        }
                        const lazy = ['data-src', 'data-original', 'data-lazy-src']
                            .map(key => image.getAttribute(key)).find(Boolean);
                        const source = image.currentSrc || image.getAttribute('src') || '';
                        const absolute = value => {
                            try { return new URL(value, document.baseURI).href; }
                            catch { return value; }
                        };
                        const selectedLazySource = lazy && source && absolute(source) === absolute(lazy);
                        const hasLazySource = lazy || image.getAttribute('data-srcset');
                        // Classes/data attributes often remain after loading. Trust the
                        // selected, decoded resource; a retained class is not a request.
                        const placeholder = source.startsWith('data:') ||
                            (image.naturalWidth === 1 && image.naturalHeight === 1);
                        const deferred = hasLazySource && (!source ||
                            (!selectedLazySource && placeholder && !image.getAttribute('srcset')));
                        const broken = source && image.complete && image.naturalWidth === 0 && !deferred;
                        if (broken) failed++;
                        if (deferred || !image.complete || broken || (!source && image.getAttribute('data-srcset'))) {
                            missing.push(index);
                        }
                    });
                    return {missing, failed, pending: missing.length - failed,
                            fontsPending: document.fonts && document.fonts.status === 'loading'};
                })()
                """) { result, error in
                    if let error { completion(.failure(error)) }
                    else { completion(.success(result)) }
                }
        }
        try Task.checkCancellation()
        guard let state = value as? [String: Any] else { throw WebCaptureError.invalidDocument }
        return state
    }

    private func recoverMissingImages() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        var retried: Set<Int> = []
        // Two bounded passes allow late site loaders to activate without slowing
        // down already-ready images or forcing a whole chapter to decode at once.
        for _ in 0..<2 {
            let state = try await imageState()
            let missing = (state["missing"] as? [NSNumber] ?? []).map(\.intValue)
            if missing.isEmpty { return }
            for index in missing {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { return }
                status = "Loading remaining images… \(missing.count)"
                _ = try await imageState(target: index, retry: retried.insert(index).inserted)
                let imageDeadline = min(deadline, ContinuousClock.now.advanced(by: .seconds(3)))
                repeat {
                    try await Task.sleep(for: .milliseconds(250))
                    let current = try await imageState()
                    let remaining = (current["missing"] as? [NSNumber] ?? []).map(\.intValue)
                    if !remaining.contains(index) { break }
                } while ContinuousClock.now < imageDeadline
            }
        }
    }

    private func inspectImages(waitForLoading: Bool = true) async throws {
        status = "Waiting for page images…"
        let deadline = Date().addingTimeInterval(10)
        while true {
            try Task.checkCancellation()
            let state = try await imageState()
            let pending = (state["pending"] as? NSNumber)?.intValue ?? 0
            let failed = (state["failed"] as? NSNumber)?.intValue ?? 0
            let fontsPending = (state["fontsPending"] as? NSNumber)?.boolValue ?? false
            if !waitForLoading || (pending == 0 && !fontsPending) || Date() >= deadline {
                var warnings: [String] = []
                if failed > 0 { warnings.append("\(failed) visible page image(s) reported a load error at capture time.") }
                if pending > 0 { warnings.append("\(pending) visible page image(s) were not confirmed ready at capture time.") }
                if fontsPending { warnings.append("Some web fonts were still loading at capture time.") }
                captureWarning = warnings.isEmpty ? nil : warnings.joined(separator: " ") +
                    " This may include site graphics outside the chapter. Check the PDF preview before saving."
                // A broken WebP or a stalled tracking image must not block the
                // entire PDF. Keep the failure visible instead of claiming completeness.
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    func returnToPage() {
        capturedPageURL = nil
        document = nil
        captureWarning = nil
    }

    func cancelCapture() {
        captureTask?.cancel()
        captureTask = nil
        captureID = nil
        if let originalOffset { webView.scrollView.setContentOffset(originalOffset, animated: false) }
        originalOffset = nil
        isCapturing = false
    }

    func close() {
        automaticCaptureNavigation = nil
        cancelCapture()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }
}
