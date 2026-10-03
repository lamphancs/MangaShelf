# Reader artwork smoke checks

Run `bash Tests/ReaderArtworkSmoke/run.sh` with a booted iOS Simulator (or pass its UDID).
The script builds a disposable copy and installs a separate test app; it does not modify
MangaShelf's installed app or library.

Checks cover empty/missing/corrupt galleries, single-image reuse, distinct random artwork,
full-viewport layout with clipped aspect-fill images, separate artwork pages and pinned boundary transitions, unchanged PDF page counts, saved-position restoration, navigation, and
cancellation of obsolete chapter loads, scroll-driven fades and gradients in both directions,
go-to-bottom navigation, short-chapter backgrounds, and pixel-level checks that artwork and PDF crossfade at both boundaries, with full PDF opacity during reading. The script prints the test result and artifact path.

Source capture checks cover nonzero scroll offsets, sharp top pixels, missing display tiles,
transition opacity, PDF page boundaries, display resolution, and JPEG encoding for gallery storage.

Fast-scroll checks cover directional prefetch with a fixed window, visible-tile priority, reverse scrolling, rapid jumps through a tall PDF, chapter replacement during rendering, correct final displayed pixels, and bounded retained tiles. Smoothness still needs profiling on a physical device with representative PDFs.
