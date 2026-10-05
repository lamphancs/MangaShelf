# MangaShelf

> Technical reference for AI agents working on this codebase. Precise over promotional.

## 1. App Overview

MangaShelf is an iOS 18+ SwiftUI manga/comic reader that imports PDF files from user-selected folders on device. The user picks a root folder containing either manga series (subfolders of chapter PDFs) or standalone PDF files; the app scans, catalogs, and renders them with a custom tiled `CALayer` PDF renderer. It supports reading-progress tracking, colored bookmarks, per-series art albums, custom cover selection/cropping, themes, and a hidden "secret shelf". The architecture is **MVVM**, with SwiftData used as a **derived cache** of folder contents: each series folder owns its own metadata under `<folder>/.mangashelf/` (a `data.json` plus an optional `cover.jpg`), so renaming, moving, or copying a folder preserves all per-series state and is a no-op at the data layer.

- **Platform / min OS:** iOS 18+ (with `#available(iOS 26, *)` branches for scene geometry APIs). Dark mode only (`preferredColorScheme(.dark)` on the root scene).
- **Frameworks:** SwiftUI, SwiftData, PDFKit, PhotosUI, UIKit (thumbnails / haptics / rendering), WebKit (full-page web capture). No third-party dependencies.
- **Pattern:** MVVM. `@Observable` view models (`LibraryViewModel`, `ReaderViewModel`), singleton services, SwiftData `@Model` types, and a shared `@Observable ThemeManager` injected via `.environment`.

## 2. Feature Map

| Feature | Description | Key files |
|---|---|---|
| Library grid/list | Browsable library with search, sort (Recently Added / A–Z / Last Read), grid⇄list toggle | `LibraryView`, `BookCardView`, `BookRowView`, `LibraryCellComponents`, `EmptyLibraryView`, `SortMenuView`, `LibraryViewModel` |
| Add series | Trailing + tile in grid/list and empty library → title, optional folder name/note → optional series URL → Done creates folder + portable metadata; Browse also opens Browse & Capture (Google when URL is empty). Supports both shelves and first-use folder selection; duplicate folders are rejected. Empty series with `.mangashelf/data.json` survive scans and cache rebuilds. Display titles are always persisted; chapter scroll offsets restore during rebuilds after a folder move/rename. | `AddSeriesView`, `NewSeries`, `ImportService` |
| Folder import & scan | Scans root/secret folder for series subfolders + loose PDFs, upserts `Book`/`Chapter` rows, generates thumbnails | `ImportService`, `SettingsView`, `LibraryViewModel` |
| PDF reader | Full-screen continuous vertical reader on a custom tiled `CALayer` renderer. UIKit handles drag and native deceleration; projected post-flick travel is capped at 1.25 viewport heights. Single tap has no scrolling action. | `ReaderView`, `ReaderViewModel`, `PDFPageView` |
| Chapter navigation | VN–EN segmented toggle (disabled without an EN directory); VN PDFs in series root, EN PDFs in EN/. Relative chapter paths keep progress and bookmarks distinct; reader navigation stays within the selected language. Chapter list with sort toggle, in-reader jump-to-chapter picker, prev/next buttons, animated go-to-top/bottom actions | `ChapterListView`, `ReaderOverlayView`, `ReaderViewModel` |
| Chapter artwork pages | Random gallery images before and after each chapter; two distinct images when available, one reused otherwise; empty galleries skipped. Artwork occupies its own full page before and after the PDF. Images stay pinned during boundary transitions and fade as a whole over a backdrop from the adjacent PDF edge. Story tiles draw above artwork and fade in during the opening transition, stay fully opaque during reading, and fade out into closing artwork; chapter content is not placed underneath the initial artwork. Settings also offers Continuous (shared scroll) and Parallax (art moves at 75% of story speed). Parallax + Continuous combines the existing Parallax opening with the Continuous closing. These spatial effects preserve full story opacity. Original PDF page counts and saved content offsets are preserved. | `PDFPageView`, `ReaderViewModel` |
| Art album | PhotosPicker to add images, horizontal thumbnail strip, full-screen viewer w/ swipe + drag-to-dismiss | `ChapterListView` art section, `ArtViewerOverlay` |
| Cover carousel | Swipe cover to browse art; tap to expand into full-screen viewer | `ChapterListView.coverHeader`, `ArtViewerOverlay` |
| Cover crop | Draggable 2:3 crop box over any art image → 400×600 JPEG cover | `CoverCropOverlay`, `ArtViewerOverlay` |
| Web page capture | Series link action → browse/navigate → explicit Capture → lazy-load preparation → full-page PDF / crop, share / save as chapter. Browsing from Eng Version carries EN context throughout the session: saved PDFs go to EN/ (created on first save), captured URLs update the EN link, and Latest chapter stays unchanged. VN captures retain the root-folder/latest-chapter behavior. | `WebPageCaptureView`, `FullPageCropView`, `WebPageCaptureModel`, `WebCaptureDocument` |
| Reader screenshot capture | Floating camera button renders the current viewport directly from source PDF/artwork into the series `Art/` folder, excluding transition effects and tile-loading placeholders | `ReaderView`, `ReaderViewModel.captureCurrentPage()`, `PDFPageView` capture closure |
| Reading progress & bookmarks | Per-chapter page + exact scroll-offset tracking; colored bookmarks with optional notes | `Book.readingProgress`, `Bookmark`, `ChapterListView`, `ReaderViewModel` |
| Portable series data | Notes, link, progress, offsets, page counts, bookmarks saved to `.mangashelf/data.json` | `BookDataService` |
| Secret library | Hidden shelf behind a 5-second long-press on the settings icon; separate folder bookmark | `Book.isSecret`, `LibraryView` long-press, `SettingsView` secret section |
| Theme & accent | 4 dark themes + 6 accent colors, persisted in UserDefaults | `ThemeManager`, `SettingsView` |
| Splash screen | Animated launch screen (icon + title fade-in) overlaid on the library | `SplashScreenView`, `MangaShelfApp` |
| Settings | Folder picker, rescan, open-in-Files, theme/accent, chapter artwork transition (Fade / Continuous / Parallax / Parallax + Continuous), secret-folder config | `SettingsView` |

