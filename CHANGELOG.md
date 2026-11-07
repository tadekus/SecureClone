# Changelog

All notable changes to SecureClone. The build number in the app
(`v1.5 (42)`) is the GitHub Actions run that produced it.

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
