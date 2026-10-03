import SwiftUI
import SwiftData

enum BookLinkKind: String, Identifiable {
    case series, latestChapter
    var id: String { rawValue }
    var title: String { self == .series ? "Series Link" : "Latest Chapter Link" }
    var addLabel: String { self == .series ? "Add series link" : "Add latest chapter link" }

    nonisolated static func webURL(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isWhitespace }),
              let url = URL(string: trimmed),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}

struct BookLinkEditorSheet: View {
    let book: Book
    let kind: BookLinkKind
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(ThemeManager.self) private var theme
    @State private var urlInput: String
    @State private var numberInput: String
    @State private var isSaving = false
    @State private var saveError: String?

    init(book: Book, kind: BookLinkKind, sharedURL: URL? = nil, pageTitle: String? = nil) {
        self.book = book
        self.kind = kind
        let existing = kind == .series ? book.seriesURL : book.latestChapterURL
        let initialURL = sharedURL?.absoluteString ?? existing ?? ""
        _urlInput = State(initialValue: initialURL)
        let suggestion = CaptureFileName.chapterSuggestion(url: URL(string: initialURL), title: pageTitle)
        let inferred = suggestion == "Chapter" ? "" : String(suggestion.dropFirst("Chapter ".count))
        _numberInput = State(initialValue: sharedURL == nil ? (book.latestChapterNumber ?? inferred) : inferred)
    }

    private var trimmedURL: String { urlInput.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedNumber: String { numberInput.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool {
        trimmedURL.isEmpty || (BookLinkKind.webURL(trimmedURL) != nil && (kind == .series || !trimmedNumber.isEmpty))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(kind == .series ? "Series table of contents" : "Latest chapter") {
                    TextField("https://...", text: $urlInput)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if kind == .latestChapter {
                        TextField("Chapter number", text: $numberInput)
                            .keyboardType(.decimalPad)
                    }
                }
                if !trimmedURL.isEmpty && BookLinkKind.webURL(trimmedURL) == nil {
                    Text("Enter a valid http or https link.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if let existing = kind == .series ? book.seriesURL : book.latestChapterURL, !existing.isEmpty {
                    Section {
                        Button("Remove Link", role: .destructive) { save(remove: true) }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.libraryBackground)
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save(remove: false) }
                        .disabled(!canSave)
                }
            }
            .disabled(isSaving)
        }
        .interactiveDismissDisabled(isSaving)
        .tint(theme.accent)
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
        .onChange(of: urlInput) { _, value in
            guard kind == .latestChapter else { return }
            let suggestion = CaptureFileName.chapterSuggestion(url: URL(string: value), title: nil)
            if suggestion != "Chapter" { numberInput = String(suggestion.dropFirst("Chapter ".count)) }
        }
        .alert("Couldn’t Save Link", isPresented: Binding(
            get: { saveError != nil }, set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: { Text(saveError ?? "") }
    }

    private func save(remove: Bool) {
        let oldURL = kind == .series ? book.seriesURL : book.latestChapterURL
        let oldNumber = book.latestChapterNumber
        let value = remove || trimmedURL.isEmpty ? nil : trimmedURL
        if kind == .series {
            book.seriesURL = value
        } else {
            book.latestChapterURL = value
            book.latestChapterNumber = value == nil ? nil : trimmedNumber
        }
        do {
            try modelContext.save()
            isSaving = true
            Task {
                await BookDataService.shared.save(book: book)
                isSaving = false
                dismiss()
            }
        } catch {
            if kind == .series { book.seriesURL = oldURL }
            else { book.latestChapterURL = oldURL; book.latestChapterNumber = oldNumber }
            saveError = error.localizedDescription
        }
    }
}
