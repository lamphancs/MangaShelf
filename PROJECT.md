# MangaShelf

## 1. App Overview

MangaShelf is an iOS 18+ SwiftUI manga/comic reader that imports PDF files from user-selected folders on device. Users pick a root folder containing manga series (subfolders of chapter PDFs) or standalone PDF files. The app scans, catalogs, and renders them with a custom CALayer-based PDF renderer. It supports reading progress tracking, bookmarks, art albums, cover customization, and a hidden "secret shelf" library. Architecture is MVVM with SwiftData for persistence and security-scoped bookmarks for file access.

## 2. Feature Map

| Feature | Description | Key Files |
|---|---|---|
| Library grid/list | Browsable library with search, sort (recently added / A-Z / last read), grid/list toggle | `LibraryView`, `BookCardView`, `BookRowView`, `EmptyLibraryView`, `SortMenuView`, `LibraryViewModel` |
| Folder import | Scans root folder for series subfolders and loose PDFs, upserts Book/Chapter records, generates thumbnails | `ImportService`, `SettingsView` |
| PDF reader | Custom CALayer-based full-screen reader with continuous vertical scroll | `ReaderView`, `ReaderViewModel`, `PDFPageView` |
| Chapter navigation | Chapter list with sort toggle, jump-to-chapter from reader overlay, prev/next chapter buttons | `ChapterListView`, `ReaderOverlayView`, `ReaderViewModel` |
| Art album | Photos picker to add images, horizontal thumbnail strip, full-screen viewer with swipe navigation and drag-to-dismiss | `ChapterListView` art section, `ArtViewerOverlay` |
| Cover carousel | Swipe cover image to browse art, tap to expand into full-screen viewer | `ChapterListView` coverHeader TabView, `ArtViewerOverlay` |
| Cover crop selection | Draggable 2:3 crop box over any art image, outputs 400x600 JPEG as custom cover | `CoverCropOverlay`, `ArtViewerOverlay` |
| Reader screenshot capture | Floating camera button captures current viewport to series Art folder | `ReaderView`, `ReaderViewModel.captureCurrentPage()` |
| Reading progress & bookmarks | Per-chapter page tracking, colored bookmarks with optional notes | `Book.readingProgress`, `Bookmark` model, `ChapterListView` |
| Portable series data | Notes, links, progress, and bookmarks saved to `.mangashelf/data.json` inside each series folder | `BookDataService` |
| Secret library | Hidden library behind 5-second long-press on settings icon, separate folder bookmark | `Book.isSecret`, `LibraryView` long-press gesture, `SettingsView` secret section |
| Theme & accent customization | 4 dark themes + 6 accent colors, persisted via UserDefaults | `ThemeManager`, `SettingsView` |
| Splash screen | Animated launch screen with icon + title fade-in | `SplashScreenView` |
| Settings | Folder picker, rescan, open in Files, theme/accent selection | `SettingsView` |

## 3. Data Layer

**Persistence:** SwiftData with `ModelContainer(for: Book.self, Chapter.self, Bookmark.self)` created in `MangaShelfApp.init()`.

### Book (`@Model`)

| Property | Type | Purpose |
|---|---|---|
| `id` | `UUID` | Unique identifier |
| `title` | `String` | Display title (cleaned from filename) |
| `filename` | `String` | Original filename or folder name |
| `filePath` | `String` | **DEPRECATED.** Legacy absolute path, never read. Retained to avoid VersionedSchema migration. Set to folder/filename during creation. |
| `thumbnailPath` | `String?` | Filename of cached cover thumbnail JPEG in `Application Support/Thumbnails/` |
| `lastReadPage` | `Int` | Last page read (0-indexed), used for single-PDF books |
| `totalPages` | `Int` | Total page count (single PDF) or sum of all chapter pages (series) |
| `dateAdded` | `Date` | When the book was added to the library |
| `lastReadDate` | `Date?` | When the book was last opened for reading |
| `fileSize` | `Int64` | File size in bytes (sum of all chapters for series) |
| `isSeries` | `Bool` | `true` if this is a folder of chapter PDFs |
| `folderName` | `String?` | Folder name in root directory (series only) |
| `currentChapterIndex` | `Int` | Index into `sortedChapters` for current reading position (series only) |
| `bookmarkData` | `Data?` | **DEPRECATED.** Unused, retained for migration avoidance. Always `nil`. |
| `hasManualCover` | `Bool` | `true` if user set a custom cover (prevents overwrite on rescan) |
| `coverVersion` | `Int` | Incremented on cover change, used to invalidate cached thumbnail views |
| `isSecret` | `Bool` | `true` if book belongs to the secret shelf |
| `isAvailable` | `Bool` | `false` when source files are no longer present in root folder |
| `seriesURL` | `String?` | User-provided URL link for the series |
| `seriesNote` | `String?` | User-provided note for the series |
| `chapters` | `[Chapter]?` | `@Relationship(deleteRule: .cascade, inverse: \Chapter.book)` |
| `bookmarks` | `[Bookmark]?` | `@Relationship(deleteRule: .cascade, inverse: \Bookmark.book)` |

