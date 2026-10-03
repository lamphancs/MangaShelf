# Add series smoke checks

Run `bash Tests/AddSeriesSmoke/run.sh` with a booted iOS Simulator.
Uses an isolated app identifier, temporary library folder and in-memory SwiftData store.
Checks creation and portable metadata, duplicate protection, unsafe input rejection,
and empty-series survival/reconstruction through the production scanner.

Also checks URL-free creation, display-title preservation across folder renames, and a
move-out/move-back cycle restoring links, notes, dates, chapter progress/scroll offsets,
bookmarks, cover, and artwork.