## 3. Data Layer

**Persistence:** SwiftData. `ModelContainer(for: Book.self, Chapter.self, Bookmark.self)` is created in `MangaShelfApp.init()` (fatal error on failure). There is **no `VersionedSchema` / migration plan**, so any stored-property rename/removal or enum raw-value change is a breaking migration risk (see §7).

### Book (`@Model`)

| Property | Type | Purpose |
|---|---|---|
| `id` | `UUID` | Unique identifier |
| `title` | `String` | Display title (cleaned from filename/folder name) |
| `filename` | `String` | Original filename (single) or folder name (series) |
| `filePath` | `String` | **DEPRECATED / stored-only.** Legacy absolute path, never read. Set to folder/file name at creation. Retained to avoid a schema migration. |
| `thumbnailPath` | `String?` | Filename of the cached cover JPEG in `Application Support/Thumbnails/` |
| `lastReadPage` | `Int` | Last page read (0-indexed) — single-PDF books |
| `lastReadOffset` | `Double` | Exact vertical scroll offset (content points) at last close; `0` ⇒ restore by page — single-PDF books |
| `totalPages` | `Int` | Page count (single) or sum of all chapter pages (series) |
| `dateAdded` | `Date` | When added to the library |
| `lastReadDate` | `Date?` | When last opened for reading |
| `fileSize` | `Int64` | File size in bytes (sum of chapters for series) |
| `isSeries` | `Bool` | `true` for a folder of chapter PDFs |
| `folderName` | `String?` | Series folder name in the root directory |
| `currentChapterIndex` | `Int` | Index into `sortedChapters` for the current reading position (series) |
| `bookmarkData` | `Data?` | **DEPRECATED / stored-only.** Unused, always `nil`. Retained to avoid a migration. |
| `hasManualCover` | `Bool` | Mirrors `<folder>/.mangashelf/cover.jpg` presence at the last scan (folder file is source of truth) |
| `coverVersion` | `Int` | Bumped when cover content changes; drives cached thumbnail invalidation |
| `isSecret` | `Bool` | `true` if the book belongs to the secret shelf |
| `isAvailable` | `Bool` | Read in `LibraryViewModel` filtering. Effectively always `true` for live rows (missing books are deleted on scan), but **not dead** — do not remove. |
| `seriesURL` | `String?` | User-provided link for the series |
| `latestChapterURL` | `String?` | Latest online chapter URL; opens Browse & Capture directly |
| `latestChapterNumber` | `String?` | Editable chapter label, independent of downloaded progress |
| `seriesNote` | `String?` | User-provided note for the series |
| `folderSignature` | `String?` | `"{folder mtime epoch}_{pdf count}"`. Lets `ImportService` skip per-folder reconciliation when the disk hasn't changed. Always `nil` for single PDFs. |
| `chapters` | `[Chapter]?` | `@Relationship(deleteRule: .cascade, inverse: \Chapter.book)` |
| `bookmarks` | `[Bookmark]?` | `@Relationship(deleteRule: .cascade, inverse: \Bookmark.book)` |

Computed: `sortedChapters`, `readingProgress`, `sortedBookmarks`, `bookmarkKey` (which UserDefaults bookmark key applies), `thumbnailURL`, `chapterProgressLabel()` (in `Extensions.swift`).

### Chapter (`@Model`)

| Property | Type | Purpose |
|---|---|---|
| `id` | `UUID` | Unique identifier |
| `filename` | `String` | PDF filename within the series folder |
| `sortOrder` | `Int` | Position in the sorted chapter list |
| `totalPages` | `Int` | Page count for this chapter's PDF |
| `lastReadPage` | `Int` | Last page read (0-indexed) |
| `lastReadOffset` | `Double` | Exact scroll offset at last close; `0` ⇒ restore by page |
| `book` | `Book?` | Inverse relationship to the parent `Book` |

