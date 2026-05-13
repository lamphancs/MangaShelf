# MangaShelf

iOS 18+ SwiftUI manga/comic reader that imports PDF files from user-selected folders on device.

## Feature Map

| Feature | Entry Point |
|---|---|
| Library grid/list with search & sort | `LibraryView` → `BookCardView` / `BookRowView` |
| Folder import (series & standalone PDFs) | `ImportService.scanRootFolder()` |
| PDF reader (single-page, scroll modes) | `ReaderView` → `ReaderViewModel` → `PDFPageView` |
| Chapter navigation for multi-PDF series | `ChapterListView` |
| Art album (photos picker + viewer overlay) | `ChapterListView` art section → `ArtViewerOverlay` |
| Reading progress & bookmarks | `Book.readingProgress`, `Bookmark` model |
| Secret library (hidden behind long-press) | `isSecret` flag on `Book`, separate bookmark key |
| Theme & accent color customization | `ThemeManager` (persisted via UserDefaults) |
| Splash screen | `SplashScreenView` |
| Settings (folder picker, reset, theme) | `SettingsView` |

## Data Layer

**Persistence:** SwiftData with `ModelContainer(for: Book.self, Chapter.self, Bookmark.self)`.

### Models

- **Book** — A manga title. Can be a single PDF (`isSeries == false`) or a folder of chapter PDFs (`isSeries == true`). Key fields: `filename`, `folderName`, `thumbnailPath`, `isSecret`, `isAvailable`, `hasManualCover`, `coverVersion`. Legacy fields `filePath` and `bookmarkData` are unused but retained to avoid requiring a `VersionedSchema` migration.
- **Chapter** — A single PDF within a series. Linked to `Book` via `@Relationship` with cascade delete. Sorted by `sortOrder`.
- **Bookmark** — A user bookmark pinned to a chapter index with a color and optional note. Linked to `Book` with cascade delete.

### UserDefaults Keys

All keys are centralized in `StorageKey` (Constants.swift): root/secret folder bookmarks, folder display names, thumbnail migration flag, theme/accent selections, library view mode.

## Service Layer

| Service | Responsibility |
|---|---|
| `LocalFileService` | Security-scoped bookmark resolution, file existence/size checks, thumbnail directory management, one-time migration from Caches → Application Support |
| `ImportService` | Scans root/secret folders, upserts `Book`/`Chapter` records, generates thumbnails, handles rename and custom cover operations |
| `ThumbnailService` | Generates PDF first-page thumbnails, manages `NSCache<NSString, UIImage>` (100 items / 50 MB), provides async cached image loading |
| `FileSourceProtocol` | Abstraction over file operations (resolve bookmark, delete, exists, size) for testability |

## Key Flows

### Folder Import
1. User picks a folder via `UIDocumentPickerViewController` in `SettingsView`
2. A security-scoped bookmark is saved to UserDefaults
3. `ImportService.scanFolder()` resolves the bookmark, enumerates subfolders (series) and loose PDFs
4. For each entry, it upserts a `Book`, creates/updates `Chapter` records for series, and generates a thumbnail via `ThumbnailService`
5. Books no longer present on disk are marked `isAvailable = false`

### PDF Reading
1. `ReaderView` receives a `Book` and optional chapter index
2. `ReaderViewModel` resolves the security-scoped bookmark, opens the PDF, and loads pages
3. `PDFPageView` renders individual pages using a `CALayer`-based `UIViewRepresentable` (not PDFKit's `PDFView`)
4. Progress is saved to `Book.lastReadPage` / `Book.currentChapterIndex`

### Thumbnail Caching
- Thumbnails are stored as JPEG files in `Application Support/Thumbnails/`
- `ThumbnailService` maintains an in-memory `NSCache` for loaded `UIImage` instances
- Cover version tracking (`Book.coverVersion`) invalidates stale cached views

## File Structure

```
MangaShelf/MangaShelf/
├── App/                        MangaShelfApp.swift
├── Models/                     Book, Chapter, Bookmark
├── ViewModels/                 LibraryViewModel, ReaderViewModel
├── Views/
│   ├── Library/                LibraryView, BookCardView, BookRowView,
│   │                           EmptyLibraryView, SortMenuView
│   ├── ChapterDetail/          ChapterListView, ArtViewerOverlay
│   ├── Reader/                 ReaderView, ReaderOverlayView, PDFPageView
│   ├── Settings/               SettingsView
│   └── Components/             SplashScreenView
├── Services/                   FileSourceProtocol, ImportService,
│                               LocalFileService, ThumbnailService
├── Utilities/                  Constants, Extensions, ThemeManager
└── Resources/                  Assets.xcassets
```

## Known Limitations

- `Book.filePath` and `Book.bookmarkData` are dead properties. They cannot be removed without adding a `VersionedSchema` migration, which is out of scope for a refactor-only pass.
- The app is dark-mode only (`preferredColorScheme(.dark)`).
- No unit or UI tests exist yet.
- `PDFPageView` uses raw `CALayer` rendering rather than `PDFKit`'s `PDFView`, which means zoom/text-selection are handled manually.
