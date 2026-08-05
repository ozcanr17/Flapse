# HANDOFF — Flapse iOS App

Last updated: **2026-08-05 — App Store RC audit**.
Written for a completely new session with no prior context.

Historical sessions remain below for context. **Read "2026-08-05 App Store RC
audit" first; it supersedes older test, signing, privacy and release-state claims.**

Read this file first, then:

1. `README.md` for the feature overview.
2. `YAYINLAMA_REHBERI.md` for the Turkish App Store publishing guide and live checklist.
3. `project_handoff.md` for older architectural and repository conventions.

## 2026-08-05 App Store RC audit

The attached release brief requested an exhaustive architecture, security,
privacy, performance, accessibility, localization, build and App Review audit,
automatic fixes, verification, and an App Store readiness decision.

### Completed

- Upgraded every target to Swift 6 and enabled complete strict concurrency.
  Release treats Swift and C/ObjC warnings as errors. Release build and static
  analysis both succeed.
- Resolved all strict-concurrency findings in camera timers/session work,
  ActivityKit, AVPlayer looping, UserDefaults, image caching, UIKit association
  storage and export rendering.
- Removed the hidden developer/admin Pro entitlement path completely. Pro is
  now derived only from verified StoreKit transactions. Removed its tests,
  launch arguments, UI and compiled localization strings.
- Moved Sign in with Apple user ID, optional e-mail and name from UserDefaults
  to Keychain, with one-time legacy migration and deletion on sign-out.
- Hardened `.flapseproject` import against path traversal, symlinks, malformed
  or oversized manifests/media, unsupported versions and free-tier bypass.
  Import now saves in batches of 25 on a detached task and cleans up the new
  project/video files on failure.
- Permanent deletion of entries/projects now removes associated external video
  files after the SwiftData deletion is saved.
- Production SwiftData failure no longer terminates at launch. A blocking,
  localized support state is shown without accepting edits into an ephemeral
  store.
- Corrected feedback privacy disclosure. Developer-readable public CloudKit
  feedback contains message, optional e-mail, app/iOS version and hardware
  model. The manifest and App Store docs declare Email Address, Other User
  Content and Other Diagnostic Data as linked, not tracked, App Functionality.
  Locale is no longer collected.
- Paywall trial copy follows StoreKit intro-offer eligibility, and lifetime
  purchase copy explicitly states that there is no recurring charge.
- Corrected App Store category to Photo & Video and soundtrack count to eight.
- Added missing VoiceOver labels and made the render animation respect Reduce
  Motion. Thumbnail cache is bounded and purged on memory warning.
- Added archive security/batching tests and video-cleanup regression coverage.

### Verification on 2026-08-05

- Unit tests: **186 passed, 0 failed**, about 16 seconds.
- UI tests: full package ran 31 configurations/cases; 30 passed. The only
  failure was a stale test tap on a non-hittable project card. After correcting
  the test, that camera case passed in isolation.
- Release simulator build: succeeded with warnings-as-errors.
- Release static analyzer: succeeded.
- Signed generic-device archive: succeeded with automatic provisioning.
- App Store Connect export: succeeded; IPA is **8.8 MB**, Apple Distribution
  signature verifies, `get-task-allow = false`, `aps-environment = production`,
  CloudKit environment = Production.
- Privacy manifests and plist files lint; app and widget signatures verify.

### Remaining manual release work

- Deploy the `iCloud.rozcan.Flapse` CloudKit schema to Production, including
  project/share types and `Feedback`.
- Complete or verify agreements, tax/banking, App Store app and IAP records,
  subscription group and seven-day trial offers.
- Enter privacy nutrition labels exactly as documented, age rating, export
  compliance, category, URLs, localized metadata and screenshots.
- Validate/upload the archive, run a two-account TestFlight smoke test on real
  devices, verify purchase/restore, permissions, project sharing, background
  render, Live Activity/Dynamic Island and widgets, then submit with review notes.
- Confirm distribution rights/licenses for all eight bundled soundtracks.
- GitHub Actions CI is enabled on macOS 26 / Xcode 26.6 and runs Release build,
  static analysis and unit tests for main pushes and pull requests.

### Do not regress