Computed: `displayName` (strips extension, `_`/`-`→space, trims — **note:** unlike `String.cleanedMangaTitle`, it does not capitalize or collapse doubled spaces), `pdfURL(folderURL:)`, `extractedNumber` (last numeric segment of `displayName`, in `Extensions.swift`).

### Bookmark (`@Model`)

| Property | Type | Purpose |
|---|---|---|
| `id` | `UUID` | Unique identifier |
| `chapterIndex` | `Int` | Index of the bookmarked chapter |
| `note` | `String` | Optional user note |
| `colorName` | `String` | Raw value of `BookmarkColor` |
| `dateCreated` | `Date` | Creation timestamp |
| `book` | `Book?` | Inverse relationship to the parent `Book` |

Supporting enum `BookmarkColor` (11 system colors `.red`…`.pink`); its raw values are persisted in `colorName`.

### UserDefaults keys (`StorageKey`, in `Constants.swift`)

| Key constant | Stored string | Purpose |
|---|---|---|
| `rootFolderBookmark` | `rootFolderBookmark` | Security-scoped bookmark for the main library folder |
| `secretFolderBookmark` | `secretFolderBookmark` | Security-scoped bookmark for the secret folder |
| `rootFolderName` | `rootFolderName` | Display name of the root folder |
| `secretFolderName` | `secretFolderName` | Display name of the secret folder |
| `thumbnailsMigrated` | `thumbnailsMigratedToAppSupport` | One-time Caches→Application Support thumbnail migration flag |
| `folderDataMigrated` | `folderDataMigratedToSeriesFolders` | One-time app-data→`.mangashelf/` migration flag |
| `appTheme` | `appTheme` | Selected `AppTheme` raw value |
| `accentTheme` | `accentTheme` | Selected `AccentTheme` raw value |
| `artworkTransition` | `artworkTransition` | Chapter artwork effect: `fade` (default), `continuous`, `parallax`, or `parallaxContinuous`; spatial effects use feathered artwork edges with fully opaque PDF content |
| `libraryViewMode` | `libraryViewMode` | Grid or list (`LibraryViewMode`, via `@AppStorage`) |

`Constants.swift` also defines `enum Layout` with `coverSize = 400×600` (shared by `ThumbnailService` and `CoverCropOverlay`).

## 4. Service Layer

All services are reference-type singletons except `ImportService` (instantiated per use; it is stateless aside from injected dependencies).

### LocalFileService (singleton, `FileSourceProtocol`)

**Responsibility:** security-scoped bookmark resolution, file existence/size checks, the thumbnail directory, one-time thumbnail migration, and cover-cache naming.

- `resolveBookmark(_:) -> (url, isStale)` — resolves bookmark `Data` to a URL.
- `fileExists(at:)` / `fileSize(at:)` — filesystem queries.
- `thumbnailsDirectory` — `Application Support/Thumbnails/` (created on access).
- `urlForThumbnail(named:)` — full URL for a thumbnail filename.
- `migrateThumbnailsIfNeeded()` — one-time move of thumbnails from Caches to Application Support (gated by `thumbnailsMigrated`).
- `static customCoverFilename(for:)` — canonical `custom_<sanitizedId>.jpg` name (shared with `BookDataService`).
- Also defines `FileServiceError`.

### ImportService

**Responsibility:** scans the root/secret folder and syncs `Book`/`Chapter` rows, generates thumbnails, handles rename and custom-cover writes. The library DB is treated as a derived cache of on-disk folders.

- `scanRootFolder(modelContext:force:)` / `scanSecretFolder(modelContext:force:)` — walk the folder and sync. With `force == false` (launch / scene-active), a series whose `folderSignature` matches the on-disk folder is **skipped** (no chapter sync, no cover refresh, no `fileSize` calls). With `force == true` (Settings → Rescan, new folder pick), every folder is fully re-walked. Duplicate collapse ("1 folder = 1 book") and "delete rows whose folder/file is gone" run unconditionally. Existing rows are updated **in place** — bookmarks/progress survive even if `data.json` is unreadable.
- `syncSeriesFromRoot(_:modelContext:)` — refreshes chapters + cover cache for one already-loaded series and restamps `folderSignature` (used by `ChapterListView`).
- `renameBook(_:to:modelContext:)` — updates title in SwiftData and propagates it into `data.json`.
- `setCustomCover(for:jpegData:modelContext:)` (`async throws`, `@MainActor`) — writes the JPEG to `<folder>/.mangashelf/cover.jpg` first, then mirrors it into the app-side thumbnail cache, evicts the old entry, sets `hasManualCover`, bumps `coverVersion`.
- Title cleaning uses `String.cleanedMangaTitle(removeExtension:)` (in `Extensions.swift`).

**Depends on:** `FileSourceProtocol` (only `fileSize`), `ThumbnailService` (thumbnails + page counts), `LocalFileService` (direct calls for bookmark resolution, thumbnail dir, cover naming), `BookDataService` (seeds/reads `.mangashelf/`).

