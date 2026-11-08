# Changelog

All notable changes to SecureClone. The build number in the app
(`v1.5 (42)`) is the GitHub Actions run that produced it.

## 2.7 — 2026-11-08
Engine and safety release.
### Added
- **Four verification modes**: Quick (copy only, never "safe to wipe"),
  Standard (hash while reading, re-read every drive), Thorough (+ re-read the
  card, second MD5 digest in the MHL), Paranoid (+ byte-by-byte compare of
  every copy against the card).
- **Source-stability checks**: `fstat` before and after each file — size,
  modification time and inode must not change, and every byte must have been
  read — otherwise the copy is rejected as "source changed during copy".
- **Durability**: `F_FULLFSYNC` on every file (pushes data past the drive's own
  cache; falls back to `fsync` on ExFAT) and an fsync of the directory after
  publishing the name.
- **Temp-file-then-atomic-rename**: files are written as `.name.sc-partial`
  and renamed only after the full flush; leftovers are removed at start.
- **Safety validator**: refuses a destination on the same physical disk as the
  source, two backups on one physical disk (override in Options), nesting,
  symlinked paths, and online-only iCloud/Dropbox placeholders (`SF_DATALESS`).
- **Link detection via IOKit**: every volume shows its bus (USB 5/10/20 Gb/s,
  USB 2.0, Thunderbolt, internal); USB 2 links are flagged and logged.
- **Crash evidence**: an active-run journal records phase, files copied and
  files verified; an interrupted run is reported at the next launch and added
  to history as unverified.
- Option to copy and verify `._` AppleDouble sidecars.
- Skip-identical now also works without an MHL by hashing the existing copy.

## 2.6 — 2026-11-08
### Changed
- **Copy path rewritten for sustained throughput on large files.** Reads and
  writes bypass the unified buffer cache (`F_NOCACHE`) so a 50 GB file no
  longer fills RAM, throttles, and stalls on the final fsync; chunks come
  from a fixed pool of page-aligned buffers instead of a fresh allocation per
  8 MB; destination files are pre-allocated to their final size
  (`F_PREALLOCATE`, a big help on ExFAT); writer queues are deeper.