- Never reintroduce a developer/account-based Pro override or compile hidden
  feature-unlock text into Release.
- Never claim “Data Not Collected”; public CloudKit feedback is developer-readable.
- Never trust archive-provided file names or materialize a large archive in one
  main-thread context.
- Never change the source `aps-environment` based only on a Development archive;
  verify the exported distribution IPA. The verified IPA already has Production.
- Do not overclaim measured FPS, memory or physical-device accessibility. Use
  Instruments and TestFlight for those final measurements.

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

## Release-prep pass (2026-08-02, second session)

The user asked to skip on-device verification for now, finish the remaining
planned items, and get the app ready to publish on the App Store.

### Done

1. **Two file leaks in the new import/export feature fixed**
   (`Flapse/Features/DataTransfer/ProjectArchive.swift`):
   - Export: `write` body moved into `writeContents(of:to:)`; `write` now wraps
     it and deletes the half-built `.flapseproject` temp directory if anything
     throws. Previously the directory leaked, because the exporter sheet never
     opened and the caller's cleanup path (`ProjectDetailView`) never ran.
   - Import: `read`'s loop is wrapped — a `videoMissing` throw on the Nth entry
     used to leave the first N-1 clips orphaned in `VideoEntryStorage`.
     `materialize` now also undoes its inserts and removes copied clips if
     `context.save()` throws. Shared helper: `discardCopiedVideos(in:)`.
     Note it deliberately does NOT call `context.rollback()` — the context is
     the app's main `@Environment(\.modelContext)` and rollback would discard
     unrelated pending changes.

2. **Localization completed.** Source language is `tr`, so any key without an
   entry for a language silently fell back to Turkish. 48 keys had no
   translations at all (import/export, location picker, custom palette, date
   editing). All 522 keys in `Localizable.xcstrings` now resolve in all 12
   languages; format-only keys (`%@`, `16:9`, `·`) are marked
   `shouldTranslate: false`. `ProjectArchive.ArchiveError.errorDescription`
   returned hardcoded Turkish and is now `String(localized:)`.

3. **Debug instrumentation gated out of Release** (HANDOFF item 5). Rather than
   deleting the call sites, the three log handles are bound to `OSLog.disabled`
   under `#if !DEBUG` — `PerfTrace.swift`, `CameraLaunchTrace.swift`,
   `CameraService.swift` (`cameraLog`). `os_log` early-outs, so interpolated
   expressions are never evaluated and nothing is emitted on a user's device.
   Call sites are untouched, so the tooling still works in Debug. If you want
   them physically removed instead, that is a separate mechanical change.

4. **Release build is warning-free — measured, not assumed.**
   `xcodebuild -configuration Release build` → `BUILD SUCCEEDED`, zero warnings.
   Two warnings were fixed to get there:
   - `ProjectArchiveDocument` stored a `FileWrapper` (not Sendable) in a
     Sendable `FileDocument`. It now stores the package URL and builds the
     wrapper inside `fileWrapper(configuration:)`. It is export-only, so
     `readableContentTypes` is `[]` and `init(configuration:)` throws.
   - `Flapse/Info.plist` declared `CFBundleDocumentTypes` for
     `.flapseproject` with `LSHandlerRank = Owner`, but nothing handled the
     open — tapping an archive in Files launched Flapse and did nothing.
     **User's decision: the declaration was removed**, not implemented.
     `UTExportedTypeDeclarations` stays, so Files still shows the package as a
     single item and Settings import still works. Cost: an AirDropped archive
     will not offer Flapse as a target. Implementing an `onOpenURL` file
     handler is a real future feature, deliberately not done here because it
     can only be verified on device.

5. **CI does not exist on GitHub at all.** Two separate problems, both of which
   the old `RELEASE_CHECKLIST.md` had ticked off as done:
   - `.github/workflows/` is in `.gitignore` (line 25). Commit `23f57c7`
     untracked it because pushing workflow files failed without the `workflow`
     token scope. So the workflow file is not in the repo and Actions has never
     run.
   - The local file still referenced scheme `Timelapse` and
     `-only-testing:TimelapseTests`; the project's schemes are `Flapse` /
     `FlapseTests`. Corrected locally, but that correction is untracked too and
     is **not** part of any commit.
   To actually get CI: grant the token `workflow` scope, drop `.gitignore:25`,
   commit the file.