### ThumbnailService (singleton)

**Responsibility:** generates PDF first-page thumbnails (`Layout.coverSize` = 400×600 JPEG) and manages an in-memory image cache.

- `generateThumbnail(for:identifier:)` — renders the first PDF page to JPEG (on `DispatchQueue.global` + `withCheckedContinuation`), writes to the thumbnail dir, returns the URL.
- `cachedImage(for:targetSize:)` — returns from `NSCache<NSString, UIImage>` (100 items / 50 MB) or decodes+aspect-fill-scales off-main.
- `evictCachedImage(for:)` — removes one cache entry.
- `getPageCount(for:)` — PDF page count via PDFKit.

### BookDataService (singleton)

**Responsibility:** owns the per-series in-folder storage `<folder>/.mangashelf/` (`data.json` + `cover.jpg`). Source of truth for all portable series state.

- `save(book:)` — resolves the bookmark internally, writes `data.json`.
- `save(book:seriesFolderURL:)` — writes `data.json` to a pre-resolved URL (used by `ReaderViewModel`).
- `load(seriesFolderURL:)` — reads/decodes `data.json`.
- `saveCoverImage(jpegData:seriesFolderURL:)` — writes `cover.jpg` atomically.
- `restoreIfNeeded(book:modelContext:)` — one-way merge of disk data into SwiftData, filling only empty fields (on series open).
- `migrateAppDataToFolders(modelContext:)` — one-time write of app-side state (cover, dateAdded, custom title) into each series folder; idempotent, gated by `folderDataMigrated`; runs inside `LibraryViewModel.performScan` before the scan.
- Static path helpers: `seriesDataDirectory(in:)`, `coverImageURL(in:)`, `dataFileURL(in:)`, `hasCoverImage(in:)`.

**Data format:** `BookSeriesData` (`Codable`) with `note`, `url`, `currentChapterIndex`, `lastReadDate`, `bookmarks[]`, `chapterProgress`, `chapterOffsets`, `chapterPageCounts`, `dateAdded`, `title` (only when the user overrode the auto-derived title). It has a **hand-rolled `init(from:)`** so older files missing newer keys decode into defaults instead of throwing (which would nuke progress/bookmarks).

### FileSourceProtocol

Protocol over `resolveBookmark` / `fileExists` / `fileSize`. Only conformer is `LocalFileService`; only `fileSize` is actually consumed through the protocol type (elsewhere `LocalFileService.shared` is used concretely). Kept as a testability seam.

## 5. Key Flows

### Launch & refresh
1. `MangaShelfApp.init()` builds the `ModelContainer` and runs `migrateThumbnailsIfNeeded()`.
2. `LibraryView` is placed in the `WindowGroup` at opacity 0 with `SplashScreenView` overlaid; splash plays its intro (~0.45s) + a 0.5s hold, then calls `onFinished`, which fades the library in over 0.4s. The scan runs in parallel with the splash.
3. `LibraryView.task` → `LibraryViewModel.quickRefresh(modelContext:)` → `performScan(force: false, blocking: false)`.
4. `performScan` runs `BookDataService.migrateAppDataToFolders` (once ever), then `scanRootFolder` / `scanSecretFolder`. Signature short-circuiting means little PDFKit/`fileSize` work on most launches.
5. `quickRefresh` toggles `isRefreshing` (a small toolbar spinner); the library — rendered directly from `@Query` — stays interactive throughout.
6. On scene `.active`, `quickRefresh` re-runs so Files.app edits are picked up.
7. Settings → "Rescan" uses `fullRescan` → `performScan(force: true, blocking: true)` (full-screen `isLoading` overlay, since row counts can change).

### Folder import
1. In `SettingsView`, tap "Select Manga Folder" → `.fileImporter` for `.folder`.
2. On success, a security-scoped bookmark is saved to `rootFolderBookmark` and the name to `rootFolderName`.
3. `SettingsView.rescan()` → `ImportService.scanRootFolder(force: true)`: resolve bookmark (refresh if stale) → enumerate root (subfolders with PDFs = series, loose PDFs = singles) → collapse duplicates → delete rows for missing folders/files → `createSeries` / `createSingleBook` for new ones, in-place update for existing → `modelContext.save()`.

