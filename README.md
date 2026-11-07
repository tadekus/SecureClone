# SecureClone

**Verified media offload for film production, native on macOS.**

SecureClone copies camera cards to multiple drives at once, verifies every
copy by re-reading it from disk, and leaves behind the reports post-production
expects: an ASC **MHL** manifest, a plain-text **job report**, and a
Silverstack-compatible **CSV** clip list with camera metadata and timecode.

Built for DITs and data wranglers who need the same guarantees as commercial
offload tools, in a small open-source app they can build themselves.

---

## Features

**Copy & verify**
- Read the source card **once**, fan out to any number of destination drives
  concurrently — a slow drive never holds back a fast one
- **xxHash64** by default (MD5 / SHA-256 available), hashed inline while reading
- Every destination is **independently re-read and verified** after the copy;
  writes are flushed to the physical disk before verification, so the OS cache
  can never mask a bad write
- Source is never written to (except, optionally, a report folder after
  verification) and system cruft (`.DS_Store`, `._*`, Spotlight) is skipped

**Control**
- Live **progress, speed, ETA** per job and per drive
- **Pause / Resume / Stop**; a stopped job checkpoints after every file and
  can be **resumed** later — resumed files are still re-verified
- Summary sheet on completion with a clear **SAFE TO WIPE / DO NOT WIPE** verdict

**Reports** (written to every destination, optionally to the source card)
- `.mhl` — ASC Media Hash List v1.1
- `.txt` — human-readable job report
- `.csv` — Silverstack-style clip list (`;`-separated, `XXH64BE:` hashes)
- `_thumbs.jpg` — contact sheet of clip thumbnails

**Clip metadata** (fills the CSV, shown in the in-app clip grid)
| Source | What it provides |
|---|---|
| ARRI `.ale` sidecars | EI, shutter angle, ND, sensor fps, TC in/out, LUT |
| MXF header (ARRI without ALE) | TC start/end, resolution, fps, codec |
| AVFoundation (MOV/MP4, ProRes, H.264, HEVC) | duration, fps, resolution, codec, **timecode track** |
| Broadcast WAV `bext` + `iXML` | TC start/end, fps, format string |
| ImageIO (DNG stills) | resolution, ISO, exposure |

Thumbnails: MOV/MP4/ProRes and DNG. ARRIRAW and RED decoding (vendor SDKs)
is planned — see Roadmap.

---

## Install

Download the latest `SecureClone-<version>-build<N>.zip` from the
[Actions](../../actions) tab (open the newest green run → **Artifacts**), unzip,
and drag `SecureClone.app` into Applications.

The app is ad-hoc signed, not notarized. On first launch **right-click → Open**.
If macOS says the app is "damaged", clear the download quarantine once:

```
xattr -cr /Applications/SecureClone.app
```

Allow access to **Removable Volumes** when prompted, or cards won't appear.

Requires macOS 14 Sonoma or later. Universal binary (Apple Silicon + Intel).

---

## Build it yourself

No Xcode project needed — it's a Swift package.

```bash
./build-app.sh              # → build/SecureClone.app
./build-app.sh --universal  # Apple Silicon + Intel
```

Needs macOS 14+ with Xcode or the Command Line Tools. The GitHub Actions
workflow in `.github/workflows/build.yml` runs the same script on every push
and publishes the app as a build artifact.

### Versioning
- `VERSION` holds the marketing version (`1.5`). Bump it when releasing.
- The build number is the GitHub Actions run number, stamped automatically.
- The app shows `v1.5 (42)` in its header; reports record the same string.

---

## How it works

```
                 ┌─► queue ─► writer thread ─► Drive A ─┐
Card ─► reader ──┼─► queue ─► writer thread ─► Drive B ─┼─► parallel re-read & verify
   (hash inline) └─► queue ─► writer thread ─► Drive C ─┘        │
                                                                  ▼
                                           reports (MHL · TXT · CSV) + metadata + thumbnails
```

1. **Scan** the card (skips system files).
2. **Copy** — one reader thread streams 8 MB chunks, hashes them, and pushes
   each into a bounded queue per destination; each destination's writer thread
   drains its own queue. After each file, `fsync` and session checkpoint.
3. **Verify** — every destination is re-read from disk concurrently and
   compared to the source hash.
4. **Metadata** — read from the verified copy (never the card): ALE › MXF ›
   AVFoundation › BWF › ImageIO.
5. **Reports** written; summary shown.
6. **Thumbnails** generated in the background; contact sheet written last.

---

## Project layout

```
SecureClone/
├── Models/        VolumeInfo, CloneJob, ClipMetadata, AppInfo
├── Services/
│   ├── CloneEngine, ChunkQueue, CloneControl     copy pipeline + pause/stop
│   ├── ChecksumService, StreamingHasher          xxHash64 / MD5 / SHA-256
│   ├── DriveMonitor, SourceScanner               volumes + file discovery
│   ├── SessionStore                              resume checkpoints
│   ├── MHLWriter, LogWriter, CSVReportWriter     reports
│   └── Metadata/  ALEParser, MXFParser, AVExtractor, WAVReader, MetadataService
├── ViewModels/    CloneViewModel
└── Views/         ContentView, pickers, JobProgressView, ClipGridView, SummarySheet
```

---

## Roadmap

- **Phase 3 — ARRIRAW & RED thumbnails** via the vendor SDKs (ARRI Image SDK,
  R3D SDK) bridged into Swift
- Verify-only mode: re-check a drive against its MHL
- Per-camera metadata for cameras that write no TC track (optional time-of-day TC)
- Notarized builds (needs an Apple Developer ID)
- LTO / tar output target

---

## Disclaimer

Test it on media you already have backed up before trusting it on set. The
app reports what it verified; it is still your responsibility to read the
report before wiping a card.

## License

MIT — see `LICENSE`.
