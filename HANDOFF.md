# HANDOFF — Flapse iOS App

Last updated: **2026-08-02**. Written for a completely new session with no
prior context. This replaces the 2026-07-21 version of this file (that phase
of work — tab performance/Liquid Glass restoration — is finished and its
commits are on `main`; see "Older, already-finished phases" at the bottom if
you need that history).

Read this file first, then:

1. `README.md` for the feature overview.
2. `YAYINLAMA_REHBERI.md` for the Turkish App Store publishing guide and live checklist.
3. `project_handoff.md` for older architectural and repository conventions.

## Project identity

Flapse is a native SwiftUI iOS app for building long-term photo/video progress
projects and creating timelapse videos. It uses SwiftData, CloudKit, StoreKit 2,
AVFoundation, Vision, ActivityKit and WidgetKit. No third-party runtime
dependencies.

- Local repository: `/Users/ridvanozcan/Desktop/workspace/Flapse`
- Stale path sometimes supplied by the environment — do NOT use it:
  `/Users/ridvanozcan/Desktop/workspace/Timelapse`
- GitHub: `https://github.com/ozcanr17/Flapse.git`
- Branch: `main`
- App display name: **Flapse**, bundle ID `rozcan.Flapse`, widget bundle
  `rozcan.Flapse.Widgets`, Apple team `5ZYCHZ39QV`
- Minimum iOS 17; development/testing also targets iOS 26.
- User is Turkish-speaking, direct, wants measurement/logs over speculation
  ("Kendin de simülatörden test edebilirsin", "Ölçümle başla"). UI work must
  follow `.claude/skills/tasteskill` — calm native Apple HIG, no neon/glow,
  color is an accent only (see pitfall list below for where this was tested).

## Current task (this session, unfinished thread)

One long continuous thread: **camera performance → camera UI redesign →
video-recording project mode → various UX fixes → project import/export
feature**. The immediate trigger for this handoff was the user pasting a
real on-device debug log and asking for (a) a bug fix from that log and
(b) a dead-code sweep of the whole app, then asking to write this handoff
and commit.

## What has been completed this session

1. **Camera post-capture review screen** (`Flapse/Features/AutoSort/AutoCaptureFlow.swift`)
   rebuilt to visually match `TimelapseExportSheet` exactly (light canvas,
   "Kapat" top-left, `theme.surface` preview card, Kullan/Tekrar Çek/Vazgeç).
   The video player is now the SAME type used by the export sheet —
   `ExportedVideoPlayer` in `Flapse/Features/Export/TimelapseExportSheet.swift`
   was changed from `private` to `internal` and is now shared by both
   screens. My own `SimpleVideoPlayer` type was removed from this screen
   (it is still used elsewhere, in `EntryViewerView.swift` — do not delete
   the file itself).

   - Preview card now sizes to the capture's real aspect ratio
     (`mediaAspect` state; for video, computed via `AVURLAsset.loadTracks` +
     `preferredTransform` so device rotation is accounted for; for photo,
     the image's own pixel size).

   - **Bug fixed**: exiting AVKit's own native fullscreen (the expand icon
     built into `AVPlayerViewController`, not our "Kapat" button) was wiping
     the pending video and dropping the preview to a frozen frame. Root
     cause: a blanket `.onDisappear` on the flow's root view called
     `discardPendingVideoFile()`, and AVKit's native fullscreen transition
     fires that `.onDisappear` even though the flow never actually closed.
     Fix: moved the discard call out of `.onDisappear` into a new
     `closeFlow()` helper, wired only to the real close points (top "Kapat",
     both "Vazgeç" buttons, dismissing the project-choice sheet).

2. **Streak card border** (`Flapse/Features/Projects/ProjectListView.swift`,
   `FireStreakBorder`): richer red-orange-to-gold gradient, faster rotation
   (7s → 4s period), added a soft blurred duplicate stroke underneath for a
   warm glow. Kept within tasteskill because it's a literal fire/streak
   motif, not decorative neon.

