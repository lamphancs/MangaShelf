# MangaShelf: agent technical reference

## 1. App overview

MangaShelf is a SwiftUI manga/comic library and continuous PDF reader for iPhone and iPad. It catalogs standalone PDFs and series folders under user-selected main and secret library roots, reads PDFs in place, captures web chapters, and maintains reading progress, bookmarks, links, notes, covers, and artwork. Series metadata travels with its folder in `.mangashelf/data.json`, with a portable custom cover in `.mangashelf/cover.jpg`; SwiftData caches library rows and also owns standalone-PDF reading state. The architecture is pragmatic MVVM: observable view models coordinate library, reader, and browser state, while feature views still own substantial presentation and some file-operation orchestration.

The **configured minimum OS is iOS 26.4**, in both project configurations; do not infer iOS 18 support from older documentation or availability branches. The target supports device families 1 and 2, uses Swift 5 language mode, approachable concurrency and default MainActor isolation, and forces dark appearance. Xcode uses a filesystem-synchronized `MangaShelf` source group, generated Info.plist, bundle identifier `com.lp.MangaShelf`, version 1.0/build 1. Frameworks include SwiftUI, SwiftData, UIKit, PDFKit, CoreGraphics, WebKit, PhotosUI, ImageIO, and system zlib; there are no package dependencies.

## 2. Feature map

| Feature | Behavior and responsible types |
|---|---|
| Library | `LibraryView` queries books, routes navigation, presents editors and settings. `LibraryViewModel` filters/searches/sorts and scans both roots; `BookCardView`, `BookRowView`, and `LibraryCellComponents` render the two layouts. |
| Add series | `AddSeriesView` collects title/folder/note and optional link in two steps. `NewSeriesDraft` validates input; `ImportService+NewSeries` commits an empty folder, portable JSON, and Book row, rolling back on failure. Browse opens the supplied URL or Google without saving Google as the homepage. |
| Folder discovery | `ImportService` enumerates roots, reconciles rows, preserves surviving chapter identities, and refreshes custom covers. `SettingsView` selects folders and forces scans. |
| Bilingual chapters | `ChapterListView` filters VN/EN chapters and supports ordering, inline filename rename, deletion, resume and restart. `Chapter.isEnglish` derives from `EN/`; reader lists contain one language at a time. |
| Reader | `ReaderView` hosts `PDFPageView`, overlay, screenshot/crop/bookmark controls and the floating thumbnail. `ReaderViewModel` owns PDF state, security scope, navigation and progress; `PDFContentView` tiles drawing and artwork transitions. |
| Thumbnail navigation | `ReaderThumbnailView` reuses the tiled renderer without artwork or top inset. Its marker represents the visible PDF region; dragging, tapping and accessibility actions seek within story content. |
| Chapter artwork | `ChapterArtwork` loads up to two random bounded previews from Art. `PDFContentView` brackets the story with them and implements Fade, Continuous, Parallax, and Parallax + Continuous. |
| Bookmarks | `BookmarkEditorSheet` is shared by detail and reader. Reader taps edit an existing bookmark; deletion is an explicit editor action. Reader changes flush with progress at lifecycle boundaries. |
| Art and covers | `ChapterListView` imports photos and loads artwork; `ArtViewerOverlay` displays full resolution on demand. `ArtImageCropOverlay` and `ArtImageCropper` replace an image in its original format; `CoverCropOverlay` renders a 2:3 cover. |
| Web browsing/capture | `WebPageCaptureModel` controls WebKit navigation, image preparation, verification and PDF capture. `WebPageCaptureView` presents browsing, crop/save/share, next-chapter actions and saved-chapter comparison. |
| PDF crop/export | `WebCaptureDocument` joins/crops source pages and renders previews. `PDFSeamRepair` and `PDFLosslessWriter` perform bounded seam repair and lossless stream rewriting. `FullPageCropView` shares the canvas with `ChapterCropView`. |
| Links and notes | `BookLinkKind` maps four language/link destinations and validates web URLs. `BookLinkEditorSheet`, `SeriesNoteEditorSheet`, and `SeriesLinks` manage edits and legacy English-link migration. |
| Update checks | `LibraryView` compares downloaded chapter numbers with `ChapterUpdateSource` results for supported ToonGod series. A shared website data store permits one verification presentation per check; NEW badges are in-memory results. |
| Themes/settings | `ThemeManager` persists four backgrounds and six accent choices. Settings also stores artwork transitions, default capture trims, preview zoom and library-root access. |
| Secret shelf/splash | Five consecutive splash-icon taps, no more than 0.6 seconds apart, enter the secret shelf. The normal entry button appears after 1.2 seconds; the icon fades over 1.5 seconds. A five-second settings-icon hold toggles shelves later. |

