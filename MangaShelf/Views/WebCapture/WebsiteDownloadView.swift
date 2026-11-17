import SwiftUI
import SwiftData

struct WebsiteDownloadView: View {
    let book: Book
    let isEnglish: Bool
    @State private var model: WebsiteDownloadModel
    @State private var showSource = false
    @State private var newestFirst = true
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(ThemeManager.self) private var theme

    init(url: URL, book: Book, isEnglish: Bool) {
        self.book = book; self.isEnglish = isEnglish
        _model = State(initialValue: WebsiteDownloadModel(url: url, isPrivate: book.isSecret))
    }
    private var selectableIDs: Set<String> {
        Set(model.chapters.map(\.id))
    }
    /// The model keeps chapters ascending (download order); only the display order flips.
    private var displayedChapters: [WebsiteChapter] {
        newestFirst ? model.chapters.reversed() : model.chapters
    }
    private var allSelected: Bool {
        !selectableIDs.isEmpty && selectableIDs.isSubset(of: model.selected)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                summaryCard
                // Only a download batch has a total; loading the list shows no progress bar.
                if (model.busy || model.isPaused || model.isFinished) && model.total > 0 {
                    downloadProgress
                }
                ZStack {
                    chapterList
                        .opacity(showSource ? 0 : 1)
                        .allowsHitTesting(!showSource)
                        .accessibilityHidden(showSource)
                    // Keep WebKit mounted so switching views preserves the browser session.
                    CaptureWebView(webView: model.browser.webView)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .opacity(showSource ? 1 : 0)
                        .allowsHitTesting(showSource)
                        .accessibilityHidden(!showSource)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .background(theme.libraryBackground)
            .tint(theme.accent)
            .navigationTitle("\(book.title) | \(model.source.host() ?? model.source.absoluteString)").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Đóng") { model.stop(); dismiss() } }
                downloadToolbar
            }
            .task { model.loadList(book: book, isEnglish: isEnglish) }
            .onDisappear { model.stop() }
            .onChange(of: scenePhase) { _, phase in model.sceneChanged(phase) }
            .onChange(of: model.browser.isVerificationRequired) { _, required in if required { showSource = true } }
            // Once the list is found, leave the website and go straight to chapter selection.
            .onChange(of: model.chapters.isEmpty) { _, isEmpty in if !isEmpty { showSource = false } }
        }
    }
    private var downloadProgress: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("\(model.completed)/\(model.total) chapters")
                    Text("-")
                    Text("\(model.failed)")
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text("-")
                    Text("\(model.succeeded)")
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(model.completed)/\(model.total) chapter, \(model.failed) lỗi, \(model.succeeded) hoàn tất")
                .accessibilityAddTraits(.updatesFrequently)
                ProgressView(value: Double(model.completed), total: Double(model.total))
                    .accessibilityLabel("Tiến trình tải")
            }
            if model.isFinished {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
                    .frame(width: 44, height: 44)
                    .transition(.symbolEffect(.appear))
                    .accessibilityLabel("Đã hoàn thành")
            } else {
                Button {
                    if model.isPaused { model.resume(book: book, isEnglish: isEnglish, context: context) }
                    else { model.pause() }
                } label: {
                    Image(systemName: model.isPaused ? "play.circle.fill" : "pause.circle.fill")
                        .font(.title2)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.accent)
                .accessibilityLabel(model.isPaused ? "Tiếp tục tải" : "Tạm dừng")
            }
        }
        .padding(.horizontal, 4)
    }

    private var summaryCard: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                summaryText
                Spacer(minLength: 8)
                websiteButton
            }
            VStack(alignment: .leading, spacing: 12) {
                summaryText
                websiteButton
            }
        }
        .padding(16)
        .background(theme.cardBackground, in: RoundedRectangle(cornerRadius: 20))
    }

    private var summaryText: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Text(book.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(isEnglish ? "EN" : "VN")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(theme.accent.opacity(0.18), in: Capsule())
                    .accessibilityLabel(isEnglish ? "English" : "Tiếng Việt")
            }
            Group {
                if model.isVerifying {
                    progressText("Đang xác minh")
                } else {
                    progressText(model.status.isEmpty ? "Đang lấy danh sách" : model.status)
                }
            }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.updatesFrequently)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Progress messages ("Đang …") get animated dots while a task runs; other messages stay static.
    @ViewBuilder
    private func progressText(_ text: String, suffix: String = "") -> some View {
        if model.busy && text.hasPrefix("Đang") {
            animatedStatus(text, suffix: suffix)
        } else {
            Text(text + suffix)
        }
    }

    /// In-progress text with cycling trailing dots; the hidden "..." reserves width so the layout doesn't jump.
    private func animatedStatus(_ text: String, suffix: String = "") -> some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
            let dots = Int(timeline.date.timeIntervalSinceReferenceDate * 2) % 3 + 1
            HStack(spacing: 0) {
                Text(text)
                Text("...").hidden()
                    .overlay(alignment: .leading) {
                        Text(String(repeating: ".", count: dots))
                    }
                Text(suffix)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text + suffix)
        }
    }

    private var websiteButton: some View {
        Button { showSource.toggle() } label: {
            Label("Website", systemImage: "globe")
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(showSource ? theme.accent.opacity(0.2) : theme.libraryBackground.opacity(0.6),
                            in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.accent)
        .accessibilityValue(showSource ? "Đang hiện website" : "Đang hiện danh sách")
        .accessibilityHint("Chuyển giữa website và danh sách chapter")
    }

    private var chapterList: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Chọn chapter để tải")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { newestFirst.toggle() } label: {
                    HStack(spacing: 4) {
                        Text(newestFirst ? "Mới nhất" : "Cũ nhất")
                        Image(systemName: newestFirst ? "arrow.down" : "arrow.up")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Sắp xếp")
                .accessibilityValue(newestFirst ? "Mới nhất trước" : "Cũ nhất trước")
                Divider()
                    .frame(height: 18)
                    .padding(.horizontal, 10)
                Button(allSelected ? "Bỏ chọn tất cả" : "Chọn tất cả") {
                    if allSelected { model.selected.removeAll() }
                    else { model.selected.formUnion(selectableIDs) }
                }
                .font(.subheadline)
                .frame(minHeight: 44)
                .disabled(model.busy || !model.libraryChecked || selectableIDs.isEmpty)
            }
            .padding(.horizontal, 4)

            ScrollViewReader { proxy in
                List(displayedChapters) { chapter in
                    chapterRow(chapter)
                        .listRowBackground(theme.cardBackground)
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                        .listRowSeparatorTint(theme.cardBorder.opacity(0.5))
                }
                // Keep the chapter being downloaded centered as the queue advances.
                .onChange(of: model.currentChapterID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay {
                if model.chapters.isEmpty && !model.busy {
                    ContentUnavailableView("Chưa có chapter", systemImage: "list.bullet",
                                           description: Text("Nhấn nút lấy lại danh sách để thử lại."))
                }
            }
        }
    }

    private func chapterRow(_ chapter: WebsiteChapter) -> some View {
        let isSaved = model.libraryChecked && model.saved[chapter.id] != nil
        let isSelected = model.selected.contains(chapter.id)
        return Button {
            if isSelected { model.selected.remove(chapter.id) }
            else { model.selected.insert(chapter.id) }
        } label: {
            HStack(spacing: 14) {
                // Saved chapters keep their seal icon; selection for re-download only tints it.
                Image(systemName: isSaved ? "checkmark.seal.fill" : (isSelected ? "checkmark.circle.fill" : "circle"))
                    .font(.title3)
                    .foregroundStyle(isSelected ? theme.accent : Color.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(chapter.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(isSaved && !isSelected ? Color.secondary : Color.primary)
                    let state = model.states[chapter.id] ?? (isSaved ? (isSelected ? "Đã tải · sẽ tải lại" : "Đã tải")
                                                             : (model.libraryChecked ? "Chưa tải" : "Chưa kiểm tra thư viện"))
                    progressText(state, suffix: model.sizes[chapter.id].map { " · " + Int64($0).formatted(.byteCount(style: .file)) } ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.busy || !model.libraryChecked)
        .accessibilityValue(isSelected ? (isSaved ? "Đã chọn, sẽ tải lại" : "Đã chọn") : (isSaved ? "Đã tải" : "Chưa chọn"))
    }

    /// Floating Liquid Glass bottom toolbar.
    @ToolbarContentBuilder
    private var downloadToolbar: some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            Button("Lấy lại danh sách", systemImage: "arrow.clockwise") {
                model.loadList(book: book, isEnglish: isEnglish)
            }
            .disabled(model.busy)
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            Text("Đã chọn \(model.selected.count) chapter")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .accessibilityAddTraits(.updatesFrequently)
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            Button("Tải / Thử lại đã chọn", systemImage: "arrow.down.to.line") {
                model.download(book: book, isEnglish: isEnglish, context: context)
            }
            .buttonStyle(.glassProminent)
            .tint(theme.accent)
            .disabled(model.busy || model.selected.isEmpty || !model.libraryChecked)
        }
    }

}
