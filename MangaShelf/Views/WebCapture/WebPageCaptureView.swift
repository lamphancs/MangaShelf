import SwiftUI
import SwiftData
import WebKit

struct WebPageCaptureView: View {
    let url: URL
    let book: Book
    let isEnglish: Bool
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(ThemeManager.self) private var theme
    @State private var model: WebPageCaptureModel
    @ScaledMetric(relativeTo: .body) private var exportButtonHeight = 56
    @ScaledMetric(relativeTo: .body) private var browserToolbarHeight = 44
    @ScaledMetric(relativeTo: .body) private var browserSideWidth = 56
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
    @State private var exportNotice: String?
    @State private var showSaveSuccess = false
    @State private var sharedLink: SharedBookLink?
    @State private var addressInput: String
    @FocusState private var isAddressFocused: Bool

    private struct SharedBookLink: Identifiable {
        let id = UUID()
        let kind: BookLinkKind
        let url: URL
        let title: String?
    }

    init(url: URL, book: Book, isEnglish: Bool = false) {
        self.url = url
        self.book = book
        self.isEnglish = isEnglish
        _addressInput = State(initialValue: url.absoluteString)
        _model = State(initialValue: WebPageCaptureModel(isPrivate: book.isSecret))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if model.document == nil {
                    browserToolbar
                }
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
                            Text(model.chapterTitle)
                                .font(.headline)
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
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            browserNavigationButtons
                            browserCaptureButton
                        }
                        VStack(spacing: 12) {
                            browserNavigationButtons
                            browserCaptureButton
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(theme.cardBackground)
                    .overlay(alignment: .top) { Divider() }
                }
            }
            .background(theme.libraryBackground)
            .navigationTitle(model.document == nil ? (model.currentURL?.host ?? url.host ?? "Web Page") : model.chapterTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(model.document == nil ? .hidden : .visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .disabled(isExporting)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if model.document == nil {
                        shareLinkMenu
                    } else {
                        Button("Back to Page") {
                            model.returnToPage()
                            resetPreview()
                        }
                        .disabled(isExporting)
                    }
                }
            }
        }
        .tint(theme.accent)
        .preferredColorScheme(.dark)
        .task { model.load(url) }
        .onChange(of: model.currentURL) { _, currentURL in
            if !isAddressFocused, let currentURL {
                addressInput = currentURL.absoluteString
            }
        }
        .onChange(of: model.document != nil) { _, ready in
            if ready {
                resetPreview()
                crop = model.defaultCrop
            }
        }
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
        .sheet(item: $sharedLink) { link in
            BookLinkEditorSheet(book: book, kind: link.kind, sharedURL: link.url, pageTitle: link.title)
        }
        .sheet(isPresented: $showSaveSuccess) {
            saveSuccessDialog
                .presentationDetents([.medium, .large])
                .preferredColorScheme(.dark)
        }
        .sheet(item: $sharedFile, onDismiss: removeTemporaryFile) { file in
            CaptureShareSheet(url: file.url)
        }
    }

    private var browserToolbar: some View {
        HStack(spacing: 8) {
            Button("Close") { dismiss() }
                .frame(width: browserSideWidth, height: browserToolbarHeight)
                .background(theme.cardBackground, in: RoundedRectangle(cornerRadius: 10))
            addressBar
            shareLinkMenu
        }
        .font(.body)
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .background(theme.libraryBackground)
    }

    private var shareLinkMenu: some View {
        Menu {
            Button("Save as Series Link") { shareCurrentLink(as: .series) }
            Button("Save as Latest Chapter Link") { shareCurrentLink(as: .latestChapter) }
            Button("Save as Eng Version Link") { shareCurrentLink(as: .englishSeries) }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .frame(width: browserSideWidth, height: browserToolbarHeight)
                .background(theme.cardBackground, in: RoundedRectangle(cornerRadius: 10))
        }
        .accessibilityLabel("Share current page to Information")
        .disabled(model.currentURL == nil || (model.isLoading && !model.canCapture) || model.isCapturing)
    }

    private var addressBar: some View {
        HStack(spacing: 0) {
            TextField("Website address", text: Binding(
                get: { isAddressFocused ? addressInput : (URL(string: addressInput)?.host ?? addressInput) },
                set: { addressInput = $0 }
            ))
                .padding(.leading, 10)
                .frame(minWidth: 0, maxWidth: .infinity)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($isAddressFocused)
                .onSubmit(navigateToAddress)
                .accessibilityLabel("Website address")
            Button {
                addressInput = ""
                isAddressFocused = true
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: browserToolbarHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear website address")
            .disabled(addressInput.isEmpty)
        }
        .frame(maxWidth: .infinity)
        .frame(height: browserToolbarHeight)
        .background(theme.cardBackground, in: RoundedRectangle(cornerRadius: 10))
        .disabled(model.isCapturing)
    }

    private func navigateToAddress() {
        guard !model.isCapturing else { return }
        let input = addressInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let destination = BookLinkKind.webURL(input) else {
            model.errorMessage = "Enter a valid website address, such as https://example.com."
            return
        }
        isAddressFocused = false
        addressInput = destination.absoluteString
        resetPreview()
        model.load(destination)
    }

    private var browserNavigationButtons: some View {
        HStack(spacing: 8) {
            browserNavigationButton("Back", icon: "chevron.left", disabled: !model.canGoBack || model.isCapturing) {
                model.goBack()
            }
            browserNavigationButton("Forward", icon: "chevron.right", disabled: !model.canGoForward || model.isCapturing) {
                model.goForward()
            }
            browserNavigationButton("Reload current page", icon: "arrow.clockwise", disabled: model.isCapturing) {
                model.reload()
            }
            browserNavigationButton("Open in Browser", icon: "safari", disabled: model.isCapturing) {
                openURL(model.currentURL ?? url)
            }
        }
    }

    private func browserNavigationButton(_ title: String, icon: String, disabled: Bool,
                                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 21, weight: .semibold))
                .frame(minWidth: 48, maxWidth: .infinity, minHeight: 52)
                .background(theme.libraryBackground, in: RoundedRectangle(cornerRadius: 14))
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.accent)
        .accessibilityLabel(title)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
    }

    private var browserCaptureButton: some View {
        Button {
            isAddressFocused = false
            model.capture(loadEntirePage: true)
        } label: {
            Label("Capture", systemImage: "camera")
                .font(.body.weight(.semibold))
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(theme.accent, in: RoundedRectangle(cornerRadius: 14))
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .disabled(!model.canCapture || model.isCapturing)
        .opacity(!model.canCapture || model.isCapturing ? 0.35 : 1)
    }

    private func shareCurrentLink(as kind: BookLinkKind) {
        guard let currentURL = model.currentURL else { return }
        sharedLink = SharedBookLink(kind: kind, url: currentURL, title: model.webView.title)
    }

    private var cropControls: some View {
        VStack(spacing: 12) {
            if let exportNotice {
                Text(exportNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let warning = model.captureWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
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
                    saved = false
                } label: {
                    Text("Full Page")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .frame(minHeight: 52)
                        .background(theme.libraryBackground, in: RoundedRectangle(cornerRadius: 14))
                }
                .foregroundStyle(theme.accent)
            }
            .buttonStyle(.plain)
            GeometryReader { geometry in
                let shareWidth = book.isSeries ? (geometry.size.width - 12) * 0.43 : geometry.size.width
                HStack(spacing: 12) {
                    Button { requestExport(saveToSeries: false) } label: {
                        Label("Share PDF", systemImage: "square.and.arrow.up")
                            .font(.body.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .frame(width: shareWidth, height: exportButtonHeight)
                            .background(theme.libraryBackground, in: RoundedRectangle(cornerRadius: 14))
                            .contentShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .foregroundStyle(theme.accent)
                    if book.isSeries {
                        Button { requestExport(saveToSeries: true) } label: {
                            Label(saved ? "Saved" : (isEnglish ? "Save PDF to EN" : "Save PDF"), systemImage: saved ? "checkmark" : "arrow.down.to.line")
                                .font(.body.weight(.semibold))
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .frame(height: exportButtonHeight)
                                .foregroundStyle(.white)
                                .background(theme.accent, in: RoundedRectangle(cornerRadius: 14))
                                .contentShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .accessibilityLabel(saved ? (isEnglish ? "Saved to EN Chapters" : "Saved to Chapters") : (isEnglish ? "Save PDF to EN" : "Save PDF"))
                        .disabled(saved)
                        .opacity(saved ? 0.55 : 1)
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(height: exportButtonHeight)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background(theme.cardBackground)
        .overlay(alignment: .top) { Divider() }
        .disabled(isExporting)
        .onChange(of: crop) { _, _ in saved = false; savedDescription = nil; exportNotice = nil }
    }

    private var saveSuccessDialog: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                    Text(savedDescription ?? "")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                    if let exportNotice {
                        Text(exportNotice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    VStack(spacing: 12) {
                        Button {
                            advanceToNextChapter(automaticallyCapture: false)
                        } label: {
                            Label("Go to next chapter", systemImage: "arrow.right.to.line")
                                .frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .buttonStyle(.bordered)
                        Button {
                            advanceToNextChapter(automaticallyCapture: true)
                        } label: {
                            Label("Next chapter & capture", systemImage: "camera")
                                .frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .disabled(model.nextChapterURL == nil)
                    if model.nextChapterURL == nil {
                        Text("No next-chapter link found. Close this message and use Back to Page to navigate manually.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(24)
            }
            .background(theme.libraryBackground)
            .navigationTitle("PDF saved successfully")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSaveSuccess = false } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Dismiss save confirmation")
                }
            }
        }
        .tint(theme.accent)
    }

    private func advanceToNextChapter(automaticallyCapture: Bool) {
        guard model.goToNextChapter(automaticallyCapture: automaticallyCapture) else { return }
        showSaveSuccess = false
        resetPreview()
    }

    private func resetPreview() {
        crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        saved = false
        savedDescription = nil
        exportNotice = nil
        filenameInput = ""
        overview = true
    }

    private func requestExport(saveToSeries: Bool) {
        pendingSaveToSeries = saveToSeries
        if filenameInput.isEmpty { filenameInput = model.suggestedFilename }
        showFilenamePrompt = true
    }

    private func export(saveToSeries: Bool, filename: String) {
        guard let document = model.document, !isExporting else { return }
        let selection = crop
        let sourceURL = model.capturedPageURL
        let chapterTitle = model.suggestedFilename
        isExporting = true
        exportNotice = nil
        exportTask = Task {
            defer { isExporting = false }
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try document.exportResult(crop: selection)
                }
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                try Task.checkCancellation()
                let data = result.data
                if result.skippedForSize {
                    exportNotice = "Kept the smaller PDF. Some seams may still appear in other viewers."
                }
                if saveToSeries {
                    let target = try await ImportService().saveCapturedChapter(data, for: book, filename: filename, sourceURL: sourceURL, chapterTitle: chapterTitle, isEnglish: isEnglish, modelContext: modelContext)
                    savedDescription = "\(isEnglish ? "EN/" : "")\(target.lastPathComponent) · \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))"
                    saved = true
                    showSaveSuccess = true
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
