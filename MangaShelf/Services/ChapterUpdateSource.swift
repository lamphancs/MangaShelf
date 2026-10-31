import WebKit

nonisolated enum ChapterUpdateSource {
    static func seriesPage(_ url: URL) -> URL? {
        guard ["toongod.org", "www.toongod.org"].contains(url.host?.lowercased()),
              url.pathComponents.count >= 3 else { return nil }
        let page = chapterNumber(url.lastPathComponent) == nil ? url : url.deletingLastPathComponent()
        guard page.pathComponents.count >= 3 else { return nil }
        return page.absoluteURL.appendingPathComponent("", isDirectory: true)
    }

    static func chapterNumber(_ name: String) -> Double? {
        let label = CaptureFileName.chapterSuggestion(url: nil, title: name)
        return Double(label.dropFirst("Chapter ".count))
    }

    @MainActor
    static func fetch(_ page: URL, dataStore: WKWebsiteDataStore,
                      verify: (WebPageCaptureModel) throws -> Void) async throws -> Double {
        let browser = WebPageCaptureModel(dataStore: dataStore)
        browser.load(page)
        defer { browser.webView.stopLoading() }
        var deadline = ContinuousClock.now + .seconds(20)
        var verifying = false
        var readyDeadline: ContinuousClock.Instant?
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let message = browser.errorMessage { throw CheckError(message: message) }
            if browser.isVerificationRequired {
                if !verifying {
                    try verify(browser)
                    verifying = true
                    deadline = .now + .seconds(90)
                }
            } else if browser.canCapture {
                let links = try await WebCaptureRequest<[String]>().run(timeout: .seconds(5)) { finish in
                    browser.webView.evaluateJavaScript("Array.from(document.links, a => a.href)") { result, error in
                        if let error { finish(.failure(error)) }
                        else { finish(.success(result as? [String] ?? [])) }
                    }
                }
                if let latest = latest(in: links, page: page) { return latest }
                if !verifying && !browser.isLoading {
                    if readyDeadline == nil { readyDeadline = .now + .seconds(5) }
                    if let readyDeadline, ContinuousClock.now >= readyDeadline { break }
                }
            }
            try await Task.sleep(for: .milliseconds(400))
        }
        if verifying {
            throw CheckError(message: "Verification did not reach the series chapter list. The check has stopped.")
        }
        if let code = browser.mainResponseStatus, code >= 400 {
            throw CheckError(message: "ToonGod returned HTTP \(code). Open the series link in Info to check access.")
        }
        throw CheckError(message: "No chapter list appeared. Check that the link in Info opens the series contents.")
    }

    static func latest(in links: [String], page: URL) -> Double? {
        func host(_ url: URL) -> String? {
            let name = url.host?.lowercased()
            return name == "www.toongod.org" ? "toongod.org" : name
        }
        return links.compactMap { link -> Double? in
            guard let url = URL(string: link),
                  host(url) == host(page),
                  url.pathComponents.dropLast().elementsEqual(page.pathComponents) else { return nil }
            return chapterNumber(url.lastPathComponent)
        }.max()
    }

    struct CheckError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