## 3. Data layer

`MangaShelfApp` creates `ModelContainer(for: Book.self, Chapter.self, Bookmark.self)` and injects it into the library hierarchy. Views use its environment context; `@Query` supplies library rows. Initialization failure currently calls `fatalError`. No `VersionedSchema` or `SchemaMigrationPlan` is present.

### Book: every stored property

| Property | Purpose |
|---|---|
| `id: UUID` | Identity, generated at construction. |
| `title: String` | Display title, independent of physical folder name. |
| `filename: String` | Standalone filename or series folder name. |
| `filePath: String` | Legacy stored path; preserved for schema compatibility. |
| `thumbnailPath: String?` | Cached cover filename; old absolute paths resolve by last component. |
| `lastReadPage: Int` | Zero-based standalone page, default 0. |
| `lastReadOffset: Double` | Standalone PDF-coordinate scroll offset, default 0; zero selects page restore. |
| `totalPages: Int` | Standalone page count or aggregate series count, default 0. |
| `dateAdded: Date` | Library addition date. |
| `lastReadDate: Date?` | Last reading timestamp. |
| `fileSize: Int64` | Standalone or aggregate series bytes, default 0. |
| `isSeries: Bool` | Folder-backed series discriminator, default false. |
| `folderName: String?` | Series directory relative to its selected root. |
| `currentChapterIndex: Int` | Index in the complete naturally ordered chapter list, default 0. |
| `bookmarkData: Data?` | Legacy per-book access data, default nil; current access uses root preferences. |
| `hasManualCover: Bool` | Portable-cover/cache marker, default false. |
| `coverVersion: Int` | Cover-view invalidation counter, default 0. |
| `isSecret: Bool` | Root/shelf discriminator, default false. |
| `isAvailable: Bool` | Library visibility filter, default true; missing files usually cause row deletion. |
| `seriesURL: String?` | VN homepage. |
| `englishSeriesURL: String?` | EN homepage, default nil. |
| `englishLatestChapterURL: String?` | EN latest online chapter URL, default nil. |
| `englishLatestChapterNumber: String?` | EN latest online chapter label, default nil. |
| `latestChapterURL: String?` | VN latest online chapter URL, default nil. |
| `latestChapterNumber: String?` | VN latest online chapter label, default nil. |
| `seriesNote: String?` | Shared series note. |
| `folderSignature: String?` | Cached v2 root/EN timestamp and count fingerprint; nil means unscanned. |
| `chapters: [Chapter]?` | Cascade relationship, inverse `Chapter.book`. |
| `bookmarks: [Bookmark]?` | Cascade relationship, inverse `Bookmark.book`. |

`sortedChapters` sorts by sortOrder. Series `readingProgress` is the current chapter's zero-based index divided by the current language's chapter count; standalone progress is page/count. `LibrarySeriesSummary.largestLanguage` uses the largest language count for the grid bar. These formulas intentionally differ. `sortedBookmarks` sorts by stored chapter index. `bookmarkKey` selects the root preference, and `thumbnailURL` constructs the Application Support path. Display helpers and chapter number extraction remain in `Utilities/Extensions.swift`.

### Chapter: every stored property

| Property | Purpose |
|---|---|
| `id: UUID` | Identity. |
| `filename: String` | Relative PDF path; EN files are `EN/name.pdf`. |
| `sortOrder: Int` | Global order: naturally sorted VN files, then naturally sorted EN files. |
| `totalPages: Int` | Cached PDF count, default 0. |
| `lastReadPage: Int` | Zero-based page, default 0. |
| `lastReadOffset: Double` | Exact PDF-coordinate offset, default 0. |
| `book: Book?` | Parent/inverse relationship. |

`displayName` strips directory/extension, replaces underscores/hyphens, and trims whitespace. It deliberately does not capitalize or collapse spaces as library title cleaning does. `extractedNumber` uses the last integer/decimal match; `chapterNumber` converts it to Double. `pdfURL(folderURL:)` appends the relative filename.

### Bookmark: every stored property

| Property | Purpose |
|---|---|
| `id: UUID` | Identity. |
| `chapterIndex: Int` | Global index in the parent book's sorted chapters. |
| `note: String` | Optional-in-UI note, stored as a string, default empty. |
| `colorName: String` | Persisted BookmarkColor raw value, default red. |
| `dateCreated: Date` | Creation timestamp. |
| `book: Book?` | Parent/inverse relationship. |

BookmarkColor contains red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple and pink. Unrecognized stored values display as red.

### Portable metadata and migrations

