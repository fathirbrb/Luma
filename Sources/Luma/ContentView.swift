import SwiftUI

@MainActor
struct ContentView: View {
    @ObservedObject var playback: PlaybackModel
    let music: MusicService

    @State private var selection: MusicCollection?
    @State private var playlists: [MusicPlaylist]?
    @State private var playlistsFailed = false
    @State private var page: MusicPage?
    @State private var pageFailed = false
    @State private var offset = 0
    @State private var reload = 0

    private let accent = Color.accentColor

    private struct LibraryRequest: Equatable {
        let processID: pid_t?
        let collection: MusicCollection?
        let offset: Int
        let reload: Int
    }

    private struct PlaylistRequest: Equatable {
        let processID: pid_t?
        let reload: Int
    }

    private var request: LibraryRequest {
        LibraryRequest(processID: playback.libraryProcessID, collection: selection, offset: offset, reload: reload)
    }

    private var playlistRequest: PlaylistRequest {
        PlaylistRequest(processID: playback.libraryProcessID, reload: reload)
    }

    private var heading: String {
        switch selection {
        case .none: return "Now Playing"
        case .songs: return "Songs"
        case .playlist(let playlist): return playlist.name
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 202)
                    .background(Color(nsColor: .underPageBackgroundColor))
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    header
                    Divider()
                    if selection == nil {
                        nowPlaying
                    } else {
                        libraryContent
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            PlaybackBar(playback: playback)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 820, idealWidth: 1_040, minHeight: 540, idealHeight: 675)
        .onAppear { playback.windowOpened() }
        .onDisappear { playback.windowClosed() }
        .task(id: request) { [request] in await loadPage(request) }
        .task(id: playlistRequest) { [playlistRequest] in
            await loadPlaylists(for: playlistRequest.processID)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label("Luma", systemImage: "music.note")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(accent)
                .padding(.horizontal, 12)
                .padding(.top, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    navRow("Now Playing", icon: "waveform", collection: nil)
                    sidebarHeading("Library")
                    navRow("Songs", icon: "music.note.list", collection: .songs)
                    sidebarHeading("Playlists")
                    if let playlists = playlists, !playlists.isEmpty {
                        ForEach(playlists) { playlist in
                            navRow(playlist.name, icon: "list.bullet", collection: .playlist(playlist))
                        }
                    } else {
                        Text(playlistStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var playlistStatus: String {
        if playlistsFailed { return "Playlists unavailable" }
        if playlists != nil { return "No playlists" }
        return playback.libraryProcessID == nil ? "Connect to Music to browse" : "Loading playlists…"
    }

    private func sidebarHeading(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 15)
            .padding(.bottom, 2)
    }

    private func navRow(_ title: String, icon: String, collection: MusicCollection?) -> some View {
        let selected = selection == collection
        return Button {
            guard !selected else { return }
            offset = 0
            page = nil
            pageFailed = false
            selection = collection
        } label: {
            Label {
                Text(title).lineLimit(1)
            } icon: {
                Image(systemName: icon)
                    .frame(width: 16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? accent : Color.primary)
        .background(selected ? accent.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var header: some View {
        HStack {
            Text(heading)
                .font(.system(size: 29, weight: .semibold))
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button {
                playback.refresh()
                reload += 1
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                    .frame(width: 28, height: 25)
            }
            .help("Refresh playback and library")
            .keyboardShortcut("r", modifiers: .command)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 19)
    }

    private var nowPlaying: some View {
        ScrollView {
            HStack(alignment: .center, spacing: 32) {
                AlbumArtwork(artwork: playback.artwork, size: 246)
                VStack(alignment: .leading, spacing: 9) {
                    Text(playback.title)
                        .font(.system(size: 36, weight: .semibold))
                        .lineLimit(3)
                    if let track = playback.state.snapshot?.track {
                        Text(track.artist ?? "Unknown artist")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        if let album = track.album {
                            Text(album)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    playbackMessage
                        .padding(.top, 10)
                    Button {
                        playback.perform(.playPause)
                    } label: {
                        Label(playback.playPauseLabel, systemImage: playback.playPauseIcon)
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!playback.canSendCommand)
                    if playback.state.connection == .available, playback.state.snapshot?.track == nil {
                        Text("Choose Play next to a song in Songs or a playlist.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(32)
            .frame(maxWidth: 940, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var libraryContent: some View {
        if playback.libraryProcessID == nil {
            VStack(alignment: .leading, spacing: 12) {
                Text("Music Library").font(.title2.weight(.semibold))
                playbackMessage
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(32)
        } else if pageFailed {
            libraryMessage("This collection is unavailable in Music.")
        } else if let page = page {
            if page.total == 0 {
                libraryMessage("This collection has no songs.")
            } else if page.tracks.isEmpty {
                libraryMessage("Music returned no tracks for this page.")
            } else {
                trackList(page)
            }
        } else {
            ProgressView("Loading songs…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func libraryMessage(_ message: String) -> some View {
        Text(message)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(32)
    }

    private func trackList(_ page: MusicPage) -> some View {
        VStack(spacing: 0) {
            if playback.commandFailed {
                Text(playback.statusText)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(page.tracks.indices, id: \.self) { index in
                        let track = page.tracks[index]
                        HStack(spacing: 16) {
                            Text("\(offset + index + 1)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .frame(width: 38, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(track.title ?? "Unknown title").fontWeight(.medium)
                                Text(track.artist ?? "Unknown artist")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(track.album ?? "")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(maxWidth: 200, alignment: .leading)
                            Text(track.duration.map(playbackTime) ?? "—")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 45, alignment: .trailing)
                            Button {
                                if let collection = selection {
                                    playback.perform(.playTrack(track, in: collection))
                                }
                            } label: {
                                Label("Play", systemImage: "play.fill")
                            }
                            .fixedSize()
                            .accessibilityLabel("Play \(track.title ?? "track")")
                            .disabled(track.musicItemID == nil || !playback.canSendCommand)
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 14)
                        Divider()
                    }
                }
                .padding(.horizontal, 18)
            }
            HStack {
                Text("\(offset + 1)–\(offset + page.tracks.count) of \(page.total) songs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Previous Page") { goToPage(max(0, offset - MusicService.pageSize)) }
                    .disabled(offset == 0)
                Button("Next Page") { goToPage(offset + MusicService.pageSize) }
                    .disabled(offset + MusicService.pageSize >= page.total)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 11)
        }
    }

    private func goToPage(_ newOffset: Int) {
        page = nil
        pageFailed = false
        offset = newOffset
    }

    private var playbackMessage: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(playback.statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if playback.state.connection == .musicClosed {
                Button("Reconnect to Music") { playback.connect() }
                    .disabled(!playback.canSendCommand)
            }
        }
    }

    private func loadPlaylists(for processID: pid_t?) async {
        playlists = nil
        playlistsFailed = false
        guard let processID = processID else { return }
        do {
            let result = try await music.playlists(for: processID)
            try Task.checkCancellation()
            playlists = result
            if case .playlist(let current) = selection {
                if let updated = result.first(where: { $0.id == current.id }) {
                    selection = .playlist(updated)
                } else {
                    offset = 0
                    selection = .songs
                }
            }
        } catch {
            if !Task.isCancelled { playlistsFailed = true }
        }
    }

    private func loadPage(_ request: LibraryRequest) async {
        page = nil
        pageFailed = false
        guard let processID = request.processID, let collection = request.collection else { return }
        do {
            try await Task.sleep(nanoseconds: 120_000_000)
            let result = try await music.tracks(in: collection, offset: request.offset, for: processID)
            try Task.checkCancellation()
            if result.total > 0 && request.offset >= result.total {
                offset = ((result.total - 1) / MusicService.pageSize) * MusicService.pageSize
            } else {
                page = result
            }
        } catch {
            if !Task.isCancelled { pageFailed = true }
        }
    }
}

struct AlbumArtwork: View {
    let artwork: MusicArtwork?
    let size: CGFloat

    var body: some View {
        ZStack {
            Color.accentColor.opacity(0.14)
            if let artwork = artwork {
                Image(decorative: artwork.image, scale: 1)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.29, weight: .regular))
                    .foregroundStyle(Color.accentColor.opacity(0.78))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size > 100 ? 14 : 6))
        .accessibilityHidden(true)
    }
}

@MainActor
private extension PlaybackModel {
    var playPauseLabel: String {
        switch state.snapshot?.status {
        case .playing, .fastForwarding, .rewinding: return "Pause"
        default: return "Play"
        }
    }

    var playPauseIcon: String { playPauseLabel == "Pause" ? "pause.fill" : "play.fill" }

    var title: String {
        if let track = state.snapshot?.track { return track.title ?? "Unknown title" }
        return state.connection == .available ? "No track" : "Apple Music"
    }

    var statusText: String {
        if state.connection == .starting { return "Starting Music in the background…" }
        if isSendingCommand { return "Waiting for Music…" }
        if commandFailed {
            return state.connection == .musicClosed ? "Could not start Music. Try reconnecting."
                : "Music did not confirm the last command."
        }
        switch state.connection {
        case .checking, .starting: return "Connecting to Music…"
        case .musicClosed: return "Music is closed."
        case .permissionDenied:
            return "Allow Luma in System Preferences → Security & Privacy → Privacy → Automation, then select Refresh."
        case .stale(.timedOut): return "Music is taking too long to respond."
        case .stale: return "Could not refresh playback."
        case .available:
            switch state.snapshot?.status {
            case .playing: return "Playing"
            case .paused: return "Paused"
            case .stopped: return "Stopped"
            case .fastForwarding: return "Fast Forwarding"
            case .rewinding: return "Rewinding"
            case .unknown, nil: return "Playback state unavailable"
            }
        }
    }
}

@MainActor
private struct PlaybackBar: View {
    @ObservedObject var playback: PlaybackModel
    @State private var volumeDraft: Double?
    @State private var editingVolume = false

    private var snapshot: PlaybackSnapshot? { playback.state.snapshot }
    private var connected: Bool { playback.state.connection == .available }

    var body: some View {
        HStack(spacing: 19) {
            HStack(spacing: 10) {
                AlbumArtwork(artwork: playback.artwork, size: 43)
                VStack(alignment: .leading, spacing: 3) {
                    Text(playback.title).font(.callout.weight(.semibold))
                    Text(snapshot?.track?.artist ?? playback.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
            }
            .frame(minWidth: 140, idealWidth: 175, maxWidth: 238, alignment: .leading)

            HStack(spacing: 10) {
                modeButton("Shuffle", icon: "shuffle", active: snapshot?.shuffle == true,
                           available: snapshot?.shuffle != nil, action: playback.toggleShuffle)
                transport(.previousTrack, icon: "backward.fill", label: "Previous Track")
                Button {
                    playback.perform(.playPause)
                } label: {
                    Label(playback.playPauseLabel, systemImage: playback.playPauseIcon)
                        .fixedSize()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!playback.canSendCommand)
                transport(.nextTrack, icon: "forward.fill", label: "Next Track")
                modeButton(repeatLabel, icon: snapshot?.repeatMode == .one ? "repeat.1" : "repeat",
                           active: snapshot?.repeatMode.map { $0 != .off } == true,
                           available: snapshot?.repeatMode != nil, action: playback.cycleRepeat)
            }

            PlaybackProgress(playback: playback)
                .frame(minWidth: 180, maxWidth: .infinity)
            volume
                .frame(width: 112)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func transport(_ command: PlaybackCommand, icon: String, label: String) -> some View {
        return Button {
            playback.perform(command)
        } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 22, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
        .disabled(!playback.canSendCommand || playback.libraryProcessID == nil)
    }

    private var repeatLabel: String {
        switch snapshot?.repeatMode {
        case .off: return "Repeat Off"
        case .all: return "Repeat All"
        case .one: return "Repeat One"
        case nil: return "Repeat Unavailable"
        }
    }

    private func modeButton(
        _ label: String, icon: String, active: Bool, available: Bool, action: @escaping @MainActor () -> Void
    ) -> some View {
        Button { action() } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 22, height: 32)
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
        .help(label)
        .disabled(!connected || !available || playback.isSendingCommand)
    }

    private var volume: some View {
        HStack(spacing: 7) {
            Image(systemName: "speaker.wave.2")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(value: Binding(
                get: { volumeDraft ?? Double(snapshot?.volume ?? 0) },
                set: {
                    if editingVolume { volumeDraft = $0 }
                    else { playback.changeVolume(to: Int($0.rounded())) }
                }
            ), in: 0...100, step: 1, onEditingChanged: { editing in
                editingVolume = editing
                if !editing, let value = volumeDraft {
                    volumeDraft = nil
                    playback.changeVolume(to: Int(value.rounded()))
                }
            })
            .accessibilityLabel("Music Volume")
        }
        .disabled(!connected || snapshot?.volume == nil || playback.isSendingCommand)
        .help(snapshot?.volume == nil ? "Volume unavailable" : "Music volume")
    }
}

@MainActor
private struct PlaybackProgress: View {
    @ObservedObject var playback: PlaybackModel
    @State private var positionDraft: Double?
    @State private var editingTrack: PlaybackSnapshot.Track?

    private var snapshot: PlaybackSnapshot? { playback.state.snapshot }

    var body: some View {
        Group {
            if let snapshot = snapshot, snapshot.status == .playing, snapshot.position != nil {
                TimelineView(.periodic(from: .now, by: 1)) { _ in progress }
            } else {
                progress
            }
        }
        .onChange(of: snapshot?.track) { track in
            if let editingTrack = editingTrack, track?.representsSameTrack(as: editingTrack) != true {
                positionDraft = nil
            }
        }
    }

    private var progress: some View {
        let duration = snapshot?.track?.duration
        let elapsed = snapshot?.elapsed()
        let displayed = positionDraft ?? elapsed
        return HStack(spacing: 7) {
            Text(displayed.map(playbackTime) ?? "—")
                .frame(width: 42, alignment: .trailing)
            Slider(value: Binding(
                get: { min(duration ?? 1, displayed ?? 0) },
                set: {
                    if editingTrack != nil { positionDraft = $0 }
                    else if let track = snapshot?.track { playback.seek(to: $0, expecting: track) }
                }
            ), in: 0...(duration ?? 1), onEditingChanged: { editing in
                if editing {
                    editingTrack = snapshot?.track
                } else {
                    if let target = positionDraft, let track = editingTrack {
                        playback.seek(to: target, expecting: track)
                    }
                    positionDraft = nil
                    editingTrack = nil
                }
            })
            .accessibilityLabel("Playback Position")
            .disabled(snapshot?.canSeek != true || playback.state.connection != .available || playback.isSendingCommand)
            .help(snapshot?.canSeek == true ? "Seek in the current track" : "Seeking unavailable")
            Text(duration.map(playbackTime) ?? "—")
                .frame(width: 46, alignment: .leading)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
}

private func playbackTime(_ time: Double) -> String {
    let seconds = Int(min(359_999, max(0, time)))
    return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
}
