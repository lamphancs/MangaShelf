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

Reader flick checks verify UIKit's native deceleration remains enabled and its projected travel is capped at 1.25 viewport heights in either direction.

Continuous transition checks cover opening/closing seams, fully opaque story content, reverse scrolling, unchanged geometry, and switching back to Fade.

Parallax checks cover distinct motion and seam widths, opening/closing endpoints, ordered mask stops, reverse scrolling, overscroll, and preserved story opacity and layout.

Hybrid checks compare Parallax + Continuous against the original opening Parallax and closing Continuous effects across endpoints, partial scrolls, and reverse scrolling.

PDF seam checks cover unpainted paper and fractional image clips over a dark background
embedded in the PDF. They exercise actual reader tiles, viewport captures, and capture
previews, while preserving a real black rule beside the join. Use Core Graphics drawing
directly: PDFKit's page drawing reintroduces edge smoothing even when it is disabled on
the caller's context. Image interpolation remains enabled.

To verify a private PDF with a known seam in a white gutter (without committing the file):

```sh
READER_SEAM_PDF='/path/to/chapter.pdf' READER_SEAM_Y=47347.9 bash Tests/ReaderArtworkSmoke/run.sh
```

`READER_SEAM_Y` is measured in PDF points from the top of the first page; the check
samples at 5% of the page width. This checks reader widths 300/390/430, fractional
viewport offsets, and preview widths 430/860/1290 pixels. A `seam-fixed.png` crop is
saved in the isolated test app's Documents directory. The supplied Chapter 2 repro
(430 x 71233 points) passed all 182 checks at this coordinate. Its embedded images
have no dark line at that join; fractional clipping against an embedded dark fill
causes the hairline. This is a display fix, not a rewrite of exported PDFs. At higher
zoom, a real subpixel gap in the PDF can still occupy a full pixel; external viewers
retain their own rendering behavior.