3. **Project import/export** — brand-new feature
   (`Flapse/Features/DataTransfer/`):
   - `ProjectArchive.swift` — no zip library. Format is a **package
     directory** with extension `.flapseproject` (`manifest.json` +
     `photos/` + `videos/`). `Flapse/Info.plist` gained a
     `UTExportedTypeDeclarations` entry (`rozcan.flapse.projectarchive`)
     conforming to `com.apple.package`, so Files treats the folder as one
     opaque item instead of something to browse into.
   - `ProjectArchiveDocument.swift` — `FileDocument` wrapper around a
     `FileWrapper` for `.fileExporter`.
   - Export entry point: `ProjectDetailView.swift` share menu → "Proje
     Arşivi (Fotoğraflar + Videolar)".
   - Import entry point: `SettingsView.swift` → Uygulama section → "Proje
     Arşivi İçe Aktar" (`.fileImporter`). Always creates a NEW project; never
     overwrites existing data.
   - **Deliberately out of scope**: rendered timelapse videos
     (`SavedTimelapse`) are NOT included in the archive. That model has no
     foreign key back to the originating `Project` (only a free-text title
     copied at render time), so matching by title would risk silently
     bundling the wrong video. Photos and video clips (the actual
     irreplaceable data) are transferred losslessly instead.

4. **Real bug fix from the pasted device log** — the log showed
   `error fetching item for URL... .flapseproject/`, `error fetching file
   provider domain`, `IIOImageSource ... fileExists == false`. Root cause:
   `UIActivityViewController` (the plain share sheet, `ActivityView` in this
   codebase) cannot share a directory — it needs a registered file-provider
   domain that a temp folder doesn't have. My first cut of the export flow
   routed through `ActivityView`, which is why the share sheet opened
   empty/broken. **Fix**: switched export to `.fileExporter` + `FileWrapper`
   (see item 3) — this is the correct, Apple-blessed path for handing a
   folder to "Save to Files", and it also matches the user's literal request
   ("let me choose where in storage it goes") better than a generic share
   sheet. All other lines in that pasted log (`BackgroundSystemTasks
   updateTaskRequest`, `ManagedConfiguration` faults, `Fig err=-12710`,
   `LaunchServices -54`, haptics `-4805`) are simulator/system noise
   unrelated to app code — do not chase them.

5. **Dead-code sweep** — checked all 228 top-level types in the app for
   real dead code (method below). Found and removed exactly one:
   **`Flapse/Features/CaptureTogether/CloudSharingView.swift`** (an old
   `UICloudSharingController` wrapper, superseded by the plain
   `ActivityView` + `CKShare` URL flow already in `ProjectDetailView.swift`
   `.cloudShare` case). Everything else that looked "unused" was a false
   positive — a `private` helper view used only within its own file. See
   "How the dead-code scan was done" below before repeating this — the
   naive heuristic (grep excluding the declaring file) is wrong.

## Where we are stuck / unverified right now

- **Unit tests did not finish this session.** Two separate `xcodebuild test`
  invocations were running in the background (one left over from an earlier
  turn, one started fresh at the end of this session); both appeared to run
  for a very long time without finishing and were killed (SIGTERM, not -9)
  when writing this handoff. **No test result exists for this session's
  changes.** Run the suite fresh, alone, with nothing else touching the
  simulator (see pitfalls).
- **Project import/export has never been exercised on a real device.**
  Nothing beyond `xcodebuild build` succeeding has verified this. Specifically
  unverified:
  - The actual export → Files save → import round trip (photo/video count
    and order should match exactly).
  - Whether `UTExportedTypeDeclarations` really makes Files show the package
    as a single tappable item instead of a browsable folder.
  - Behavior over AirDrop / Mail attachment of the `.fileExporter` output.
- **New review screen's video aspect-ratio sizing** was reviewed in code and
  compiles, but never visually confirmed on a real capture.

## Next plan, in priority order

1. Get a fresh on-device build running and ask for either a screen recording
   or specific repro steps for:
   a. Record a video in the new review screen, enter/exit AVKit fullscreen,
      confirm the video keeps playing and the title stays "Video".
   b. Export a project (Proje Detay → paylaş menü → "Proje Arşivi"), save to
      Files, then re-import it from Ayarlar → "Proje Arşivi İçe Aktar" —
      confirm every photo/video comes back, in the same order, playable.
2. Run the unit test suite exactly once, with no other `xcodebuild test`
   process alive (see pitfalls) — a stale/duplicate run is the most likely
   reason previous attempts never finished.
3. If the user confirms it's needed: deploy the CloudKit `Feedback` schema
   from Development to Production in CloudKit Dashboard before release —
   without this the in-app "Bildir" feature silently fails in production.
4. Still not done: directional (left/right by tab position) tab-switch
   animation. Attempted three times across earlier sessions, reverted every
   time because SwiftUI `TabView` + `.id()`/`.transition()` rebuilds the
   destination pane and adds measurable latency (device logs showed per-tab
   cost rising from ~10-50ms to 45-178ms). The next attempt should be a
   `UIPageViewController` wrapper, not another `TabView` trick.
