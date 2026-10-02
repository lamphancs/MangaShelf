//
//  MangaShelfApp.swift
//  MangaShelf
//
//  Created by Khoa Phan on 4/24/26.
//

import SwiftUI
import SwiftData

@main
struct MangaShelfApp: App {

    let modelContainer: ModelContainer
    @State private var themeManager = ThemeManager()
    @State private var libraryViewModel = LibraryViewModel()
    @State private var isReady = false

    init() {
        do {
            modelContainer = try ModelContainer(for: Book.self, Chapter.self, Bookmark.self)
        } catch {
            fatalError("Failed to initialize SwiftData container: \(error)")
        }
        LocalFileService.shared.migrateThumbnailsIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                LibraryView(viewModel: libraryViewModel)
                    .modelContainer(modelContainer)
                    .environment(themeManager)
                    .opacity(isReady ? 1 : 0)
                    .allowsHitTesting(isReady)
                    .accessibilityHidden(!isReady)

                if !isReady {
                    SplashScreenView { isSecretMode in
                        libraryViewModel.isSecretMode = isSecretMode
                        withAnimation(.easeInOut(duration: 0.4)) {
                            isReady = true
                        }
                    }
                    .transition(.opacity)
                }
            }
            .preferredColorScheme(.dark)
        }
    }
}
