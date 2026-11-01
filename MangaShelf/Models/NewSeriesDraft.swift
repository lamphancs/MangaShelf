import Foundation

struct NewSeriesDraft {
    var title = ""
    var folderName = ""
    var note = ""
    var url = ""

    var trimmedURL: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isLinkValid: Bool { trimmedURL.isEmpty || BookLinkKind.webURL(trimmedURL) != nil }
    static let defaultBrowseURL = URL(string: "https://www.google.com")!

    var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    var resolvedFolderName: String {
        let value = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? trimmedTitle : value
    }
    var hasValidDetails: Bool {
        !trimmedTitle.isEmpty && Self.isValidFolderName(resolvedFolderName)
    }

    /// Folder names must be non-empty, visible (no leading dot), and a single path component.
    static func isValidFolderName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".")
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