Computed properties: `sortedChapters`, `readingProgress`, `sortedBookmarks`, `bookmarkKey`, `thumbnailURL`, `chapterProgressLabel()`.

### Chapter (`@Model`)

| Property | Type | Purpose |
|---|---|---|
| `id` | `UUID` | Unique identifier |
| `filename` | `String` | PDF filename within the series folder |
| `sortOrder` | `Int` | Position in the sorted chapter list |
| `totalPages` | `Int` | Page count for this chapter's PDF |
| `lastReadPage` | `Int` | Last page read in this chapter (0-indexed) |
| `book` | `Book?` | Inverse relationship to parent Book |

Computed properties: `displayName` (strips extension, replaces `_`/`-` with spaces), `extractedNumber` (last numeric segment from display name), `pdfURL(folderURL:)`.

### Bookmark (`@Model`)

| Property | Type | Purpose |
|---|---|---|
| `id` | `UUID` | Unique identifier |
| `chapterIndex` | `Int` | Index of the bookmarked chapter |
| `note` | `String` | Optional user note |
| `colorName` | `String` | Raw value of `BookmarkColor` enum |
| `dateCreated` | `Date` | Creation timestamp |
| `book` | `Book?` | Inverse relationship to parent Book |

Supporting enum: `BookmarkColor` (11 system colors, `.red` through `.pink`).

### UserDefaults Keys (`StorageKey`)

| Key | Purpose |
|---|---|
| `rootFolderBookmark` | Security-scoped bookmark data for the main library folder |
| `secretFolderBookmark` | Security-scoped bookmark data for the secret library folder |
| `rootFolderName` | Display name of the root folder |
| `secretFolderName` | Display name of the secret folder |
| `thumbnailsMigrated` | Flag: one-time migration from Caches to Application Support completed |
| `appTheme` | Selected `AppTheme` raw value |
| `accentTheme` | Selected `AccentTheme` raw value |
| `libraryViewMode` | Grid or list mode for library display |

## 4. Service Layer

### LocalFileService (singleton)

**Responsibility:** Security-scoped bookmark resolution, file existence/size checks, thumbnail directory management, one-time thumbnail migration from Caches to Application Support.

- `resolveBookmark(_ data: Data) -> (url: URL, isStale: Bool)` - Resolves bookmark data to a URL
- `fileExists(at:)` / `fileSize(at:)` - File system queries
- `thumbnailsDirectory` - Computed URL for `Application Support/Thumbnails/`, creates directory if missing
- `urlForThumbnail(named:)` - Constructs full URL for a thumbnail filename
- `migrateThumbnailsIfNeeded()` - One-time migration of thumbnails from Caches (old location) to Application Support

Conforms to `FileSourceProtocol` for testability abstraction.

### ImportService

**Responsibility:** Scans root/secret folders, upserts Book/Chapter records, generates thumbnails, handles rename and custom cover operations.

- `scanRootFolder(modelContext:)` / `scanSecretFolder(modelContext:)` - Full library scan
- `syncSeriesFromRoot(_:modelContext:)` - Syncs a single series by resolving the root bookmark
- `renameBook(_:to:modelContext:)` - Updates book title
- `setCustomCover(for:jpegData:modelContext:)` - Saves custom cover JPEG, evicts old cache entry, updates Book
- `customCoverName(for:)` - Generates safe filename for custom covers

