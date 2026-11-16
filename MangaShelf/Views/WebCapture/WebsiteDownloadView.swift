import SwiftUI
import SwiftData

struct WebsiteDownloadView: View {
    let book: Book
    let isEnglish: Bool
    @State private var model: WebsiteDownloadModel
    @State private var search = ""
    @State private var showSource = false
    @State private var share: DownloadShareFile?
    @State private var shareError: String?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(ThemeManager.self) private var theme

    init(url: URL, book: Book, isEnglish: Bool) {
        self.book = book; self.isEnglish = isEnglish
        _model = State(initialValue: WebsiteDownloadModel(url: url, isPrivate: book.isSecret))
    }
    private var filtered: [WebsiteChapter] {
        model.chapters.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || ($0.filename ?? "").localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Text(model.title).font(.headline).lineLimit(2)
                Text("\(model.chapters.count) chapter · Đã chọn \(model.selected.count) · \(isEnglish ? "EN" : "VN")").font(.caption)
                Text(model.status).font(.caption).accessibilityAddTraits(.updatesFrequently)
                if !model.warning.isEmpty { Text(model.warning).font(.caption2).foregroundStyle(.orange).padding(.horizontal) }
                if model.busy {
                    ProgressView(value: model.imageProgress)
                    if model.total > 0 { ProgressView(value: Double(model.completed), total: Double(model.total)) }
                    Button("Dừng tác vụ", role: .destructive) { model.stop() }
                }
                HStack {
                    Button("Chọn kết quả") { model.selected.formUnion(filtered.filter { model.saved[$0.id] == nil }.map(\.id)) }.disabled(model.busy)
                    Button("Bỏ chọn") { model.selected.removeAll() }.disabled(model.busy)
                    Spacer()
                    Button(showSource ? "Ẩn trang nguồn" : "Trang nguồn") { showSource.toggle() }
                }.font(.caption).padding(.horizontal)
                List(filtered) { chapter in
                    VStack(alignment: .leading, spacing: 5) {
                        Button {
                            if model.selected.contains(chapter.id) { model.selected.remove(chapter.id) }
                            else { model.selected.insert(chapter.id) }
                        } label: {
                            HStack {
                                Image(systemName: model.selected.contains(chapter.id) ? "checkmark.circle.fill" : "circle")
                                Text(chapter.title).foregroundStyle(.primary)
                            }
                        }.disabled(model.busy || model.saved[chapter.id] != nil)
                        if let state = model.states[chapter.id] { Text(state).font(.caption).foregroundStyle(.secondary) }
                        if let timing = model.timings[chapter.id] { Text(timing).font(.caption2).foregroundStyle(.secondary) }
                        if let url = model.saved[chapter.id] {
                            Button { prepareShare(url) } label: { Label("Chia sẻ / Lưu vào Files", systemImage: "square.and.arrow.up") }.font(.caption)
                        }
                    }
                }.listStyle(.plain)
                // Keep one WebKit instance mounted: toggling the source must not lose its session.
                CaptureWebView(webView: model.browser.webView)
                    .frame(height: 230)
                    .frame(height: showSource ? 230 : 1, alignment: .top)
                    .clipped()
                Text("Không cần mở trang nguồn để tải ảnh trực tiếp. Khi vào nền, app cố hoàn tất chapter hiện tại trong thời gian iOS cho phép; trang cần JavaScript sẽ dừng.").font(.caption2).foregroundStyle(.secondary).padding(.horizontal)
                HStack {
                    Button("Lấy lại danh sách") { model.loadList() }
                    Button("Tải / Thử lại đã chọn") { model.download(book: book, isEnglish: isEnglish, context: context) }
                        .buttonStyle(.borderedProminent).disabled(model.selected.isEmpty)
                }.disabled(model.busy).padding(.bottom, 8)
            }
            .background(theme.libraryBackground).tint(theme.accent)
            .searchable(text: $search, prompt: "Tìm chapter")
            .navigationTitle("Tải truyện từ website").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(model.saved.isEmpty ? "Đóng" : "Mở thư viện") { model.stop(); dismiss() } } }
            .sheet(item: $share, onDismiss: { cleanupShare() }) { item in
                DownloadActivity(items: [item.url])
            }
            .alert("Không thể chia sẻ", isPresented: Binding(get: { shareError != nil }, set: { if !$0 { shareError = nil } })) {
                Button("OK") { shareError = nil }
            } message: { Text(shareError ?? "") }
            .task { model.loadList() }
            .onDisappear { model.stop() }
            .onChange(of: scenePhase) { _, phase in model.sceneChanged(phase) }
            .onChange(of: model.browser.isVerificationRequired) { _, required in if required { showSource = true } }
        }
    }
    @State private var shareFolder: URL?
    private func cleanupShare() {
        if let shareFolder { try? FileManager.default.removeItem(at: shareFolder) }
        shareFolder = nil
    }
    private func prepareShare(_ url: URL) {
        guard let bookmark = UserDefaults.standard.data(forKey: book.bookmarkKey),
              let (root, _) = try? LocalFileService.shared.resolveBookmark(bookmark),
              root.startAccessingSecurityScopedResource() else {
            shareError = "Không truy cập được thư mục thư viện."; return
        }
        Task {
            defer { root.stopAccessingSecurityScopedResource() }
            do {
                cleanupShare()
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("website-share-\(UUID())")
                shareFolder = folder
                let target = folder.appendingPathComponent(url.lastPathComponent)
                try await Task.detached {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: target)
                }.value
                share = DownloadShareFile(url: target)
            } catch { cleanupShare(); shareError = error.localizedDescription }
        }
    }

}

private struct DownloadShareFile: Identifiable {
    let id = UUID()
    let url: URL
}
private struct DownloadActivity: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
