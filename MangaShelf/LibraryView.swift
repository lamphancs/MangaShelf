//
//  LibraryView.swift
//  MangaShelf
//
//  Created by Khoa Phan on 4/24/26.
//

import SwiftUI
import SwiftData
import PhotosUI

struct LibraryView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(ThemeManager.self) private var theme
    @Query private var books: [Book]

    @State private var viewModel = LibraryViewModel()
    @State private var selectedBook: Book?
    @State private var navigationPath = NavigationPath()
    @State private var showSettings = false
    @State private var bookForCoverPick: Book?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @AppStorage("libraryViewMode") private var viewMode: LibraryViewMode = .grid

    private let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 20)
    ]

    private var filteredBooks: [Book] {
        viewModel.filteredAndSortedBooks(books)
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                theme.libraryBackground
                    .ignoresSafeArea()

                if filteredBooks.isEmpty {
                    EmptyLibraryView {
                        showSettings = true
                    }
                } else {
                    ScrollView {
                        switch viewMode {
                        case .grid:
                            LazyVGrid(columns: columns, spacing: 24) {
                                ForEach(filteredBooks) { book in
                                    BookCardView(
                                        book: book,
                                        onTap: {
                                            if book.isSeries {
                                                navigationPath.append(book.id)
                                            } else {
                                                selectedBook = book
                                            }
                                        },
                                        onRename: {
                                            viewModel.showRename(for: book)
                                        },
                                        onSetCover: {
                                            bookForCoverPick = book
                                            showPhotoPicker = true
                                        }
                                    )
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.top, 20)
                            .padding(.bottom, 40)

                        case .list:
                            LazyVStack(spacing: 10) {
                                ForEach(filteredBooks) { book in
                                    BookRowView(
                                        book: book,
                                        onTap: {
                                            if book.isSeries {
                                                navigationPath.append(book.id)
                                            } else {
                                                selectedBook = book
                                            }
                                        },
                                        onRename: {
                                            viewModel.showRename(for: book)
                                        },
                                        onSetCover: {
                                            bookForCoverPick = book
                                            showPhotoPicker = true
                                        }
                                    )
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 20)
                            .padding(.bottom, 40)
                        }
                    }
                }

                if viewModel.isLoading {
                    ZStack {
                        Color.black.opacity(0.4)
                            .ignoresSafeArea()

                        ProgressView()
                            .tint(theme.accent)
                            .scaleEffect(1.5)
                            .padding(40)
                            .background(theme.cardBackground)
                            .cornerRadius(16)
                    }
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
                ToolbarItem(placement: .topBarLeading) {
                    if !filteredBooks.isEmpty {
                        SortMenuView(selectedOption: $viewModel.sortOption)
                    }
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
                Task { await viewModel.scanLibrary(modelContext: modelContext) }
            }) {
                SettingsView(isSecretMode: viewModel.isSecretMode)
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
        .task {
            await viewModel.scanLibrary(modelContext: modelContext)
        }
    }
    private func saveCover(from item: PhotosPickerItem) async {
        guard let book = bookForCoverPick else { return }

        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data),
              let jpegData = image.jpegData(compressionQuality: 0.9) else { return }

        let filename = ImportService().customCoverName(for: book.folderName ?? book.filename)
        let thumbnailDir = LocalFileService.shared.thumbnailsDirectory
        let fileURL = thumbnailDir.appendingPathComponent(filename)

        if let oldPath = book.thumbnailPath {
            let oldURL = thumbnailDir.appendingPathComponent(oldPath)
            try? FileManager.default.removeItem(at: oldURL)
        }

        do {
            try jpegData.write(to: fileURL)
            ThumbnailService.shared.evictCachedImage(for: fileURL)
            book.thumbnailPath = filename
            book.hasManualCover = true
            book.coverVersion += 1
            try modelContext.save()
        } catch {}

        bookForCoverPick = nil
    }
}

#Preview {
    LibraryView()
        .modelContainer(for: [Book.self, Chapter.self], inMemory: true)
        .environment(ThemeManager())
        .preferredColorScheme(.dark)
}