**Dependencies:** `FileSourceProtocol` (for fileSize), `ThumbnailService` (for thumbnail generation and page counts), `LocalFileService` (direct calls for bookmark resolution and thumbnail paths), `BookDataService` (restores portable data on series creation).

### ThumbnailService (singleton)

**Responsibility:** Generates PDF first-page thumbnails (400x600 JPEG), manages `NSCache<NSString, UIImage>` (100 items / 50 MB limit), provides async cached image loading with aspect-fill scaling.

- `generateThumbnail(for:identifier:)` - Renders first PDF page to JPEG, saves to thumbnail directory
- `cachedImage(for:targetSize:)` - Loads from NSCache or disk, scales to target size with aspect-fill
- `evictCachedImage(for:)` - Removes a specific entry from NSCache
- `getPageCount(for:)` - Returns PDF page count via PDFKit

### BookDataService (singleton)

**Responsibility:** Reads/writes `.mangashelf/data.json` inside each series folder. Syncs notes, links, reading progress, chapter progress, and bookmarks to disk so data travels with the folder.

- `save(book:)` - Resolves bookmark internally, writes data.json
- `save(book:seriesFolderURL:)` - Writes data.json to a pre-resolved URL (used by ReaderViewModel)
- `load(seriesFolderURL:)` - Reads and decodes data.json
- `restoreIfNeeded(book:modelContext:)` - Merges disk data into SwiftData when SwiftData fields are empty (one-way merge on series open)

Data format: `BookSeriesData` Codable struct with `note`, `url`, `currentChapterIndex`, `lastReadDate`, `bookmarks` array, `chapterProgress` dictionary.

### FileSourceProtocol

Protocol abstraction over file operations (`resolveBookmark`, `fileExists`, `fileSize`). Only conformer is `LocalFileService`. Intended for testability but not fully utilized by `ImportService` (which also calls `LocalFileService.shared` directly).

## 5. Key Flows

### Folder Import Flow

1. User opens `SettingsView` and taps "Select Manga Folder"
2. `fileImporter` presents a `UIDocumentPickerViewController` for `.folder`
3. On selection, a security-scoped bookmark is saved to UserDefaults (`rootFolderBookmark`)
4. The folder display name is saved to UserDefaults (`rootFolderName`)
5. `ImportService.scanRootFolder()` is called:
   a. Resolves the bookmark to a URL, refreshes if stale
   b. Enumerates root contents: subfolders with PDFs become series, loose PDFs become single books
   c. For each series folder: upserts a `Book` (isSeries=true), creates/updates `Chapter` records, generates thumbnail from first PDF page
   d. For each single PDF: upserts a `Book` (isSeries=false), generates thumbnail
   e. Books no longer present on disk are marked `isAvailable = false`
   f. On new series creation, checks for existing `.mangashelf/data.json` and restores portable data
6. `modelContext.save()` persists all changes

### PDF Reading Flow

1. User taps a book in `LibraryView` (single PDF opens `ReaderView` directly; series opens `ChapterListView` first)
2. `ReaderViewModel.init(book:)` resolves the security-scoped bookmark, opens the PDF via `PDFDocument(url:)`, sets initial page from saved progress
3. `PDFPageView` (UIViewRepresentable) creates a `UIScrollView` containing a `PDFContentView`
4. `PDFContentView.configure()` calculates page rects (offsets + heights), creates one `CALayer` per page
5. As the user scrolls, `scrollViewDidScroll` performs binary search on `pageOffsets` to determine current page
6. `PDFContentView.updateCenter(page:)` triggers async rendering of nearby pages (4-page window, forward-biased)
7. Rendering: each page is drawn at screen-scale resolution using `UIGraphicsImageRenderer` + `PDFPage.draw()` on a background `OperationQueue` (max 4 concurrent), then applied to the CALayer on the main thread
8. Pages outside the active window are evicted (layer contents set to nil, CGImage released)
9. On scroll end, `ReaderViewModel.debounceSave()` saves progress after 2 seconds of inactivity
10. On dismiss, `saveProgress()` writes to SwiftData and `BookDataService` (for series)

### Chapter Navigation Flow

1. In reader: overlay shows prev/next buttons and chapter picker
2. `goToNextChapter()` / `goToPreviousChapter()` / `goToChapter(index:)` all call `navigateToChapter(index:)`
3. Current chapter's `lastReadPage` is saved
4. `pdfDocument` is set to nil (clears current render), `isLoadingChapter = true`
5. New PDF is loaded on a detached task
6. On completion: `currentChapterIndex` updated, `pdfDocument` set, book saved to SwiftData

