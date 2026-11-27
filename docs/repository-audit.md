# Luma repository audit

## Baseline and evidence

The audit started from commit `c7108e7` on `main`. The worktree was clean and `main` was even with the local `origin/main` reference. The configured fetch and push remote is `https://github.com/fathirbrb/Luma.git`. Remote freshness was outside the local Git check. There were no local release tags, CI workflows, or tracked build scripts.

The host reported macOS 12.7.6 (21H1320), x86_64, Apple Swift 5.7.2, Command Line Tools selected at `/Library/Developer/CommandLineTools`, and macOS SDK 13.1. The committed `build/Luma` is an unsigned x86_64 Mach-O executable with a minimum system version of macOS 12.0. `Package.swift` also declares macOS 12 and a Swift tools version of 5.7. SDK 13.1 can expose APIs unavailable on Monterey, so direct builds must continue to set the deployment target explicitly.

`swiftc -target x86_64-apple-macosx12.0 -module-cache-path <temporary-cache> Sources/Luma/*.swift -o <temporary-output>` successfully built the current sources. `file` and `otool -l` confirmed x86_64 and macOS 12.0. The temporary build preserves the tracked binary.

`swift package dump-package` reproduced `no such module 'PackageDescription'` with a temporary SwiftPM module cache. The first sandboxed run also reported cache access problems and a Swift 5.7.1 SDK interface versus Swift 5.7.2 compiler diagnostic. Those observations do not establish the cause of the missing manifest module. Keep `swiftc` as the supported build path and investigate SwiftPM separately.

The local scripting dictionary belongs to Music 1.2.5 at `/System/Applications/Music.app/Contents/Resources/com.apple.Music.sdef`. Using the installed application's explicit path, `osacompile` compiled a read-only probe for player state, track name, and artist. It also compiled the existing Previous, Play/Pause, Next, and metadata command syntax in a separate probe. Neither compiled probe was executed. Bundle-ID lookup returned `-1728` in the audit shell, while the explicit-path running check reported Music closed. Code inspection verifies the presence and wiring of playback controls and manual refresh. The native window, playback mutations, Automation prompts, notifications, and streamed metadata still need an interactive session with Music and Luma. The audit left playback and library data untouched.

