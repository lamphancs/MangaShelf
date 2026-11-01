//
//  LibraryView.swift
//  MangaShelf
//
//  Created by Khoa Phan on 4/24/26.
//

import SwiftUI
import SwiftData
import PhotosUI
import WebKit

struct LibraryView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(ThemeManager.self) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @Query private var books: [Book]

    @State private var viewModel: LibraryViewModel
    @State private var summaryStore = LibrarySummaryStore()
    @State private var selectedBook: Book?
    @State private var navigationPath = NavigationPath()
    @State private var verificationBrowser: WebPageCaptureModel?
    @State private var checkID: UUID?
    @State private var onlineChapters: [URL: Double] = [:]
    @State private var checkMessage: String?
    @State private var showSettings = false
    @State private var showAddSeries = false
    @State private var newlyCreatedBook: Book?
    @State private var browseAfterCreation = false
    @State private var bookForCapture: Book?
    @State private var bookForCoverPick: Book?
    @State private var seriesForRename: Book?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @AppStorage(StorageKey.libraryViewMode) private var viewMode: LibraryViewMode = .grid

    @MainActor
    init(viewModel: LibraryViewModel? = nil) {
        _viewModel = State(initialValue: viewModel ?? LibraryViewModel())
    }

    private let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 20)
    ]

    var body: some View {
        let filteredBooks = viewModel.filteredAndSortedBooks(books)
        return NavigationStack(path: $navigationPath) {
            ZStack {
                theme.libraryBackground
                    .ignoresSafeArea()

                if filteredBooks.isEmpty {
                    VStack {
                        EmptyLibraryView {
                            showSettings = true
                        }
                        AddSeriesTile(isGrid: false) { showAddSeries = true }
                            .padding(20)
                    }
                } else {
                    ScrollView {
                        switch viewMode {
                        case .grid:
                            LazyVGrid(columns: columns, spacing: 24) {
                                ForEach(filteredBooks) { book in
                                    libraryCell(book, mode: .grid)
                                }
                                AddSeriesTile(isGrid: true) { showAddSeries = true }
                            }
                            .padding(.horizontal, 20)
                            .padding(.top, 20)
                            .padding(.bottom, 40)

                        case .list:
                            LazyVStack(spacing: 10) {
                                ForEach(filteredBooks) { book in
                                    libraryCell(book, mode: .list)
                                }
                                AddSeriesTile(isGrid: false) { showAddSeries = true }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 20)
                            .padding(.bottom, 40)
                        }
                    }
                    .scrollIndicators(.hidden)
                }


            }
            .searchable(text: $viewModel.searchText, prompt: "Search by title")
            .navigationTitle(viewModel.isSecretMode ? "Secret Shelf" : "Library")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: UUID.self) { bookID in
                if let book = books.first(where: { $0.id == bookID }) {
                    ChapterListView(book: book)
                }
            }
            .toolbar {
                DefaultToolbarItem(kind: .search, placement: .bottomBar)
                ToolbarSpacer(.fixed, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    Button("Add Series", systemImage: "plus") { showAddSeries = true }
                }

                ToolbarItem(placement: .topBarLeading) {
                    if !filteredBooks.isEmpty {
                        SortMenuView(selectedOption: $viewModel.sortOption)
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        checkID = UUID()
                    } label: {
                        if checkID != nil {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .tint(theme.accent)
                    .disabled(checkID != nil)
                    .accessibilityLabel("Check for new chapters")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    if !filteredBooks.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                viewMode = viewMode == .grid ? .list : .grid
                            }
                        } label: {
                            Image(systemName: viewMode == .grid ? "list.bullet" : "square.grid.2x2")
                                .font(.body)
                                .fontWeight(.semibold)
                                .foregroundColor(theme.accent)
                        }
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    if viewModel.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .tint(theme.accent)
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Image(systemName: "gearshape")
                        .font(.body)
                        .fontWeight(.semibold)
                        .foregroundColor(theme.accent)
                        .onTapGesture {
                            showSettings = true
                        }
                        .onLongPressGesture(minimumDuration: 5) {
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            withAnimation(.easeInOut(duration: 0.3)) {
                                viewModel.isSecretMode.toggle()
                            }
                        }
                }
            }
            .sheet(isPresented: $showSettings, onDismiss: {
                Task { await viewModel.quickRefresh(modelContext: modelContext) }
            }) {
                SettingsView(isSecretMode: viewModel.isSecretMode)
            }
            .sheet(isPresented: $showAddSeries, onDismiss: {
                if let book = newlyCreatedBook {
                    viewModel.searchText = ""
                    navigationPath.append(book.id)
                    if browseAfterCreation { bookForCapture = book }
                    browseAfterCreation = false
                    newlyCreatedBook = nil
                }
                Task { await viewModel.quickRefresh(modelContext: modelContext) }
            }) {
                AddSeriesView(isSecret: viewModel.isSecretMode) { book, browse in
                    newlyCreatedBook = book
                    browseAfterCreation = browse
                }
            }
            .fullScreenCover(item: $bookForCapture) { book in
                WebPageCaptureView(
                    url: book.seriesURL.flatMap(BookLinkKind.webURL) ?? NewSeriesDraft.defaultBrowseURL,
                    book: book
                )
            }
            .alert("Error", isPresented: $viewModel.showError) {
                Button("OK", role: .cancel) {}
            } message: {
                if let error = viewModel.errorMessage {
                    Text(error)
                }
            }
            .alert("Rename Book", isPresented: $viewModel.showRenameDialog) {
                TextField("Title", text: $viewModel.renameText)
                    .autocorrectionDisabled()

                Button("Cancel", role: .cancel) {
                    viewModel.selectedBook = nil
                }

                Button("Rename") {
                    Task {
                        await viewModel.confirmRename(modelContext: modelContext)
                    }
                }
            } message: {
                Text("Enter a new title for this book")
            }
            .sheet(item: $seriesForRename) { book in
                SeriesRenameSheet(book: book)
            }
            .fullScreenCover(item: $selectedBook) { book in
                ReaderView(book: book)
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhoto, matching: .images)
            .onChange(of: selectedPhoto) { _, newItem in
                guard let item = newItem else { return }
                Task {
                    await saveCover(from: item)
                    selectedPhoto = nil
                }
            }
        }
        .sheet(item: $verificationBrowser) { browser in
            NavigationStack {
                CaptureWebView(webView: browser.webView)
                    .navigationTitle("Verify on ToonGod")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        Button("Cancel Check") {
                            checkID = nil
                            verificationBrowser = nil
                        }
                    }
            }
            .interactiveDismissDisabled()
        }
        .task(id: checkID) {
            if checkID != nil { await checkForUpdates() }
        }
        .onChange(of: viewModel.isSecretMode) {
            checkID = nil
            checkMessage = nil
            verificationBrowser = nil
            onlineChapters = [:]
        }
        .alert("Chapter Check", isPresented: Binding(get: { checkMessage != nil }, set: { if !$0 { checkMessage = nil } })) {
            Button("OK") { checkMessage = nil }
        } message: {
            Text(checkMessage ?? "")
        }
        .task {
            await viewModel.quickRefresh(modelContext: modelContext)
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Reconcile when the user returns from Files-app edits, etc. Cheap thanks
            // to per-folder signature short-circuiting in `ImportService`.
            if newPhase == .active {
                Task { await viewModel.quickRefresh(modelContext: modelContext) }
            }
        }
    }

    private func libraryCell(_ book: Book, mode: LibraryViewMode) -> some View {
        let links = onlineChapters.isEmpty ? [] : sources(book)
        return LibraryBookCell(
            book: book, mode: mode, store: summaryStore,
            onlineEnglish: links.first { $0.english }.flatMap { onlineChapters[$0.page] },
            onlineVietnamese: links.first { !$0.english }.flatMap { onlineChapters[$0.page] },
            onTap: {
                if book.isSeries { navigationPath.append(book.id) }
                else { selectedBook = book }
            },
            onRename: { startRename(book) },
            onSetCover: {
                bookForCoverPick = book
                showPhotoPicker = true
            }
        )
    }

    private func sources(_ book: Book) -> [(page: URL, english: Bool)] {
        guard book.isSeries else { return [] }
        return [(book.seriesURL, book.latestChapterURL, false),
                (book.englishSeriesURL, book.englishLatestChapterURL, true)].compactMap { homepage, latest, english in
            let page = [homepage, latest].compactMap { value -> URL? in
                guard let value, let url = BookLinkKind.webURL(value) else { return nil }
                return ChapterUpdateSource.seriesPage(url)
            }.first
            guard let page else { return nil }
            return (page, english)
        }
    }

    private func checkForUpdates() async {
        let shelf = books.filter { $0.isSecret == viewModel.isSecretMode && $0.isAvailable && $0.isSeries }
        let pages = Set(shelf.flatMap { sources($0).map(\.page) })
        var failures: [URL: String] = [:]
        let dataStore: WKWebsiteDataStore = viewModel.isSecretMode ? .nonPersistent() : .default()
        var presentedVerification = false
        for page in pages {
            var requestedVerification = false
            do {
                let latest = try await ChapterUpdateSource.fetch(page, dataStore: dataStore) { browser in
                    requestedVerification = true
                    guard !presentedVerification else {
                        throw ChapterUpdateSource.CheckError(message: "ToonGod requested verification again. The check has stopped.")
                    }
                    presentedVerification = true
                    verificationBrowser = browser
                }
                guard !Task.isCancelled else { return }
                verificationBrowser = nil
                onlineChapters[page] = latest
            } catch {
                guard !Task.isCancelled else { return }
                if requestedVerification {
                    verificationBrowser = nil
                    checkID = nil
                    checkMessage = error.localizedDescription
                    return
                }
                failures[page] = error.localizedDescription
            }
        }
        guard !Task.isCancelled else { return }
        var issues: [String] = []
        var foundUpdate = false
        for book in shelf {
            let links = sources(book)
            guard !links.isEmpty else { continue }
            let key = LibrarySummaryKey(bookID: book.id, signature: book.folderSignature,
                                        chapterIndex: book.currentChapterIndex, needsChapterNumbers: true)
            let summary = try? await summaryStore.summary(for: key, in: modelContext.container)
            guard !Task.isCancelled else { return }
            for source in links {
                let label = source.english ? "\(book.title) (EN)" : book.title
                let local = source.english ? summary?.latestEnglish : summary?.latestVietnamese
                if let message = failures[source.page] {
                    issues.append("\(label) — \(message)")
                } else if let local, let remote = onlineChapters[source.page] {
                    if remote > local { foundUpdate = true }
                } else {
                    issues.append("\(label) — No numbered PDF found. Include the chapter number in a filename.")
                }
            }
        }
        checkID = nil
        if pages.isEmpty {
            checkMessage = "Add a ToonGod series link in Info to check for new chapters."
        } else if !issues.isEmpty {
            checkMessage = issues.joined(separator: "\n\n")
        } else if !foundUpdate {
            checkMessage = "No new chapters found on the checked sources."
        }
    }

    /// Series rename both the title and the folder on disk; single PDFs rename the title only.
    private func startRename(_ book: Book) {
        if book.isSeries, book.folderName != nil {
            seriesForRename = book
        } else {
            viewModel.showRename(for: book)
        }
    }

    private func saveCover(from item: PhotosPickerItem) async {
        guard let book = bookForCoverPick else { return }

        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data),
              let jpegData = image.jpegData(compressionQuality: 0.9) else { return }

        do {
            try await ImportService().setCustomCover(for: book, jpegData: jpegData, modelContext: modelContext)
        } catch {
            print("Failed to set cover: \(error.localizedDescription)")
        }

        bookForCoverPick = nil
    }
}

#Preview {
    LibraryView()
        .modelContainer(for: [Book.self, Chapter.self], inMemory: true)
        .environment(ThemeManager())
        .preferredColorScheme(.dark)
}
