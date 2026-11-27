# Luma project instructions

Luma is a lightweight, native Apple Music companion for older Intel Macs. Its tagline is **Music without the weight.** Apple Music owns playback, subscription access, and the user's library.

## Platform and build

- Support macOS Monterey 12, Intel x86_64, and Swift 5.7.2. Use the 2017 MacBook Air running macOS 12.7.6 as the reference device.
- Keep a direct `swiftc` build working with Apple Command Line Tools. Use `-target x86_64-apple-macosx12.0` when verifying the deployment baseline. Use ./build.sh for a signed bundle and ./install.sh for the per-user installation. Treat SwiftPM as optional until it works on the reference setup.
- Prefer native SwiftUI, AppKit, and Foundation. Keep dependencies minimal. Full Xcode, Electron, Chromium, and paid Apple Developer membership are outside the baseline.
- Keep generated binaries, app bundles, and build caches out of commits. Generate the icon from scripts/AppIcon.swift and keep the bundle ID stable. Ask before installing software, purchasing services, or performing destructive operations.

## Music integration

- Use public macOS APIs and Apple Music's exposed scripting capabilities. Preserve the user's Apple Music subscription and library. Respect DRM, authentication, and macOS Automation consent.
- Check the Music scripting dictionary on Monterey and verify behavior with representative local, cloud-library, and streaming content before making support claims.
- Keep blocking Music automation off the UI thread and serialize process-addressed Apple Events based on the Music AppleScript dictionary. Read related metadata together and publish a single coherent player snapshot on the main actor.
- Coalesce refresh triggers, bound retries, and keep fallback polling infrequent. Treat undocumented notifications as optional hints. Keep a recovery path for absent or dropped notifications.
- Distinguish permission denial, unavailable Music, absent metadata, and playback state. Prepare Music once on the first Luma window using a hidden, non-activating Workspace launch if needed. Keep passive reads launch-free. After Music quits, reconnect only on explicit user action or when the user opens Music independently. Closing or quitting Luma leaves Music running.

## Design and verification

- Build a minimal native interface that adapts to window sizes, light and dark appearance, and keyboard navigation. Use album artwork as a primary visual when it is available and keep animation restrained.
- Inspect before modifying. Work incrementally and keep the architecture proportional. Preserve existing working behavior unless the approved scope calls for a change.
- Compile after meaningful changes, check existing controls before extending them, and document important technical decisions and verification limits. Measure CPU, memory, and automation activity before claiming performance improvements.
- Explain important decisions to the user in Indonesian. Write source identifiers and technical documentation in English.
