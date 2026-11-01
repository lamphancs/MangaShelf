import SwiftUI
import SwiftData

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
        let existing = book[keyPath: kind.urlKeyPath]
        let initialURL = sharedURL?.absoluteString ?? existing ?? ""
        _urlInput = State(initialValue: initialURL)
        let suggestion = CaptureFileName.chapterSuggestion(url: URL(string: initialURL), title: pageTitle)
        let inferred = suggestion == "Chapter" ? "" : String(suggestion.dropFirst("Chapter ".count))
        _numberInput = State(initialValue: sharedURL == nil ? (book[keyPath: kind.numberKeyPath] ?? inferred) : inferred)
    }

    private var trimmedURL: String { urlInput.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedNumber: String { numberInput.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool {
        trimmedURL.isEmpty || (BookLinkKind.webURL(trimmedURL) != nil && (!kind.isLatestChapter || !trimmedNumber.isEmpty))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(kind.sectionTitle) {
                    TextField("example.com/series/...", text: $urlInput)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if kind.isLatestChapter {
                        TextField("Chapter number", text: $numberInput)
                            .keyboardType(.decimalPad)
                    }
                }
                if !trimmedURL.isEmpty && BookLinkKind.webURL(trimmedURL) == nil {
                    Text("Enter a valid website address, such as example.com/series.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if let existing = book[keyPath: kind.urlKeyPath], !existing.isEmpty {
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
            guard kind.isLatestChapter else { return }
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
        let oldURL = book[keyPath: kind.urlKeyPath]
        let oldNumber = book[keyPath: kind.numberKeyPath]
        let value = remove || trimmedURL.isEmpty ? nil : BookLinkKind.webURL(trimmedURL)?.absoluteString
        book[keyPath: kind.urlKeyPath] = value
        if kind.isLatestChapter {
            book[keyPath: kind.numberKeyPath] = value == nil ? nil : trimmedNumber
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
            book[keyPath: kind.urlKeyPath] = oldURL
            if kind.isLatestChapter { book[keyPath: kind.numberKeyPath] = oldNumber }
            saveError = error.localizedDescription
        }
    }
}