### PDF reading (tiled renderer)
1. Tapping a book: single PDF → `ReaderView` directly; series → `ChapterListView` first.
2. `ReaderViewModel.init(book:)` resolves the bookmark, starts security-scoped access, opens the current PDF via `PDFDocument(url:)`, and sets `currentPage` / `initialOffset` from saved progress.
3. `PDFPageView` (`UIViewRepresentable`) builds a `UIScrollView` hosting one `PDFContentView` (`UIView`).
4. `PDFContentView.configure(document:width:)` lays pages out vertically and **splits each page into vertical bands ("tiles") of ≤ `tileHeightPoints` (384pt)**, one `CALayer` per tile. Tiling keeps every rendered texture small so no single upload exceeds GPU limits — the fix for stutter on tall webtoon pages.
5. On scroll, `scrollViewDidScroll` binary-searches `pageOffsets` for the current page and calls `updateViewport`, which coalesces render requests and shifts a fixed three-screen overscan budget toward scroll velocity (up to 2.5 screens ahead, 0.5 behind; 1.5 each when stationary) on a background `OperationQueue` (`maxConcurrentOperationCount = 2`, `.utility` QoS, below the scroll runloop). Visible tiles have highest queue priority, followed by tiles ahead of travel; pending priorities update on direction changes. Off-range tiles have their layer `contents` cleared; in-flight renders for tiles that scroll away are cancelled. Operation identity and chapter generation checks prevent cancelled work from clearing replacements or publishing stale images.
6. Each tile is drawn with `UIGraphicsImageRenderer` + `PDFPage.draw(with:.mediaBox…)` at screen scale, then committed to its `CALayer` on the main thread inside a `CATransaction` with actions disabled.
7. Position restore: if `initialOffset > 0`, `scrollToOffset` jumps to the exact content offset and `awaitViewportRendered` fires `onRestoreComplete` once the target tiles render (a restore spinner shows meanwhile, with a 5s safety timeout); otherwise `scrollToPage` restores by page.
8. Page changes are reported to the view model on drag/decelerate end via `onPageChange`.

### Chapter navigation
1. Reader overlay shows prev/next + a chapter-picker sheet (`ReaderOverlayView`).
2. `goToNextChapter` / `goToPreviousChapter` / `goToChapter(index:)` funnel into `ReaderViewModel.navigateToChapter(index:)`.
3. It saves the current chapter's `lastReadPage`/`lastReadOffset`, nils `pdfDocument`, sets `isLoadingChapter`, loads the new PDF on a detached task, then updates `currentChapterIndex`, `pdfDocument`, `book.currentChapterIndex`, `lastReadDate`, and saves.

### Reader bookmarks
- Double-tap the reader to show its overlay, then tap the bookmark button above the camera button (series only).
- `BookmarkEditorSheet` shares the color/note form with `ChapterListView`. Tapping an unbookmarked chapter opens the form; tapping an existing bookmark removes it immediately.
- `ReaderViewModel.saveBookmark` and `removeCurrentBookmark` update in-memory models immediately without explicitly saving on the tap path. `saveProgress` flushes changes to SwiftData and the series `.mangashelf/data.json` on chapter change, reader dismissal, or backgrounding. Bookmarks remain chapter-level; no schema change is required.
- The bookmark button is disabled while a chapter loads or its PDF is unavailable. Overlay auto-hide pauses while the editor is open and resumes on dismissal.

### Series URL / note
1. `ChapterListView` info box: URL row (open link-actions sheet: Safari / Chrome / Copy; pencil to edit) and note row (TextEditor sheet).
2. On save: SwiftData updated → `BookDataService.save()` writes `data.json`.

### Art album
1. Art thumbnails are read from `<series>/Art/` in `ChapterListView.loadArtImages()`.
2. Add via `PhotosPicker` (saved as timestamped files, extension inferred from magic bytes) or via the reader screenshot button (`ReaderViewModel.captureCurrentPage()` writes `ch###_p####_y########.jpg`).
3. Tapping opens `ArtViewerOverlay` (swipe nav, drag-to-dismiss, delete, "Show in Files"). "Use as Cover Image" → `CoverCropOverlay`.
4. `CoverCropOverlay`: draggable/clamped 2:3 box → `Layout.coverSize` (400×600) JPEG on confirm.

### Cover customization
1. Library long-press → "Set Cover" → PhotosPicker; or art viewer → "Use as Cover Image" → crop.
2. Both call `ImportService.setCustomCover()`: write `<folder>/.mangashelf/cover.jpg` → mirror into the thumbnail cache → evict old → `hasManualCover = true` → `coverVersion += 1`.
3. `coverVersion` change re-triggers `BookCoverThumbnail`'s `.task(id:)` reload in card/row.
4. Because `cover.jpg` lives in the folder, the cover travels with the folder and is restored on the next scan (`refreshCustomCover` / `createSeries`).

### Progress persistence
- While scrolling, position is kept **in memory only** (`ReaderViewModel.updatePage`); there is **no periodic/debounced disk write** (it caused a scroll stutter).
- Persisted on: reader dismiss/`onDisappear`, chapter change, and app entering `.background` — all via `saveProgress`, which writes `lastReadPage`/`lastReadOffset` + `currentChapterIndex` + `lastReadDate` to SwiftData and, for series, `BookDataService.save(book:seriesFolderURL:)` to `data.json`.

## 6. File & Folder Structure

