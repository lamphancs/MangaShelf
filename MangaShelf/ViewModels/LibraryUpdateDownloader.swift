import SwiftUI
import SwiftData
import WebKit

/// One series source whose website lists chapters newer than the library's latest that are not saved yet.
struct LibraryChapterUpdate: Identifiable {
    let id: String
    let book: Book
    let isEnglish: Bool
    let model: WebsiteDownloadModel
    let chapters: [WebsiteChapter]
    var title: String { isEnglish ? "\(book.title) (EN)" : book.title }
}

/// Collects missing chapters after the library check and downloads them without showing the website.
@MainActor @Observable
final class LibraryUpdateDownloader {
    struct Candidate {
        let book: Book
        let page: URL
        let isEnglish: Bool
        let localLatest: Double
    }

    enum Phase {
        /// The person picks which series to download.
        case choosing
        case downloading
        /// The batch ended (finished or stopped); results stay visible until the person closes them.
        case finished
    }

    var updates: [LibraryChapterUpdate] = []
    var selected = Set<String>()
    var showsUpdates = false
    var phase = Phase.choosing
    /// The series being downloaded, in order.
    var queue: [LibraryChapterUpdate] = []
    /// Check problems for other series, shown under the update list.
    var notes: [String] = []
    var isDownloading: Bool { phase == .downloading }
    /// Paused by the person, so returning from the background does not resume it.
    var isPaused = false
    /// Series whose batch could not start (e.g. the library folder was unreachable), with the reason.
    var startFailures: [String: String] = [:]
    /// The running download's web view, mounted off-screen so it has a real layout width for the PDF.
    var hiddenBrowser: WebPageCaptureModel?
    private(set) var current: LibraryChapterUpdate?
    private var task: Task<Void, Never>?

    var chapterCount: Int { updates.reduce(0) { $0 + $1.chapters.count } }

    // Batch totals are summed from each series' own download model.
    var total: Int { queue.reduce(0) { $0 + $1.chapters.count } }
    var completed: Int { queue.reduce(0) { $0 + (startFailures[$1.id] != nil ? $1.chapters.count : $1.model.completed) } }
    var succeeded: Int { queue.reduce(0) { $0 + $1.model.succeeded } }
    var failed: Int { queue.reduce(0) { $0 + (startFailures[$1.id] != nil ? $1.chapters.count : $1.model.failed) } }
    var currentChapterID: String? { current?.model.currentChapterID }

    /// Loads each candidate's chapter list (dates and "new" badges included) and keeps the unsaved newer chapters.
    /// `verify` receives the browser while the website asks for verification, then `nil`.
    func collect(_ candidates: [Candidate], dataStore: WKWebsiteDataStore,
                 verify: (WebPageCaptureModel?) -> Void) async -> [String] {
        var found: [LibraryChapterUpdate] = []
        var issues: [String] = []
        for candidate in candidates {
            let label = candidate.isEnglish ? "\(candidate.book.title) (EN)" : candidate.book.title
            let model = WebsiteDownloadModel(url: candidate.page, dataStore: dataStore)
            model.loadList(book: candidate.book, isEnglish: candidate.isEnglish)
            var verifying = false
            while model.busy {
                if Task.isCancelled {
                    model.stop()
                    if verifying { verify(nil) }
                    return []
                }
                if model.browser.isVerificationRequired != verifying {
                    verifying.toggle()
                    verify(verifying ? model.browser : nil)
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
            if verifying { verify(nil) }
            guard !model.chapters.isEmpty, model.libraryChecked else {
                issues.append("\(label) — \(model.status)")
                continue
            }
            let missing = model.chapters.filter { chapter in
                guard model.saved[chapter.id] == nil, let number = chapter.number else { return false }
                return NSDecimalNumber(decimal: number).doubleValue > candidate.localLatest
            }
            if !missing.isEmpty {
                found.append(LibraryChapterUpdate(id: "\(candidate.page.absoluteString)|\(candidate.isEnglish)",
                                                  book: candidate.book, isEnglish: candidate.isEnglish,
                                                  model: model, chapters: missing))
            }
        }
        updates = found
        selected = []
        queue = []
        startFailures = [:]
        phase = .choosing
        showsUpdates = !found.isEmpty
        return issues
    }

    /// Downloads the missing chapters of the chosen series one after another.
    /// The list stays on screen with per-chapter results when the batch ends.
    func download(_ ids: Set<String>, context: ModelContext, onFinish: @escaping () async -> Void) {
        let chosen = updates.filter { ids.contains($0.id) }
        guard !chosen.isEmpty, phase == .choosing else { return }
        // Series that were not chosen are not downloaded; release their web views.
        for update in updates where !ids.contains(update.id) { update.model.stop() }
        queue = chosen
        startFailures = [:]
        isPaused = false
        phase = .downloading
        task = Task {
            for update in chosen {
                guard !Task.isCancelled else { break }
                let model = update.model
                model.selected = Set(update.chapters.map(\.id))
                current = update
                hiddenBrowser = model.browser
                // `download` freezes the web view width as the PDF width, so wait for layout.
                var attempts = 0
                while model.browser.webView.bounds.width <= 0 && attempts < 50 {
                    attempts += 1
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard !Task.isCancelled else { break }
                model.download(book: update.book, isEnglish: update.isEnglish, context: context)
                // A batch paused by the app going to the background resumes in `sceneChanged`.
                while model.busy || model.isPaused {
                    if Task.isCancelled { model.stop() }
                    try? await Task.sleep(for: .milliseconds(300))
                }
                if model.total == 0 && !Task.isCancelled {
                    startFailures[update.id] = model.status
                }
            }
            hiddenBrowser = nil
            current = nil
            isPaused = false
            phase = .finished
            await onFinish()
        }
    }

    func pause() {
        guard phase == .downloading, let current else { return }
        isPaused = true
        current.model.pause()
    }

    func resume(context: ModelContext) {
        guard phase == .downloading, let current, current.model.isPaused else { return }
        isPaused = false
        current.model.resume(book: current.book, isEnglish: current.isEnglish, context: context)
    }

    /// Stops the batch but keeps the results on screen.
    func stop() {
        task?.cancel()
        current?.model.stop()
    }

    func sceneChanged(_ phase: ScenePhase, context: ModelContext) {
        guard let current else { return }
        current.model.sceneChanged(phase)
        if phase == .active, !isPaused, current.model.isPaused {
            current.model.resume(book: current.book, isEnglish: current.isEnglish, context: context)
        }
    }

    /// Closes the list (before downloading, or after reviewing the results).
    func dismiss() {
        showsUpdates = false
        for update in updates { update.model.stop() }
        updates = []
        selected = []
        queue = []
        notes = []
        startFailures = [:]
        phase = .choosing
    }

    func cancel() {
        stop()
        dismiss()
        hiddenBrowser = nil
        current = nil
        isPaused = false
    }
}
