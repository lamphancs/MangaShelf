import SwiftUI
import SwiftData

struct SeriesNoteEditorSheet: View {
    let book: Book
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(ThemeManager.self) private var theme
    @State private var text: String
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var contentHeight: CGFloat = 240

    init(book: Book) {
        self.book = book
        _text = State(initialValue: book.seriesNote ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack {
                    Button("Cancel") { dismiss() }
                        .frame(minHeight: 44)
                    Spacer()
                    Button("Save") {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        save(trimmed.isEmpty ? nil : trimmed)
                    }
                    .fontWeight(.semibold)
                    .frame(minHeight: 44)
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Note")
                        .font(.title2.bold())
                    Text(book.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 8)

                TextField("Write a note…", text: $text, axis: .vertical)
                    .font(.body)
                    .lineLimit(1...6)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                    .accessibilityLabel("Note")

                VStack(spacing: 0) {
                    Divider()
                    HStack {
                        Text("Changes are saved when you tap Save.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        if !(book.seriesNote ?? "").isEmpty {
                            Button(role: .destructive) { save(nil) } label: {
                                Image(systemName: "trash")
                                    .frame(width: 44, height: 44)
                            }
                            .accessibilityLabel("Remove note")
                        }
                    }
                    .frame(minHeight: 44)
                }
                .padding(.horizontal, 24)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(theme.libraryBackground)
        .tint(theme.accent)
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
        .presentationDetents([.height(min(360, contentHeight))])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
        .alert("Couldn’t Save Note", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    private func save(_ value: String?) {
        let previousNote = book.seriesNote
        book.seriesNote = value
        do {
            try modelContext.save()
            isSaving = true
            Task {
                await BookDataService.shared.save(book: book)
                dismiss()
            }
        } catch {
            book.seriesNote = previousNote
            saveError = error.localizedDescription
        }
    }
}
