import SwiftUI
import SwiftData
import UIKit

@main
struct AddSeriesSmokeApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Add series smoke checks")
                .task {
                    let result: String
                    do { result = try await runChecks() }
                    catch { result = "FAIL: \(error)" }
                    let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("result.txt")
                    try? result.write(to: file, atomically: true, encoding: .utf8)
                }
        }
    }

    @MainActor
    private func runChecks() async throws -> String {
        let container = try ModelContainer(for: Book.self, Chapter.self, Bookmark.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ImportService()
        let draft = NewSeriesDraft(title: " My Manga ", folderName: "My Folder", note: " A note ", url: "https://example.com/manga")
        let book = try service.addSeries(draft, isSecret: true, rootURL: root, modelContext: context)
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: message, code: 1) }
        }
        try check(book.isSeries && book.isSecret && book.title == "My Manga", "Book fields")
        try check(book.sortedChapters.isEmpty, "Initially no chapters")
        let folder = root.appendingPathComponent("My Folder")
        let metadata = await BookDataService.shared.load(seriesFolderURL: folder)
        try check(metadata?.title == "My Manga" && metadata?.note == "A note" && metadata?.url == draft.url, "Portable metadata")
        do {
            _ = try service.addSeries(draft, isSecret: true, rootURL: root, modelContext: context)
            throw NSError(domain: "Duplicate accepted", code: 1)
        } catch NewSeriesError.folderExists { }
        for name in ["../escape", ".hidden", "a/b", "a:b", "a\nline"] {
            var invalid = draft
            invalid.folderName = name
            try check(!invalid.detailsAreValid, "Unsafe folder accepted")
        }
        var invalid = draft
        invalid.folderName = "Invalid Link"
        invalid.url = "file:///tmp/test"
        do {
            _ = try service.addSeries(invalid, isSecret: false, rootURL: root, modelContext: context)
            throw NSError(domain: "Invalid URL accepted", code: 1)
        } catch NewSeriesError.invalidURL { }
        try check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Invalid Link").path), "Invalid input created folder")
        // Use a bookmark in this isolated test app to exercise the production scanner.
        let key = StorageKey.secretFolderBookmark
        UserDefaults.standard.set(try root.bookmarkData(options: .minimalBookmark), forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        _ = try await service.scanSecretFolder(modelContext: context, force: true)
        try check(try context.fetch(FetchDescriptor<Book>()).count == 1, "Empty series survives scan")
        context.delete(book)
        try context.save()
        _ = try await service.scanSecretFolder(modelContext: context, force: true)
        let restored = try context.fetch(FetchDescriptor<Book>())
        try check(restored.count == 1 && restored.first?.title == "My Manga" && restored.first?.seriesURL == draft.url,
                  "Empty series restored from disk")
        // Creating without a URL must not persist the browser's Google fallback.
        let offline = try service.addSeries(
            NewSeriesDraft(title: "Offline Manga", note: "No URL yet", url: "  "),
            isSecret: true, rootURL: root, modelContext: context)
        try check(offline.seriesURL == nil, "Optional URL remains nil")
        let offlineFolder = root.appendingPathComponent("Offline Manga")
        await BookDataService.shared.save(book: offline, seriesFolderURL: offlineFolder)
        let offlineMetadata = await BookDataService.shared.load(seriesFolderURL: offlineFolder)
        try check(offlineMetadata?.title == "Offline Manga" && offlineMetadata?.url == nil,
                  "Normal save preserves title matching folder and nil URL")
        let renamedOffline = root.appendingPathComponent("Renamed Offline")
        try FileManager.default.moveItem(at: offlineFolder, to: renamedOffline)
        _ = try await service.scanSecretFolder(modelContext: context, force: true)
        let offlineRestored = try context.fetch(FetchDescriptor<Book>()).first { $0.folderName == "Renamed Offline" }
        try check(offlineRestored?.title == "Offline Manga" && offlineRestored?.seriesNote == "No URL yet"
                  && offlineRestored?.seriesURL == nil, "No-URL series survives folder rename")

        // Exercise a real move out/in with all portable reading metadata and cover/art.
        let pageBounds = CGRect(x: 0, y: 0, width: 100, height: 150)
        let pdf = UIGraphicsPDFRenderer(bounds: pageBounds).pdfData { renderer in
            for _ in 0..<3 { renderer.beginPage() }
        }
        for name in ["Chapter 1.pdf", "Chapter 2.pdf"] {
            try pdf.write(to: folder.appendingPathComponent(name))
        }
        _ = try await service.scanSecretFolder(modelContext: context, force: true)
        let rich = try context.fetch(FetchDescriptor<Book>()).first { $0.folderName == "My Folder" }!
        rich.currentChapterIndex = 1
        rich.lastReadDate = Date(timeIntervalSince1970: 1_700_000_000)
        rich.latestChapterURL = "https://example.com/manga/42"
        rich.latestChapterNumber = "42"
        rich.englishSeriesURL = "https://example.com/en/manga"
        let addedDate = rich.dateAdded
        rich.sortedChapters[1].lastReadPage = 2
        rich.sortedChapters[1].lastReadOffset = 123.5
        let bookmark = Bookmark(chapterIndex: 1, note: "Remember this", colorName: "blue")
        bookmark.book = rich
        context.insert(bookmark)
        try context.save()
        await BookDataService.shared.save(book: rich, seriesFolderURL: folder)
        let cover = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 60)).image { renderer in
            UIColor.red.setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: 40, height: 60))
        }.jpegData(compressionQuality: 0.9)!
        let savedCover = await BookDataService.shared.saveCoverImage(jpegData: cover, seriesFolderURL: folder)
        try check(savedCover, "Portable cover saved")
        let artFolder = folder.appendingPathComponent("Art")
        try FileManager.default.createDirectory(at: artFolder, withIntermediateDirectories: false)
        try cover.write(to: artFolder.appendingPathComponent("art.jpg"))
        let parked = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parked) }
        try FileManager.default.moveItem(at: folder, to: parked)
        _ = try await service.scanSecretFolder(modelContext: context, force: true)
        try check(try context.fetch(FetchDescriptor<Book>()).allSatisfy { $0.folderName != "My Folder" }, "Moved-out row removed")
        let returnedFolder = root.appendingPathComponent("Returned Manga")
        try FileManager.default.moveItem(at: parked, to: returnedFolder)
        _ = try await service.scanSecretFolder(modelContext: context, force: true)
        let returned = try context.fetch(FetchDescriptor<Book>()).first { $0.folderName == "Returned Manga" }!
        try check(returned.title == "My Manga" && returned.seriesNote == "A note" && returned.seriesURL == draft.url,
                  "Moved series identity restored")
        try check(abs(returned.dateAdded.timeIntervalSince(addedDate)) < 1
                  && returned.lastReadDate == Date(timeIntervalSince1970: 1_700_000_000), "Dates restored")
        try check(returned.latestChapterNumber == "42" && returned.latestChapterURL == "https://example.com/manga/42",
                  "Latest chapter restored")
        try check(returned.englishSeriesURL == "https://example.com/en/manga", "English version link restored")
        try check(returned.currentChapterIndex == 1 && returned.sortedChapters[1].lastReadPage == 2
                  && returned.sortedChapters[1].lastReadOffset == 123.5 && returned.totalPages == 6, "Reading state restored")
        try check(returned.sortedBookmarks.first?.note == "Remember this"
                  && returned.sortedBookmarks.first?.colorName == "blue", "Bookmarks restored")
        try check(returned.hasManualCover && returned.thumbnailPath != nil, "Cover restored")
        try check(try Data(contentsOf: returnedFolder.appendingPathComponent("Art/art.jpg")) == cover, "Art preserved")
        try check(!ImportService.hasEnglishFolder(in: returnedFolder), "Missing EN folder disables language switch")
        let englishFolder = returnedFolder.appendingPathComponent("EN")
        try Data().write(to: englishFolder)
        try check(!ImportService.hasEnglishFolder(in: returnedFolder), "EN file is not a directory")
        try FileManager.default.removeItem(at: englishFolder)
        try FileManager.default.createDirectory(at: englishFolder, withIntermediateDirectories: false)
        try check(ImportService.hasEnglishFolder(in: returnedFolder), "Empty EN folder enables switch")
        for name in ["Chapter 10.pdf", "Chapter 2.pdf"] {
            try pdf.write(to: englishFolder.appendingPathComponent(name))
        }
        _ = try await service.scanSecretFolder(modelContext: context)
        try check(returned.sortedChapters.map(\.filename) == [
            "Chapter 1.pdf", "Chapter 2.pdf", "EN/Chapter 2.pdf", "EN/Chapter 10.pdf"
        ], "Both languages scan in natural order without filename collisions")
        let english = returned.sortedChapters[2]
        try check(english.displayName == "Chapter 2" && english.isEnglish, "EN display name")
        returned.currentChapterIndex = 2
        let reader = ReaderViewModel(book: returned)
        try check(reader.sortedChapters.count == 2 && reader.sortedChapters.allSatisfy(\.isEnglish)
                  && reader.currentChapterIndex == 0, "Reader navigation stays in EN")
        reader.saveBookmark(note: "English bookmark", color: .red, modelContext: context)
        try check(returned.bookmarks?.contains { $0.chapterIndex == 2 && $0.note == "English bookmark" } == true,
                  "Reader maps EN bookmarks to stored chapter identity")
        reader.currentPage = 1
        reader.saveProgress(modelContext: context)
        try check(returned.currentChapterIndex == 2 && english.lastReadPage == 1
                  && returned.sortedChapters[1].lastReadPage == 2, "Language progress stays separate")
        try pdf.write(to: returnedFolder.appendingPathComponent("Chapter 0.pdf"))
        _ = try await service.scanSecretFolder(modelContext: context, force: true)
        try check(returned.sortedChapters[returned.currentChapterIndex].filename == "EN/Chapter 2.pdf",
                  "Rescan preserves current EN chapter when VN indices shift")
        try check(returned.bookmarks?.contains {
            $0.note == "English bookmark" && returned.sortedChapters[$0.chapterIndex].filename == "EN/Chapter 2.pdf"
        } == true, "Rescan preserves EN bookmark identity")
        try pdf.write(to: englishFolder.appendingPathComponent("Chapter 3.pdf"))
        _ = try await service.scanSecretFolder(modelContext: context)
        try check(returned.sortedChapters.contains { $0.filename == "EN/Chapter 3.pdf" },
                  "EN folder changes invalidate scan signature")
        await BookDataService.shared.save(book: returned, seriesFolderURL: returnedFolder)
        let bilingualData = await BookDataService.shared.load(seriesFolderURL: returnedFolder)
        try check(bilingualData?.chapterProgress["EN/Chapter 2.pdf"] == 1
                  && bilingualData?.chapterProgress["Chapter 2.pdf"] == 2, "Portable progress uses distinct language paths")
        try FileManager.default.removeItem(at: englishFolder)
        _ = try await service.scanSecretFolder(modelContext: context, force: true)
        try check(!ImportService.hasEnglishFolder(in: returnedFolder)
                  && returned.sortedChapters.allSatisfy { !$0.isEnglish }, "Removing EN folder removes EN chapters")
        return "PASS: series creation, metadata round-trip, VN/EN discovery, natural sort, reader language isolation, separate progress/bookmarks, rescan identity and EN removal"
    }
}
