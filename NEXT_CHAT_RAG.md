# Current source update — 2026-10-11

The notes below describe earlier releases. Current baseline before this update was v1.0.76, which added reported seeder sorting.

This update adds:
- Poster sizing shared by Discover and Library: exact per-row counts, or a poster-width slider.
- Quick play prefers an available HTTP(S) source entry, otherwise the highest ranked torrent. URLs are not probed in advance.
- Native piece priorities follow the VLC playback/seek position, with decoder lookbehind and head/tail metadata retained. Playback-time fractions estimate file bytes; variable bitrate media needs physical-device testing.
- Seeks wait for verified contiguous pieces around the estimated position, with cancellation and timeout handling.
- Metadata timeout/reannounce uses elapsed time. Native progress snapshots are throttled to reduce UI work.
- Player skip/speed controls, explicit buffering/errors/retry, and playback timing/rebuffer diagnostics.

Unsigned physical-iPhone Release validation passed: https://github.com/aminoulogie/playbox/actions/runs/38178772947 (native compilation, exported playback command, Swift app build, embedded frameworks, and IPA packaging). This is a build check; on-device playback timing/seek checks still need to be performed.

The 1 MiB startup threshold is retained pending actual iPhone timing and stall data. “Playback began” uses the first advancing player clock, not a direct rendered-frame callback.

Required device checks for future sessions: test MP4/MKV startup, resume, forward/backward seeks, repeated seeks, replay after end, source errors, and closing/reopening; record playback details on the iPhone before tuning buffers.

---

# Playbox — Next Chat RAG / Handoff

# START HERE — REQUIRED FOR THE NEXT AI CHAT

Before changing any code:

1. Read this entire file.
2. Fetch the current `main` branch and latest release/build state.
3. Do **not** redo the old SwiftTorrent investigation.
4. Do **not** assume Torrentio is installed; verify addon state when a title shows no torrent sources.
5. Treat the current app-code baseline as the libtorrent + VLC streaming implementation, not the earlier full-download implementation.
6. The user's immediate priority is **torrent Play behavior**, not more tracker experiments.
7. After Play behavior is validated/fixed, implement source sorting/filtering with **seeders high → low** as the default.

Latest user-confirmed runtime state:

- Torrentio was reinstalled/configured and torrent sources returned.
- libtorrent peer discovery is working on-device.
- A real test showed approximately:
  - Connected: 8
  - Known: 214
  - Candidates: 71
  - DHT: 111 nodes / 100 peers
  - active transfer speed visible
- Therefore, **do not treat peer discovery as the current blocker**.
- The earlier “Buy / Unsupported stream URL” screen was caused by Torrentio not being installed at that moment, not by a libtorrent regression.

Immediate next engineering task:

> Make sure tapping the torrent **Play** button opens the player immediately and uses the existing libtorrent + VLC growing-file/streaming path. Reuse the already integrated open-source libtorrent/VLCKit method; do not invent another torrent engine. If current v1.0.71 behavior still fails on-device, debug the existing `streamReady` → VLC handoff, buffering, file growth, piece priority/deadlines, and player lifecycle.

Do not merge backend changes until a physical-iPhone Release build passes.

---

> Purpose: give a new ChatGPT/Codex session enough context to continue work on this repository without re-discovering the architecture, repeating old torrent fixes, or reverting successful work.
>
> Repository: `aminoulogie/playbox`
>
> Default branch: `main`
>
> Current application-code baseline referenced by this handoff: `21195efe37d8c7e73ded3bc1281acdb1f24781b5` (the handoff file itself was committed immediately afterward on `main`).
>
> Latest published IPA when this file was created: **v1.0.71**
>
> Current torrent backend: **libtorrent 2.0.13**, not SwiftTorrent.

---

## 1. Product summary

Playbox is an iOS 17+ SwiftUI media app with:

- Stremio-style add-ons
- catalog/discovery UI
- movie / series detail pages
- subtitle selection
- direct HTTP(S) playback
- torrent playback/download
- library/bookmarks
- GitHub Actions unsigned IPA builds/releases

The app is built with XcodeGen using `project.yml`.

---

## 2. Important current architecture

### Torrent stack

**Do not revert this to SwiftTorrent.**

The app previously used `warppipe/swift-torrent`, but that path caused repeated peer discovery / tracker / DHT / metadata problems.

The project was migrated to:

```text
Playbox SwiftUI
    ↓
TorrentEngine.swift
    ↓
local Swift wrapper
    ↓
LibtorrentNative.framework
    ↓
libtorrent 2.0.13
    ↓
OpenSSL
```

Relevant files:

- `Playbox/Torrent/TorrentEngine.swift`
- `Playbox/Libtorrent/LibtorrentSDK.swift`
- `Playbox/Libtorrent/NativeLibtorrentSession.swift`
- `native/LibtorrentNative/CMakeLists.txt`
- `native/LibtorrentNative/include/LibtorrentNative.h`
- `native/LibtorrentNative/src/LibtorrentNative.cpp`
- `scripts/build_libtorrent_ios.sh`
- `project.yml`
- `.github/workflows/build-ipa.yml`