| Path | Role and finding |
| --- | --- |
| [`Sources/Luma/LumaApp.swift`](../Sources/Luma/LumaApp.swift#L3) | SwiftUI `@main` entry point. `WindowGroup` hosts `ContentView`. |
| [`Sources/Luma/ContentView.swift`](../Sources/Luma/ContentView.swift#L3) | Renders a music-note placeholder, title, artist, Previous, Play/Pause, Next, and Refresh. Stores two independent view-local `@State` values. Each playback button runs a command and invokes `refresh()`. |
| [`Sources/Luma/MusicService.swift`](../Sources/Luma/MusicService.swift#L5) | Builds a `tell application "Music"` script per operation, executes synchronously with `NSAppleScript`, and extracts a string or prints the error. |
| [`Package.swift`](../Package.swift#L1) | Declares one executable product and target, with zero external dependencies. |
| [`Tests/LumaTests/LumaTests.swift`](../Tests/LumaTests/LumaTests.swift#L4) | Leftover template test refers to `Luma().text`, which has no implementation in the current app. The manifest declares no test target. |
| [`README.md`](../README.md#L1) | Contains a placeholder description. The working direct build and launch steps are currently tribal knowledge. |
| [`.gitignore`](../.gitignore#L1), `build/`, `.build/` | `.build/` is ignored. `build/Luma` is tracked with mode `100755`. Regenerating it in place can dirty the worktree and put a stale binary in a release. |

## Bugs and technical debt

| Priority | Finding | Impact |
| --- | --- | --- |
| High | Metadata refresh depends on button presses. There is no initial load, observer, or reconciliation timer. | Launching during playback shows placeholders. Changes from Music, media keys, or natural track advancement remain stale until a click. |
| High | `refresh()` reads the title and artist in separate scripts. | A track change between calls can pair a title with the wrong artist. A read immediately after Next or Previous can also capture the previous track while Music transitions. The second case needs runtime reproduction. |
| High | SwiftUI actions execute synchronously. Each transport click constructs and executes three scripts. | A delayed Music reply or Automation interaction can stall the window. Running scripts synchronously and compiling per call are potential bottlenecks. CPU, memory, and latency have yet to be measured. |
| High | `playPause()` sends a toggle and ignores its outcome. The view displays a fixed icon and has no playback state. | The user cannot distinguish playing, paused, stopped, and an unsuccessful command. |
| High | Script errors collapse into `Unavailable` or an empty string, and command results are discarded. | Missing metadata, no current track, permission denial, timeout, and target failure lack clear UI or recovery paths. Full error dictionaries go to stdout. |
| Medium | The view owns its service and state. `WindowGroup` can instantiate more than one view. | Adding observers or polling per view would multiply reads and let windows disagree. |
| Medium | The tracked output has no checked-in bundle metadata or build recipe. | Reproducibility and Automation identity need verification. There is no committed usage-description resource for a future app bundle. |
| Medium | The test scaffold is stale and the README is a placeholder. | The project has no runnable regression suite or documented release checks. |

## AppleScript and alternative APIs

- The local dictionary documents command and property access. It exposes no supported now-playing subscription. Evaluate `com.apple.Music.playerInfo` as an undocumented hint during the Monterey spike. Ignore its payload and fetch an authoritative snapshot. Distributed notifications may arrive late, be suspended when inactive, or be dropped. [Distributed notifications](https://developer.apple.com/documentation/foundation/distributednotificationcenter?language=objc) · [Suspension behavior](https://developer.apple.com/documentation/foundation/distributednotificationcenter/suspended?language=objc)
- One AppleScript invocation can package title, artist, and player state together, but Music may process several underlying Apple events. Verify track transitions and track identity on the reference system before claiming snapshot consistency. Short AppleScript timeouts bound individual event waits. A timeout can leave an already-sent playback command running, so automatic retries must stay read-only. Apple permits secondary-thread `NSAppleScript` execution when work is serialized. [AppleScript timeout semantics](https://developer.apple.com/library/archive/documentation/AppleScript/Conceptual/AppleScriptLangGuide/reference/ASLR_control_statements.html) · [Apple DTS threading guidance](https://developer.apple.com/forums/thread/759287)
- The installed macOS SDK 13.1 Swift interface marks MusicKit `SystemMusicPlayer`, `ApplicationMusicPlayer`, and `MusicLibraryRequest` unavailable on macOS. `MusicCatalogSearchRequest` is available starting on macOS 12 in that SDK, but catalog search cannot provide the current Music playback session or substitute for library search. Keep Music as the playback authority. [MusicKit catalog search](https://developer.apple.com/documentation/musickit/musiccatalogsearchrequest) · [MusicKit system player](https://developer.apple.com/documentation/musickit/systemmusicplayer)
- The public iTunesLibrary framework is a candidate for read-only library metadata if AppleScript listing proves too slow. Coverage of cloud and subscription items and identity mapping to a Music track need a local spike. Library reads, playback commands, and artwork reads each require their own behavior checks. [iTunesLibrary framework](https://developer.apple.com/documentation/ituneslibrary)

## Feature feasibility on Monterey

| Feature | Implementation candidate | Boundary to verify |
| --- | --- | --- |
| Automatic now playing | Serialized snapshot, lifecycle events, and low-frequency reconciliation. Optional `playerInfo` hint. | Record which events arrive in foreground and background for local, cloud, streamed, and naturally advancing playback. |
| Album artwork | `artworks` and `raw data` on Music items. Decode and downsample off the UI thread, cache bounded thumbnails by track identity, and show a placeholder on missing art. | Some content may yield no artwork or fail. Verify representative formats, sizes, and streaming coverage. |
| Dynamic controls | `player state`, `playpause`, `previous track`, and `next track`. | `player state` includes playing, paused, stopped, fast forwarding, and rewinding. Capability to skip at either queue edge is unverified. |
| Progress and seeking | Read track `duration` and `player position`, interpolate with a monotonic clock during playback, and set position when the user seeks. | Verify source-specific seek support and rejected or unavailable seeks for radio and streams. Avoid per-frame Apple events. |
| Volume | Read and set Music `sound volume` in the documented `0...100` range. | Treat it as Music volume. Check AirPlay behavior and debounce writes during slider drags. |
| Library and playlist browsing | `library playlist`, `user playlist`, and track collections. Fetch bounded results and only needed fields. | Check large libraries, smart playlists, folders, shared and cloud items, and whether collection slicing works efficiently. |
| Individual track selection | Resolve the chosen track reference in its library or playlist context and send `play` to Music. | Verify persistence and availability of IDs, duplicate tracks, queue behavior, and Music's own subscription enforcement. |
| Library search | Music's playlist-scoped `search` or a bounded in-memory index of metadata retrieved through public APIs. | Check search fields, partial matching, empty results, large libraries, and query latency. |
| Native interface | SwiftUI views and AppKit where needed, semantic colors, accessible labels, and adaptive layout. | Verify light and dark appearance, resizing, keyboard focus, and VoiceOver. |
| MiniPlayer | A second Luma window or AppKit `NSPanel` backed by the shared playback model. | Verify focus, resizing, and visibility. Luma can own its MiniPlayer window. |
| Menu bar | AppKit `NSStatusItem` hosting an `NSMenu` or popover. | SwiftUI `MenuBarExtra` requires macOS 13. Test tracking and cleanup when all windows are closed. |
| Keyboard shortcuts | SwiftUI commands for app shortcuts. Evaluate a public system-wide hotkey API separately. | Check focus, collisions, and permission needs. Existing media keys can be tested as external changes without intercepting them. |
| Native packaging | Use CLT to build a `.app` with a stable bundle ID, `Info.plist`, and `NSAppleEventsUsageDescription`. Verify Automation from the packaged entry point. | Local builds can stay free. Developer ID signing and standard notarized distribution require a program membership. If Hardened Runtime is used, set the Apple Events entitlement and verify user consent. [Usage description](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription) · [Developer ID requirements](https://developer.apple.com/help/glossary/) · [Apple DTS on Automation](https://developer.apple.com/forums/thread/759287) |

## Recommended architecture and roadmap

Keep the existing SwiftUI entry point. Let `LumaApp` own one `@StateObject` playback model shared by views. A `@MainActor` model holds the last `PlaybackSnapshot`, connection status, and command progress. `MusicService` owns its serial script execution context and returns typed values. `ContentView` renders the model and forwards user actions. Put observer, refresh, and command coordination in the model initially. The [v0.0.2 plan](v0.0.2-plan.md) defines the ordering and lifecycle rules.

| Phase | Work | Exit check |
| --- | --- | --- |
| v0.0.2 | Automatic title and artist updates, playback state, responsive commands, permission handling, and repeatable CLT development launch. | Pass the Monterey regression and latency checks in the milestone plan. |
| v0.0.3 | Add artwork, playback progress and seeking, and Music volume. | Verify on supported source types and measure thumbnail memory and animation costs. |
| v0.0.4 | Add read-only library and playlist browsing, individual song playback, and library search. | Verify local, cloud, unavailable items, and large-library behavior while preserving library contents. |
| v0.0.5 | Refine the native interface and add a MiniPlayer, menu bar controls, and app shortcuts. | Confirm shared state, keyboard and accessibility behavior, and background lifecycle. |
| Release preparation | Build a versioned Finder-launchable `.app` using CLT, then verify the local installation path and document distribution limits. | Validate build reproducibility, permission behavior on a fresh session, and release instructions under the free-toolchain constraint. |