`BookSeriesData` is Codable, not SwiftData. Its fields are `note`, `url` (VN homepage), `englishSeriesURL`, `englishLatestChapterURL`, `englishLatestChapterNumber`, `latestChapterURL`, `latestChapterNumber`, `currentChapterIndex`, `lastReadDate`, `bookmarks`, `chapterProgress`, `chapterOffsets`, `chapterPageCounts`, `dateAdded`, and `title`. BookmarkEntry stores `chapterIndex`, `note`, and `color`. Dictionaries use exact chapter filenames including `EN/`; timestamps use ISO 8601, and writes use pretty-printed, sorted-key JSON. Missing optional values decode as nil; missing index, collections and dictionaries use zero/empty defaults. The title is always saved, including when it equals the folder name.

`SeriesLinks.migrateEnglish` splits older chapter-valued EN homepage links into homepage/latest URL/number, preserving an existing latest link. It runs during JSON decoding and Book save/restore. `BookDataService` migrates older app metadata/custom covers into series folders once. `LocalFileService` migrates thumbnails from Caches to Application Support once. These are application-level data migrations, not SwiftData schema migrations; neither flag guarantees every attempted I/O succeeded.

Never rename/remove stored model fields or change relationship rules without a deliberate migration and existing-store validation. Preserve JSON keys, bookmark colors, theme/effect raw values, preference strings, chapter relative paths and artwork filename conventions. The refactor changes none of these contracts.

### Preferences

`StorageKey` defines rootFolderBookmark, secretFolderBookmark, rootFolderName, secretFolderName, appTheme, accentTheme, artworkTransition, libraryViewMode, captureCropTrimPages, captureCropTopTrimPages, captureOverviewZoom and captureDetailZoom with matching stored strings. The two exceptions are thumbnailsMigrated → `thumbnailsMigratedToAppSupport` and folderDataMigrated → `folderDataMigratedToSeriesFolders`.

Defaults: warmBrown background, blue accent, grid library, fade artwork, bottom trim 5 browser viewports, top trim 0, overview zoom 2.25 and detail zoom 1. Trim range is 0–50; overview zoom 1–10, detail 1–4, step 0.25. Cover output is 400×600 points through UIKit's default renderer scale. Reader tile height is 384 points; crop preview/rail bands are 384/192 display points.

## 4. Service layer

| Type | Inputs → outputs; responsibilities and dependencies |
|---|---|
| `LocalFileService` | Bookmark Data → URL/stale flag; URL → existence/bytes; thumbnail name → cache URL. Singleton conforming to FileSourceProtocol; creates thumbnail directory and performs legacy migration. |
| `FileSourceProtocol` | Bookmark resolution, existence, size abstraction. ImportService currently consumes only fileSize through this protocol and uses LocalFileService directly elsewhere. |
| `ImportService` | Root bookmark/context → reconciled library; Book/Chapter edits → disk/model updates; captured Data/name/source/language → saved URL. Depends on local files, thumbnails, portable metadata, capture validation/naming and draft validation. |
| `ImportService+NewSeries` | Validated draft/root/shelf/context → new Book and directory; synchronous commit keeps scans from seeing half-created series. Rollback deletes the new directory and inserted row on failure. |
| `BookDataService` | Book → JSON snapshot/write; series URL → decoded BookSeriesData; JPEG bytes → portable cover success flag. Singleton; depends on local bookmarks, SwiftData and SeriesLinks. Save APIs suppress encoding/write errors. |
| `ThumbnailService` | PDF URL/identifier → cached first-page JPEG URL; image URL/size → scaled UIImage; PDF URL → page count. Singleton NSCache has 100-item/50 MiB limits. File generation uses a global queue; image reads use detached tasks. |
| `CaptureFileName` | URL/title → chapter suggestion; user string → validated `.pdf` name; Data/name/folder → collision-safe URL through UniqueFileWriter. |
| `UniqueFileWriter` | Data/folder/number-to-name closure → first available URL. Atomic temporary sibling write, exclusive move, up to 10,000 candidates, defer cleanup. PDF suffixes are ` (2)`; artwork suffixes are `_2`. |
| `WebCaptureRequest<Value>` | Callback operation/timeout → async result. MainActor continuation bridge resumes exactly once on completion, timeout or cancellation. |
| `WebCaptureDocument` | PDF Data → validated continuous page layout. Normalized crop → PDF bytes or preview UIImage; existing CropBoxes → normalized selection. Depends on PDFKit/CoreGraphics and PDFSeamRepair; stores original Data and page rectangles. |
| `PDFSeamRepair` | Native PDF → data/repaired/skippedForSize result. Detects simple full-width touching-image joins and narrow background overpaint, creates local 3x bands and uses PDFLosslessWriter. |
| `PDFLosslessWriter` | Quartz PDF plus optional raster/image patches → rewritten PDF. Reconstructs object references, preserves JPEG/JPX streams, recompresses decoded streams with zlib. Borrowed Core Graphics references remain valid until serialization ends; queued closures are explicitly cleared to break self-retention. |
| `CapturePDFTileRenderer` | Normalized crop/pixel width → UIImage on a serial actor. Uses WebCaptureDocument, a 24-item/24 MiB cache and cancellation checks. |
| `ChapterArtwork` | Optional Art directory → zero or two UIImage previews, maximum 2048 pixels per image; repeats one usable image and skips corrupt entries. |
| `ArtImageCropper` | UIImage/normalized rect → orientation-correct crop; original URL/new image → atomic same-format replacement and downsampled preview. Depends on ImageIO and ArtItem. |
| `ChapterUpdateSource` | Supported series URL/data store/verification callback → latest Double chapter number. Uses WebPageCaptureModel and WebCaptureRequest; 20-second initial deadline, 90 seconds after verification, 5-second link-read timeout. |
| `SeriesLinks` | Inout legacy homepage/latest/number → migrated English link fields without disk access. |