Third-party wrapper provenance / licensing is documented under:

- `ThirdParty/LibtorrentSDK-LICENSE.txt`
- `ThirdParty/LibtorrentSDK-THIRD-PARTY-NOTICES.md`

The Swift wrapper / native bridge was adapted from the MIT-licensed `tryAGI/LibtorrentSDK` project, while libtorrent itself is built from source in CI.

### iOS support

- minimum deployment target: **iOS 17.0**
- libtorrent 2.0.13 is compiled for **arm64 iOS 17**
- OpenSSL is bundled for HTTPS tracker support
- `LibtorrentNative.framework` and `openssl.framework` are embedded in the app

Do not raise the app minimum OS just to consume a prebuilt wrapper binary.

---

## 3. Torrent history and what was fixed

Earlier versions repeatedly showed:

```text
Finding torrent metadata… 0 peers
```

The old SwiftTorrent path was investigated extensively. Fixes attempted included:

- merging Stremio tracker sources into raw magnet links
- HTTP tracker `info_hash` encoding fixes
- trying additional trackers
- DHT fallback
- DHT response race fixes
- magnet announce `left=0` correction
- HTTPS-first fallback trackers
- tracker / DHT / connection diagnostics
- aggregating peers from all trackers instead of stopping at first non-empty tracker

Those patches helped diagnose the problem but should be considered **legacy work**.

The decisive change was replacing SwiftTorrent with **libtorrent 2.0.13**.

Do not spend a new chat re-debugging the old SwiftTorrent code unless specifically asked to study history.

---

## 4. Current torrent behavior

Current libtorrent backend supports:

- magnet URLs
- trackers
- DHT
- peer discovery
- PEX through libtorrent
- Stremio `fileIdx`
- selected-file priority
- fallback to largest supported video file if `fileIdx` is missing/invalid
- download progress
- swarm diagnostics
- reannounce / peer refresh while metadata is unresolved
- cancellation
- separate Play and Download UI semantics

Supported video extensions in the current engine include:

- mp4
- m4v
- mov
- mkv

### Current player behavior as of main commit 21195efe

The latest main commit is:

> **Open torrent player immediately and buffer with VLC**

The current intended behavior is:

1. User taps Play.
2. The player UI opens immediately.
3. libtorrent prepares / downloads the selected torrent file.
4. The player shows buffering while data is not yet ready.
5. When the torrent backend emits `streamReady`, Playbox hands the growing local file to VLC.
6. Playback should begin from the growing file instead of waiting for the entire torrent to complete.

This behavior was added after the initial libtorrent migration.

Latest release containing this work:

- **v1.0.71**
- release tag: `v1.0.71`
- stable tag: `v1.0.71-latest`

---

## 5. Current source / addon behavior

Torrentio must actually be installed/configured in Playbox for torrent sources to appear.

A previous screenshot showed only:

```text
Buy
Unsupported stream URL
```

That was not a torrent-engine regression. Torrentio simply was not installed at that moment.

Once Torrentio was installed, torrent sources appeared and libtorrent successfully showed:

- connected peers
- known peers
- connection candidates
- DHT nodes / peers
- transfer speed

Do not mistake “no Torrentio addon installed” for a torrent backend failure.

---

## 6. Current GitHub Actions build

Main workflow:

`.github/workflows/build-ipa.yml`

It currently:

1. checks out source
2. installs XcodeGen, CMake, Boost
3. builds libtorrent 2.0.13 for iOS 17
4. builds / copies OpenSSL framework
5. generates Xcode project
6. builds unsigned physical-iPhone app
7. verifies embedded native frameworks
8. packages IPA
9. uploads workflow artifact
10. creates versioned GitHub release
11. creates / updates stable `-latest` release

The libtorrent native compile is much slower than the old SwiftTorrent build because it compiles the C++ engine from source.

### Build optimization opportunity

A future improvement is to cache the built native frameworks or publish an internal iOS 17 libtorrent artifact so each small Swift/UI change does not rebuild libtorrent from scratch.

Do not sacrifice correctness or iOS 17 compatibility just to speed this up.

---

## 7. Important current files

### App / UI

- `Playbox/Views/DetailView.swift`
- `Playbox/Models/AddonModels.swift`
- `Playbox/Services/AddonClient.swift`
- `Playbox/Stores/AddonStore.swift`

### Torrent / player

- `Playbox/Torrent/TorrentEngine.swift`
- `Playbox/Libtorrent/LibtorrentSDK.swift`
- `Playbox/Libtorrent/NativeLibtorrentSession.swift`

Search the repo for the VLC player implementation and the latest `streamReady` handling before changing playback.

### Build