6. **`RELEASE_CHECKLIST.md` rewritten** against measured reality.

7. **Archive import bypassed the paywall** (`SettingsView.swift`). "Proje Arşivi
   İçe Aktar" had no gate at all, while every other project-creating path
   (`ProjectListView.addProjectTapped` and `importTapped`) checks
   `FeatureGate.canCreateProject`. A free user could exceed
   `freeProjectLimit = 1` through the archive. Worse for the user than for
   revenue: `materialize` preserves the archive's original `createdAt`, and
   `FeatureGate.unlockedProjectID` unlocks only the *newest* project — so a
   free user importing an older project got an "İçe Aktarıldı" success message
   followed by a project that was immediately locked. Now gated via
   `importArchiveTapped()`, showing the paywall like everywhere else.
   Note: the sign-in gate (`auth.gateSkipped`) is still NOT mirrored in
   Settings — that machinery lives in `ProjectListView`. Low impact (it is a
   skippable soft gate) but it is still an inconsistency.

8. **Export menu label was misleading.** "Proje Arşivi (Fotoğraflar +
   Videolar)" reads as if rendered timelapses are included; they are not (see
   the first session's note about `SavedTimelapse` having no foreign key).
   "Videolar" actually meant video-mode capture clips. Renamed to
   **"Proje Arşivi (Tüm Kareler)"** — "kare" is the app's own word for an
   entry ("Kare çek", "%lld kare"), so it no longer implies timelapse videos.
   The old key was removed from the catalog and the new one translated.

9. **Export loaded every photo into memory at once — likely OOM on large
   projects.** `ProjectArchive.snapshot(of:)` was `@MainActor` and read
   `entry.imageData` for *every* entry into one array, and
   `exportProjectArchive()` called it synchronously before the progress
   overlay could draw. Photos are stored as full-resolution camera JPEGs
   (`CameraCaptureViewModel.swift:189`, cropped but not downsampled), roughly
   2-4 MB each, behind `@Attribute(.externalStorage)`. A 365-entry project
   meant ~1 GB pulled onto the main actor in one go — a direct violation of
   this file's own `imageData` pitfall, and it only bites projects big enough
   that the user actually wants a backup.
   **Fixed by streaming:** `ProjectSnapshot`/`EntrySnapshot` are gone.
   `write(project:)` is now `@MainActor async` and walks entries one at a time,
   handing each photo's `Data` (Sendable) to a detached task for the disk
   write, so memory is bounded to one photo and the main actor is free between
   entries. Import got the cheap half of the same fix: `read` no longer carries
   photo bytes, only `photoFileName`, and `materialize` loads each photo just
   before constructing its `Entry` — this halves import peak memory.

### Two corrections to the older text below — do not trust the old versions

- **"Data Not Collected" is WRONG.** `FeedbackService.swift:57` writes the
  "Bildir" report to the **public** CloudKit database of
  `iCloud.rozcan.Flapse`, which the developer reads in CloudKit Dashboard. The
  record carries free-text message, optional contact e-mail, app version, iOS
  version, hardware model and locale. `Flapse/PrivacyInfo.xcprivacy` correctly
  declares Email Address + Other User Content; the App Store Connect privacy
  questionnaire must match it exactly or App Review will flag the mismatch.
  The claim "no networking" in the old checklist was also wrong.
- **Promoting the CloudKit `Feedback` schema to Production is NOT release
  blocking.** The old text said "Bildir" would silently fail without it.
  `FeedbackViewModel.swift:45` catches *every* error and falls back to a
  prefilled support e-mail. Promoting the schema just spares users that path.

### Still unverified / blocked

- ~~Unit tests never complete~~ — **SOLVED, see "The test hang" below. The
  suite is green: 184 tests, 0 failures.**
- **An App Store archive cannot be produced on this Mac.** `security
  find-identity -p codesigning` shows only an *Apple Development* certificate,
  and `~/Library/MobileDevice/Provisioning Profiles/` is empty. So the
  `aps-environment` question is unresolved: the entitlements file says
  `development`, an App Store build needs `production`. After archiving, read
  the embedded value rather than guessing:
  `codesign -d --entitlements - <path>/Flapse.app`