```
MangaShelf/
├── App/
│   └── MangaShelfApp.swift              @main App: ModelContainer, thumbnail migration, splash→library crossfade
├── Models/
│   ├── Book.swift                       @Model for a title (single PDF or series) + computed helpers
│   ├── Bookmark.swift                   @Model for a chapter bookmark + BookmarkColor enum
│   └── Chapter.swift                    @Model for one PDF within a series
├── ViewModels/
│   ├── LibraryViewModel.swift           Library state: sort/search/secret mode, scan (quick/full), rename, filtered-books cache + LibraryViewMode/LibrarySortOption
│   └── ReaderViewModel.swift            Reader state: PDF/chapter loading, page + scroll-offset tracking, overlay, go-to-top, restore, screenshot capture, security-scope lifecycle
├── Views/
│   ├── Library/
│   │   ├── LibraryView.swift            Main screen: NavigationStack, grid/list, search, settings sheet, cover PhotosPicker, scene-phase refresh, secret long-press
│   │   ├── BookCardView.swift           Grid card: cover thumbnail + title + progress
│   │   ├── BookRowView.swift            List row: cover thumbnail + title + progress
│   │   ├── EmptyLibraryView.swift       Empty / no-manga-found state
│   │   └── SortMenuView.swift           Sort-option dropdown
│   ├── ChapterDetail/
│   │   ├── ChapterListView.swift        Series detail: cover carousel, info box, URL/note sheets, bookmarks, art album, chapter list (largest file)
│   │   ├── ArtViewerOverlay.swift       Full-screen art viewer (swipe, drag-to-dismiss, delete, crop-to-cover) + ArtItem model
│   │   └── CoverCropOverlay.swift       2:3 draggable crop box → Layout.coverSize JPEG
│   ├── Reader/
│   │   ├── ReaderView.swift             Reader host: PDFPageView, overlays, screenshot/go-to-top buttons, load-error + restore states, save on background/dismiss
│   │   ├── ReaderOverlayView.swift      Top bar (title/dismiss) + bottom bar (chapter nav / page info) + chapter picker sheet
│   │   └── PDFPageView.swift            UIViewRepresentable: UIScrollView + tiled CALayer PDF renderer with off-screen eviction + render-complete callbacks
│   ├── Settings/
│   │   └── SettingsView.swift           Folder picker, rescan, open-in-Files, theme/accent, secret-folder config
│   └── Components/
│       ├── SplashScreenView.swift       Animated splash (icon + title fade-in), then onFinished
│       └── LibraryCellComponents.swift  Shared BookCoverThumbnail (async cover load) + BookProgressBar for card/row
├── Services/
│   ├── BookDataService.swift            Portable per-series storage (.mangashelf/ data.json + cover.jpg) + BookSeriesData DTO
│   ├── FileSourceProtocol.swift         File-op protocol seam (resolveBookmark/fileExists/fileSize)
│   ├── ImportService.swift              Folder scan, Book/Chapter sync, thumbnails, rename, custom cover
│   ├── LocalFileService.swift           Security-scoped bookmarks, file ops, thumbnail dir/migration, cover naming + FileServiceError
│   └── ThumbnailService.swift           PDF first-page thumbnails + NSCache image loading
├── Utilities/
│   ├── Constants.swift                  StorageKey (UserDefaults keys) + Layout (coverSize)
│   ├── Extensions.swift                 Color constants, String.cleanedMangaTitle, Chapter.extractedNumber, UIImage.dominantColor, Book.chapterProgressLabel, UIImpactFeedbackGenerator.impact, Collection[safe:]
│   └── ThemeManager.swift               AppTheme + AccentTheme enums, @Observable ThemeManager (UserDefaults-backed)
└── Resources/
    └── Assets.xcassets                  App icon + asset catalog
```

## 7. Known Limitations & Technical Debt

### SwiftData migration constraints 🚩
- No `VersionedSchema`/migration plan exists. **Do not rename or remove any stored `@Model` property** — this includes the dead-but-stored `Book.filePath` and `Book.bookmarkData`. `Book.isAvailable` looks dead but is read in library filtering; leave it.
- Persisted enum raw values (`BookmarkColor.colorName`, `AppTheme`, `AccentTheme`) and the literal `StorageKey` strings are effectively schema — do not change their string values.

### Rendering
- `PDFPageView` uses a hand-rolled tiled `CALayer` renderer, not `PDFView`. Consequence: no zoom and no text selection, in exchange for tight memory/scroll control.
- Tiling (≤384pt bands) keeps textures under GPU limits; very tall webtoon pages (e.g. 430×14400pt) rely on this. A page wider than the width used for scale could still, in theory, approach the ~16384px texture limit at 3× — standard manga is far under this.
- Scene geometry fallbacks (`852` height, `393` width, `59` top inset) are hardcoded in `PDFPageView` for the no-active-scene case. (These were intentionally left in place during the last refactor because the file was under concurrent edit; consider folding them into `Layout` later.)

### Concurrency
- `ThumbnailService.generateThumbnail` uses `DispatchQueue.global` + `withCheckedContinuation` rather than the `Task.detached` used elsewhere — stylistic inconsistency, functionally fine.
- `ReaderViewModel.navigateToChapter` spawns an untracked `Task {}` not cancelled by `cleanup()`; if dismissed mid-load it runs to completion (wasted work, no crash).
- Service singletons are not formally `Sendable`; they are safe in practice via `@MainActor` + `Task.detached` isolation but not statically guaranteed.

