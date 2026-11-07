# SecureClone

A native macOS (SwiftUI) tool for **verified media offload** in film production.
Read a source card **once**, fan the data out to **multiple destination drives**
concurrently, hash with **xxHash64**, then independently **re-read and verify**
every copy. Produces an industry-standard **MHL** manifest plus a plain-text
report per drive.

---

## Setup (Xcode)

This is a source-only starter — you create the Xcode project and drop these files in.

1. **Create the project**
   - Xcode → File → New → Project → **macOS → App**
   - Product Name: `SecureClone`
   - Interface: **SwiftUI**, Language: **Swift**
   - Delete the auto-generated `ContentView.swift` and `SecureCloneApp.swift`.

2. **Add the source files**
   - Drag the `Models/`, `Services/`, `ViewModels/`, `Views/` folders and
     `SecureCloneApp.swift` into the project (Copy items if needed, create groups).

3. **Add the xxHash dependency**
   - File → Add Package Dependencies…
   - URL: `https://github.com/daisuke-t-jp/xxHash-Swift`
   - Add the `xxHash-Swift` product to the SecureClone target.
   - *Until you do this,* the code still compiles (the xxHash path is guarded by
     `#if canImport(xxHash_Swift)`), but xxHash64 will be unavailable at runtime —
     pick MD5 or SHA-256 in the UI in the meantime.

4. **Entitlements / file access**
   - Use the included `SecureClone.entitlements`.
   - For your own on-set use, the **App Sandbox is OFF** so the app can read any
     mounted volume directly. For Mac App Store distribution you must turn the
     sandbox ON and adopt security-scoped bookmarks (see notes in the file).
   - On first run, macOS may prompt for access to "Removable Volumes" — allow it.
     (System Settings → Privacy & Security → Files and Folders.)

5. **Build & run** (⌘R).

---

## How it works

```
Source card ──(single read, hashed inline)──┐
                                             ├─→ Drive 1 ──(re-read + verify)
                                             ├─→ Drive 2 ──(re-read + verify)
                                             └─→ Drive 3 ──(re-read + verify)
```

- **Pass 1** streams the source in 8 MB chunks, hashing as it reads and writing
  each chunk to every destination concurrently (`TaskGroup`).
- **Pass 2** re-reads each destination file from disk independently and compares
  its hash to the source. This is what catches write errors / silent corruption —
  it's the difference between "copied" and "verified."

## Outputs

Each destination drive (and optionally the source card) gets a
`SecureClone_Logs/` folder containing, named `<Job>_<yyyyMMdd>_<DOW>_<HHmm>`:
- `.mhl` — ASC MHL v1.1 manifest (xxHash64 by default)
- `.txt` — human-readable report ending in either
  `SAFE TO WIPE SOURCE` or `DO NOT WIPE SOURCE`
- `.csv` — Silverstack-style clip list (semicolon-separated, `XXH64BE:` hashes)
  that matches the other DIT tools' exports. Camera-metadata columns are empty
  until per-format header parsing (ARRI MXF, RED R3D…) is added.

## Pause / Stop / Resume

- **Pause** holds the reader between chunks; **Resume** continues.
- **Stop** ends the job cleanly. Progress is checkpointed after every file into
  a hidden `.session_<job>.json` inside `SecureClone_Logs/` on every destination.
- Pressing **Start Clone** again with the same card, drives and job name offers
  to resume. Resumed files are skipped in the copy phase but are **always
  re-verified from disk**. A half-written file is deleted on stop so it can
  never be mistaken for a finished copy.

## Safety principles baked in

- **Source is never modified** — opened read-only, never written/renamed/moved.
- **Verify, don't trust** — independent re-read of every copy.
- **Read once, write many** — the card is read a single time.
- **System cruft skipped** — `.DS_Store`, `._*`, `.Spotlight-V100`, etc.
- **Capacity pre-flight** — warns if a destination may be too small.

---

## Roadmap / next steps

- Per-destination bounded write queues so one slow USB drive doesn't throttle
  the whole job (decouple readers from writers).
- Eject/verify-only modes; re-verify an existing drive against its MHL.
- XXH3/XXH128 option for Apple-Silicon speed (keep XXH64 default for compat).
- LTO / tar output target.
- Source-card read-only enforcement via mounting flags.
- Resume / skip-existing using prior MHL.

## File map

| File | Role |
|------|------|
| `SecureCloneApp.swift` | App entry point |
| `Models/VolumeInfo.swift` | Mounted volume model |
| `Models/CloneJob.swift` | Job + per-file / per-destination state |
| `Services/DriveMonitor.swift` | DiskArbitration mount/unmount detection |
| `Services/SourceScanner.swift` | Walks the card, skips system files |
| `Services/ChecksumService.swift` | File hashing (xxHash64 / MD5 / SHA-256) |
| `Services/StreamingHasher.swift` | Incremental hashing during read pass |
| `Services/CloneEngine.swift` | Read-once fan-out copy + verify (the core) |
| `Services/MHLWriter.swift` | ASC MHL manifest output |
| `Services/LogWriter.swift` | Plain-text job report |
| `ViewModels/CloneViewModel.swift` | Orchestration + progress |
| `Views/*` | SwiftUI interface |
