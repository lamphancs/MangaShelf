import Foundation
import SwiftData

struct NewSeriesDraft {
    var title = ""
    var folderName = ""
    var note = ""
    var url = ""

    var trimmedURL: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }
    var linkIsValid: Bool { trimmedURL.isEmpty || BookLinkKind.webURL(trimmedURL) != nil }
    static let defaultBrowseURL = URL(string: "https://www.google.com")!

    var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    var resolvedFolderName: String {
        let value = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? trimmedTitle : value
    }
    var detailsAreValid: Bool {
        let name = resolvedFolderName
        return !trimmedTitle.isEmpty && !name.isEmpty && !name.hasPrefix(".")
            && !name.contains("/") && !name.contains(":")
            && name.rangeOfCharacter(from: .controlCharacters) == nil
    }
}

enum NewSeriesError: LocalizedError {
    case invalidDetails, invalidURL, folderExists

    var errorDescription: String? {
        switch self {
        case .invalidDetails: return "Enter a title and a folder name without /, :, control characters, or a leading dot."
        case .invalidURL: return "Enter a valid http or https series link."
        case .folderExists: return "This folder already exists. Choose a different folder name."
        }
    }
}

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
        guard draft.detailsAreValid else { throw NewSeriesError.invalidDetails }
        guard draft.linkIsValid else { throw NewSeriesError.invalidURL }
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
