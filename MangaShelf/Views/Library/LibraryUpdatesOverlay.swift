import SwiftUI
import SwiftData

/// Centered card listing unsaved new chapters per series, with their website date and "new" badge.
/// After the person starts a download it shows the batch progress per chapter, and keeps the
/// results on screen when the batch ends until the person closes it.
struct LibraryUpdatesOverlay: View {
    @Bindable var downloader: LibraryUpdateDownloader
    let onDownload: (Set<String>) -> Void
    @Environment(ThemeManager.self) private var theme
    @Environment(\.modelContext) private var modelContext

    private var isChoosing: Bool { downloader.phase == .choosing }
    private var wasStopped: Bool { downloader.phase == .finished && downloader.completed < downloader.total }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                header
                    .padding(16)

                if !isChoosing {
                    downloadProgress
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }

                Divider()

                ScrollViewReader { proxy in
                    // Grow with the content and only scroll once the list is taller than the card allows.
                    ViewThatFits(in: .vertical) {
                        updateList
                        ScrollView { updateList }
                            .scrollIndicators(.hidden)
                    }
                    // Keep the chapter being downloaded in view as the queue advances.
                    .onChange(of: downloader.currentChapterID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                .frame(maxHeight: 440)

                Divider()

                actions
                    .padding(16)
            }
            .frame(maxWidth: 440)
            .background(theme.cardBackground, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(theme.cardBorder.opacity(0.5)))
            .padding(24)
        }
        .tint(theme.accent)
        .animation(.easeInOut(duration: 0.25), value: downloader.phase)
    }

    // MARK: - Header and progress

    private var header: some View {
        VStack(spacing: 4) {
            switch downloader.phase {
            case .choosing:
                Text("Chapter mới")
                    .font(.headline)
                Text("\(downloader.chapterCount) chapter chưa tải · \(downloader.updates.count) truyện")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .downloading:
                Text("Đang tải chapter mới")
                    .font(.headline)
                Text(downloader.current.map { "Đang tải: \($0.title)" } ?? "Đang chuẩn bị")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            case .finished:
                Text(wasStopped ? "Đã dừng tải" : "Đã tải xong")
                    .font(.headline)
                Text("\(downloader.succeeded) chapter đã lưu vào thư viện")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
    }

    /// Batch progress across every chosen series, styled like the website download screen.
    private var downloadProgress: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("\(downloader.completed)/\(downloader.total) chapter")
                    Text("-")
                    Text("\(downloader.failed)")
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text("-")
                    Text("\(downloader.succeeded)")
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(downloader.completed)/\(downloader.total) chapter, \(downloader.failed) lỗi, \(downloader.succeeded) hoàn tất")
                .accessibilityAddTraits(.updatesFrequently)
                ProgressView(value: Double(downloader.completed), total: Double(max(downloader.total, 1)))
                    .accessibilityLabel("Tiến trình tải")
            }
            if downloader.phase == .finished {
                Image(systemName: wasStopped ? "stop.circle.fill" : "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(wasStopped ? Color.orange : Color.green)
                    .frame(width: 44, height: 44)
                    .transition(.symbolEffect(.appear))
                    .accessibilityLabel(wasStopped ? "Đã dừng" : "Đã hoàn thành")
            } else {
                Button {
                    if downloader.isPaused { downloader.resume(context: modelContext) }
                    else { downloader.pause() }
                } label: {
                    Image(systemName: downloader.isPaused ? "play.circle.fill" : "pause.circle.fill")
                        .font(.title2)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.accent)
                .accessibilityLabel(downloader.isPaused ? "Tiếp tục tải" : "Tạm dừng")
            }
        }
    }

    // MARK: - List

    private var updateList: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isChoosing {
                ForEach(downloader.updates) { update in
                    choiceSection(update)
                }
                if !downloader.notes.isEmpty {
                    Text(downloader.notes.joined(separator: "\n"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ForEach(downloader.queue) { update in
                    progressSection(update)
                }
            }
        }
        .padding(16)
    }

    private func choiceSection(_ update: LibraryChapterUpdate) -> some View {
        let isSelected = downloader.selected.contains(update.id)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                if isSelected { downloader.selected.remove(update.id) }
                else { downloader.selected.insert(update.id) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? theme.accent : Color.secondary)
                    Text(update.title)
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    countBadge("\(update.chapters.count)")
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isSelected ? "Đã chọn" : "Chưa chọn")

            // Newest first, matching the website's chapter list.
            VStack(alignment: .leading, spacing: 6) {
                ForEach(update.chapters.reversed()) { chapter in
                    HStack(spacing: 6) {
                        Text(chapter.title)
                            .font(.caption)
                            .lineLimit(1)
                        if chapter.isNew { newBadge }
                        Spacer(minLength: 8)
                        if let date = chapter.date {
                            Text(date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.leading, 34)
        }
    }

    private func progressSection(_ update: LibraryChapterUpdate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(update.title)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                countBadge("\(update.model.succeeded)/\(update.chapters.count)")
            }
            // Download order (oldest first), so progress runs top to bottom.
            ForEach(update.chapters) { chapter in
                progressRow(chapter, in: update)
                    .id(chapter.id)
            }
        }
    }

    private func progressRow(_ chapter: WebsiteChapter, in update: LibraryChapterUpdate) -> some View {
        let model = update.model
        let startFailure = downloader.startFailures[update.id]
        let state = model.states[chapter.id]
        let isSaved = model.saved[chapter.id] != nil
        let isFailed = startFailure != nil || state?.hasPrefix("Lỗi") == true
        let isCurrent = downloader.isDownloading && downloader.currentChapterID == chapter.id
        let text = state ?? startFailure.map { "Lỗi: \($0)" } ?? (downloader.phase == .finished ? "Chưa tải" : "Đang chờ")
        let size = model.sizes[chapter.id].map { " · " + Int64($0).formatted(.byteCount(style: .file)) } ?? ""
        return HStack(spacing: 10) {
            Group {
                if isSaved {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if isFailed {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                } else if isCurrent && !downloader.isPaused {
                    ProgressView().controlSize(.small)
                } else if isCurrent {
                    Image(systemName: "pause.circle.fill").foregroundStyle(theme.accent)
                } else {
                    Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                }
            }
            .font(.body)
            .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(chapter.title)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    if chapter.isNew { newBadge }
                }
                Text(text + size)
                    .font(.caption2)
                    .foregroundStyle(isFailed ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let date = chapter.date {
                Text(date)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(isCurrent ? theme.accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    private var newBadge: some View {
        Text("NEW")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.red, in: Capsule())
            .accessibilityLabel("Mới")
    }

    private func countBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.bold).monospacedDigit())
            .foregroundStyle(theme.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(theme.accent.opacity(0.18), in: Capsule())
    }

    // MARK: - Actions

    @ViewBuilder
    private var actions: some View {
        switch downloader.phase {
        case .choosing:
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        onDownload(downloader.selected)
                    } label: {
                        Text("Tải đã chọn (\(downloader.selected.count))")
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.bordered)
                    .disabled(downloader.selected.isEmpty)

                    Button {
                        onDownload(Set(downloader.updates.map(\.id)))
                    } label: {
                        Text("Tải tất cả")
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.glassProminent)
                }
                Button("Đóng") { downloader.dismiss() }
                    .frame(minHeight: 44)
            }
        case .downloading:
            Button(role: .destructive) {
                downloader.stop()
            } label: {
                Text("Dừng tải")
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.bordered)
        case .finished:
            Button {
                downloader.dismiss()
            } label: {
                Text("Đóng")
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.glassProminent)
        }
    }
}
