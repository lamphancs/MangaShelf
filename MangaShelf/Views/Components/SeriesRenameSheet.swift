import SwiftUI
import SwiftData

/// Edits a series' display title and its folder name on disk.
struct SeriesRenameSheet: View {
    let book: Book
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(ThemeManager.self) private var theme
    @State private var titleInput: String
    @State private var folderInput: String
    @State private var isSaving = false
    @State private var saveError: String?

    init(book: Book) {
        self.book = book
        _titleInput = State(initialValue: book.title)
        _folderInput = State(initialValue: book.folderName ?? "")
    }

    private var trimmedTitle: String { titleInput.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedFolder: String { folderInput.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var folderIsValid: Bool { NewSeriesDraft.isValidFolderName(trimmedFolder) }
    private var hasChanges: Bool { trimmedTitle != book.title || trimmedFolder != book.folderName }
    private var canSave: Bool { !trimmedTitle.isEmpty && folderIsValid && hasChanges }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Title", text: $titleInput)
                }
                Section {
                    TextField("Folder name", text: $folderInput)
                        .autocorrectionDisabled()
                    Button("Use Title as Folder Name") { folderInput = trimmedTitle }
                        .disabled(trimmedTitle.isEmpty || trimmedTitle == trimmedFolder)
                } header: {
                    Text("Folder")
                } footer: {
                    if !trimmedFolder.isEmpty && !folderIsValid {
                        Text("Folder names cannot start with a dot or contain / or :.")
                            .foregroundStyle(.red)
                    } else {
                        Text("Renames the series folder in your library. Chapters, progress, bookmarks, notes, and the cover move with it.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.libraryBackground)
            .navigationTitle("Rename Series")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { save() }
                            .disabled(!canSave)
                    }
                }
            }
            .disabled(isSaving)
        }
        .interactiveDismissDisabled(isSaving)
        .tint(theme.accent)
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
        .alert("Couldn’t Rename Series", isPresented: Binding(
            get: { saveError != nil }, set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: { Text(saveError ?? "") }
    }

    private func save() {
        isSaving = true
        Task {
            do {
                try await ImportService().renameSeries(
                    book, title: trimmedTitle, folderName: trimmedFolder, modelContext: modelContext
                )
                dismiss()
            } catch {
                saveError = error.localizedDescription
            }
            isSaving = false
        }
    }
}