### Series URL / Note Flow

1. In `ChapterListView`, user taps info button to show `seriesInfoBox`
2. URL row: tap to open link actions sheet (Safari, Chrome, Copy), pencil icon to edit
3. Note row: tap to edit in a TextEditor sheet
4. On save: SwiftData updated, `BookDataService.save()` writes to `.mangashelf/data.json`

### Art Album Flow

1. In `ChapterListView` info box, art section shows thumbnails from `SeriesFolder/Art/`
2. User can add images via PhotosPicker (saved as timestamped files to Art folder)
3. User can capture reader screenshots (floating camera button in `ReaderView`)
4. Tapping an art thumbnail opens `ArtViewerOverlay` (full-screen cover with swipe navigation)
5. From viewer: "Use as Cover Image" opens `CoverCropOverlay`, "Show in Files" opens the Art folder in Files app
6. `CoverCropOverlay`: draggable 2:3 box over the image, renders to 400x600 JPEG on confirm

### Cover Customization Flow

1. From library: long-press context menu "Set Cover" opens PhotosPicker
2. From art viewer: "Use as Cover Image" opens crop overlay
3. Both paths call `ImportService.setCustomCover()`: saves JPEG to thumbnail dir, evicts old cache, sets `hasManualCover = true`, increments `coverVersion`
4. `coverVersion` change triggers thumbnail reload in `BookCardView`/`BookRowView` via `.task(id:)`

### Portable Series Data Flow

