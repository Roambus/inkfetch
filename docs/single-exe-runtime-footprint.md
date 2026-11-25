# Single-EXE Runtime Footprint Audit — InkFetch 墨取 (Windows desktop)

**Scope:** every filesystem location the *Windows* release build writes to or creates at runtime,
plus what the current `InkFetch-2.1.0-windows-x64.exe` self-extracting wrapper itself writes.
**Method:** static read of `lib/**.dart`, `pubspec.lock`, `windows/runner/*`, `.github/workflows/build.yml`,
plus inspection of the resolved plugin sources in `%LOCALAPPDATA%\Pub\Cache` and of the shipped
wrapper binary. **This is a read-only audit: no file was modified, no build was run.**

---

## 0. Summary

| # | Verdict |
|---|---|
| Stray files **inside the user's download folder** | **1 kind**: `<name>.octopart` sidecar. Everything else in that folder is the downloaded payload (plus the in-flight `.part`-free same-name file, which *is* the payload). |
| Stray files **next to the exe** | **0**. No `flutter_assets` writes, no log file, no config beside the executable. |
| Stray files **on the Desktop** | **0**. |
| Stray files elsewhere, unavoidable by design | SharedPreferences JSON, the single-exe wrapper's unpack directory, and Windows/Flutter OS-level scratch (Prefetch, shader caches, jump lists). |
| Biggest single-file-EXE problem | The **wrapper itself** (12.4 MB `dist/InkFetch-2.1.0-windows-x64.exe`) is a custom SFX that unpacks to `%LOCALAPPDATA%\InkFetch\<version>\` and never cleans up — that is the largest out-of-folder footprint and it is *not* in `lib/`. |

Windows resolves the two root locations as follows (verified on this machine):

- `%APPDATA%` = `C:\Users\Just\AppData\Roaming`
- `%LOCALAPPDATA%` = `C:\Users\Just\AppData\Local`
- Downloads known folder = `C:\Users\Just\Downloads` (registry `User Shell Folders\{374DE290-…}`)
- `getDownloadsDirectory()` → `SHGetKnownFolderPath(FOLDERID_Downloads)` — `path_provider_windows-2.3.0/lib/src/path_provider_windows_real.dart:131`
- `getApplicationSupportPath()` → `%APPDATA%\<CompanyName>\<ProductName>` — same file `:119-120` → `_createApplicationSubdirectory` `:250`, create at `:263`; component built by `_getApplicationSpecificSubdirectory` `:180`

---

## 1. Full inventory

Legend — **Vis.** = where the user sees it: `DL` = user's download folder, `EXE` = next to the exe,
`DESK` = Desktop, `APPDATA` = `%APPDATA%`, `LOCAL` = `%LOCALAPPDATA%`, `TMP` = `%TEMP%`, `OS` = invisible OS location.
**Req.** = required for a documented feature (R = resume/`.octopart`, Q = queue persistence, H = history, S = settings).

### 1.1 Settings / history / queue persistence (SharedPreferences)

| Item | Path pattern (actual Windows path) | Code | Created | Removed | Vis. | Req. |
|---|---|---|---|---|---|---|
| `inkfetch.settings.v1` | `%APPDATA%\app.inkfetch\墨取 InkFetch\shared_preferences.json` | `lib/core/storage.dart:8,45-48`; `lib/state/app_controller.dart:436,672,684,691…` | first settings write (theme/connections/picker/`_prepareDestination` fallback) | never (app never deletes it) | APPDATA | S |
| `inkfetch.history.v1` | same JSON file (one key) | `lib/core/storage.dart:9,50-57`; `app_controller.dart:391` | after every download finishes (`startDownload`) | only via "清空历史" (`clearHistory`, `app_controller.dart:735-740`) | APPDATA | H |
| `inkfetch.queue.v1` | same JSON file | `lib/core/storage.dart:10,59-62`; `app_controller.dart:465,476,495,502` | on enqueue / dequeue / clear | only when queue emptied | APPDATA | Q |

Plugin chain (all four keys land in **one file**, not three): `shared_preferences-2.5.6` →
`shared_preferences_windows-2.4.1/lib/shared_preferences_windows.dart:17` (`_defaultFileName = 'shared_preferences'`)
→ `:334` `_getLocalDataFile` joins `getApplicationSupportPath()` + `shared_preferences.json` (`:344`)
→ `_writePreferences` `:391` does `createSync(recursive: true)` + `:394` `writeAsStringSync`.

**Exact paths observed on this machine (evidence of real runs):**
- `C:\Users\Just\AppData\Roaming\app.inkfetch\墨取 InkFetch\shared_preferences.json` (554 B, 2026/11/2 02:27) — current build.
- `C:\Users\Just\AppData\Roaming\app.inkfetch\inkfetch\` — **empty legacy directory** from an older
  `windows/runner/Runner.rc` where `ProductName` was `inkfetch`; `Runner.rc:92,98` now yields CompanyName
  `app.inkfetch`, ProductName `墨取 InkFetch`, so path_provider's `_getApplicationSpecificSubdirectory()`
  (`path_provider_windows_real.dart:180`) produces the CJK folder. Confirmed from the built exe's
  VERSIONINFO: `CompanyName=[app.inkfetch]`, `ProductName=[墨取 InkFetch]`, `OriginalFilename=[inkfetch.exe]`.
- **Note:** because the subdirectory component is the localized `ProductName`, the path is
  **language/UNICODE-dependent and changes if the product name changes**. That is a real portability wart
  for a "no stray files" guarantee, and it is why an old `inkfetch\` dir is left behind forever.

### 1.2 Download destination resolution

| Item | Path pattern | Code | Notes |
|---|---|---|---|
| Desktop root resolution | `settings.downloadDir` → else `NativeBridge.defaultDownloadDir()` → else `getApplicationDocumentsDirectory()` (which on Windows is `%USERPROFILE%\Documents`) | `lib/state/app_controller.dart:418-454`; `lib/core/platform.dart:36-54` | `defaultDownloadDir()` calls `getDownloadsDirectory()` (`platform.dart:45`), falls back to `$USERPROFILE\Downloads` (`platform.dart:49-51`). |
| Directory creation | `<root>\` | `app_controller.dart:438` `Directory(root).create(recursive: true)` | only creates the folder the user chose; a *user-visible* folder, expected. On the fallback path it **also rewrites settings** (`:434-437`). |
| Collision avoidance | `<name>.ext`, `<name> (1).ext`, `<name> (2).ext`, … | `app_controller.dart:439-453` | Read-only probing of `File(candidate).exists()`; no temp file. If `<name>.octopart` exists, the **same** name is reused (resume), so no ` (1)` duplicate. |

**Android-only branches (not Windows, listed for completeness):** `app_controller.dart:420-427` (internal dir + tree URI),
`:337-366` (`saveToTree` copy then `File(destPath).delete()`), `platform.dart:37-43,57-73,83-101`.

### 1.3 `.octopart` sidecar — the only stray file in the download folder

| Item | Path pattern | Code | Created | Removed | Vis. | Req. |
|---|---|---|---|---|---|---|
| Sidecar | `<downloadDir>\<filename>.octopart` (e.g. `C:\Users\Just\Downloads\git-master.zip.octopart`) | set at `lib/core/downloader.dart:304` `_sidecarPath = '$destPath.octopart'`; written by `_maybeWriteSidecar` `:672-699` (`File(path).writeAsString(payload)`) | during chunked download: first tick of the 3 s timer `_startSidecarTimer` `:653-658`, plus on pause (`:169`) and on cancel cleanup (`:834`) | **success only**: `_deleteSidecar()` `:820-826` called at `:263` after full download, and at `:251` on SHA-256 mismatch | DL | R |
| Partial payload | `<downloadDir>\<filename>` (no `.part` suffix) | `downloader.dart:296` `file.open(mode: FileMode.append/write)`; `:303` `truncate(_total)` | at download start | on cancel/failure **not removed** (kept for resume) | DL | R |
| Sidecar JSON content | `{version, url, total, etag, chunkSize, chunkCount, completed[]}` | `downloader.dart:683-691` | — | — | — | R |

Behaviour matrix (this is where the "stray file" pain is):

| Outcome | payload `<file>` | `.octopart` | Evidence |
|---|---|---|---|
| **Success** | kept (the deliverable) | **deleted** | `downloader.dart:234-264`, `_deleteSidecar` at `:263` |
| **SHA-256 mismatch** | kept (corrupt) | **deleted** | `:250-257` (deletes then reports failure — so the corrupt file is *not* resumable; deliberate) |
| **User cancel** | kept | **kept** (`_cleanupCancelled` `:829-836` force-writes it) | notice text `app_controller.dart:403` "未完成的分片已保留" |
| **Fatal failure** (`_fatalError`, "还剩 N 个分片未能完成") | kept | **kept** (last 3 s tick / pause write) | `downloader.dart:353-357`, `:265-272` |
| **Single-stream path** (`_runSingleStream`, `:513-583`) | kept | **never created** (`_sidecarPath` stays null → `_maybeWriteSidecar` returns early `:674`) | so a failed single-stream download leaves a `.part`-less truncated file with **no** `.octopart`, i.e. invisible to resume |
| App killed / power loss | kept (partially flushed) | kept, up to ~3 s stale | `_flushAndPersist` `:660-670` flushes then persists |

Two further stray-file mechanics worth flagging:

1. **Sidecar write is fire-and-forget and unthrottled-enough**: `_sidecarPending = _sidecarPending.then(...)` (`:693`)
   queues a `writeAsString` per 3 s tick; each write is a **non-atomic in-place overwrite** of the `.octopart`
   (`:695` `flush: false`). A crash mid-write leaves a truncated JSON → `_loadSidecar` catches and returns
   `null` (`:648`) → resume silently restarts from zero, and `refreshIncompleteTasks` silently skips it
   (`app_controller.dart:525-557` catch `:556`). No temp-file rename is used, so there is no extra stray file
   but also no crash-safety.
2. **`.octopart` files are the only app-authored artefacts the user ever sees in `Downloads`.**
   They have no hidden/system attribute, no `.part`/`~` prefix, no dot-prefix — on Windows the leading-dot
   convention is meaningless, so they look like ordinary files.

### 1.4 Incomplete-task scanning (`refreshIncompleteTasks`)

| Item | Detail | Code |
|---|---|---|
| Dirs scanned | **exactly one** on Windows: `settings.downloadDir` (single-element `Set<String>`) | `app_controller.dart:506-514` |
| Filter | non-recursive `dir.list(followLinks: false)`, files ending in `.octopart` | `:520-523` |
| Side effects | **read-only** — `readAsString` per sidecar, `jsonDecode`; no write, no temp file, no cache | `:525-557` |
| Called from | `init()` `:102`, after every finished download `:414`, after destination failure `:286`, after every delete `:599,615` | — |
| Consequence | Only downloads in the **current** `downloadDir` are discoverable. Change the folder in settings and older `.octopart` files become invisible orphans **that this app will never clean up** — permanent stray files. | — |

### 1.5 Explicit deletion paths (the only ways a user removes strays)

| UI | Deletes | Code |
|---|---|---|
| 未完成任务 → 删除 | `<destPath>` then `<destPath>.octopart`, each in its own `try/_` | `app_controller.dart:591-601` |
| 下载失败/取消 → 删除未完成文件 | same pair | `:603-617` |
| 清空历史 | only the SharedPreferences key | `:735-740` |
| Settings → 恢复默认 | rewrites `downloadDir` only; **never deletes anything** | `:677-687` |

**Nothing auto-cleans stale `.octopart` files: no TTL, no startup sweep for orphans, no "clean up on exit".**

### 1.6 Logs / caches / crash dumps

| Item | Finding | Code |
|---|---|---|
| App log file | **None.** All diagnostics go to `debugPrint` (which is a no-op in release on Windows desktop unless a console is attached — `windows/runner/main.cpp:11-13` only attaches a console when a parent console exists or a debugger is present). | `lib/main.dart:14-22` |
| Crash dumps from Dart | **None by app code.** No `FlutterError` dump-to-disk, no `runZonedGuarded` file sink. | `main.dart:12-23` |
| Crash dumps from OS | Windows Error Reporting / `%LOCALAPPDATA%\CrashDumps` may appear on native crash — not app-controlled, nothing to remove in code. | — |
| Temp files from the app | **None.** `getTemporaryDirectory()` is never called anywhere in `lib/` (grep: zero hits). The downloader writes the payload in place and never uses a `.part`/`.tmp` staging file. | verified by grep |
| Flutter engine caches next to exe | None written. `data/` and `flutter_windows.dll` are only *read*; the engine's shader/persistent caches are created by the OS/GPU driver path, not in the app folder. | `windows/runner/*` |

### 1.7 Plugins on Windows — confirmations

| Plugin | Windows path used | Writes? | Evidence |
|---|---|---|---|
| `shared_preferences 2.5.6` | `shared_preferences_windows 2.4.1` (pure Dart, no native plugin: `windows/flutter/generated_plugin_registrant.cc` registers **nothing**) | **Yes** — one `shared_preferences.json` (§1.1) | `shared_preferences_windows.dart:334-344,391-394` |
| `path_provider 2.1.6` | `path_provider_windows 2.3.0` (pure Dart/FFI, also not in the registrant) | **Yes, indirectly** — `getApplicationSupportPath()`/`getApplicationCachePath()` **create** `%APPDATA%\app.inkfetch\墨取 InkFetch\` via `directory.create(recursive: true)` (`path_provider_windows_real.dart:250-263`). `getDownloadsDirectory()` `:131` and `getApplicationDocumentsDirectory()` `:123` are read-only lookups. | as cited |
| `file_picker 13.3.1` → `windows_file_picker 2.0.1` | only `FilePicker.getDirectoryPath()` used | **No files created.** Native `IFileOpenDialog` in a spawned isolate (`file_picker_windows.dart:128-148`). `saveFile()` *does* `File(...).writeAsBytes` (`:254`) but **is never called by this app**. The dialog may itself write shell MRU history (`Recent`/Jump Lists) — OS behaviour, not app files. | `lib/core/platform.dart:75` is the only call site |
| `package_info_plus 10.2.2` | `PackageInfoPlusWindowsPlugin` — reads VERSIONINFO of `Platform.resolvedExecutable` via FFI | **No writes at all.** Pure read (`package_info_plus_windows.dart:20-36`, `file_version_info.dart`/`file_attribute.dart` open files read-only). Used only for the version label (`lib/ui/settings_page.dart:15,257-266`). | as cited |
| `crypto 3.0.8` | pure Dart (`sha256`) | No writes; `_hashFile` only **reads** the finished file (`downloader.dart:847-858`) | — |
| `jni 1.1.1` (transitive, Android-only) | **built into the Windows bundle** as an FFI plugin (`windows/flutter/generated_plugins.cmake:8-9` `FLUTTER_FFI_PLUGIN_LIST jni`) | **No runtime writes observed** (no `getTemporaryDirectory`/extract logic in `jni-1.1.1/lib`); it is dead weight in the Windows build — its native asset is empty (`native_assets.json` = `{"format-version":[1,0,0],"native-assets":{}}` in both `Release\` and `data\flutter_assets\`). | should be excluded from Windows via pubspec platform gating |

### 1.8 The single-EXE wrapper itself (largest footprint, outside `lib/`)

`dist/InkFetch-2.1.0-windows-x64.exe` (12,451,840 B) is **not** a Flutter artifact — it is a hand-rolled SFX
(MZ/PE, imports only `KERNEL32/SHELL32/USER32/VCRUNTIME140`, embeds its payload as an `RCDATA` resource via
`FindResourceW/LoadResource/SizeofResource`, and its embedded string table is:
`%LOCALAPPDATA%`, `%TEMP%`, `InkFetch`, `2.1.0`, `InkFetch.exe`, `payload.zip`, `"PAYLOAD.tar.exe" -xf "%s" -C "%s"`,
plus Chinese messages "解压失败，请确认系统中有可用的解压工具（Windows 10 及以上自带）" / "启动文件缺失，请重新下载完整安装包").

| Item | Path pattern | Created | Removed | Vis. | Req. |
|---|---|---|---|---|---|
| Unpacked app tree | `%LOCALAPPDATA%\InkFetch\<version>\{InkFetch.exe, flutter_windows.dll, native_assets.json, data\app.so, data\icudtl.dat, data\flutter_assets\**}` | first launch of that version | **never** — no cleanup code in `lib/` or `windows/` | LOCAL | accidental (see §2) |
| Shell staging | `%TEMP%\PAYLOAD.tar.exe` (the wrapper drops a copy of the system `tar` to extract the payload) | each launch | **not confirmed removed** — `DeleteFile` *is* imported, but no `%TEMP%\InkFetch` exists now and no leftover payload was found, so cleanup is at best partial/best-effort | TMP | accidental |

**Observed evidence on this machine:** `%LOCALAPPDATA%\InkFetch\2.0.1\` (208 MB incl. `flutter_windows.dll` 21 MB)
**and** `2.1.0\` coexist — an old version tree that nothing ever deletes. Documented in `README.md:36`
("首次启动解压到 `%LOCALAPPDATA%\InkFetch`") but the README says nothing about old versions accumulating.

---

## 2. What cannot be removed without losing a documented feature

| Artifact | Feature it backs | README evidence | Minimal mitigation (keeps feature) |
|---|---|---|---|
| `%APPDATA%\app.inkfetch\墨取 InkFetch\shared_preferences.json` | settings + history + queue persistence | `README.md:17,19,20` | none needed — it is one file in `%APPDATA%`, and a portable build can be pointed elsewhere, but **deleting it loses settings, history and the queue**. |
| `<downloadDir>\<file>.octopart` | 断点续传 resume (`README.md:17`), 重启恢复 (`README.md:20`) | `README.md:17,20` | move it out of `downloadDir` into `%APPDATA%\<state>\sidecars\<hash>.octopart`, keyed by a hash of the absolute dest path (see §3.1) — **resume still works, download folder becomes pristine**. |
| `<downloadDir>\<file>` partial payload on cancel/failure | same resume feature — the data must live somewhere | `README.md:17` | keep the payload in the download folder (it *is* the file the user asked for) but rename the in-flight file to `<file>.part` and only rename to `<file>` on success; then "no stray files" is true by construction and a killed app cannot leave a plausible-looking truncated `.zip`. |
| `%LOCALAPPDATA%\InkFetch\<version>\**` | single-file distribution (`README.md:36`) | `README.md:36` | prune sibling version directories on startup and/or unpack to `%LOCALAPPDATA%\InkFetch\app\` (single, overwritten slot) instead of per-version. |
| `%APPDATA%\app.inkfetch\inkfetch\` (empty) | nothing — legacy leftover from a renamed ProductName | — | safe to delete; prevent recurrence by pinning the app-data subdirectory instead of deriving it from `ProductName`. |

---

## 3. Concrete minimal code changes, ranked by risk

**Risk = chance of breaking a shipped behaviour.**

| # | Risk | Change | Where | Effect |
|---|---|---|---|---|
| 1 | **Very low** | Stop deriving the app-data path from `ProductName`. Either (a) call `getApplicationSupportPath()` and accept the CJK folder but add a one-time migration that deletes the empty sibling `inkfetch\`, or (b) bypass path_provider for prefs by writing to an explicit `%APPDATA%\InkFetch\prefs.json`. Prefer (a): it is 10 lines and no new dependency. | new `lib/core/paths.dart`, used by `lib/core/storage.dart:14,46,51,60` | Removes the CJK/ProductName coupling and the orphan `inkfetch\` dir; keeps all three keys. |
| 2 | **Low** | Prune the wrapper's old unpack trees: at startup, `Directory(%LOCALAPPDATA%\InkFetch).list()` and delete any version dir that is not `Platform.resolvedExecutable`'s ancestor. | `lib/main.dart:10-18` (before `runApp`), guarded by `Platform.isWindows` | Kills the 208 MB `2.0.1\` tree; no user-visible behaviour change. Note the wrapper is outside this repo, so this is the only in-repo fix. |
| 3 | **Low** | Make the sidecar write atomic: write `<path>.octopart.tmp` then `renameSync` over the real path. | `downloader.dart:693-698` | Removes the truncated-JSON failure mode; adds a `.tmp` that exists for microseconds only (and `refreshIncompleteTasks` already filters on `.endsWith('.octopart')`, so a leftover `.tmp` would sort as an orphan — add it to the scan's ignore list). |
| 4 | **Medium** | Move `.octopart` out of the download folder into a sidecar store keyed by a hash of the absolute dest path, e.g. `%APPDATA%\app.inkfetch\墨取 InkFetch\sidecars\<sha1(destPath)>.octopart` with an internal `destPath` field. Changes: `downloader.dart:304,634`, `app_controller.dart:442,506-563,591-617`. | — | **Download folder becomes completely clean** (the stated goal) while resume + restart-recovery keep working. Requires a migration: on first run, scan `downloadDir` once for legacy `*.octopart`, import, delete. Biggest single win; medium risk because `refreshIncompleteTasks`, both delete paths, and the collision check at `:442` all read the sidecar by path. |
| 5 | **Medium** | Rename in-flight payload to `<file>.part` and `renameSync` to `<file>` only on success; make `.part` the resume marker too (then the sidecar can even be dropped). | `downloader.dart:291-296,304,515-516`, `app_controller.dart:439-453` | Guarantees no truncated file ever masquerades as a finished download, and makes "the only file in Downloads is the finished download" structurally true. Risk: every "open file / open folder" path and history entry records `destPath` — must record the final name. |
| 6 | **Medium** | Give `.octopart` (and any `.part`) the Windows **hidden** attribute so Explorer does not show them, as a stop-gap if #4/#5 are deferred. | `downloader.dart` after each write | One `attrib +h` / `SetFileAttributesW` call via `ffi`/`win32` (already a transitive dep). Cheap, but it is a cosmetic fix — the file is still there. |
| 7 | **Low** | Add an orphan sweep: `refreshIncompleteTasks` already enumerates `.octopart`; if a sidecar's `destPath` no longer exists or the `downloadDir` in settings changed, offer/auto-delete after N days. | `app_controller.dart:506-563` | Fixes permanent orphans when the user changes the download folder. |
| 8 | **Very low** | Exclude `jni` from the Windows build (`pubspec.yaml` platform gating / move the Android-only channel code behind a separate package) — it currently compiles an empty FFI plugin into the exe. | `pubspec.yaml:38-41` area, `windows/flutter/generated_plugins.cmake:8-9` (generated — fix at pubspec level) | Smaller exe; no runtime footprint change, listed for completeness. |

**Do not do:** delete the partial payload on cancel/failure to "clean up" — that is exactly the documented
resume feature (`README.md:17`, `app_controller.dart:403`, `downloader.dart:828-836`). And do not delete
`shared_preferences.json` — it holds settings, history and queue in one file.