`ArtItem` describes an artwork ID, preview UIImage and cover flag; its ImageIO helper downsamples to 1400 pixels. `ArtCapturePosition` parses/formats chapter/page/offset/language filenames and delegates collision-safe writes. `NewSeriesDraft` stores form fields and validation; `NewSeriesError` reports validation/collision failures. `BookLinkKind` supplies URL/number key paths and UI labels while centralizing web-address normalization.

## 5. Key flows

### Launch and root/folder import

1. App initialization creates the container and runs thumbnail migration. The library mounts behind the splash and begins scanning while entry is gated.
2. Settings selects a root with `.fileImporter(.folder)`, saves a minimal security-scoped bookmark and display name, then directly invokes ImportService with `force: true`.
3. Library launch/scene-active refresh invokes LibraryViewModel.quickRefresh. It migrates portable metadata once, then scans both configured shelves with `force: false`, exposing an inline refresh indicator.
4. A scan resolves/refreshes the bookmark and holds security scope through the operation. Root subfolders qualify if they contain root-level PDFs or `.mangashelf/data.json`; loose root PDFs are standalone books.
5. Duplicate rows collapse by last-read date, bookmark count, chapter count and dateAdded. Missing rows are deleted; existing folders update in place.
6. Matching v2 folder signatures skip series reconciliation during quick refresh. Otherwise chapters reconcile by filename, remapping current/bookmarked identities and dropping bookmarks for deleted chapters.
7. New series restore portable metadata, cached page counts, cover and progress. Missing metadata is seeded, but an existing unreadable JSON file is not overwritten during initial creation. Context save completes the scan.

### Standalone PDF import

1. Place a PDF directly in the selected root and trigger scan/refresh; there is no separate standalone PDF picker.
2. ImportService creates a Book with cleaned title, PDFKit page count, file size and first-page thumbnail.
3. Library selection opens ReaderView directly. Progress remains in SwiftData; standalone PDFs do not get portable series JSON.

### Web URL capture, stitching and save

1. A homepage/latest link in ChapterListView opens WebPageCaptureView with language and shelf context. Normal browsing uses persistent WebKit data; secret sessions use an ephemeral store. Add Series Browse can start without a saved homepage.
2. HTTP(S) browsing remains interactive. Scripted popups are blocked; activated new-window links reuse the web view. Verification challenge responses disable capture while allowing user verification and local subframes.
3. Explicit Capture freezes source URL/title/filename, walks viewports to trigger lazy loading until the bottom stabilizes three times, then revisits missing images with two bounded recovery passes. Final diagnostics retain image/font warnings.
4. WebKit creates PDF data for the whole scroll content with a 45-second callback timeout. WebCaptureDocument validates all pages and records a continuous top-left layout; default crop trims configured browser-viewport units while retaining at least one viewport.
5. FullPageCropView shows bounded preview tiles, normalized handles, trim controls and a thumbnail rail. Compare optionally opens a same-language saved chapter in a separate PDFView at its bottom; manual reference zoom/scroll persists.
6. Save/Share asks for a validated name. Export clips intersecting source pages to their own bands and draws them into one PDF MediaBox, preserving PDF drawing content rather than flattening the chapter. Unchanged one-page export can return original bytes.
7. PDFKit repacking disables JPEG reencoding and screen optimization and accepts only smaller geometry-equivalent output. Seam repair optionally restores background overpaint from source image resources and adds approximately two-point 3x repair bands; ordinary band candidates allow up to 5 MiB growth.
8. Save resolves the correct root, creates EN if needed, exclusively writes a numbered PDF, syncs chapters, preserves current/bookmark identities, updates only that language's latest URL/number, saves the context and portable JSON. A sync failure reports that the PDF was already written.
9. Share writes a separate temporary directory and presents UIActivityViewController; dismissal removes it. Save success presents filename/size and optional next-chapter browsing or one-shot automatic capture, based on unambiguous same-origin links discovered in the captured page.

