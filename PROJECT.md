# MangaShelf

> Technical reference for AI agents working on this codebase. Precise over promotional.

## 1. App Overview

MangaShelf is an iOS 18+ SwiftUI manga/comic reader that imports PDF files from user-selected folders on device. The user picks a root folder containing either manga series (subfolders of chapter PDFs) or standalone PDF files; the app scans, catalogs, and renders them with a custom tiled `CALayer` PDF renderer. It supports reading-progress tracking, colored bookmarks, per-series art albums, custom cover selection/cropping, themes, and a hidden "secret shelf". The architecture is **MVVM**, with SwiftData used as a **derived cache** of folder contents: each series folder owns its own metadata under `<folder>/.mangashelf/` (a `data.json` plus an optional `cover.jpg`), so renaming, moving, or copying a folder preserves all per-series state and is a no-op at the data layer.

- **Platform / min OS:** iOS 18+ (with `#available(iOS 26, *)` branches for scene geometry APIs). Dark mode only (`preferredColorScheme(.dark)` on the root scene).
- **Frameworks:** SwiftUI, SwiftData, PDFKit, PhotosUI, UIKit (thumbnails / haptics / rendering). No third-party dependencies.
- **Pattern:** MVVM. `@Observable` view models (`LibraryViewModel`, `ReaderViewModel`), singleton services, SwiftData `@Model` types, and a shared `@Observable ThemeManager` injected via `.environment`.

## 2. Feature Map

| Feature | Description | Key files |
|---|---|---|
| Library grid/list | Browsable library with search, sort (Recently Added / A–Z / Last Read), grid⇄list toggle | `LibraryView`, `BookCardView`, `BookRowView`, `LibraryCellComponents`, `EmptyLibraryView`, `SortMenuView`, `LibraryViewModel` |
| Folder import & scan | Scans root/secret folder for series subfolders + loose PDFs, upserts `Book`/`Chapter` rows, generates thumbnails | `ImportService`, `SettingsView`, `LibraryViewModel` |
| PDF reader | Full-screen continuous vertical reader on a custom tiled `CALayer` renderer | `ReaderView`, `ReaderViewModel`, `PDFPageView` |
| Chapter navigation | Chapter list with sort toggle, in-reader jump-to-chapter picker, prev/next buttons | `ChapterListView`, `ReaderOverlayView`, `ReaderViewModel` |
| Art album | PhotosPicker to add images, horizontal thumbnail strip, full-screen viewer w/ swipe + drag-to-dismiss | `ChapterListView` art section, `ArtViewerOverlay` |
| Cover carousel | Swipe cover to browse art; tap to expand into full-screen viewer | `ChapterListView.coverHeader`, `ArtViewerOverlay` |
| Cover crop | Draggable 2:3 crop box over any art image → 400×600 JPEG cover | `CoverCropOverlay`, `ArtViewerOverlay` |
| Reader screenshot capture | Floating camera button captures current viewport into the series `Art/` folder | `ReaderView`, `ReaderViewModel.captureCurrentPage()`, `PDFPageView` capture closure |
| Reading progress & bookmarks | Per-chapter page + exact scroll-offset tracking; colored bookmarks with optional notes | `Book.readingProgress`, `Bookmark`, `ChapterListView`, `ReaderViewModel` |
| Portable series data | Notes, link, progress, offsets, page counts, bookmarks saved to `.mangashelf/data.json` | `BookDataService` |
| Secret library | Hidden shelf behind a 5-second long-press on the settings icon; separate folder bookmark | `Book.isSecret`, `LibraryView` long-press, `SettingsView` secret section |
| Theme & accent | 4 dark themes + 6 accent colors, persisted in UserDefaults | `ThemeManager`, `SettingsView` |
| Splash screen | Animated launch screen (icon + title fade-in) overlaid on the library | `SplashScreenView`, `MangaShelfApp` |
| Settings | Folder picker, rescan, open-in-Files, theme/accent, secret-folder config | `SettingsView` |

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
5. On scroll, `scrollViewDidScroll` binary-searches `pageOffsets` for the current page and calls `updateViewport`, which (throttled) schedules rendering for tiles within `overscanFactor` (1.5×) of the viewport on a background `OperationQueue` (`maxConcurrentOperationCount = 2`, `.utility` QoS, below the scroll runloop). Off-range tiles have their layer `contents` cleared; in-flight renders for tiles that scroll away are cancelled.
6. Each tile is drawn with `UIGraphicsImageRenderer` + `PDFPage.draw(with:.mediaBox…)` at screen scale, then committed to its `CALayer` on the main thread inside a `CATransaction` with actions disabled.
7. Position restore: if `initialOffset > 0`, `scrollToOffset` jumps to the exact content offset and `awaitViewportRendered` fires `onRestoreComplete` once the target tiles render (a restore spinner shows meanwhile, with a 5s safety timeout); otherwise `scrollToPage` restores by page.
8. Page changes are reported to the view model on drag/decelerate end via `onPageChange`.

### Chapter navigation
1. Reader overlay shows prev/next + a chapter-picker sheet (`ReaderOverlayView`).
2. `goToNextChapter` / `goToPreviousChapter` / `goToChapter(index:)` funnel into `ReaderViewModel.navigateToChapter(index:)`.
3. It saves the current chapter's `lastReadPage`/`lastReadOffset`, nils `pdfDocument`, sets `isLoadingChapter`, loads the new PDF on a detached task, then updates `currentChapterIndex`, `pdfDocument`, `book.currentChapterIndex`, `lastReadDate`, and saves.

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
- No unit or UI tests exist.

### File access
- Security-scoped bookmarks can go stale if the root folder moves; the app refreshes stale bookmarks on scan but does not prompt for re-selection.
- "Open in Files" builds a `shareddocuments://` URL and depends on the Files app.
