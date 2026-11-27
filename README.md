# Luma

**Music without the weight.** Luma is a native Apple Music companion for older Intel Macs. Its desktop window shows Now Playing, artwork, Songs, playlists, and transport, progress, volume, shuffle, and repeat controls.

## Build and install

Use macOS Monterey 12 on Intel with Apple Command Line Tools and Swift 5.7.2. Run these commands from the repository.

```sh
./build.sh
./install.sh
```

The build produces `.build/luma-dev/Luma.app`. The installer copies the verified bundle to `~/Applications/Luma.app` and replaces an earlier Luma bundle at that path. Quit and reopen Luma after an update. The bundle identifier stays `com.fathirbrb.luma`, so preferences remain in the usual macOS location. An ad-hoc-signed update can require Automation consent again.

Open `~/Applications` in Finder and double-click **Luma**. After opening it, choose **Options → Keep in Dock** from its Dock icon if desired. You can also search for Luma in Spotlight or Launchpad once macOS lists the installed bundle. The installed app launches without a terminal or IDE.

## Music and permissions

Luma checks for Music when its first window opens. If needed, it starts Music in the background once per Luma session and waits for readiness. If you quit Music, **Reconnect to Music** restores the connection. Closing a Luma window or quitting Luma leaves Music running. Browsing and tracking controls depend on the data and operations exposed by Music for the current library, track, or stream.

Use **Play** in Now Playing or the playback bar to resume Music. To start a specific song, use **Play** next to its row in Songs or a playlist. A row can be played when Music supplies an item ID for it.

Allow Music Automation when macOS prompts. If access was denied, enable Luma in **System Preferences → Security & Privacy → Privacy → Automation** and select **Refresh** in Luma. A local build uses ad-hoc signing and standard Automation consent.

The app uses Music's AppleScript dictionary through public, process-addressed Apple Events. `MusicLifecycle` handles discovery and launch, `MusicService` serializes automation off the UI thread, and `PlaybackModel` drives the shared SwiftUI state and caches recent artwork. `scripts/AppIcon.swift` generates the icon using Core Graphics and Image I/O. [Apple's native ICNS packaging method](https://developer.apple.com/library/archive/documentation/GraphicsAnimation/Conceptual/HighResolutionOSX/CapturingScreenContents/CapturingScreenContents.html)

## Run the regression checks

After building the app, use the same compiler and module cache for the standalone checks.

```sh
swiftc -target x86_64-apple-macosx12.0 \
  -module-cache-path "$PWD/.build/luma-dev/cache" \
  Sources/Luma/MusicService.swift Sources/Luma/MusicLifecycle.swift \
  Sources/Luma/PlaybackModel.swift Tests/PlaybackChecks/PlaybackChecks.swift \
  -o .build/luma-dev/PlaybackChecks
.build/luma-dev/PlaybackChecks
```

To test missed notifications, quit Luma and launch it with `open "$HOME/Applications/Luma.app" --args --no-music-notifications`. A responsive Music instance should reconcile on the fallback timer, normally about every 15 seconds.

## Manual release checks and performance

1. Quit Luma and Music normally, then open the installed Luma from Finder. Check that Music starts in the background and the Luma window keeps focus. Repeat from Spotlight and the Dock after they list Luma.
2. Play a song. Test Previous, Play/Pause, Next, seek, Music volume, shuffle, and each repeat mode. Change tracks from Music or the media keys and check metadata and artwork in Luma. Try a saved song and an Apple Music stream. Note which controls and metadata the source exposes.
3. While audio is playing, close the last Luma window and then quit Luma. Check that Music continues. Reopen Luma, quit Music, wait 20 seconds, and verify Luma stays disconnected until **Reconnect to Music** is selected. For the denial path, turn off Luma's Automation access, select Refresh, and restore access after checking the message and recovery.
4. For CPU and memory, keep one instance of each app open and sample once with playback paused and again while a song is playing. Run the following command from a separate terminal. Discard the first CPU sample, average the remaining samples per process, and add their memory readings for the combined footprint. Record the macOS version, playback source, sample window, and whether Luma's window was visible.

   ```sh
   top -l 31 -s 1 -pid "$(pgrep -xn Luma)" -pid "$(pgrep -xn Music)" -stats pid,command,cpu,mem
   ```

5. For timing, start the log stream before launching Luma. Record the elapsed time from open to the first successful snapshot. Exercise controls and record the playback-command duration and the following snapshot or visible state update. Repeat with cold Music, warm Music, and a stream. Log timings capture the automation calls. Compare the visible update separately for end-to-end UI latency.

   ```sh
   /usr/bin/log stream --level debug --style compact --predicate 'subsystem == "com.fathirbrb.luma"'
   ```
