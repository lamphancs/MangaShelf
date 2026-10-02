import SwiftUI
import SwiftData
import WebKit

struct WebPageCaptureView: View {
    let url: URL
    let book: Book
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(ThemeManager.self) private var theme
    @State private var model: WebPageCaptureModel
    @State private var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var overview = true
    @State private var isExporting = false
    @State private var exportTask: Task<Void, Never>?
    @State private var sharedFile: CaptureShareFile?
    @State private var temporaryFile: URL?
    @State private var saved = false
    @State private var showFilenamePrompt = false
    @State private var filenameInput = ""
    @State private var pendingSaveToSeries = true
    @State private var savedDescription: String?

    init(url: URL, book: Book) {
        self.url = url
        self.book = book
        _model = State(initialValue: WebPageCaptureModel(isPrivate: book.isSecret))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    CaptureWebView(webView: model.webView)
                        .allowsHitTesting(!model.isCapturing && model.document == nil)
                    if let document = model.document {
                        FullPageCropView(document: document, crop: $crop, overview: overview)
                            .background(theme.libraryBackground)
                            .allowsHitTesting(!isExporting)
                    }
                    if (model.isLoading && !model.canCapture && !model.isVerificationRequired) || model.isCapturing || isExporting {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text(isExporting ? "Preparing PDF…" : model.status)
                                .font(.subheadline)
                            if model.isCapturing {
                                Button("Stop Loading") { model.cancelCapture() }
                            }
                        }
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
                if model.document != nil {
                    cropControls
                } else {
                    if model.isVerificationRequired {
                        Text("Complete the website verification above. If it keeps repeating, open this page in your browser and capture it there.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    }
                    HStack(spacing: 20) {
                        Button { model.goBack() } label: {
                            Image(systemName: "chevron.left")
                        }
                        .accessibilityLabel("Back")
                        .disabled(!model.canGoBack || model.isCapturing)
                        Button { model.goForward() } label: {
                            Image(systemName: "chevron.right")
                        }
                        .accessibilityLabel("Forward")
                        .disabled(!model.canGoForward || model.isCapturing)
                        Button { model.reload() } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("Reload current page")
                        .disabled(model.isCapturing)
                        Button { openURL(model.currentURL ?? url) } label: {
                            Image(systemName: "safari")
                        }
                        .accessibilityLabel("Open in Browser")
                        .disabled(model.isCapturing)
                        Spacer()
                        Button { model.capture(loadEntirePage: true) } label: {
                            Label("Capture", systemImage: "camera")
                        }
                        .disabled(!model.canCapture || model.isCapturing)
                    }
                    .padding()
                }
            }
            .background(theme.libraryBackground)
            .navigationTitle(model.document == nil ? (model.currentURL?.host ?? url.host ?? "Web Page") : "Full Page Capture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .disabled(isExporting)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if model.document != nil {
                        Button("Back to Page") {
                            model.returnToPage()
                            crop = CGRect(x: 0, y: 0, width: 1, height: 1)
                            saved = false
                            savedDescription = nil
                            filenameInput = ""
                            overview = true
                        }
                        .disabled(isExporting)
                    }
                }
            }
        }
        .tint(theme.accent)
        .preferredColorScheme(.dark)
        .task { model.load(url) }
        .onDisappear {
            model.close()
            exportTask?.cancel()
            removeTemporaryFile()
        }
        .alert("Capture", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("PDF File Name", isPresented: $showFilenamePrompt) {
            TextField(model.suggestedFilename, text: $filenameInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) { }
            Button(pendingSaveToSeries ? "Save" : "Share") {
                guard let filename = try? CaptureFileName.filename(filenameInput) else { return }
                export(saveToSeries: pendingSaveToSeries, filename: filename)
            }
            .disabled((try? CaptureFileName.filename(filenameInput)) == nil)
        } message: {
            Text("The .pdf extension is added automatically. Existing files are kept; duplicate names receive a number.")
        }
        .sheet(item: $sharedFile, onDismiss: removeTemporaryFile) { file in
            CaptureShareSheet(url: file.url)
        }
    }

    private var cropControls: some View {
        VStack(spacing: 12) {
            if let warning = model.captureWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text("Drag the corners to crop. Scroll in Detail to reach any part of the page.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Picker("Preview", selection: $overview) {
                    Text("Overview").tag(true)
                    Text("Detail").tag(false)
                }
                .pickerStyle(.segmented)
                Button("Full Page") {
                    crop = CGRect(x: 0, y: 0, width: 1, height: 1)
                    saved = false
                }
            }
            HStack {
                Button { requestExport(saveToSeries: false) } label: {
                    Label("Share PDF", systemImage: "square.and.arrow.up")
                }
                Spacer()
                if book.isSeries {
                    Button { requestExport(saveToSeries: true) } label: {
                        Label(saved ? "Saved to Chapters" : "Save PDF", systemImage: saved ? "checkmark" : "doc.badge.plus")
                    }
                    .disabled(saved)
                }
            }
            if let savedDescription {
                Text(savedDescription).font(.caption).foregroundStyle(.secondary)
            }
            Text("PDF export keeps the captured source quality. Detail renders each visible region directly from the PDF.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .disabled(isExporting)
        .onChange(of: crop) { _, _ in saved = false; savedDescription = nil }
    }

    private func requestExport(saveToSeries: Bool) {
        pendingSaveToSeries = saveToSeries
        if filenameInput.isEmpty { filenameInput = model.suggestedFilename }
        showFilenamePrompt = true
    }

    private func export(saveToSeries: Bool, filename: String) {
        guard let document = model.document, !isExporting else { return }
        let selection = crop
        isExporting = true
        exportTask = Task {
            defer { isExporting = false }
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try document.exportPDF(crop: selection)
                }.value
                try Task.checkCancellation()
                if saveToSeries {
                    let target = try await ImportService().saveCapturedChapter(data, for: book, filename: filename, modelContext: modelContext)
                    savedDescription = "\(target.lastPathComponent) · \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))"
                    saved = true
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } else {
                    removeTemporaryFile()
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("capture_\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let target = folder.appendingPathComponent(filename)
                    temporaryFile = target
                    try await Task.detached(priority: .userInitiated) { try data.write(to: target, options: .atomic) }.value
                    if Task.isCancelled {
                        removeTemporaryFile()
                        return
                    }
                    temporaryFile = target
                    sharedFile = CaptureShareFile(url: target)
                }
            } catch is CancellationError {
            } catch {
                if !saveToSeries { removeTemporaryFile() }
                model.errorMessage = error.localizedDescription
            }
        }
    }

    private func removeTemporaryFile() {
        if let temporaryFile { try? FileManager.default.removeItem(at: temporaryFile.deletingLastPathComponent()) }
        temporaryFile = nil
    }
}

private struct CaptureWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

private struct CaptureShareFile: Identifiable {
    let id = UUID()
    let url: URL
}

private struct CaptureShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