### Reader open and chapter navigation

1. Detail selection sets the global chapter index; explicit chapter selection/restart resets its page and offset. Resume preserves them.
2. ReaderViewModel resolves the root and holds security access, selects the stored chapter's language and opens its PDF. Initial PDF opening is synchronous.
3. PDFPageView installs UIScrollView and coordinator callbacks. ChapterArtwork loads off-main; PDFContentView lays out CropBox-aware pages and 384-point bands, optionally bracketed by artwork.
4. The renderer schedules only a bounded viewport/prefetch window on two utility workers. Generation and operation-identity checks reject obsolete commits; CALayer updates run on main. Native flick travel is capped to 1.25 viewport heights.
5. Positive saved offsets restore in PDF coordinates plus opening artwork offset; otherwise page restore is used. Restore completion waits for visible tiles with a view-model timeout.
6. Next/previous/jump first save progress, clear the PDF and load the target on a detached task. Language toggle maps the same numeric chapter and restores relative PDF progress; ordinary chapter navigation starts at the top.
7. Double-tap toggles overlay. Overlay auto-hide pauses for thumbnail/bookmark interaction. Closing/backgrounding saves progress; disappearance also cancels tracked tasks and releases security access.

### Progress and bookmarks

1. Scroll callbacks update the current page in memory after scrolling ends; offset providers read the live coordinate when needed.
2. saveProgress updates the current Chapter or standalone Book, maps language-local reader index back to the global Book index, updates lastReadDate, and attempts context save.
3. For series, an asynchronous portable snapshot is written. Positive pages/offsets/counts are recorded by exact filename; current index, dates, notes, links, title and bookmarks accompany them.
4. Reader bookmark edits update models immediately and flush with progress. Detail bookmark edits attempt an immediate save plus portable write. Existing reader bookmarks open the editor rather than being removed on tap.

### Artwork, covers and editable chapter crop

1. Photos imports save original bytes into Art using inferred extensions. Reader screenshots render source PDF/artwork at display resolution, excluding transition opacity/placeholders, and write position-bearing JPEG names.
2. Album loading reuses 1400-pixel previews by filename; the viewer requests only the current full-resolution image. Open in Reader parses position/language; legacy `y` offsets subtract an estimated opening-artwork height.
3. Image crop corrects orientation, preserves selected pixel resolution, encodes the original image format, validates decoding, atomically replaces the same path and refreshes the preview. Cover crop produces the fixed 2:3 image, saved through ImportService to portable cover and cache.
4. Reader chapter crop reads MediaBox content and reconstructs selection from CropBoxes. Save changes retained pages' CropBoxes and removes wholly excluded pages, preserving remaining MediaBoxes/content. Reopening can expand retained hidden areas, but cannot restore removed pages or previously discarded MediaBox content.
5. Reader replacement atomically writes PDF bytes, reloads from the top, updates page counts and resets page/offset progress. It does not introduce backup PDFs.

## 6. File and folder structure

The tree below lists repository application, configuration, fixture and design-reference files. `.git`, `.DS_Store`, and empty local state directories are workspace metadata, not application inputs. The icon concept PNGs are retained design artifacts and are not bundled.

