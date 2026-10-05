//
//  ChapterListView.swift
//  MangaShelf
//
//  Created by Khoa Phan on 4/26/26.
//

import SwiftUI
import SwiftData
import PhotosUI

struct ChapterListView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(ThemeManager.self) private var theme
    let book: Book

    @State private var showEnglish = false
    @State private var hasEnglishFolder = false
    @State private var showReader = false
    @State private var isSyncing = false
    @State private var coverImage: UIImage?
    @State private var dominantColor: Color?
    @State private var sortAscending = false
    @State private var showAddBookmark = false
    @State private var bookmarkChapterIndex: Int?
    @State private var bookmarkNote = ""
    @State private var bookmarkColor: BookmarkColor = .red
    @State private var editingLink: BookLinkKind?
    @State private var showEditSeriesNote = false
    @State private var showInfoBox = false
    @State private var captureURL: CaptureLink?
    @State private var artImages: [ArtItem] = []
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var artViewerItem: ArtViewerItem?
    @State private var coverDisplayIndex: Int = 0
    @State private var deleteErrorMessage: String?

    private struct ArtViewerItem: Identifiable {
        let id = UUID()
        let index: Int
    }

    private struct CaptureLink: Identifiable {
        let id = UUID()
        let url: URL
        var isEnglish = false
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                coverHeader
                infoSection
                    .padding(.top, 20)

                if showInfoBox {
                    seriesInfoBox
                        .padding(.top, 14)
                        .padding(.horizontal, 20)
                        .transition(.opacity)
                }

                actionButtons
                    .padding(.top, 16)
                    .padding(.horizontal, 20)

                chaptersHeader
                    .padding(.top, 24)

                chapterList
                    .padding(.top, 8)
                    .padding(.bottom, 40)
            }
        }
        .refreshable { await syncChapters() }
        .background(theme.libraryBackground)
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(theme.libraryBackground, for: .navigationBar)
        .fullScreenCover(isPresented: $showReader, onDismiss: {
            Task { await loadArtImages() }
        }) {
            ReaderView(book: book)
        }
        .task {
            await syncChapters()
            await BookDataService.shared.restoreIfNeeded(book: book, modelContext: modelContext)
            await BookDataService.shared.save(book: book)
            await loadCoverImage()
            await loadArtImages()
        }
        .sheet(isPresented: $showAddBookmark) {
            addBookmarkSheet
        }
        .sheet(item: $editingLink) { kind in
            BookLinkEditorSheet(book: book, kind: kind)
        }
        .sheet(isPresented: $showEditSeriesNote) {
            SeriesNoteEditorSheet(book: book)
        }
        .fullScreenCover(item: $captureURL, onDismiss: {
            Task {
                await syncChapters()
                await loadArtImages()
            }
        }) { link in
            WebPageCaptureView(url: link.url, book: book, isEnglish: link.isEnglish)
        }
        .fullScreenCover(item: $artViewerItem, onDismiss: {
            Task { await loadArtImages() }
        }) { item in
            ArtViewerOverlay(
                artImages: coverCarouselItems,
                initialIndex: item.index,
                onDeleteFile: { filename in
                    await deleteArtFile(filename: filename)
                },
                onSetCover: { image in
                    await setImageAsCover(image)
                },
                onOpenInFolder: {
                    openArtFolder()
                }
            )
        }
        .alert(
            "Couldn't Delete Chapter",
            isPresented: Binding(
                get: { deleteErrorMessage != nil },
                set: { if !$0 { deleteErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteErrorMessage ?? "")
        }
        .onChange(of: selectedPhotoItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            Task {
                for item in newItems {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        await saveArtImage(data)
                    }
                }
                await loadArtImages()
                selectedPhotoItems = []
            }
        }
        .preferredColorScheme(.dark)
    }

    private var maxCoverHeight: CGFloat {
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let height: CGFloat
        if #available(iOS 26, *) {
            height = scene?.effectiveGeometry.coordinateSpace.bounds.height ?? 852
        } else {
            height = scene?.coordinateSpace.bounds.height ?? 852
        }
        return height * 0.55
    }

    // MARK: - Cover Header

    private var coverCarouselItems: [ArtItem] {
        var items: [ArtItem] = []
        if let cover = coverImage {
            items.append(ArtItem(id: "__cover__", image: cover, isCover: true))
        }
        items.append(contentsOf: artImages)
        return items
    }

    private var coverHeader: some View {
        let items = coverCarouselItems

        return VStack(spacing: 0) {
            if items.count > 1 {
                let baseImage = items[0].image
                let aspect = baseImage.size.width / baseImage.size.height

                Color.clear
                    .aspectRatio(aspect, contentMode: .fit)
                    .frame(maxHeight: maxCoverHeight)
                    .overlay {
                        TabView(selection: $coverDisplayIndex) {
                            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                                Color.clear
                                    .overlay {
                                        Image(uiImage: item.image)
                                            .resizable()
                                            .scaledToFill()
                                    }
                                    .clipped()
                                    .contentShape(Rectangle())
                                    .onTapGesture { handleCoverTap() }
                                    .tag(index)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                    }
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: (dominantColor ?? theme.accent).opacity(0.6), radius: 40, x: 0, y: 0)
                    .shadow(color: (dominantColor ?? theme.accent).opacity(0.3), radius: 80, x: 0, y: 0)
            } else if let singleItem = items.first {
                let aspect = singleItem.image.size.width / singleItem.image.size.height
                Color.clear
                    .aspectRatio(aspect, contentMode: .fit)
                    .frame(maxHeight: maxCoverHeight)
                    .overlay {
                        Image(uiImage: singleItem.image)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: (dominantColor ?? theme.accent).opacity(0.6), radius: 40, x: 0, y: 0)
                    .shadow(color: (dominantColor ?? theme.accent).opacity(0.3), radius: 80, x: 0, y: 0)
                    .onTapGesture { handleCoverTap() }
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.cardBackground)
                    .aspectRatio(0.7, contentMode: .fit)
                    .frame(maxHeight: maxCoverHeight)
                    .overlay {
                        if isSyncing {
                            ProgressView()
                                .tint(theme.accent)
                        } else {
                            Image(systemName: "book.closed.fill")
                                .font(.system(size: 48))
                                .foregroundStyle(Color.tertiaryText)
                        }
                    }
                    .shadow(color: (dominantColor ?? theme.accent).opacity(0.6), radius: 40, x: 0, y: 0)
                    .shadow(color: (dominantColor ?? theme.accent).opacity(0.3), radius: 80, x: 0, y: 0)
            }
        }
        .padding(.horizontal, 40)
        .padding(.top, 8)
        .onChange(of: artImages.count) { _, _ in
            let maxIndex = coverCarouselItems.count - 1
            if coverDisplayIndex > maxIndex {
                coverDisplayIndex = max(maxIndex, 0)
            }
        }
    }

    private func handleCoverTap() {
        guard !coverCarouselItems.isEmpty else { return }
        artViewerItem = ArtViewerItem(index: coverDisplayIndex)
    }

    // MARK: - Info Section

    private var infoSection: some View {
        VStack(spacing: 12) {
            Text(book.title)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 32)

            HStack(spacing: 6) {
                Label("\(book.sortedChapters.count) chapters", systemImage: "book.fill")
                    .font(.subheadline)
                    .foregroundColor(.secondaryText)

                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        showInfoBox.toggle()
                    }
                } label: {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(showInfoBox ? theme.accent : .tertiaryText)
                        .symbolEffect(.bounce, value: showInfoBox)
                }
            }

            if book.readingProgress > 0 {
                progressBar
                    .padding(.horizontal, 40)
                    .padding(.top, 4)
            }
        }
    }

    private var progressBar: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.1))
                        .frame(height: 4)

                    Capsule()
                        .fill(theme.accent)
                        .frame(width: geo.size.width * book.readingProgress, height: 4)
                }
            }
            .frame(height: 4)

            Text("\(Int(book.readingProgress * 100))% complete")
                .font(.caption)
                .foregroundColor(.tertiaryText)
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 0) {
            Button {
                guard let firstChapter = languageChapters.first else { return }
                book.currentChapterIndex = firstChapter.sortOrder
                firstChapter.lastReadPage = 0
                firstChapter.lastReadOffset = 0
                try? modelContext.save()
                showReader = true
            } label: {
                VStack(spacing: 5) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.secondaryText)
                    Text("From Start")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundColor(.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }

            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(width: 1)
                .padding(.vertical, 10)

            Button {
                guard let chapter = resumeChapter else { return }
                book.currentChapterIndex = chapter.sortOrder
                try? modelContext.save()
                showReader = true
            } label: {
                VStack(spacing: 5) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 16))
                        .foregroundColor(theme.accent)

                    if book.readingProgress > 0,
                       let chapter = resumeChapter {
                        Text(chapter.displayName)
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .lineLimit(1)
                    } else {
                        Text("Start Reading")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
        }
        .disabled(isSyncing || languageChapters.isEmpty)
        .opacity(languageChapters.isEmpty ? 0.5 : 1)
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Series Info Box

    private var seriesInfoBox: some View {
        VStack(spacing: 10) {
            bookLinkRow(.series)
            bookLinkRow(.latestChapter)
            bookLinkRow(.englishSeries)

            Rectangle()
                .fill(Color.white.opacity(0.04))
                .frame(height: 1)

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "note.text")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.yellow)
                    .frame(width: 28)

                if let note = book.seriesNote, !note.isEmpty {
                    Text(note.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        showEditSeriesNote = true
                    } label: {
                        Image(systemName: "pencil.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(theme.accent)
                    }
                } else {
                    Button {
                        showEditSeriesNote = true
                    } label: {
                        Text("Add note")
                            .font(.subheadline)
                            .foregroundColor(.tertiaryText)
                    }
                    Spacer()
                }
            }

            if book.isSeries {
                Rectangle()
                    .fill(Color.white.opacity(0.04))
                    .frame(height: 1)

                artAlbumSection
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
        )
    }

    private func bookLinkRow(_ kind: BookLinkKind) -> some View {
        let value = book[keyPath: kind.urlKeyPath]
        let url = BookLinkKind.webURL(value ?? "")
        return HStack(spacing: 12) {
            Image(systemName: kind.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.accent)
                .frame(width: 28)
            Button {
                guard let url else { editingLink = kind; return }
                captureURL = CaptureLink(url: url, isEnglish: kind == .englishSeries)
            } label: {
                Text(url == nil ? kind.addLabel : (kind == .englishSeries ? "\(englishChapterLabel(url)) - EN" : (kind == .series ? book.title : "Chapter \(book.latestChapterNumber ?? "#")")))
                    .font(.subheadline)
                    .foregroundColor(url == nil ? .tertiaryText : theme.accent)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .contextMenu {
                if let url {
                    Button {
                        UIPasteboard.general.string = url.absoluteString
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    } label: {
                        Label("Copy Link", systemImage: "doc.on.doc")
                    }
                }
            }
            Spacer(minLength: 8)
            Button { editingLink = kind } label: {
                Image(systemName: "pencil.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(theme.accent)
            }
            .accessibilityLabel("Edit \(kind.title)")
        }
    }

    /// The EN link has no stored chapter number, so infer it from the URL ("Chapter #" when it can't be read).
    private func englishChapterLabel(_ url: URL?) -> String {
        let suggestion = CaptureFileName.chapterSuggestion(url: url, title: nil)
        return suggestion == "Chapter" ? "Chapter #" : suggestion
    }

    // MARK: - Chapters Header

    private var languageChapters: [Chapter] {
        book.sortedChapters.filter { $0.isEnglish == showEnglish }
    }

    private var resumeChapter: Chapter? {
        languageChapters.first { $0.sortOrder == book.currentChapterIndex } ?? languageChapters.first
    }

    private var chaptersHeader: some View {
        HStack {
            Text("Chapters")
                .font(.headline)
                .foregroundColor(.white)
            Picker("Chapter language", selection: $showEnglish) {
                Text("VN").tag(false)
                Text("EN").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 110)
            .disabled(!hasEnglishFolder || isSyncing)
            .accessibilityHint(hasEnglishFolder ? "Switch chapter language" : "EN folder is unavailable")
            Spacer()
            Button {
                sortAscending.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text(sortAscending ? "Oldest" : "Newest")
                        .font(.subheadline)
                    Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                        .font(.caption)
                }
                .foregroundColor(theme.accent)
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Chapter List

    private var chapterList: some View {
        let allChapters = languageChapters
        let displayChapters = sortAscending ? allChapters : allChapters.reversed()

        return LazyVStack(spacing: 0) {
            if allChapters.isEmpty {
                Text(showEnglish ? "No English chapters" : "No Vietnamese chapters")
                    .font(.subheadline)
                    .foregroundColor(.secondaryText)
                    .frame(maxWidth: .infinity)
                    .padding(24)
            }
            ForEach(Array(displayChapters.enumerated()), id: \.element.id) { displayIndex, chapter in
                let originalIndex = chapter.sortOrder
                Button {
                    book.currentChapterIndex = originalIndex
                    chapter.lastReadPage = 0
                    chapter.lastReadOffset = 0
                    try? modelContext.save()
                    showReader = true
                } label: {
                    chapterRow(chapter: chapter, index: originalIndex)
                }
                .contextMenu {
                    Button {
                        bookmarkChapterIndex = originalIndex
                        bookmarkNote = ""
                        bookmarkColor = .red
                        showAddBookmark = true
                    } label: {
                        Label("Add Bookmark", systemImage: "bookmark.fill")
                    }

                    if let existing = bookmarkFor(index: originalIndex) {
                        Button(role: .destructive) {
                            modelContext.delete(existing)
                            try? modelContext.save()
                            saveBookData()
                        } label: {
                            Label("Remove Bookmark", systemImage: "bookmark.slash")
                        }
                    }

                    Divider()

                    Button(role: .destructive) {
                        Task { await deleteChapter(chapter) }
                    } label: {
                        Label("Delete Chapter", systemImage: "trash")
                    }
                }

                if displayIndex < allChapters.count - 1 {
                    Divider()
                        .background(Color.white.opacity(0.06))
                        .padding(.leading, 64)
                }
            }
        }
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 20)
    }

    // MARK: - Private

    private func syncChapters() async {
        isSyncing = true
        defer { isSyncing = false }
        do {
            hasEnglishFolder = try await ImportService().syncSeriesFromRoot(book, modelContext: modelContext)
            if !hasEnglishFolder { showEnglish = false }
        } catch {
            print("Failed to sync chapters: \(error.localizedDescription)")
        }
    }

    private func deleteChapter(_ chapter: Chapter) async {
        isSyncing = true
        defer { isSyncing = false }
        do {
            try await ImportService().deleteChapter(chapter, from: book, modelContext: modelContext)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            deleteErrorMessage = error.localizedDescription
        }
    }

    private var addBookmarkSheet: some View {
        BookmarkEditorSheet(
            title: "Add Bookmark",
            chapterTitle: bookmarkChapterIndex.flatMap { book.sortedChapters[safe: $0]?.displayName },
            bookmarkNote: $bookmarkNote,
            bookmarkColor: $bookmarkColor,
            onSave: saveBookmark
        )
    }

    private func saveBookmark() {
        guard let index = bookmarkChapterIndex else { return }

        if let existing = bookmarkFor(index: index) {
            modelContext.delete(existing)
        }

        let bookmark = Bookmark(
            chapterIndex: index,
            note: bookmarkNote.trimmingCharacters(in: .whitespaces),
            colorName: bookmarkColor.rawValue
        )
        bookmark.book = book
        modelContext.insert(bookmark)
        try? modelContext.save()
        saveBookData()
    }

    private func loadCoverImage() async {
        guard let thumbURL = book.thumbnailURL else { return }
        let loaded = await Task.detached(priority: .userInitiated) { () -> (UIImage, UIColor?)? in
            guard let data = try? Data(contentsOf: thumbURL),
                  let image = UIImage(data: data) else { return nil }
            return (image, image.dominantColor())
        }.value
        if let (image, uiColor) = loaded {
            coverImage = image
            if let uiColor {
                dominantColor = Color(uiColor)
            }
        }
    }

    // MARK: - Art Album

    private var artAlbumSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.green)
                    .frame(width: 28)

                if artImages.isEmpty {
                    Text("Add art")
                        .font(.subheadline)
                        .foregroundColor(.tertiaryText)
                } else {
                    Text("Art")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.8))

                    Text("\(artImages.count)")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundColor(.tertiaryText)
                }

                Spacer()

                PhotosPicker(selection: $selectedPhotoItems, matching: .images) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(theme.accent)
                }
            }

            if !artImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(artImages.enumerated()), id: \.element.id) { index, art in
                            Button {
                                let offset = (coverImage != nil) ? 1 : 0
                                artViewerItem = ArtViewerItem(index: index + offset)
                            } label: {
                                Image(uiImage: art.image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 100, height: 100)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Art Helpers

    private func loadArtImages() async {
        guard book.isSeries, let folderName = book.folderName else { return }
        guard let bookmarkData = UserDefaults.standard.data(forKey: book.bookmarkKey),
              let (rootURL, _) = try? LocalFileService.shared.resolveBookmark(bookmarkData),
              rootURL.startAccessingSecurityScopedResource() else { return }
        defer { rootURL.stopAccessingSecurityScopedResource() }

        let artFolder = rootURL.appendingPathComponent(folderName).appendingPathComponent("Art")

        let loaded = await Task.detached(priority: .userInitiated) { () -> [ArtItem] in
            let fm = FileManager.default
            guard fm.fileExists(atPath: artFolder.path) else { return [] }
            let contents = (try? fm.contentsOfDirectory(at: artFolder, includingPropertiesForKeys: nil)) ?? []
            let imageExts: Set<String> = ["jpg", "jpeg", "png", "heic", "webp", "gif"]
            let imageFiles = contents
                .filter { imageExts.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

            var items: [ArtItem] = []
            for file in imageFiles {
                if let data = try? Data(contentsOf: file),
                   let image = UIImage(data: data) {
                    items.append(ArtItem(id: file.lastPathComponent, image: image))
                }
            }
            return items
        }.value

        artImages = loaded
    }

    private func saveArtImage(_ data: Data) async {
        guard book.isSeries, let folderName = book.folderName else { return }

        guard let bookmarkData = UserDefaults.standard.data(forKey: book.bookmarkKey),
              let (rootURL, _) = try? LocalFileService.shared.resolveBookmark(bookmarkData),
              rootURL.startAccessingSecurityScopedResource() else { return }
        defer { rootURL.stopAccessingSecurityScopedResource() }

        let artFolder = rootURL.appendingPathComponent(folderName).appendingPathComponent("Art")

        if !FileManager.default.fileExists(atPath: artFolder.path) {
            try? FileManager.default.createDirectory(at: artFolder, withIntermediateDirectories: true)
        }

        let ext = imageFileExtension(from: data)
        let filename = "art_\(Int(Date().timeIntervalSince1970 * 1000)).\(ext)"
        let fileURL = artFolder.appendingPathComponent(filename)
        try? data.write(to: fileURL)
    }

    private func deleteArtFile(filename: String) async {
        guard book.isSeries, let folderName = book.folderName else { return }
        guard let bookmarkData = UserDefaults.standard.data(forKey: book.bookmarkKey),
              let (rootURL, _) = try? LocalFileService.shared.resolveBookmark(bookmarkData),
              rootURL.startAccessingSecurityScopedResource() else { return }
        defer { rootURL.stopAccessingSecurityScopedResource() }

        let artFolder = rootURL.appendingPathComponent(folderName).appendingPathComponent("Art")
        let fileURL = artFolder.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func openArtFolder() {
        guard book.isSeries, let folderName = book.folderName else { return }
        guard let bookmarkData = UserDefaults.standard.data(forKey: book.bookmarkKey),
              let (rootURL, _) = try? LocalFileService.shared.resolveBookmark(bookmarkData),
              rootURL.startAccessingSecurityScopedResource() else { return }
        defer { rootURL.stopAccessingSecurityScopedResource() }

        let artFolder = rootURL.appendingPathComponent(folderName).appendingPathComponent("Art")
        let encoded = artFolder.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? artFolder.path
        if let url = URL(string: "shareddocuments://\(encoded)") {
            UIApplication.shared.open(url)
        }
    }

    private func setImageAsCover(_ image: UIImage) async {
        guard let jpegData = image.jpegData(compressionQuality: 0.9) else { return }

        do {
            try await ImportService().setCustomCover(for: book, jpegData: jpegData, modelContext: modelContext)
            coverImage = image
            if let color = image.dominantColor() {
                dominantColor = Color(color)
            }
        } catch {
            print("Failed to set cover: \(error.localizedDescription)")
        }
    }

    private func imageFileExtension(from data: Data) -> String {
        guard data.count >= 12 else { return "jpg" }
        let bytes = [UInt8](data.prefix(12))
        if bytes[0] == 0x89 && bytes[1] == 0x50 { return "png" }
        if bytes[0] == 0xFF && bytes[1] == 0xD8 { return "jpg" }
        if bytes[0] == 0x47 && bytes[1] == 0x49 { return "gif" }
        if bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 { return "webp" }
        if bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70 { return "heic" }
        return "jpg"
    }

    private func chapterRow(chapter: Chapter, index: Int) -> some View {
        let isCurrentChapter = index == book.currentChapterIndex && book.readingProgress > 0
        let userBookmark = bookmarkFor(index: index)

        return HStack(spacing: 14) {
            Text("\((languageChapters.firstIndex { $0.id == chapter.id } ?? 0) + 1)")
                .font(.subheadline)
                .fontWeight(.bold)
                .foregroundColor(isCurrentChapter ? theme.accent : .tertiaryText)
                .frame(width: 32, alignment: .center)

            VStack(alignment: .leading, spacing: 3) {
                Text(chapter.displayName)
                    .font(.subheadline)
                    .fontWeight(isCurrentChapter ? .semibold : .regular)
                    .foregroundColor(.white)
                    .lineLimit(1)

                if let bm = userBookmark, !bm.note.isEmpty {
                    Text(bm.note)
                        .font(.caption2)
                        .foregroundColor(bm.bookmarkColor.color)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let bm = userBookmark {
                Image(systemName: "bookmark.fill")
                    .font(.caption)
                    .foregroundColor(bm.bookmarkColor.color)
            }

            if isCurrentChapter {
                Image(systemName: "bookmark.fill")
                    .font(.caption)
                    .foregroundColor(theme.accent)
            }

            Image(systemName: "chevron.right")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundColor(.tertiaryText)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(isCurrentChapter ? theme.accent.opacity(0.08) : Color.clear)
    }

    private func saveBookData() {
        Task { await BookDataService.shared.save(book: book) }
    }

    private func bookmarkFor(index: Int) -> Bookmark? {
        book.sortedBookmarks.first { $0.chapterIndex == index }
    }
}

#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: Book.self, Chapter.self, Bookmark.self, configurations: config)

    let book = Book(
        title: "One Piece",
        filename: "one_piece",
        filePath: "",
        totalPages: 600,
        isSeries: true,
        folderName: "One Piece",
        currentChapterIndex: 1
    )
    container.mainContext.insert(book)

    for i in 0..<12 {
        let ch = Chapter(filename: "Chapter \(i + 1).pdf", sortOrder: i, totalPages: 50, lastReadPage: i < 2 ? 30 : 0)
        ch.book = book
        container.mainContext.insert(ch)
    }

    return NavigationStack {
        ChapterListView(book: book)
    }
    .modelContainer(container)
    .environment(ThemeManager())
    .preferredColorScheme(.dark)
}
