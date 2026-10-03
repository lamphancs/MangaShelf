import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct AddSeriesView: View {
    let isSecret: Bool
    let onCreated: (Book, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(ThemeManager.self) private var theme
    @State private var draft = NewSeriesDraft()
    @State private var linkStep = false
    @State private var showFolderPicker = false
    @State private var folderReady = false
    @State private var errorMessage: String?

    private var bookmarkKey: String {
        isSecret ? StorageKey.secretFolderBookmark : StorageKey.rootFolderBookmark
    }

    var body: some View {
        NavigationStack {
            Form {
                if linkStep {
                    Section {
                        TextField("https://... (optional)", text: $draft.url)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: {
                        Text("Optional series link · Step 2 of 2")
                    } footer: {
                        Text("Done creates the series and its folder. Browse also opens Browse & Capture at your link, or Google if you leave it empty. You can save the series link from the browser later.")
                    }
                    Section("Summary") {
                        LabeledContent("Title", value: draft.trimmedTitle)
                        LabeledContent("Folder", value: draft.resolvedFolderName)
                        LabeledContent("Library", value: isSecret ? "Secret Shelf" : "Library")
                    }
                    Section {
                        Button("Done") { createSeries(browse: false) }
                        Button("Browse") { createSeries(browse: true) }
                    }
                    .disabled(!draft.linkIsValid)
                    if !draft.linkIsValid {
                        Text("Enter a valid http or https link, or leave it empty.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } else {
                    Section("Series details · Step 1 of 2") {
                        TextField("Title (required)", text: $draft.title)
                        TextField("Folder name (defaults to title)", text: $draft.folderName)
                            .autocorrectionDisabled()
                        TextField("Note (optional)", text: $draft.note, axis: .vertical)
                            .lineLimit(3...6)
                    }
                    Section {
                        LabeledContent("New folder", value: draft.resolvedFolderName)
                        if !folderReady {
                            Button("Choose Library Folder") { showFolderPicker = true }
                        }
                    } footer: {
                        Text(folderReady
                             ? "The new folder will be created inside your selected library folder. Folder names cannot start with a dot or contain / or :."
                             : "Choose the parent folder where your library is stored before continuing.")
                    }
                    Button("Next") { linkStep = true }
                        .disabled(!draft.detailsAreValid || !folderReady)
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.libraryBackground)
            .navigationTitle("Add Series")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if linkStep {
                        Button("Back") { linkStep = false }
                    } else {
                        Button("Cancel") { dismiss() }
                    }
                }
                if linkStep {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
        .tint(theme.accent)
        .preferredColorScheme(.dark)
        .onAppear { folderReady = UserDefaults.standard.data(forKey: bookmarkKey) != nil }
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
            do {
                let url = try result.get()
                guard url.startAccessingSecurityScopedResource() else {
                    throw FileServiceError.bookmarkResolutionFailed
                }
                defer { url.stopAccessingSecurityScopedResource() }
                let data = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                UserDefaults.standard.set(data, forKey: bookmarkKey)
                folderReady = true
            } catch { errorMessage = error.localizedDescription }
        }
        .alert("Couldn’t Add Series", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: { Text(errorMessage ?? "") }
    }

    private func createSeries(browse: Bool) {
        do {
            let book = try ImportService().addSeries(draft, isSecret: isSecret, modelContext: modelContext)
            onCreated(book, browse)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct AddSeriesTile: View {
    let isGrid: Bool
    let action: () -> Void
    @Environment(ThemeManager.self) private var theme

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.system(size: isGrid ? 44 : 28, weight: .light))
                Text("Add Series")
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(theme.accent)
            .frame(maxWidth: .infinity)
            .frame(height: isGrid ? 302 : 104)
            .background(theme.cardBackground, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(theme.accent.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add new series")
    }
}