```text
MangaShelf repository/
├── MangaShelf/
│   ├── App/
│   │   └── MangaShelfApp.swift — App entry, model container, splash and environment injection.
│   ├── Models/
│   │   ├── ArtCapturePosition.swift — Artwork filename position/language codec and exclusive JPEG save.
│   │   ├── ArtItem.swift — Artwork preview model and ImageIO downsampling.
│   │   ├── Book.swift — SwiftData book/series schema and computed progress/path helpers.
│   │   ├── BookLinkKind.swift — Four link destinations, model key paths and web URL normalization.
│   │   ├── BookSeriesData.swift — Backward-compatible portable JSON model and decoder.
│   │   ├── Bookmark.swift — SwiftData bookmark schema and persisted color choices.
│   │   ├── Chapter.swift — SwiftData chapter schema and relative PDF identity.
│   │   └── NewSeriesDraft.swift — New-series input validation and errors.
│   ├── Resources/
│   │   └── Assets.xcassets/
│   │       ├── AccentColor.colorset/
│   │       │   └── Contents.json — Asset catalog metadata for AccentColor.colorset.
│   │       ├── AppIcon.appiconset/
│   │       │   ├── AppIcon-Dark.png — Unmodified bundled icon/splash image.
│   │       │   ├── AppIcon.png — Unmodified bundled icon/splash image.
│   │       │   └── Contents.json — Asset catalog metadata for AppIcon.appiconset.
│   │       ├── SplashIcon.imageset/
│   │       │   ├── Contents.json — Asset catalog metadata for SplashIcon.imageset.
│   │       │   └── SplashIcon.png — Unmodified bundled icon/splash image.
│   │       └── Contents.json — Asset catalog metadata for Assets.xcassets.
│   ├── Services/
│   │   ├── ArtImageCropper.swift — Pixel crop and same-format atomic image replacement.
│   │   ├── BookDataService.swift — Portable JSON/cover persistence, restore and legacy migration.
│   │   ├── CaptureFileName.swift — Chapter suggestions, PDF name validation and exclusive save.
│   │   ├── CapturePDFTileRenderer.swift — Serial background PDF preview renderer and bounded cache.
│   │   ├── ChapterArtwork.swift — Bounded random artwork loading for chapter boundaries.
│   │   ├── ChapterUpdateSource.swift — Supported-site chapter discovery and verification-aware fetch.
│   │   ├── FileSourceProtocol.swift — File access abstraction used by the import service.
│   │   ├── ImportService+NewSeries.swift — Transactional creation of a series folder and model row.
│   │   ├── ImportService.swift — Root reconciliation, chapter edits, capture import and cover caching.
│   │   ├── LocalFileService.swift — Bookmark resolution, file operations and thumbnail directory migration.
│   │   ├── PDFLosslessWriter.swift — PDF object serialization, image patches and zlib recompression.
│   │   ├── PDFSeamRepair.swift — Touching-image seam detection, overpaint restoration and repair bands.
│   │   ├── SeriesLinks.swift — Legacy English homepage/latest link migration.
│   │   ├── ThumbnailService.swift — PDF cover generation, image cache and page count queries.
│   │   ├── UniqueFileWriter.swift — Temporary sibling write and exclusive collision-numbered move.
│   │   ├── WebCaptureDocument.swift — Continuous PDF geometry, export, editable crop and raster previews.
│   │   └── WebCaptureRequest.swift — Exactly-once cancellable timeout bridge for WebKit callbacks.
│   ├── Utilities/
│   │   ├── Constants.swift — Stable preference keys, cover/crop dimensions and artwork effect values.
│   │   ├── Extensions.swift — Title/progress/color/image/haptic and safe-collection helpers.
│   │   ├── PDFPage+ReaderDisplayBounds.swift — Rotated CropBox dimensions for reader and thumbnails.
│   │   └── ThemeManager.swift — Observable persisted theme/accent palettes.
│   ├── ViewModels/
│   │   ├── LibraryViewModel.swift — Library filtering, sorting, refresh and rename state.
│   │   ├── ReaderViewModel.swift — Reader navigation, progress, bookmark and security-scope lifecycle.
│   │   └── WebPageCaptureModel.swift — Observable WebKit browser, capture and image-loading state.
│   └── Views/
│       ├── ChapterDetail/
│       │   ├── ArtImageCropOverlay.swift — Normalized freeform artwork crop controls.
│       │   ├── ArtViewerOverlay.swift — Full-resolution artwork viewer, crop actions and dismissal gestures.
│       │   ├── ChapterListView.swift — Series detail, chapters, bookmarks, cover carousel and album orchestration.
│       │   └── CoverCropOverlay.swift — Fixed-ratio cover selection and rendering.
│       ├── Components/
│       │   ├── BookLinkEditorSheet.swift — Homepage/latest URL and number editor.
│       │   ├── BookmarkEditorSheet.swift — Shared bookmark color/note/deletion form.
│       │   ├── LibraryCellComponents.swift — Shared cover loading, progress bar and corner clipping.
│       │   ├── SeriesNoteEditorSheet.swift — Content-sized note editor and save rollback.
│       │   ├── SeriesRenameSheet.swift — Series title/folder rename form.
│       │   └── SplashScreenView.swift — Animated entry gate and secret tap sequence.
│       ├── Library/
│       │   ├── AddSeriesView.swift — Two-step creation form and add-series tile.
│       │   ├── BookCardView.swift — Grid cell and shared NEW chapter badge.
│       │   ├── BookRowView.swift — List cell with reading progress.
│       │   ├── EmptyLibraryView.swift — Empty-library guidance and settings action.
│       │   ├── LibraryView.swift — Main library, navigation, editors and online update checks.
│       │   └── SortMenuView.swift — Library sort-choice menu.
│       ├── Reader/
│       │   ├── ChapterCropView.swift — Existing-PDF editable crop and replacement confirmation.
│       │   ├── PDFContentView.swift — Bounded tiled UIKit rendering, prefetch policy and artwork transitions.
│       │   ├── PDFPageView.swift — SwiftUI/UIScrollView bridge, navigation and position coordinator.
│       │   ├── ReaderOverlayView.swift — Reader title/page/chapter controls and chapter picker.
│       │   ├── ReaderThumbnailView.swift — Tiled floating chapter navigator and viewport marker.
│       │   └── ReaderView.swift — Reader host, lifecycle saves, controls and thumbnail presentation.
│       ├── Settings/
│       │   └── SettingsView.swift — Theme/capture preferences and main/secret root management.
│       └── WebCapture/
│           ├── CapturePDFTile.swift — Cancellable SwiftUI preview tile presentation.
│           ├── ChapterReferenceView.swift — Independent read-only saved PDF comparison pane.
│           ├── FullPageCropView.swift — Tiled normalized crop canvas, trim controls and thumbnail rail.
│           └── WebPageCaptureView.swift — Browser, capture preview, comparison, save and share presentation.
├── MangaShelf.xcodeproj/
│   ├── project.xcworkspace/
│   │   ├── xcshareddata/
│   │   │   └── swiftpm/
│   │   │       └── configuration/
│   │   ├── xcuserdata/
│   │   │   └── khoaphan.xcuserdatad/
│   │   │       ├── IDEFindNavigatorScopes.plist — User-local Xcode search scopes.
│   │   │       └── UserInterfaceState.xcuserstate — Repository file.
│   │   └── contents.xcworkspacedata — Xcode workspace self-reference.
│   ├── xcuserdata/
│   │   └── khoaphan.xcuserdatad/
│   │       ├── xcdebugger/
│   │       │   └── Breakpoints_v2.xcbkptlist — Disabled legacy app-initializer breakpoint.
│   │       └── xcschemes/
│   │           └── xcschememanagement.plist — User-local scheme sidebar ordering.
│   └── project.pbxproj — Synchronized Xcode target and build settings; bundles PROJECT.md.
├── Tests/
│   ├── AddSeriesSmoke/
│   │   ├── README.md — Harness usage, coverage and manual verification notes.
│   │   ├── SmokeApp.swift — Isolated AddSeriesSmoke app entry and regression orchestration.
│   │   └── run.sh — Builds and runs this isolated simulator harness in a temporary checkout.
│   ├── ReaderArtworkSmoke/
│   │   ├── README.md — Harness usage, coverage and manual verification notes.
│   │   ├── SmokeApp.swift — Isolated ReaderArtworkSmoke app entry and regression orchestration.
│   │   ├── SmokeChecks.swift — Reader, artwork, crop, collision, tile and seam regression assertions.
│   │   └── run.sh — Builds and runs this isolated simulator harness in a temporary checkout.
│   └── WebCaptureSmoke/
│       ├── README.md — Harness usage, coverage and manual verification notes.
│       ├── SmokeApp.swift — Isolated WebCaptureSmoke app entry and regression orchestration.
│       ├── broken.webp — Deliberately corrupt WebP fixture for image-load warnings.
│       ├── index.html — Local colored/lazy/broken-image web capture fixtures.
│       ├── run.sh — Builds and runs this isolated simulator harness in a temporary checkout.
│       └── server.py — Loopback fixture server, delayed images and verification simulation.
├── output/
│   ├── icon-concepts/
│   │   ├── 01-neon-shelf.png — Unmodified design concept image.
│   │   ├── 02-manga-panels.png — Unmodified design concept image.
│   │   ├── 03-open-book.png — Unmodified design concept image.
│   │   └── prompts.md — Historical icon concept prompts.
│   └── pdf/
└── PROJECT.md — This agent reference.
```

