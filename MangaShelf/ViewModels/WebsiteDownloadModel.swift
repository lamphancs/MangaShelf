import SwiftUI
import SwiftData
import WebKit

@MainActor @Observable
final class WebsiteDownloadModel {
    let browser: WebPageCaptureModel
    let source: URL
    let provider: WebsiteProvider?
    var title = "Tải truyện từ website"
    var chapters: [WebsiteChapter] = []
    var selected = Set<String>()
    var states: [String: String] = [:]
    var saved: [String: URL] = [:]
    var status = ""
    var warning = ""
    var busy = false
    var completed = 0
    var total = 0
    var imageProgress = 0.0
    var timings: [String: String] = [:]
    private var task: Task<Void, Never>?
    private var inBackground = false
    private var needsWebExecution = false
    private var backgroundLease: UIBackgroundTaskIdentifier = .invalid

    func sceneChanged(_ phase: ScenePhase) {
        inBackground = phase == .background
        if inBackground && busy && needsWebExecution {
            status = "Đã dừng: trang cần JavaScript/xác minh; mở lại app để thử tiếp."
            stop()
        }
    }
    private func endBackgroundLease() {
        if backgroundLease != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundLease)
            backgroundLease = .invalid
        }
    }

    init(url: URL, isPrivate: Bool) {
        source = url; provider = WebsiteProvider(url: url)
        browser = WebPageCaptureModel(isPrivate: isPrivate)
    }
    func stop() { task?.cancel(); browser.webView.stopLoading() }
    private func js(_ script: String, timeout: Duration = .seconds(35)) async throws -> Any {
        try await WebCaptureRequest<Any>().run(timeout: timeout) { finish in
            browser.webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
                finish(result.map { $0 as Any })
            }
        }
    }
    private func navigate(_ url: URL) async throws {
        browser.load(url)
        try await Task.sleep(for: .milliseconds(500))
        let deadline = ContinuousClock.now + .seconds(120)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if browser.isVerificationRequired { status = "Đang chờ xác minh — hoàn thành trong trang nguồn bên dưới." }
            else if browser.canCapture && !browser.isLoading { return }
            if let error = browser.errorMessage { throw WebsiteDownloadError(error) }
            try await Task.sleep(for: .milliseconds(400))
        }
        throw WebsiteDownloadError("Trang chưa sẵn sàng. Hoàn thành xác minh/đăng nhập rồi thử lại.")
    }
    func loadList() {
        guard !busy else { return }
        busy = true
        task = Task {
            defer { busy = false; needsWebExecution = false }
            needsWebExecution = true
            do {
                guard let provider else { throw WebsiteDownloadError("Website này chưa có adapter.") }
                status = "Đang lấy danh sách"; warning = ""
                try await navigate(source)
                title = browser.webView.title ?? title
                var links: [[String: String]] = []
                var stable = 0
                for _ in 0..<20 {
                    let next = try await js("return \(provider.linksScript)") as? [[String: String]] ?? []
                    stable = next == links && !next.isEmpty ? stable + 1 : 0
                    links = next
                    if stable >= 3 { break }
                    try await Task.sleep(for: .seconds(1))
                }
                var verified = false
                if provider == .toonGod {
                    // Same-origin requests use the actual WebKit session; never invent clearance tokens.
                    let extra = try await js(#"""
                    const base = location.href.split(/[?#]/)[0].replace(/\/$/,'');
                    let html = '';
                    try { const r = await fetch(base + '/ajax/chapters/', {method:'POST'}); if(r.ok) html = await r.text(); } catch {}
                    const id = document.querySelector('.rating-post-id[data-id],#manga-chapters-holder[data-id],.chapter-list[data-id]')?.dataset.id;
                    if (!html && id) {
                      const r = await fetch('/wp-admin/admin-ajax.php', {method:'POST', headers:{'Content-Type':'application/x-www-form-urlencoded'}, body:new URLSearchParams({action:'manga_get_chapters',manga:id})});
                      if(r.ok) html = await r.text();
                    }
                    const doc = new DOMParser().parseFromString(html,'text/html');
                    return [...doc.querySelectorAll('a[href]')].map(a=>({url:new URL(a.getAttribute('href'),location.href).href,title:a.textContent.trim()}));
                    """#) as? [[String: String]] ?? []
                    links += extra
                    // An AJAX response alone is not proof of a complete list.
                }
                if provider == .omega {
                    if let result = try? await omegaList(), !result.isEmpty { links = result; verified = true }
                }
                chapters = provider.chapters(links, series: source)
                guard !chapters.isEmpty else { throw WebsiteDownloadError("Không tìm thấy chapter đúng bộ truyện. Kiểm tra URL trang chủ, đăng nhập hoặc cấu trúc website.") }
                selected.formIntersection(Set(chapters.map(\.id)))
                warning = (verified ? "Đã đối chiếu đủ phân trang chapter. " : "Chưa xác minh được danh sách đầy đủ. Website có thể phân trang hoặc ẩn chapter. ") + "Ảnh được kiểm tra theo DOM và tổng trang nếu website cung cấp; hãy đối chiếu chapter sau khi tải."
                status = "Tìm thấy \(chapters.count) chapter"
            } catch { status = Task.isCancelled ? "Đã dừng" : error.localizedDescription }
        }
    }
    private func omegaList() async throws -> [[String: String]] {
        // Match the exact series slug inside structured objects, never a random series_id.
        let result = try await js(WebsiteProvider.omegaListScript)
        return result as? [[String: String]] ?? []
    }
    private struct ImageManifest {
        let urls: [URL]
        let referer: URL
        let usesPage: Bool
    }
    private func imageURLs(_ chapter: WebsiteChapter, session: URLSession, agent: String) async throws -> ImageManifest {
        guard let provider else { throw WebsiteDownloadError("Website không hỗ trợ.") }
        // Try an inert HTML document first. It never loads images/ads or runs site scripts.
        states[chapter.id] = "Đang lấy URL ảnh trực tiếp"
        do {
            var request = URLRequest(url: chapter.url, timeoutInterval: 20)
            request.setValue(source.absoluteString, forHTTPHeaderField: "Referer")
            request.setValue(agent, forHTTPHeaderField: "User-Agent")
            let (html, response) = try await session.data(for: request)
            try Task.checkCancellation()
            if let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
               let finalURL = response.url,
               WebsiteProvider.canonical(finalURL) == WebsiteProvider.canonical(chapter.url),
               html.count <= 8 * 1024 * 1024, let text = String(data: html, encoding: .utf8) {
                let result = try await js(provider.staticImagesScript(html: text, url: finalURL)) as? [String: Any] ?? [:]
                let urls = (result["urls"] as? [String] ?? []).compactMap(URL.init(string:))
                let pending = result["pending"] as? Int ?? 0
                let total = result["total"] as? Int ?? 0
                if !urls.isEmpty, pending == 0, result["requiresScript"] as? Bool != true,
                   provider != .omega || total > 0, total == 0 || total == urls.count,
                   urls.allSatisfy({ ["http", "https"].contains($0.scheme ?? "") }) {
                    return ImageManifest(urls: urls, referer: finalURL, usesPage: false)
                }
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            // Verification, encrypted client-side content or changed HTML falls back
            // to the user's real browsing session, never an incomplete static PDF.
        }
        states[chapter.id] = "Website cần JavaScript — đang đọc trang nguồn"
        try await navigate(chapter.url)
        guard let current = browser.webView.url,
              WebsiteProvider.canonical(current) == WebsiteProvider.canonical(chapter.url) else {
            throw WebsiteDownloadError("Trang đã chuyển khỏi chapter đã chọn. Kiểm tra đăng nhập hoặc URL nguồn.")
        }
        var previous: [String] = [], stable = 0
        for _ in 0..<120 {
            try Task.checkCancellation()
            if browser.isVerificationRequired { throw WebsiteDownloadError("Đang chờ xác minh. Hoàn thành trong trang nguồn rồi thử lại.") }
            let result = try await js("return \(provider.imagesScript)") as? [String: Any] ?? [:]
            let urls = result["urls"] as? [String] ?? []
            let pending = result["pending"] as? Int ?? 0
            let expected = result["total"] as? Int ?? 0
            let text = (result["text"] as? String ?? "").lowercased()
            if urls.isEmpty && ["unlock chapter", "purchase chapter", "chapter is locked", "đăng nhập để đọc", "mở khóa chương"].contains(where: text.contains) {
                throw WebsiteDownloadError("Chapter bị khóa hoặc yêu cầu đăng nhập. Chỉ tải khi phiên web được phép xem ảnh.")
            }
            // Lazy URL attributes can be read without decoding/rendering the image.
            // Scroll only when unresolved placeholders actually require visibility.
            if urls.isEmpty || pending > 0 {
                _ = try await js("window.scrollBy(0, Math.max(1, innerHeight * 0.8)); return true")
            }
            if urls == previous && !urls.isEmpty && pending == 0 { stable += 1 } else { stable = 0 }
            if stable >= (expected > 0 ? 3 : 9) && (expected == 0 || expected == urls.count) {
                guard let current = browser.webView.url, WebsiteProvider.canonical(current) == WebsiteProvider.canonical(chapter.url) else {
                    throw WebsiteDownloadError("Trang nguồn thay đổi trong khi đọc ảnh; hãy thử lại chapter.")
                }
                let resolved = try urls.map { value in
                    guard let url = URL(string: value), ["http", "https", "blob", "data"].contains(url.scheme ?? "") else {
                        throw WebsiteDownloadError("URL ảnh không được hỗ trợ; chapter không được lưu thiếu ảnh.")
                    }
                    return url
                }
                return ImageManifest(urls: resolved, referer: current, usesPage: true)
            }
            previous = urls
            try await Task.sleep(for: .milliseconds(350))
        }
        throw WebsiteDownloadError("Ảnh chưa tải đủ, còn placeholder hoặc cấu trúc trang thay đổi. Không tạo PDF thiếu ảnh.")
    }
    func download(book: Book, isEnglish: Bool, context: ModelContext) {
        guard !busy else { return }
        let queue = chapters.filter { selected.contains($0.id) && saved[$0.id] == nil }
        guard !queue.isEmpty else { return }
        // Freeze the full-width browser viewport for this batch: rotations and
        // chapter length must not change the output width halfway through a queue.
        let pdfWidth = Double(browser.webView.bounds.width)
        guard pdfWidth.isFinite, pdfWidth > 0 else {
            status = "Khung trình duyệt chưa sẵn sàng. Vui lòng thử lại."
            return
        }
        busy = true; completed = 0; total = queue.count
        backgroundLease = UIApplication.shared.beginBackgroundTask(withName: "Finish website chapter") { [weak self] in
            Task { @MainActor in self?.stop(); self?.endBackgroundLease() }
        }
        task = Task {
            defer { busy = false; needsWebExecution = false; endBackgroundLease() }
            for chapter in queue {
                if Task.isCancelled || inBackground { break }
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("website-\(UUID())", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: folder) }
                let started = ContinuousClock.now
                do {
                    needsWebExecution = true
                    guard let filename = chapter.filename else { throw WebsiteDownloadError("Không xác định được số chapter; không tự gán số thứ tự.") }
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let capacity = try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
                    if let capacity, capacity < 600 * 1024 * 1024 { throw WebsiteDownloadError("Cần ít nhất 600 MB dung lượng trống để tạo PDF an toàn.") }
                    states[chapter.id] = "Đang tải ảnh"; status = chapter.title; imageProgress = 0
                    let cookies = await browser.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                    let config = URLSessionConfiguration.ephemeral
                    config.timeoutIntervalForRequest = 40; config.timeoutIntervalForResource = 120
                    config.httpMaximumConnectionsPerHost = 3
                    for cookie in cookies { config.httpCookieStorage?.setCookie(cookie) }
                    let session = URLSession(configuration: config)
                    defer { session.invalidateAndCancel() }
                    let agent = try await js("return navigator.userAgent") as? String ?? ""
                    let manifest = try await imageURLs(chapter, session: session, agent: agent)
                    let urls = manifest.urls, referer = manifest.referer
                    if manifest.usesPage {
                        let freshCookies = await browser.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                        for cookie in freshCookies { config.httpCookieStorage?.setCookie(cookie) }
                    }
                    let resolvedAt = ContinuousClock.now
                    needsWebExecution = urls.contains { ["blob", "data"].contains($0.scheme ?? "") }
                    var files: [URL] = [], bytes = 0
                    if !needsWebExecution {
                        let requests = urls.map { url in
                            var request = URLRequest(url: url)
                            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
                            request.setValue(agent, forHTTPHeaderField: "User-Agent")
                            return request
                        }
                        files = try await WebsiteImageTransfer.fetchAll(requests, session: session, folder: folder) { count in
                            await MainActor.run {
                                self.imageProgress = Double(count) / Double(urls.count)
                                self.states[chapter.id] = "Đang tải ảnh \(count)/\(urls.count) · 3 luồng"
                            }
                        }
                    } else {
                        for (index, url) in urls.enumerated() {
                            try Task.checkCancellation()
                            var request = URLRequest(url: url)
                            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
                            request.setValue(agent, forHTTPHeaderField: "User-Agent")
                            let target = folder.appendingPathComponent("image-\(index)")
                            let count: Int
                            if ["blob", "data"].contains(url.scheme ?? "") {
                                count = try await fetchPageImage(url, to: target)
                            } else {
                                let imageRequest = request
                                let transfer = Task.detached(priority: .utility) { try await Self.fetch(imageRequest, session: session, to: target) }
                                count = try await withTaskCancellationHandler { try await transfer.value } onCancel: { transfer.cancel() }
                            }
                            bytes += count
                            guard bytes <= 250 * 1024 * 1024 else { throw WebsiteDownloadError("Chapter vượt giới hạn 250 MB.") }
                            files.append(target); imageProgress = Double(index + 1) / Double(urls.count)
                            states[chapter.id] = "Đang tải ảnh \(index + 1)/\(urls.count)"
                        }
                    }
                    needsWebExecution = false
                    let downloadedAt = ContinuousClock.now
                    try Task.checkCancellation()
                    states[chapter.id] = "Đang tạo PDF"
                    let pdf = folder.appendingPathComponent("chapter.pdf")
                    let worker = Task.detached(priority: .userInitiated) { try ChapterImagePDF.write(images: files, to: pdf, pageWidth: pdfWidth) }
                    try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    try Task.checkCancellation()
                    let writtenAt = ContinuousClock.now
                    states[chapter.id] = "Đang lưu"
                    let data = try Data(contentsOf: pdf, options: .mappedIfSafe)
                    let result = try await ImportService().saveCapturedChapter(data, for: book, filename: filename, sourceURL: chapter.url, chapterTitle: chapter.title, isEnglish: isEnglish, modelContext: context)
                    saved[chapter.id] = result; selected.remove(chapter.id)
                    func seconds(_ from: ContinuousClock.Instant, _ to: ContinuousClock.Instant) -> String {
                        let c = from.duration(to: to).components
                        return String(format: "%.1f", Double(c.seconds) + Double(c.attoseconds) / 1e18)
                    }
                    states[chapter.id] = "Hoàn tất · \(seconds(started, .now)) giây"
                    timings[chapter.id] = "URL \(seconds(started, resolvedAt))s · Tải ảnh \(seconds(resolvedAt, downloadedAt))s · PDF \(seconds(downloadedAt, writtenAt))s · Lưu \(seconds(writtenAt, .now))s"
                } catch {
                    states[chapter.id] = Task.isCancelled ? "Đã dừng" : "Lỗi: \(error.localizedDescription)"
                }
                completed += 1
            }
            status = Task.isCancelled || inBackground ? "Đã dừng — PDF đã lưu được giữ lại; mở app để tải tiếp phần còn chọn" : "Đã xử lý \(completed)/\(total) chapter"
        }
    }
    // Blob/data bytes remain in their owning page. Only one 64 KiB chunk crosses
    // the WebKit bridge at a time; no chapter-sized base64 string is constructed.
    func fetchPageImage(_ url: URL, to target: URL) async throws -> Int {
        let key = "__mangashelfImage_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let quoted = String(data: try JSONEncoder().encode(url.absoluteString), encoding: .utf8)!
        do {
            let count = try await js("""
            const r = await fetch(\(quoted));
            if (!r.ok) throw new Error('Ảnh trong phiên web HTTP '+r.status);
            const blob = await r.blob();
            if (!blob.size || blob.size > 41943040) throw new Error('Ảnh rỗng hoặc vượt 40 MB');
            window.\(key) = new Uint8Array(await blob.arrayBuffer());
            return window.\(key).length;
            """) as? Int ?? 0
            guard count > 0 else { throw WebsiteDownloadError("Không đọc được ảnh trong phiên web.") }
            FileManager.default.createFile(atPath: target.path, contents: nil)
            let file = try FileHandle(forWritingTo: target)
            defer { try? file.close() }
            for start in stride(from: 0, to: count, by: 65536) {
                try Task.checkCancellation()
                let end = min(start + 65536, count)
                guard let encoded = try await js("return btoa(String.fromCharCode(...window.\(key).subarray(\(start),\(end))))") as? String,
                      let data = Data(base64Encoded: encoded), data.count == end - start else {
                    throw WebsiteDownloadError("Dữ liệu ảnh trong phiên web bị gián đoạn.")
                }
                try file.write(contentsOf: data)
            }
            _ = try await js("delete window.\(key); return true")
            return count
        } catch {
            // Cleanup must still run when the download task was cancelled, without
            // delaying its original error or waiting indefinitely on a stopped WebKit process.
            Task { @MainActor [weak self] in
                _ = try? await self?.js("delete window.\(key); return true", timeout: .seconds(2))
            }
            throw error
        }
    }

    nonisolated static func fetch(_ request: URLRequest, session: URLSession, to target: URL) async throws -> Int {
        try await WebsiteImageTransfer.fetch(request, session: session, to: target)
    }
}
