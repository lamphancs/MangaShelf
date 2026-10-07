import SwiftUI

/// Shared color and note editor for chapter bookmarks.
struct BookmarkEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var theme

    let title: String
    let chapterTitle: String?
    @Binding var bookmarkNote: String
    @Binding var bookmarkColor: BookmarkColor
    let onSave: () -> Void
    /// When provided, the sheet shows a destructive "Delete Bookmark" action.
    var onDelete: (() -> Void)? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section("Color") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 36))], spacing: 12) {
                        ForEach(BookmarkColor.allCases, id: \.rawValue) { color in
                            Circle()
                                .fill(color.color)
                                .frame(width: 32, height: 32)
                                .overlay {
                                    if bookmarkColor == color {
                                        Image(systemName: "checkmark")
                                            .font(.caption)
                                            .fontWeight(.bold)
                                            .foregroundColor(.white)
                                    }
                                }
                                .onTapGesture {
                                    bookmarkColor = color
                                }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Note (optional)") {
                    TextField("e.g. Fight scene, Plot twist...", text: $bookmarkNote)
                }

                if let chapterTitle {
                    Section {
                        Text(chapterTitle)
                            .foregroundColor(.secondaryText)
                    } header: {
                        Text("Chapter")
                    }
                }

                if let onDelete {
                    Section {
                        Button(role: .destructive) {
                            onDelete()
                            dismiss()
                        } label: {
                            Label("Delete Bookmark", systemImage: "bookmark.slash")
                                .foregroundColor(.red)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.libraryBackground)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(.secondaryText)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        onSave()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundColor(theme.accent)
                }
            }
        }
        .presentationDetents([.medium])
        .preferredColorScheme(.dark)
    }

}
