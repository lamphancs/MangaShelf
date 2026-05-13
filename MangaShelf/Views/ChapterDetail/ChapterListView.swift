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

    @State private var showReader = false
    @State private var isSyncing = false
    @State private var coverImage: UIImage?
    @State private var dominantColor: Color?
    @State private var sortAscending = false
    @State private var showAddBookmark = false
    @State private var bookmarkChapterIndex: Int?
    @State private var bookmarkNote = ""
    @State private var bookmarkColor: BookmarkColor = .red
    @State private var showEditSeriesURL = false
    @State private var seriesURLInput = ""
    @State private var showEditSeriesNote = false
    @State private var seriesNoteInput = ""
    @State private var showInfoBox = false
    @State private var showLinkActions = false
    @State private var artImages: [ArtItem] = []
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var artViewerItem: ArtViewerItem?

    private struct ArtViewerItem: Identifiable {
        let id = UUID()
        let index: Int
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
        .background(theme.libraryBackground)
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(theme.libraryBackground, for: .navigationBar)
        .fullScreenCover(isPresented: $showReader) {
            ReaderView(book: book)
        }
        .task {
            await syncChapters()
            await loadCoverImage()
            await loadArtImages()
        }
        .sheet(isPresented: $showAddBookmark) {
            addBookmarkSheet
        }
        .sheet(isPresented: $showEditSeriesURL) {
            editSeriesURLSheet
        }
        .sheet(isPresented: $showEditSeriesNote) {
            editSeriesNoteSheet
        }
        .sheet(isPresented: $showLinkActions) {
            linkActionsSheet
        }
        .fullScreenCover(item: $artViewerItem, onDismiss: {
            Task { await loadArtImages() }
        }) { item in
            ArtViewerOverlay(
                artImages: artImages,
                initialIndex: item.index,
                onDeleteFile: { filename in
                    await deleteArtFile(filename: filename)
                },
                onSetCover: { image in
                    await setImageAsCover(image)
                }
            )
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

    private var coverHeader: some View {
        VStack {
            if let cover = coverImage {
                let aspect = cover.size.width / cover.size.height
                Color.clear
                    .aspectRatio(aspect, contentMode: .fit)
                    .frame(maxHeight: maxCoverHeight)
                    .overlay {
                        Image(uiImage: cover)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: (dominantColor ?? theme.accent).opacity(0.6), radius: 40, x: 0, y: 0)
                    .shadow(color: (dominantColor ?? theme.accent).opacity(0.3), radius: 80, x: 0, y: 0)
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
                book.currentChapterIndex = 0
                if let firstChapter = book.sortedChapters.first {
                    firstChapter.lastReadPage = 0
                }
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
                showReader = true
            } label: {
                VStack(spacing: 5) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 16))
                        .foregroundColor(theme.accent)

                    if book.readingProgress > 0,
                       let chapter = book.sortedChapters[safe: book.currentChapterIndex] {
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
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Series Info Box

    private var seriesInfoBox: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "link")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.accent)
                    .frame(width: 28)

                if let urlString = book.seriesURL, !urlString.isEmpty,
                   let url = URL(string: urlString) {
                    Button {
                        showLinkActions = true
                    } label: {
                        Text(url.host ?? urlString)
                            .font(.subheadline)
                            .foregroundColor(theme.accent)
                            .lineLimit(1)
                    }

                    Spacer()

                    Button {
                        seriesURLInput = urlString
                        showEditSeriesURL = true
                    } label: {
                        Image(systemName: "pencil.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.white.opacity(0.15))
                    }
                } else {
                    Button {
                        seriesURLInput = ""
                        showEditSeriesURL = true
                    } label: {
                        Text("Add link")
                            .font(.subheadline)
                            .foregroundColor(.tertiaryText)
                    }
                    Spacer()
                }
            }

            Rectangle()
                .fill(Color.white.opacity(0.04))
                .frame(height: 1)

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "note.text")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.yellow)
                    .frame(width: 28)

                if let note = book.seriesNote, !note.isEmpty {
                    Text(note)
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        seriesNoteInput = note
                        showEditSeriesNote = true
                    } label: {
                        Image(systemName: "pencil.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.white.opacity(0.15))
                    }
                } else {
                    Button {
                        seriesNoteInput = ""
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
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
        )
    }

    // MARK: - Link Actions

    private var linkActionsSheet: some View {
        VStack(spacing: 0) {
            if let urlString = book.seriesURL, !urlString.isEmpty,
               let url = URL(string: urlString) {

                Text(url.host ?? urlString)
                    .font(.caption)
                    .foregroundColor(.secondaryText)
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                linkActionRow(icon: "safari", title: "Open in Safari") {
                    showLinkActions = false
                    UIApplication.shared.open(url)
                }

                if let chromeURL = chromeURL(from: url) {
                    linkActionRow(icon: "globe", title: "Open in Chrome") {
                        showLinkActions = false
                        UIApplication.shared.open(chromeURL)
                    }
                }

                Divider()
                    .padding(.horizontal, 20)

                linkActionRow(icon: "doc.on.doc", title: "Copy Link") {
                    UIPasteboard.general.string = urlString
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    showLinkActions = false
                }
            }
        }
        .padding(.bottom, 8)
        .presentationDetents([.height(220)])
        .presentationDragIndicator(.visible)
        .presentationBackground(theme.cardBackground)
        .preferredColorScheme(.dark)
    }

    private func linkActionRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(theme.accent)
                    .frame(width: 24)
                Text(title)
                    .font(.subheadline)
                    .foregroundColor(.white)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
    }

    private func chromeURL(from url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        let chromeScheme = scheme == "https" ? "googlechromes" : "googlechrome"
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = chromeScheme
        return components?.url
    }

    // MARK: - Chapters Header

    private var chaptersHeader: some View {
        HStack {
            Text("Chapters")
                .font(.headline)
                .foregroundColor(.white)
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
        let allChapters = book.sortedChapters
        let displayChapters = sortAscending ? allChapters : allChapters.reversed()

        return LazyVStack(spacing: 0) {
            ForEach(Array(displayChapters.enumerated()), id: \.element.id) { displayIndex, chapter in
                let originalIndex = sortAscending ? displayIndex : (allChapters.count - 1 - displayIndex)
                Button {
                    book.currentChapterIndex = originalIndex
                    chapter.lastReadPage = 0
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
                        } label: {
                            Label("Remove Bookmark", systemImage: "bookmark.slash")
                        }
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
            try await ImportService().syncSeriesFromRoot(book, modelContext: modelContext)
        } catch {
            print("Failed to sync chapters: \(error.localizedDescription)")
        }
    }

    private var addBookmarkSheet: some View {
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

                if let idx = bookmarkChapterIndex,
                   let chapter = book.sortedChapters[safe: idx] {
                    Section {
                        Text(chapter.displayName)
                            .foregroundColor(.secondaryText)
                    } header: {
                        Text("Chapter")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.libraryBackground)
            .navigationTitle("Add Bookmark")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        showAddBookmark = false
                    }
                    .foregroundColor(.secondaryText)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        saveBookmark()
                        showAddBookmark = false
                    }
                    .fontWeight(.semibold)
                    .foregroundColor(theme.accent)
                }
            }
        }
        .presentationDetents([.medium])
        .preferredColorScheme(.dark)
    }

    private var editSeriesURLSheet: some View {
        NavigationStack {
            Form {
                Section("Series URL") {
                    TextField("https://...", text: $seriesURLInput)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                if let existing = book.seriesURL, !existing.isEmpty {
                    Section {
                        Button(role: .destructive) {
                            book.seriesURL = nil
                            try? modelContext.save()
                            showEditSeriesURL = false
                        } label: {
                            Label("Remove Link", systemImage: "trash")
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.libraryBackground)
            .navigationTitle("Series Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        showEditSeriesURL = false
                    }
                    .foregroundColor(.secondaryText)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        let trimmed = seriesURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        book.seriesURL = trimmed.isEmpty ? nil : trimmed
                        try? modelContext.save()
                        showEditSeriesURL = false
                    }
                    .fontWeight(.semibold)
                    .foregroundColor(theme.accent)
                }
            }
        }
        .presentationDetents([.medium])
        .preferredColorScheme(.dark)
    }

    private var editSeriesNoteSheet: some View {
        NavigationStack {
            Form {
                Section("Note") {
                    TextEditor(text: $seriesNoteInput)
                        .frame(minHeight: 120)
                        .scrollContentBackground(.hidden)
                }

                if let existing = book.seriesNote, !existing.isEmpty {
                    Section {
                        Button(role: .destructive) {
                            book.seriesNote = nil
                            try? modelContext.save()
                            showEditSeriesNote = false
                        } label: {
                            Label("Remove Note", systemImage: "trash")
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.libraryBackground)
            .navigationTitle("Series Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        showEditSeriesNote = false
                    }
                    .foregroundColor(.secondaryText)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        let trimmed = seriesNoteInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        book.seriesNote = trimmed.isEmpty ? nil : trimmed
                        try? modelContext.save()
                        showEditSeriesNote = false
                    }
                    .fontWeight(.semibold)
                    .foregroundColor(theme.accent)
                }
            }
        }
        .presentationDetents([.medium])
        .preferredColorScheme(.dark)
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
                                artViewerItem = ArtViewerItem(index: index)
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

    private func setImageAsCover(_ image: UIImage) async {
        guard let jpegData = image.jpegData(compressionQuality: 0.9) else { return }

        do {
            try ImportService().setCustomCover(for: book, jpegData: jpegData, modelContext: modelContext)
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
            Text("\(index + 1)")
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