- `project.yml`
- `scripts/build_libtorrent_ios.sh`
- `.github/workflows/build-ipa.yml`

---

## 8. Requested next work / backlog

The most important next work from the conversation is:

### A. Validate and improve torrent streaming playback

The current v1.0.71 behavior opens the player immediately and buffers using VLC while libtorrent prepares the growing file.

Next session should verify on a real device:

- does player open immediately after tapping Play?
- does it leave the buffering state once `streamReady` fires?
- does VLC successfully play a growing MP4/MKV file?
- does seeking work?
- what happens if the user seeks far ahead of downloaded pieces?
- does playback continue while pieces download?
- does cancelling player stop or retain the torrent job as intended?
- does switching sources cleanly cancel the old job?
- does Download still behave independently from Play?

If playback still waits too long, improve piece prioritization / deadlines in the native libtorrent bridge instead of returning to “download whole torrent then play”.

### B. Add source sorting/filtering

The user explicitly requested source filtering/sorting.

Desired default:

- **sort torrents by seeders high → low**

Useful controls:

- Seeders high → low
- Date added / recency if source metadata supports it
- Quality: 4K / 1080p / 720p
- Codec: HEVC / H.264 / AV1
- HDR / Dolby Vision
- Size
- Source/addon

Do not fabricate seed counts. Parse them from available source text / metadata.

The source list should remain responsive and preserve Play/Download controls.

### C. Clean torrent diagnostics UI after stability

The detailed diagnostic line was useful during debugging, but once playback is reliable it may be too noisy.

Consider:

- concise normal status by default
- expandable “Torrent details” diagnostics
- show peers / speed / DHT only when needed
- keep enough diagnostics to debug future reports

### D. Build-speed optimization

Consider caching or publishing the iOS 17 native libtorrent/OpenSSL frameworks so ordinary UI changes do not spend minutes rebuilding C++ dependencies.

---

## 9. Things NOT to do

- Do **not** restore `warppipe/swift-torrent`.
- Do **not** re-add `scripts/patch_swifttorrent.py`.
- Do **not** raise deployment target above iOS 17 unless explicitly requested.
- Do **not** remove Torrentio/addon support.
- Do **not** treat Torrentio seed counts as active connected peers.
- Do **not** merge unvalidated native/backend changes directly to main.
- Do **not** claim playback is fixed until an IPA is built and tested.
- Do **not** rewrite the whole SwiftUI UI just to change torrent internals.
- Keep Play and Download as separate actions.

---

## 10. Preferred development workflow

For significant backend changes:

1. create a branch from current `main`
2. inspect current code before editing
3. make the smallest coherent change
4. add a temporary branch-only validation workflow if native compilation must be tested
5. build for physical iPhone unsigned
6. remove the temporary validation workflow
7. open PR
8. check mergeability
9. merge to main
10. wait for normal IPA workflow
11. verify release asset exists
12. give user the actual IPA release link

For UI-only changes, avoid rebuilding native dependencies unnecessarily if the CI can be optimized first.

---

## 11. Ready-to-paste prompt for a new chat

Use this prompt in a fresh chat:

```text
Work on my GitHub repo aminoulogie/playbox.

First read NEXT_CHAT_RAG.md at the repo root and inspect the current main branch before making changes.

Important:
- Playbox is iOS 17+ SwiftUI.
- Torrent backend is libtorrent 2.0.13, not SwiftTorrent.
- Do not revert to SwiftTorrent or reintroduce old SwiftTorrent patches.
- Latest known release in the handoff is v1.0.71, but verify current main/release state first.
- Current torrent Play behavior should open the player immediately, buffer, then hand the growing selected file to VLC when streamReady fires.
- Torrentio must be installed/configured for torrent sources.

Start with these priorities:
1. verify/improve real torrent streaming playback in the current libtorrent + VLC implementation, especially streamReady, growing-file playback, seeking, buffering, cancellation, and source switching;
2. then add source sorting/filtering, defaulting torrents to seeders high-to-low;
3. preserve separate Play and Download actions;
4. keep iOS 17 compatibility;
5. validate significant backend changes with a physical-iPhone Release build before merging;
6. once merged, run/wait for the normal IPA workflow and give me the actual new release link.

Do not just describe changes. Inspect the repo, implement them, validate them, merge when safe, and report exact results.
```

---

## 12. Fast context summary for retrieval systems

Keywords:

```text
Playbox
aminoulogie/playbox
iOS 17
SwiftUI
Stremio
Torrentio
libtorrent 2.0.13
OpenSSL
LibtorrentNative.framework
VLC
streamReady
torrent streaming
growing file
magnet
fileIdx
DHT
PEX
tracker
torrent player
source sorting
seeders
IPA
GitHub Actions
XcodeGen
```

Current direction:

> Keep libtorrent. Make torrent Play behave like actual streaming through VLC. Then add source sorting/filtering with seeders descending as the default.