- Everything in the first session's "Where we are stuck" list below is still
  unverified — the export → Files → import round trip in particular.

### The test hang — root cause found, tests are green

Three sessions reported `xcodebuild test` hanging "after simulator boot". **It
was never the tests or the app — it was a wedged `CoreSimulatorService` on this
Mac.** The suite is green: **184 tests, 0 failures, ~16 seconds.**

How it was isolated (repeat this if it ever comes back):

1. Split the phases. `xcodebuild build-for-testing` finished in **21 seconds** —
   so the build was never the problem, the run was.
2. `xcodebuild test-without-building` stalled immediately after printing its
   invocation banner. `ps` showed the simulator booted and `testmanagerd`
   running, but **no `xctest` process and no `Flapse` process** — the test host
   app was never launching.
3. Reproduced it outside xcodebuild entirely: `xcrun simctl install booted
   Flapse.app` hung with no output, and `xcrun simctl bootstatus <udid> -b`
   never returned even though the device reported `Booted`. That pins it on
   CoreSimulator, not on anything in this repo.

The fix:

```sh
pkill -TERM -f "xcodebuild test"          # never -9 an xctest process
xcrun simctl shutdown all
killall -9 com.apple.CoreSimulator.CoreSimulatorService   # respawns on demand
xcrun simctl boot C85B1445-BFF2-40AC-B7FD-95A9C374AFA8
```

After that, `simctl install` took 10 seconds and the full suite ran normally.

Two things worth knowing for next time:

- **`FlapseTests` is a host-app bundle** (`TEST_HOST = Flapse.app`), so every
  test run launches the whole app first. That is why a broken simulator looks
  exactly like a broken test suite — the failure is upstream of any test code.
- The disk is at **93% full (~14 GiB free)**. Not proven to be the cause, but
  CoreSimulator is known to misbehave when space runs low, and this Mac is
  close. Worth clearing DerivedData if the hang recurs.

### Known limitations left in on purpose (import/export)

Found in a user's-eye review of the feature; none is release blocking, all are
worth a follow-up:

- **Import peak memory is still ~one archive's worth of photos.** Streaming got
  it down from ~2× to ~1×, but every `Entry` holds its `imageData` in the
  context until the single `context.save()` at the end. The real fix is a
  batched save (say every 25 entries) — deliberately not done here because it
  would trade away the all-or-nothing rollback that `materialize` now has.
- **No progress indication.** Export/import show an indeterminate spinner
  ("Arşiv hazırlanıyor…"). On a several-hundred-entry project this runs long
  enough that it looks hung. Now cheap to add — `writeContents` already loops
  per entry, so a `(done, total)` callback would be a small change.
- **Importing the same archive twice silently creates a duplicate project.**
  No dedupe is possible across two exports anyway: `Manifest.ProjectPayload.id`
  is freshly generated on every export rather than carried from the project.
- **Plural grammar.** Strings like `%lld Fotoğrafın Konumu` have no plural
  variations, so English renders "Location of 1 Photos". Pre-existing pattern
  across the catalog, not specific to the new strings; fixing it means adding
  `variations`/plural rules to the affected keys.

### Deferred by the user this session

- **Directional tab transition** (old item 4) — explicitly postponed to after
  1.0 so release prep would not destabilise a shippable build. When picked up:
  use a `UIPageViewController` wrapper, not another `TabView` trick, and the
  number to beat is the current 10-50 ms per switch (the three reverted
  attempts measured 45-178 ms).
- On-device verification of the camera review screen and the import/export
  round trip (old "Next plan" item 1).

## Current task (first 2026-08-02 session)

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
3. ~~CloudKit `Feedback` schema~~ — **corrected above**: it is not release
   blocking and does not silently fail; there is a mail fallback.
4. ~~Directional tab-switch animation~~ — **deferred to post-1.0 by the user**;
   see the release-prep section above. Original notes kept for the reasoning:
   directional (left/right by tab position) tab-switch
   animation. Attempted three times across earlier sessions, reverted every
   time because SwiftUI `TabView` + `.id()`/`.transition()` rebuilds the
   destination pane and adds measurable latency (device logs showed per-tab
   cost rising from ~10-50ms to 45-178ms). The next attempt should be a
   `UIPageViewController` wrapper, not another `TabView` trick.