## 7. Known limitations and technical debt

### Persistence and file access

- SwiftData is reconstructible for series only to the extent portable writes succeeded. Standalone progress/custom covers are not equivalently portable. Never treat a model field as removable just because current code no longer reads it.
- Many context saves, JSON reads/writes, folder migrations and art operations use `try?` or print-only errors. Portable save returns no success status; a UI can report success even if the folder copy failed. Migration flags can be set after partial failure, and thumbnail migration removes its old directory after attempted moves.
- Reader portable saves are unstructured tasks. Concurrent snapshots can complete out of order, and reader cleanup can release security scope before a write completes. These semantics were preserved in the refactor.
- Scan signatures use root/EN mtimes and counts, not PDF contents; cached page counts may remain stale after in-place replacement. EN-only folders without root PDFs or metadata do not qualify during root discovery.
- Chapter/bookmark identity is filename/global-index based. App-controlled rename/sync remaps indices, but external filename changes cannot always preserve identity. Series rename rollback can itself fail.
- Custom-cover cache identifiers sanitize names without shelf identity; collisions are possible. Thumbnail image cache keys use URL only, not requested dimensions. Album previews reused by filename may miss external in-place image edits.
- Root access can become stale. Scans refresh bookmarks but do not universally renew every caller's access. Show in Files depends on a `shareddocuments` URL.