### Architecture
- `ImportService` partially bypasses `FileSourceProtocol`, calling `LocalFileService.shared` directly for everything except `fileSize`.
- `ImportService()` is created fresh in `ChapterListView`, `LibraryView`, and `SettingsView`, but injected into `LibraryViewModel`. It is stateless, so this is fine but inconsistent.
- The security-scoped bookmark resolve/access/`defer`-release block is duplicated ~10× (across `BookDataService`, `ImportService`, `ChapterListView`, `SettingsView`, `ReaderViewModel`). A single `withResolvedRootFolder` helper would remove it but touches many files; deferred to avoid regression risk under the zero-behavior-change mandate.
- `ChapterListView` (~1000 lines) is the largest file and handles cover carousel, info box, URL/note sheets, bookmarks, art album, and the chapter list. Cohesive but dense; a candidate for splitting.

### UI / testing
- Dark mode only.
- No XCTest target exists. `Tests/WebCaptureSmoke/run.sh` builds an isolated simulator app and checks browser navigation without automatic capture, WebKit full-page capture, lazy-loaded content, original/cropped PDF quality, PDFKit compatibility, chapter import and bookmark preservation, invalid input, cancellation, recapture, and a 44 MB / 140,000-point chapter with full-resolution visible-region rendering and bounded visible tile work. See its README for device checks.

### File access
- Security-scoped bookmarks can go stale if the root folder moves; the app refreshes stale bookmarks on scan but does not prompt for re-selection.
- "Open in Files" builds a `shareddocuments://` URL and depends on the Files app.

## Web page capture

`ChapterListView` presents **Browse & Capture** for HTTP(S) series links after the link sheet dismisses. `WebPageCaptureModel` owns a `WKWebView` with persistent website data for normal library books and an isolated ephemeral store for Secret Library books. Opening links, following links, navigating back/forward, and reloading only browse; Cloudflare responses with `cf-mitigated: challenge` remain interactive but disable Capture, with guidance and an Open in Browser button. This supports user verification; it does not guarantee embedded-browser acceptance or share Safari cookies. Capture becomes available once a non-challenge main document commits, even if a subresource keeps loading; the user explicitly taps **Capture** on the desired page. The primary **Capture** button loads the full page and prepares lazy images before capture; there is no separate immediate-capture menu. Reload operates on the current page. Capture walks the main document to trigger lazy loading, waits briefly for images/fonts, and creates a full-content PDF. Viewport-by-viewport loading avoids forcing all lazy images to decode at once. Each viewport gets a 150 ms event-delivery interval, extended to 350 ms when visible images are pending or the bottom is being checked. Broken or still-pending images/fonts produce a visible preview warning rather than blocking capture. Preparation visits viewports until the bottom settles, without a fixed chapter height or total scrolling deadline; Stop Loading cancels even infinite feeds. After the fast viewport pass, up to two targeted recovery passes revisit missing images (including common lazy placeholders with no source), dwell up to 3 seconds per image within a 30-second total budget, and retry failed image sources once. Final image waiting is bounded to 10 seconds. Image diagnostics ignore hidden elements and rendered 1×1 tracking pixels, and trust loaded sources over retained lazy-loader classes. Unresolved lazy placeholders still warn. Diagnostics are refreshed immediately before PDF creation and frozen with the capture; later website loads cannot clear warnings for an existing PDF. Errors preserve the browser for retry. **Back to Page** supports continuing navigation before another capture.

`WebCaptureDocument` accepts every page of the returned PDF and lays them out vertically for preview/cropping (it must not require exactly one PDF page). Full-page and cropped PDF export join intersecting source pages into one continuous PDF media box, eliminating page separators in Preview. Each source is clipped to its own vertical band without a bitmap intermediate, preserving page order, rotation and a consistent output width. An unchanged single-page source retains its original bytes. Neither export applies bitmap pixel limits or intentional image downsampling. Quality is limited by the content supplied by the website/WebKit. The crop screen never rasterizes the whole chapter into a single preview. `CapturePDFTileRenderer` renders visible 384-point bands directly from the PDF at screen pixel width on a serial background actor, with a 24 MB image-cache budget. Visible bands use absolute canvas offsets derived from scroll geometry, not estimated LazyVStack positions; raster dimensions are rounded consistently with PDF crop coordinates. Offscreen tile views release their images. Total chapter length does not reduce Detail resolution. Crop coordinates are normalized from the top left of the continuous document and converted to per-page PDF coordinates when exporting. `WebCaptureRequest` bounds JavaScript/PDF callback operations with cancellation and timeouts; late callbacks cannot resume twice. PDF creation has a 45-second deadline. Errors include their capture stage and domain/code; terminated web processes disable capture until reload.