5. ~~Debug instrumentation still in the codebase~~ — **done in the release-prep
   pass**: the call sites remain, but in Release the log handles are bound to
   `OSLog.disabled`, so nothing is emitted on a user's device.
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
- **Do not conclude the test suite is broken when `xcodebuild test` hangs.**
  Three sessions did, and the suite was green all along — a wedged
  `CoreSimulatorService` was stopping the test host app from launching. Before
  blaming any code, split the phases (`build-for-testing` vs
  `test-without-building`) and check whether `xcrun simctl install booted` on
  its own hangs. Full procedure and fix in "The test hang" above.
- **Do not run more than one `xcodebuild test` at a time, and never
  `pkill -9` an `xctest` process.** An earlier session traced a ~9-minute
  hang with zero CPU directly to a `pkill -9 xctest`, which corrupted the
  simulator's test daemon; the fix was restarting the simulator. Kill with
  plain `kill` (SIGTERM) if you must, and confirm no other test run is alive
  before starting a new one. (Killing `CoreSimulatorService` with -9 *is*
  fine — it is a host-side daemon that respawns on demand, and that is exactly
  what unblocked the hang above.)
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
- **Do not declare an `Info.plist` capability nothing implements.** A
  `CFBundleDocumentTypes` entry with `LSHandlerRank = Owner` makes the app the
  owner of that file type; without an open handler, tapping the file launches
  the app into a dead end, and the build warns about
  `LSSupportsOpeningDocumentsInPlace`.
- **Do not store a `FileWrapper` in a `FileDocument`.** `FileDocument` must be
  Sendable and `FileWrapper` is not. Store the URL and build the wrapper inside
  `fileWrapper(configuration:)`.
- **Do not copy files into `VideoEntryStorage` before the SwiftData objects
  that reference them are saved** without a cleanup path — those files live
  outside the store, so a throw anywhere in between orphans them permanently.
- **Do not reformat `.xcstrings` with `json.dump(sort_keys=True)`.** Python's
  code-point ordering differs from Xcode's, which rewrites the whole file and
  turned a ~3k-line diff into a ~14k-line one. Preserve the loaded key order
  and use `separators=(",", " : ")` to match Xcode's style; only sort the
  per-entry `localizations` dict.
- **Do not assume a string is localized because the app has 12 catalogs.** The
  source language is `tr`, so a missing entry silently renders Turkish in every
  other language instead of failing. Check for keys with no `en` localization.
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

## App Store publishing status

**Superseded by `RELEASE_CHECKLIST.md`, which was rewritten 2026-08-02 against
measured state — use that file, not this paragraph.**

The old claim that "the technical signing/export path was verified end-to-end"
does not hold on this machine today: there is no Apple Distribution certificate
and no provisioning profiles installed, so no App Store archive can be built
here (see the release-prep section above). GitHub Pages privacy/support pages
are live — re-verified 2026-08-02, all three URLs return 200. Remaining work is
App Store Connect setup by the owner (Paid Applications agreement/banking/tax,
app record + IAPs, metadata from `docs/AppStoreListing.md`, screenshots, and the
privacy questionnaire — which must declare Email Address + Other User Content,
**not** "Data Not Collected"). Product IDs intentionally keep the old domain,
do not rename:

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

Start with `git log -3` and `git status`. Both 2026-08-02 sessions committed
everything in the working tree — if `git status` shows anything dirty when you
start, it is new, not leftover. `.agents/` and `.codex/` stay untracked.

Do not redo: the camera-review-screen redesign, the streak border, the
import/export feature, the localization pass, the instrumentation gating, or
the release-checklist rewrite.

The one thing actually worth doing next:

1. **On-device verification** of the export → Files → import round trip and the
   camera review screen (the user has deferred this twice; it needs them).

Then the owner-side App Store Connect work in `RELEASE_CHECKLIST.md` — the
privacy questionnaire and the distribution certificate are the two items
blocking a submission.