1. Each series folder can contain `.mangashelf/data.json`
2. On series creation (`ImportService.createSeries`): if data.json exists, its contents are restored into SwiftData
3. On series open (`ChapterListView.task`): `BookDataService.restoreIfNeeded()` merges disk data into SwiftData (only fills empty fields, doesn't overwrite)
4. On every edit (note, link, bookmark, progress): both SwiftData and data.json are updated via `BookDataService.save()`
5. This means series data travels with the folder if copied between devices

### Progress Persistence Flow

1. Single books: `Book.lastReadPage` updated by `ReaderViewModel.debounceSave()` (2-second debounce after scroll ends)
2. Series: `Chapter.lastReadPage` + `Book.currentChapterIndex` updated
3. `Book.lastReadDate` set on every save
4. On reader dismiss: `ReaderViewModel.saveProgress()` does a final synchronous save
5. For series: `BookDataService.save()` also writes to `.mangashelf/data.json`

## 6. File & Folder Structure

```
MangaShelf/
├── App/
│   └── MangaShelfApp.swift              App entry point, ModelContainer setup, thumbnail migration, splash screen
├── Models/
│   ├── Book.swift                       SwiftData @Model for manga titles (single + series)
│   ├── Bookmark.swift                   SwiftData @Model for chapter bookmarks + BookmarkColor enum
│   └── Chapter.swift                    SwiftData @Model for individual PDFs within a series
├── ViewModels/
│   ├── LibraryViewModel.swift           Library state: sort, search, secret mode, scan, rename + LibraryViewMode/LibrarySortOption enums
│   └── ReaderViewModel.swift            Reader state: PDF loading, page tracking, chapter nav, overlay, screenshot capture
├── Views/
│   ├── Library/
│   │   ├── LibraryView.swift            Main library screen: NavigationStack, grid/list, search, settings sheet, cover picker
│   │   ├── BookCardView.swift           Grid card: thumbnail, title, progress bar
│   │   ├── BookRowView.swift            List row: thumbnail, title, progress bar
│   │   ├── EmptyLibraryView.swift       Shown when library is empty or no manga found
│   │   └── SortMenuView.swift           Sort option dropdown menu
│   ├── ChapterDetail/
│   │   ├── ChapterListView.swift        Series detail: cover carousel, info box, URL/note editing, bookmarks, art album, chapter list
│   │   ├── ArtViewerOverlay.swift       Full-screen art viewer with swipe nav, drag-to-dismiss, delete, crop-to-cover
│   │   └── CoverCropOverlay.swift       2:3 draggable crop box for selecting cover region from art
│   ├── Reader/
│   │   ├── ReaderView.swift             Full-screen reader: PDFPageView host, overlay, screenshot button, error state
│   │   ├── ReaderOverlayView.swift      Top bar (title, dismiss) + bottom bar (chapter nav, page info)
│   │   └── PDFPageView.swift            UIViewRepresentable: UIScrollView + CALayer-based PDF rendering with windowed page management
│   ├── Settings/
│   │   └── SettingsView.swift           Settings: folder picker, rescan, open in Files, theme/accent selection, secret shelf config
│   └── Components/
│       └── SplashScreenView.swift       Animated splash screen with icon + title fade-in
├── Services/
│   ├── BookDataService.swift            Portable data sync (.mangashelf/data.json read/write) + BookSeriesData Codable DTO
│   ├── FileSourceProtocol.swift         Protocol abstraction for file operations (resolveBookmark, fileExists, fileSize)
│   ├── ImportService.swift              Folder scanning, Book/Chapter upsert, thumbnail generation, rename, custom cover
│   ├── LocalFileService.swift           Security-scoped bookmark resolution, file ops, thumbnail directory, migration + FileServiceError
│   └── ThumbnailService.swift           PDF thumbnail generation, NSCache management, cached image loading
├── Utilities/
│   ├── Constants.swift                  StorageKey enum (UserDefaults key constants)
│   ├── Extensions.swift                 Color constants, Chapter.extractedNumber, UIImage.dominantColor, Book.chapterProgressLabel, UIImpactFeedbackGenerator.impact, Collection[safe:]
│   └── ThemeManager.swift               AppTheme enum, AccentTheme enum, @Observable ThemeManager (UserDefaults-backed)
└── Resources/
    └── Assets.xcassets                  App icon and asset catalog
```

## 7. Known Limitations & Technical Debt

### SwiftData Migration Constraints
- `Book.filePath` and `Book.bookmarkData` are dead properties. They cannot be removed without adding a `VersionedSchema` migration, which is out of scope for a refactor-only pass. They are set during creation but never read.

### Rendering
- `PDFPageView` uses raw `CALayer` rendering rather than `PDFKit`'s `PDFView`. This gives full control over memory and rendering but means zoom and text selection are not supported.
- The rendering window is 4 pages (forward-biased). Large PDFs with very high-resolution pages may cause transient memory spikes during rendering. The `OperationQueue` is capped at 4 concurrent operations.
- GPU texture size limits: `UIGraphicsImageRenderer` renders at screen scale. On 3x displays, a page wider than ~4096 logical points would exceed the 16384-pixel GPU texture limit. Standard manga PDFs are well under this.

### Concurrency
- `ThumbnailService.generateThumbnail` uses `DispatchQueue.global` with `withCheckedContinuation` instead of `Task.detached`, unlike the rest of the codebase which uses structured concurrency.
- `ReaderViewModel.navigateToChapter` creates an untracked `Task {}` that isn't cancelled by `cleanup()`. If the view disappears mid-chapter-load, this task runs to completion (wasted work, no crash).
- Service singletons lack formal `Sendable` conformance. They work correctly due to `@MainActor` annotations and `Task.detached` isolation patterns but aren't formally safe.

### Architecture
- `ImportService` partially bypasses its own `FileSourceProtocol` abstraction, calling `LocalFileService.shared` directly for bookmark resolution, thumbnail directory, and thumbnail URL construction. Only `fileSize` goes through the protocol.
- `ImportService()` is instantiated fresh in `ChapterListView`, `LibraryView`, and `SettingsView`, while `LibraryViewModel` receives one via init. The service is stateless so this is functionally fine but inconsistent.
- Duplicate `progressBar(value:)` implementations exist in `BookCardView` and `BookRowView`.
- Duplicate thumbnail loading pattern exists in `BookCardView` and `BookRowView`.

### UI/UX
- The app is dark-mode only (`preferredColorScheme(.dark)` set on the root WindowGroup).
- No unit or UI tests exist.
- `ChapterListView` is the largest file (~1050 lines) handling cover, info, bookmarks, art, and chapters. It's cohesive but dense.

### File Access
- Security-scoped bookmarks can become stale if the user moves the root folder. The app refreshes stale bookmarks on scan but doesn't prompt the user to re-select.
- The "Open in Files" feature constructs a `shareddocuments://` URL which depends on the Files app being available.