### Rendering and memory

- The custom reader has no pinch zoom or text selection. Tall PDFs use 384-point bands, bounded visible/prefetched decoded images, two render workers and off-range eviction. This avoids a single full-height GPU texture; there is no explicit universal maximum texture-width check in the reader.
- Web preview rasterization limits each render to 20 million pixels (4 million for preview mode) and a 16,000-pixel maximum dimension. These are software image limits, not a verified universal GPU capability. PDF export itself has no corresponding bitmap-height limit.
- Full PDF Data, PDFKit/CoreGraphics object graphs, encoded/decoded streams and export copies can coexist. Bounded tiles do not bound whole-export memory. The object writer rejects graphs beyond 100,000 referenced objects; unsupported structures fall back or throw through existing paths.
- Seam detection conservatively skips complex paths, nested form/image arrangements, rotated pages, multi-page repair inputs and widths over 4096 points. Narrow raster repair bands have fixed 3x detail. Background vector repairs are retained in fallback even when optional raster bands exceed budget; therefore the 5 MiB check is not an unconditional cap on all possible fallback output.
- Gallery previews accumulate with album size; the viewer additionally retains one full-resolution image. Screenshot rendering/JPEG encoding and initial PDF open still occur on main. Scans also enumerate files and query uncached PDF counts synchronously.
- Render geometry uses scene fallbacks (393 width, 852 height, 59 top inset). Main reader layout is not fully reconstructed for every resize; test rotation with representative PDFs. UIKit/AppKit framework behavior and physical-device memory/FPS require device validation.

### Concurrency and architecture

- Reader navigation cancels a detached loader but its completion task is untracked. Overlapping loads/dismissal can allow obsolete completion to update state. Do not claim that renderer generation protection fixes view-model navigation ordering.
- Library sort cache invalidates on filter settings and available IDs, not every mutation of titles/lastReadDate. Concurrent refresh requests also share a single Boolean activity indicator.
- SwiftData access remains on the app's actor context. Do not move ModelContext/Book/Chapter objects into background work to eliminate main-thread I/O; use immutable snapshots and deliberate ordering in a separately tested change.
- ChapterListView and WebPageCaptureView still own extensive state and operation orchestration. Extracting stateful subviews or changing persistence boundaries can alter SwiftUI identity/lifecycle. This refactor splits independent types while retaining those behaviors.
- FileSourceProtocol is only partially used for injection. SeriesLinks is intentionally a small separate migration utility rather than merged across architectural boundaries.

### Web capture and validation

- Preparation has no overall scrolling deadline: finite pages settle; infinite feeds need Stop Loading. Nested scrollers, virtualized content, protected media and third-party verification cannot be guaranteed complete. Image/font warnings describe capture-time observations, not proof of completeness.
- Website sessions are persistent for normal books and ephemeral for secret books. Secret Shelf is hidden UI and separate root selection, not encryption or an authentication boundary. External-browser cookies are not transferred into WebKit.
- No XCTest target exists. `Tests/AddSeriesSmoke`, `Tests/ReaderArtworkSmoke` and `Tests/WebCaptureSmoke` build disposable app copies with separate bundle IDs and temporary fixtures. Run their scripts with a booted simulator UDID. The reader script appends its checks to PDFContentView.swift to reach the file-private render-window policy; do not inject tests into production files.
- Before this refactor, AddSeriesSmoke expected EN capture to replace the homepage and failed against current production behavior. Its assertions now check englishLatestChapterURL and preserve englishSeriesURL, consistent with the existing WebCaptureSmoke language checks.
- The original WebCaptureSmoke large-export assertion also failed on unchanged HEAD: it required no growth despite the existing seam-repair allowance. The assertion now uses that allowance and reports the joined PDF size being compared; pixel-equality and text checks remain unchanged. Its optional live-diagnostic interpolation is explicit to avoid a pre-existing test compiler warning.
- Existing Xcode builds emit an AppIntents metadata-extraction warning because the target has no AppIntents dependency. It is a build-tool diagnostic, not a Swift compilation warning. Do not add a framework or suppress diagnostics merely to hide it.
- Simulator regression checks cannot establish that every feature is unchanged on physical devices. Manual coverage still includes both shelves, real provider permissions, real-site verification, Dynamic Type, rotation, keyboard/sheet presentation and representative large-PDF performance.