`FullPageCropView` opens in Overview by default and provides draggable corners and a move handle. Overview uses a minimum 100-point document width and scrolls for long chapters, rather than squeezing the full chapter into a near-zero-width line. Both modes use lazy PDF tiles; crop coordinates remain normalized to the original document dimensions. **Save PDF** and **Share PDF** first ask for a file name. `CaptureFileName` validates names, normalizes the PDF suffix and preserves Unicode. **Save PDF** uses `ImportService.saveCapturedChapter` to resolve the main/secret folder bookmark, write a temporary sibling PDF and move it into the series folder without overwriting existing files (duplicate names get a numbered suffix), sync chapters, preserve current-chapter/bookmark identities across sorting, and persist metadata. The PDF is immediately available in the chapter list and opens through the existing PDFKit reader. **Share PDF** uses the chosen name in an isolated temporary directory cleaned up on dismissal. `WebCaptureDocument.exportPDF` attempts PDFKit object repacking with JPEG encoding and screen downsampling explicitly disabled. It uses the repacked output only when smaller and page geometry is unchanged; otherwise it retains the original export. This is best-effort lossless optimization, not a guaranteed file-size ratio. PNG remains supported only in Art, not as a reader chapter. Previously saved PNG captures are not automatically converted. No model schema changes.

Scope: main document scroll content; virtualized lists, nested scrollers, protected media, and infinite feeds cannot be guaranteed complete. Unfinished/broken image loading is reported as a preview warning; PDF failures remain explicit errors.

Capture filenames default to `Chapter <number>` from the captured URL, falling back to the page title and then `Chapter`. The suggestion is frozen when capture starts.

Browse & Capture disables automatic JavaScript windows and rejects scripted new-window requests in both navigation and UI delegates. Activated HTTP(S) links targeting a new window continue in the existing browser. This does not filter ads embedded in page content or same-frame redirects.

Capture preview defaults to trimming five browser viewport heights from the bottom, retaining at least one viewport on short pages. Full Page restores the entire selection. Successful Save PDF presents a dismissible sheet with the actual filename and file size, plus Go to next chapter and Next chapter & capture actions. The X dismisses it without changing the preview; saving itself never advances. These controls and file details no longer occupy the crop footer. Go to crop bottom scrolls to the lower edge of the current selection (initially the default crop), keeping its handles visible. Capture discovers explicit same-origin next-chapter links (chapter labels, rel=next, or chapter-specific IDs/classes), rejects ambiguous destinations and never increments URLs. If unavailable, the option is disabled with manual-navigation guidance. Advancing clears preview/save/filename state. The browse action opens the next chapter without capturing; the capture action runs full-page preparation and capture once that navigation finishes. Automatic capture is scoped to that navigation and cleared on navigation failure, replacement, website verification, or close.

Information shows the series link as the book title and the latest online link as `Chapter <number>`, hiding URLs in the rows. Both use `BookLinkEditorSheet` for manual editing; latest chapter numbers are suggested from recognized URLs and remain editable. Browse & Capture’s share menu freezes the current URL/title and opens the same editor for either destination. The existing series link still opens its action sheet; the latest link opens Browse & Capture directly. Both new optional fields are saved/restored in portable metadata with backward-compatible decoding. Notes trim outer whitespace for display, use compact vertical spacing, and have a growing multiline editor instead of a fixed minimum-height TextEditor.

After Save PDF succeeds, the capture import updates the latest chapter URL and number and writes them to the same `.mangashelf/data.json` as the series link. The source URL is frozen when capture begins; chapter recognition prefers that URL, then captured title, then the chosen filename. Invalid PDF/folder saves leave the existing link untouched. The note editor uses a content-sized sheet and one-line minimum multiline field, requests keyboard focus on presentation, and the note edit icon uses the accent color.

Note sheet redesign: `SeriesNoteEditorSheet` uses a dedicated 240-point sheet, a single scrolling TextEditor, and a compact top row for Close, Delete, and Save. No Form, nested scroll view, measured detent, or reserved lower action section. Keyboard focus belongs to the sheet. All Information pencil buttons use the theme accent. Capture controls omit the PDF-quality explanatory footer.

Approved UI: Note option B uses a large sheet with Cancel/Save, a prominent Note heading and book title, an unboxed editor, and a bottom delete action above the keyboard. Capture option A pins adjacent Share PDF and Save PDF buttons in the bottom controls: minimum 56-point height (scales with Dynamic Type), rounded corners, a wider accent-filled Save action, and a secondary Share action. Existing filename/share/save behavior is unchanged.

Note sizing refinement: the Note B hierarchy now uses a content-height sheet capped at 360 points, with a 1–6-line growing input and automatic keyboard focus. Long notes scroll. Capture no longer shows the default-crop explanatory paragraph; Overview/Detail use 44-point buttons inside a 52-point segmented surface, matching the 52-point Full Page action.

Note no longer requests initial keyboard focus; tapping the note starts editing. Browser navigation now uses 21-point icons with at least 48×52-point hit targets for Back, Forward, Reload, and Open in Browser. Capture is a prominent 52-point button. Narrow widths place Capture on a second row rather than shrinking navigation targets.