5. Debug instrumentation (`LAUNCHTRACE`, `PERFTRACE`, `MODESWITCH`,
   `MICPREARM`, `FLASH`, `ASPECT` — all via `os.Logger`/`OSSignposter`) is
   intentionally still in the codebase. The user explicitly said to leave it
   until the current body of work is done ("İşimiz bittiğinde daha sonra
   kaldıracağız") — do not proactively remove it.
6. Not started, mentioned once, no plan yet: video clips and rendered
   timelapses are not covered by CloudKit sync (only entries/projects are,
   when Pro + iCloud backup is on) — this is a known data-loss-on-device-loss
   risk the user has been told about but not asked to fix yet.

## Pitfalls encountered this session — do not repeat

- **Do not attach cleanup/state-reset logic to a blanket `.onDisappear`.**
  A `UIViewControllerRepresentable`-hosted `AVPlayerViewController`'s own
  native fullscreen expand/collapse can fire the enclosing SwiftUI view's
  `.onDisappear` even though nothing actually closed. Only wire cleanup to
  an explicit function called from real close actions.
- **Do not share a folder via `UIActivityViewController`/`ActivityView`.**
  It needs a file-provider domain a temp directory doesn't have and fails
  with "error fetching item" / "fileExists == false" on device (this is
  exactly what broke on the user's phone). Use `.fileExporter` +
  `FileDocument`/`FileWrapper` for folder-shaped exports instead.
- **Do not scan for "unused" types by checking whether the name appears in
  any file other than its own.** That flags every legitimate `private`
  in-file helper view as dead. Count TOTAL occurrences across the whole
  codebase (declaration included); only `count <= 1` is real dead code.
  `@main`-attributed types are an expected, harmless exception (count = 1,
  not actually dead).
- **Do not run more than one `xcodebuild test` at a time, and never
  `pkill -9` an `xctest` process.** An earlier session traced a ~9-minute
  hang with zero CPU directly to a `pkill -9 xctest`, which corrupted the
  simulator's test daemon; the fix was restarting the simulator. This
  session again found two overlapping `xcodebuild test` runs stuck for over
  an hour — kill with plain `kill` (SIGTERM) if you must, and confirm no
  other test run is alive before starting a new one.
- **Do not restore the duplicate tab icon row, the 0.4s tab spring, or the
  220ms context-menu delay** in `MainTabView.swift`/`Theme.swift` — all were
  measured as directly responsible for sluggish interaction in an earlier
  phase of this project (see "Older, already-finished phases" below); this
  is still true.
- **Do not load `entry.imageData` in `body`, in sorting/filtering computed
  properties, or before the thumbnail concurrency slot** — SwiftData
  `.externalStorage` faults can synchronously pull a large compressed photo
  onto the main actor.
- **Do not load all CloudKit/shared-project images into one array/dictionary
  at once, and always deduplicate CloudKit record IDs before building a
  dictionary from them** — both caused real crashes/perf regressions in an
  earlier phase (`Fatal error: Duplicate values for key`, 86% CPU / 1.38GB
  peak memory).
- **Do not add new user-facing strings without TR+EN at minimum.** The
  catalogs also cover ar, de, es, fr, hi, ja, ko, pt, ru, zh-Hans; full
  translation of new strings from this session has not been done — Xcode's
  String Catalog will auto-populate missing keys using the source text as a
  placeholder, which is an acceptable interim state, not a finished one.
- **Do not write code comments unless the WHY is non-obvious.** No comments
  explaining what code does; the repo convention is comments only for
  hidden constraints/workarounds. This was followed throughout — keep doing
  so.

## How the dead-code scan was done (repeatable)

```bash
# 1) Collect top-level type declarations
for f in $(find Flapse Widgets -name "*.swift"); do
  grep -oE "^(public |internal |private |fileprivate )?(final )?(struct|class|enum|protocol) [A-Za-z_][A-Za-z0-9_]*" "$f" \
    | awk -v file="$f" '{print $NF, file}'
done > types.txt

# 2) For each type, count TOTAL occurrences across the whole codebase
#    (NOT "does it appear in another file" — that produces false positives
#    for private in-file helper views).
while read -r name file; do
  count=$(grep -rho "\b$name\b" Flapse Widgets --include=*.swift | wc -l)
  [ "$count" -le 1 ] && echo "$name -- $file (count=$count)"
done < types.txt
```

`@main`-attributed App/WidgetBundle types will show `count=1` and are not
actually dead (entry points aren't referenced by name elsewhere).

## Build/test commands

```sh
cd /Users/ridvanozcan/Desktop/workspace/Flapse
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

xcodebuild -scheme Flapse -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -configuration Debug build

# Confirm nothing is already running before this:
ps aux | grep "xcodebuild test" | grep -v grep

xcodebuild test -scheme Flapse \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:FlapseTests
```

Prefer simulator UUID `C85B1445-BFF2-40AC-B7FD-95A9C374AFA8` (iPhone 17 Pro,
iOS 26.5) when resolving a specific device is needed; otherwise the named
destination above is fine. SourceKit's `No such module 'UIKit'` diagnostics
outside a real `xcodebuild` invocation are noise from the editor's indexer,
not real errors — only trust `xcodebuild build` output.

## App Store publishing status (unchanged this session)

Technical signing/export path was previously verified end-to-end (archive,
provisioning, entitlements, `.ipa` export). GitHub Pages privacy/support
pages are live. Remaining work is primarily App Store Connect setup by the
owner (Paid Applications agreement/banking/tax, app record + IAPs, metadata
from `docs/AppStoreListing.md`, screenshots, **promote CloudKit schema to
Production** — see "Next plan" item 3 above for the specific schema still
pending). Product IDs intentionally keep the old domain, do not rename:

- `com.ridvan.timelapse.pro.monthly`
- `com.ridvan.timelapse.pro.yearly`
- `com.ridvan.timelapse.pro.lifetime`

See `YAYINLAMA_REHBERI.md` before changing publishing configuration.

## Key file map

- `Flapse/Features/AutoSort/AutoCaptureFlow.swift` — camera auto-sort +
  post-capture review flow (rewritten this session).
- `Flapse/Features/Export/TimelapseExportSheet.swift` — timelapse export
  sheet; `ExportedVideoPlayer` inside it is now shared with the review flow.
- `Flapse/Features/DataTransfer/` — new project import/export feature
  (`ProjectArchive.swift`, `ProjectArchiveDocument.swift`).
- `Flapse/Features/ProjectDetail/ProjectDetailView.swift` — project detail,
  share menu (archive export lives here), timeline.
- `Flapse/Features/Settings/SettingsView.swift` — settings; archive import
  lives here.
- `Flapse/Features/Projects/ProjectListView.swift` — project list,
  `FireStreakBorder`.
- `Flapse/Features/Camera/` — `CameraService.swift` (AVFoundation session),
  `CameraCaptureViewModel.swift`, `CameraCaptureView.swift`,
  `CameraPreviewHost.swift` (singleton preview layer, biggest perf win from
  an earlier phase), `CameraLaunchTrace.swift`/`PerfTrace.swift`
  (instrumentation, keep until told to remove).
- `Flapse/MainTabView.swift` — tab shell, capture entry points, Liquid Glass
  bar.
- `Flapse/Theme.swift` — palettes and shared Liquid Glass modifiers.
- `Flapse/ImageDownsampler.swift` — bounded image loading/decoding, thumbnail
  cache, `opaqueJPEGData` helper.
- `Flapse/Models/CoreModels.swift` — `Project`, `Entry`, `ProjectCategory`
  (includes `.video`), `CaptureCadence` (includes `.monthly`).
- `Flapse/Models/SavedTimelapse.swift` — rendered-timelapse library entries;
  **no foreign key to `Project`**, only a copied title string (relevant if
  you ever revisit bundling timelapses into the export archive).
- `Widgets/FlapseWidgets.swift` — Home/Lock Screen widgets.
- `docs/AppStoreListing.md`, `YAYINLAMA_REHBERI.md`, `RELEASE_CHECKLIST.md`,
  `ExportOptions.plist`, `Products.storekit` — publishing material.

## Working-tree notes

`.agents/` and `.codex/` are untracked, unrelated tool config directories —
leave them untracked, do not add them to any commit.

## Older, already-finished phases (for history only, do not redo)

A tab-performance and Liquid Glass restoration pass finished 2026-07-21,
commits `7d164f6`, `bff6d8d`, `3af4684`, `55a8382` on `origin/main`. Its
pitfalls (duplicate tab icon row, slow tab spring, 220ms menu delay, eager
`imageData` loads, un-deduplicated CloudKit dictionaries, unstable SwiftUI
`ForEach` IDs) are folded into the pitfall list above where still relevant —
they are still true constraints, just not this session's active work.

## Final note for the next session

Start with `git log -3` and `git status`. This session committed everything
in the working tree (see the commit this file was added in) — if `git
status` shows anything dirty when you start, it is new, not leftover from
this handoff. Do not redo the camera-review-screen redesign, the streak
border, or the import/export feature; verify them on-device instead (see
"Next plan" above).