- Per-file transfer time, duration and MB/s in the text report (with the
  job's average), and in the log line for each file.

## 2.5 — 2026-11-08
### Fixed
- Free-space check reported "has Zero KB" on ExFAT / HFS+ / NTFS drives and
  refused to start: it used an APFS-only capacity figure. Now uses the plain
  available capacity, with the APFS figure only when it's non-zero.

## 2.4 — 2026-11-08
### Fixed
- **Launch hang — root cause found** (from a symbolized process sample):
  `MenuBarExtra(isInserted:)` writes its binding back on every update; bound
  directly to a `@Published` setting it re-published on each write and the
  App body looped forever. The binding now writes only on a real change, and
  settings saves are coalesced per run-loop turn.

## 2.3 — 2026-11-08
### Fixed
- **Launch hang, second pass.** The split view sized its panes from their
  content, which fed back into the window size (the window grew off-screen,
  memory climbed, the main thread never returned). Replaced with a fixed-width
  left pane in a plain HStack and an explicit default window size. Drive
  monitoring now starts in the app's init, before any view exists, so the
  volume list no longer depends on the first layout pass completing.

## 2.2 — 2026-11-08
### Fixed
- **Hang at launch** (main thread unresponsive, force-quit by macOS). Volume
  rows had a new identity on every refresh, start-up work published state from
  inside the first view update, and the naming form used a `Grid` with
  middle-truncated text inside the split view — all replaced with stable IDs,
  deferred start-up, plain stacks and tail truncation.
- **Throughput ~100 MB/s on fast SSDs.** Hashing was the bottleneck: the pure-
  Swift xxHash package plus a per-chunk array copy, running in series with the
  reader. Replaced with a built-in pointer-based xxHash64 (validated against
  the reference vectors) running on its own pipeline thread. Verification uses
  8 MB reads with the cache bypassed, so it measures the disk, not RAM.
- Speed-test progress updates are coalesced (~10/s) instead of one per chunk.
### Changed
- No external package dependencies any more.

## 2.1 — 2026-11-08
### Added
- **Speed test mode.** Pick any volumes: each gets a write test (temp file,
  cache disabled, fsync'd, deleted) and a read test; read-only volumes
  (locked cards) skip the write and read their existing files instead. Shows
  an estimated transfer matrix for every direction (`min(read A, write B)`)
  and, optionally, real measured transfers from a chosen source to each
  writable drive. 256 MB / 1 GB / 4 GB sizes; results can be copied.
### Fixed
- Day-summary CSV row that timed out the Swift type-checker.

## 2.0 — 2026-11-08
A "card-ingest station" release: the app now runs a queue, names folders
for you, notices cards it has seen before, and can verify drives on its own.
### Added
- **Job queue.** Press Start (or Queue) while a job runs and the card waits
  its turn; jobs run back to back. Pending jobs are listed and removable.
- **Auto-start & auto-eject.** Insert a card → it is detected, named and
  queued against the remembered destinations; a verified card can be ejected
  automatically. Eject buttons on every volume row and in the summary.
- **Reel / camera detection** for ARRI, RED, Blackmagic, DJI, Sony and Canon
  card layouts; pre-fills reel, camera and job name.
- **Naming template** `{project}/{day}/{camera}/{reel}` (also `{date}`, `{job}`,
  `{card}`) builds the destination folder; live preview. Project and day are
  remembered between runs.
- **Source subfolder and per-destination base folder** pickers (default: whole
  card → drive root).
- **Skip identical files.** When the target folder already holds a file with
  the same size and a matching verified hash (from an MHL there), the source is
  hashed and, if equal, the write is skipped. Skipped files are still
  re-verified from disk and counted in the report.
- **Duplicate-card guard.** Warns when a card with the same reel, file count
  and size was already verified in the last 7 days.
- **Blocking free-space check** before copying, with the exact shortfall.
- **Verify-only mode.** Pick a drive, choose one of the MHLs found on it (or
  any .mhl file), re-hash every listed file and get a verification report.
  Reads MHLs from other tools too.
- **Shooting-day summary** (`DAY_<date>_SUMMARY.txt/.csv`) regenerated after
  every job on each destination: all cards, totals, per camera, per drive.
- **Verification progress** has its own percentage, speed, ETA and elapsed.
- **Searchable log** with export, copy and Follow; persisted to
  `~/Library/Application Support/SecureClone/logs/<date>.log`.
- **Jobs** tab listing finished jobs with their reports.
- **Menu-bar item** with live progress and pause/stop; the app keeps running
  when the window is closed; quitting mid-job asks first.
- **Sleep prevention** while a job runs.
### Changed
- Reports and MHLs live in `<destination folder>/SecureClone_Logs/`; the day
  summary at the drive root's `SecureClone_Logs/`.

## 1.5 — 2026-11-07
### Added
- Timecode for production audio: Broadcast WAV `bext` TimeReference at the
  frame rate from the `iXML` chunk (falls back to 25 fps); RF64 supported.
- Single-pass WAV header reader (`WAVReader`) replaces the earlier helpers.
### Fixed
- Build: CSV row literal that timed out the Swift type-checker; timecode flags
  read as a raw `UInt32` on the current SDK.

## 1.4 — 2026-11-07
### Added
- **Clip metadata** extraction after verification, from the verified copy:
  ARRI `.ale` sidecars › MXF header parser › AVFoundation (MOV/MP4/ProRes,
  incl. timecode track) › ImageIO (DNG).
- CSV report now fills Duration, Sensor FPS, EI/ISO, ND, Shutter Angle,
  TC Start/End, LUT, Codec and Resolution.
- **Thumbnails** for MOV/MP4/ProRes/DNG, generated in the background after the
  summary; **Clips** tab in the app; `_thumbs.jpg` contact sheet next to the
  reports.

## 1.3 — 2026-11-07
### Added
- **Pause / Resume / Stop.** A stopped job checkpoints after every file
  (`.session_<job>.json` on each destination) and offers to resume on the next
  start; resumed files are always re-verified. Half-written files are removed
  on stop.
- **Summary sheet** on completion with the full report, Reveal-in-Finder
  buttons and a copy button.
- **CSV report** in Silverstack format (`;`-separated, quoted, `XXH64BE:` hashes).
- Option to also save `.txt` + `.csv` to the source card (report folder only,
  after verification; ignored on the next offload).
- Unified report naming: `<Job>_<yyyyMMdd>_<DOW>_<HHmm>.{mhl,txt,csv}`.

## 1.2 — 2026-11-07
### Changed
- **Pipelined copy engine.** Dedicated reader thread with a bounded chunk
  queue and writer thread per destination: card, hasher and all drives work
  concurrently; a slow drive no longer throttles the others.
- **Parallel verification.** All destinations are re-read at the same time
  after the copy phase instead of one file at a time.
- Writers `fsync` each file before verification so the OS cache can't mask a
  bad write.
- Separate verification progress bar; per-drive rows show "written" vs
  "verified" correctly.

## 1.1 — 2026-11-07
### Added
- Progress percentage, smoothed transfer speed, ETA and elapsed time.
- App versioning: `VERSION` file + CI build number, shown in the header and
  recorded in every report.
- Build artifacts named `SecureClone-<version>-build<N>.zip`.

## 1.0 — 2026-11-05
### Added
- Initial release: read-once fan-out copy to multiple drives, xxHash64 /
  MD5 / SHA-256, independent re-read verification, ASC MHL v1.1 and
  plain-text report per destination, drive detection via DiskArbitration,
  SwiftUI interface.
- Swift package layout with `build-app.sh` and GitHub Actions workflow
  producing a universal `.app`.
