import Foundation
import SwiftData

extension ImportService {
    @MainActor
    func addSeries(_ draft: NewSeriesDraft, isSecret: Bool, modelContext: ModelContext) throws -> Book {
        let key = isSecret ? StorageKey.secretFolderBookmark : StorageKey.rootFolderBookmark
        guard let data = UserDefaults.standard.data(forKey: key) else {
            throw FileServiceError.bookmarkResolutionFailed
        }
        let (rootURL, _) = try LocalFileService.shared.resolveBookmark(data)
        guard rootURL.startAccessingSecurityScopedResource() else {
            throw FileServiceError.bookmarkResolutionFailed
        }
        defer { rootURL.stopAccessingSecurityScopedResource() }
        return try addSeries(draft, isSecret: isSecret, rootURL: rootURL, modelContext: modelContext)
    }

    /// Synchronous commit: scans cannot observe the folder before its metadata is ready.
    @MainActor
    func addSeries(_ draft: NewSeriesDraft, isSecret: Bool, rootURL: URL, modelContext: ModelContext) throws -> Book {
        guard draft.hasValidDetails else { throw NewSeriesError.invalidDetails }
        guard draft.isLinkValid else { throw NewSeriesError.invalidURL }
        let url = BookLinkKind.webURL(draft.trimmedURL)
        let folderName = draft.resolvedFolderName
        let folder = rootURL.appendingPathComponent(folderName, isDirectory: true)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: folder.path) else { throw NewSeriesError.folderExists }
        // Never merge with or overwrite an existing series directory.
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        let book = Book(title: draft.trimmedTitle, filename: folderName, filePath: folderName,
                        isSeries: true, folderName: folderName)
        book.isSecret = isSecret
        book.seriesURL = url?.absoluteString
        let note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
        book.seriesNote = note.isEmpty ? nil : note
        var inserted = false
        do {
            var metadata = BookSeriesData()
            metadata.title = book.title
            metadata.dateAdded = book.dateAdded
            metadata.note = book.seriesNote
            metadata.url = book.seriesURL
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try fm.createDirectory(at: BookDataService.seriesDataDirectory(in: folder), withIntermediateDirectories: false)
            try encoder.encode(metadata).write(to: BookDataService.dataFileURL(in: folder), options: .atomic)
            modelContext.insert(book)
            inserted = true
            try modelContext.save()
            return book
        } catch {
            if inserted { modelContext.delete(book) }
            try? fm.removeItem(at: folder)
            throw error
        }
    }
}
