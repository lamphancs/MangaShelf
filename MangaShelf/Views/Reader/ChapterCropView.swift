import SwiftUI

/// Edits the saved selection against the media bounds still present in the chapter PDF.
struct ChapterCropView: View {
    let pdfURL: URL
    let title: String
    let onSave: (Data) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var theme
    @State private var document: WebCaptureDocument?
    @State private var loadFailed = false
    @State private var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var savedCrop = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var overview = true
    @State private var isSaving = false
    @State private var showReplaceConfirmation = false
    @State private var errorMessage: String?

    private var isFullChapter: Bool {
        crop == CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    if let document {
                        FullPageCropView(document: document, crop: $crop, overview: overview)
                            .allowsHitTesting(!isSaving)
                    } else if loadFailed {
                        Label("This PDF can't be cropped.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                    if isSaving {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Saving PDF…")
                                .font(.subheadline)
                        }
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if document != nil {
                    controls
                }
            }
            .background(theme.libraryBackground)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { showReplaceConfirmation = true }
                        .fontWeight(.semibold)
                        .disabled(document == nil || crop == savedCrop || isSaving)
                }
            }
        }
        .tint(theme.accent)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(isSaving)
        .task {
            let url = pdfURL
            do {
                let source = try await Task.detached(priority: .userInitiated) {
                    let document = try WebCaptureDocument(data: Data(contentsOf: url))
                    return (document: document, crop: try document.existingChapterCrop())
                }.value
                crop = source.crop
                savedCrop = source.crop
                document = source.document
            } catch {
                loadFailed = true
            }
        }
        .confirmationDialog("Replace this chapter's PDF with the cropped version?",
                            isPresented: $showReplaceConfirmation, titleVisibility: .visible) {
            Button("Crop Chapter", role: .destructive) { save() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The chapter PDF will show the selected area. Hidden areas on retained pages can be edited again. Entire pages outside the selection are removed.")
        }
        .alert("Crop", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach([true, false], id: \.self) { isOverview in
                    Button { overview = isOverview } label: {
                        Text(isOverview ? "Overview" : "Detail")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(overview == isOverview ? theme.cardBackground : .clear,
                                        in: RoundedRectangle(cornerRadius: 10))
                    }
                    .foregroundStyle(overview == isOverview ? .primary : .secondary)
                    .accessibilityAddTraits(overview == isOverview ? .isSelected : [])
                }
            }
            .padding(4)
            .background(theme.libraryBackground, in: RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Preview mode")

            Button {
                crop = CGRect(x: 0, y: 0, width: 1, height: 1)
            } label: {
                Text("Full Chapter")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 52)
                    .background(theme.libraryBackground, in: RoundedRectangle(cornerRadius: 14))
            }
            .foregroundStyle(theme.accent)
            .disabled(isFullChapter)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background(theme.cardBackground)
        .overlay(alignment: .top) { Divider() }
        .disabled(isSaving)
    }

    private func save() {
        guard let document, !isSaving else { return }
        let selection = crop
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try document.croppedChapterPDF(crop: selection)
                }.value
                try await onSave(data)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
