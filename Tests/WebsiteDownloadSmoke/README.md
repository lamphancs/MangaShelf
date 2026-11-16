# Website download checks

Run on a booted iOS 26.4+ simulator:

```sh
bash Tests/WebsiteDownloadSmoke/run.sh <simulator-udid>
```

The runner copies the project into `/tmp`, uses an isolated bundle ID and in-memory
SwiftData, and never reads or modifies the installed MangaShelf library.

Fixtures exercise:

- Four provider scopes, canonical URL deduplication, numeric/decimal ordering,
  Chapter/Chap/Ch./Chương/Hồi naming (including Hồi 600 with Tập 78).
- Real WKWebView DOM execution and byte-preserving blob/data chunk transfer: delayed image creation, lazy attributes,
  picture/source fallback deduplication and advertisement removal.
- Omega Next.js state matched by series slug, two API pages and incomplete metadata rejection.
- Native URLSession response handling: missing Referer produces HTTP 403 without retry;
  supplied Referer retrieves exact bytes; task cancellation.
- One continuous PDF page, source JPEG stream byte equality, non-JPEG PNG lossless
  stream, ICC profile resources, seam pixels, fixed width beyond 14,400-point height and explicit EXIF rejection.
- Existing PDFContentView uses width fitting for the generated tall page.
- EN import through ImportService, PDFKit opening and duplicate-file preservation.

## Live checks — 2026-11-16

These are deliberately separate from fixtures:

| Provider | Live evidence | Remaining verification |
| --- | --- | --- |
| ToonGod | Supplied series URL returned a Cloudflare “Just a moment” page | Complete verification in iPhone WebKit; AJAX list, image download and full chapter PDF |
| Omega | Public series HTML contains matching `series_slug`/ID in Next Flight state; public API returned 126 unique chapters across 2 pages with matching metadata | API from iPhone WebKit/CORS, actual comic image downloads and full chapter PDF (the live pagination sample was a novel) |
| damconuong | `.cool` homepage serves links to `.tech`; sampled chapter HTML contains `#chapter-content`, `data-cipher-path` and `data-cipher-decoder`; explicit alias supported | Series list completeness, dynamic decoder DOM and full chapter on iPhone |
| TruyenQQ | Live access returned HTTP 403 | Real list/image selectors, verification and complete chapter on iPhone |

No complete real website chapter export has been verified. No provider is claimed
to be fully verified on a physical iPhone. Web access checks were performed from
the development environment, not the user's authenticated session.

References: [Omega sample series](https://omegascans.org/series/the-scion-of-the-labyrinth-city),
[Omega public API](https://api.omegascans.org/chapter/query?page=1&perPage=100&series_id=186),
[ToonGod supplied sample](https://www.toongod.org/webtoon/swordmasters-youngest-son-beaabc/),
[damconuong](https://damconuong.cool/), [TruyenQQ](https://truyenqqko.com/),
[Apple WKHTTPCookieStore](https://developer.apple.com/documentation/webkit/wkhttpcookiestore).

## Device checklist

Hold the VN/EN Series Homepage link in Info → “Tải truyện từ website”. Complete
verification or sign-in in the source pane, then refresh the list. Search/select
chapters, download, stop midway, retry failed selections, return to the library,
open the saved chapter and share it to Files. Confirm EN placement and VN placement,
secret-session isolation, light/dark artwork unchanged, existing theme persistence,
landscape/Dynamic Type layout, storage permission failures and background stopping.
Test RGB/grayscale/progressive JPEG and WebP from real sources, with their ICC
profiles; CMYK and non-default EXIF must fail clearly rather than recompress.
Verify Hỏa Phụng's actual series page exposes all Hồi rather than only one Tập.

Current limits: 40 MB/source image, 250 MB/source chapter, 32 million pixels/image,
512 MB PDF budget, 600 MB free-space preflight. PNG/WebP are decoded to 8-bit RGB
and losslessly compressed on a white background; higher bit depth and animated
images are rejected. JPEG CMYK and EXIF orientation other than 1 are rejected.
DOM stability is not proof of completeness; the UI warns where counts cannot be
verified. There is no background resume or persisted download queue.

## Performance regression checks

The runner starts an ephemeral loopback HTTP server and downloads six 256 KiB
responses with deliberately staggered delays. It verifies a peak of exactly three
active requests, byte content and original image order despite out-of-order
completion, cancellation before partial installation, and the 40 MB download limit.
A simulator run measured 1.915 seconds sequential versus 0.634 seconds with three
transfers (about 3× faster for this fixture). This is not a live website/chapter
benchmark and excludes provider/PDF/import work.

The HTML fast path is tested for relative/lazy URLs, total counts, no chapter
navigation, unchanged scroll position and no website-script execution. PNG RGB
samples are compared exactly after Accelerate channel conversion; the original
JPEG-byte, PDF geometry and import checks remain in the suite.

Background behavior changed: native work may finish the current chapter under a
bounded UIApplication background lease. Preparation requiring WebKit stops, and
no new chapters start after backgrounding. Expiration/force termination/resumption
still require device verification; this is not persistent background downloading.

Fixed-width update: the long-page fixture now expects a 20 × 18,000-point page,
with the same 20-point width as its short counterpart. The old 14,400-point cap
assertion was replaced. Production width is the browser viewport frozen per batch.
