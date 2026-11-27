import AppKit
import Combine

@MainActor
final class PlaybackModel: NSObject, ObservableObject {
    enum Connection: Equatable {
        case checking, starting, available, musicClosed, permissionDenied, stale(MusicError)
    }

    struct State: Equatable {
        let snapshot: PlaybackSnapshot?
        let connection: Connection
    }

    @Published private(set) var state = State(snapshot: nil, connection: .checking)
    @Published private(set) var isSendingCommand = false
    @Published private(set) var commandFailed = false
    @Published private(set) var artwork: MusicArtwork?

    private let music: any MusicControlling
    private let runningMusic: () -> pid_t?
    private let launchMusic: () async throws -> pid_t
    private let observesNotifications: Bool
    private var openWindows = 0
    private var didPrepareMusic = false
    private var artworkCache: [(track: PlaybackSnapshot.Track, artwork: MusicArtwork)] = []
    private var processID: pid_t?
    private var generation = 0
    private var isReading = false
    private var pendingRefresh = false
    private var failedReads = 0
    private var pollTimer: Timer?
    private var hintTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var readinessTask: Task<Void, Never>?
    private var artworkTrack: PlaybackSnapshot.Track?
    private var verification: CommandVerification?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    private static let playerInfo = Notification.Name("com.apple.Music.playerInfo")

    private struct CommandVerification {
        let command: PlaybackCommand
        let previous: PlaybackSnapshot?
        var retries = 0

        func needsRetry(after snapshot: PlaybackSnapshot?) -> Bool {
            guard let snapshot = snapshot else { return true }
            switch command {
            case .playPause:
                return previous?.status == snapshot.status || snapshot.status == .unknown
            case .previousTrack, .nextTrack:
                return snapshot.track == nil || previous?.track == snapshot.track
            case .playTrack(let expected, _):
                return snapshot.status != .playing || snapshot.track?.representsSameTrack(as: expected) != true
            case .seek, .setVolume, .setShuffle, .setRepeat:
                return false
            }
        }
    }

    init(
        music: any MusicControlling = MusicService(),
        runningMusic: @escaping () -> pid_t? = { MusicLifecycle.readyProcessID() },
        launchMusic: @escaping () async throws -> pid_t = { try await MusicLifecycle.prepare() },
        observesNotifications: Bool = true
    ) {
        self.music = music
        self.runningMusic = runningMusic
        self.launchMusic = launchMusic
        self.observesNotifications = observesNotifications
    }

    var canSendCommand: Bool {
        !isSendingCommand && state.connection != .permissionDenied
            && state.connection != .checking && state.connection != .starting
    }

    var libraryProcessID: pid_t? {
        switch state.connection {
        case .available, .stale: return processID
        case .checking, .starting, .musicClosed, .permissionDenied: return nil
        }
    }

    func windowOpened() {
        openWindows += 1
        guard openWindows == 1 else { return }
        if observesNotifications { startObserving() }
        updateTarget(runningMusic())
        let isFirstConnection = !didPrepareMusic
        didPrepareMusic = true
        if isFirstConnection && processID == nil {
            connect()
        } else {
            requestRefresh()
        }
    }

    func windowClosed() {
        guard openWindows > 0 else { return }
        openWindows -= 1
        guard openWindows == 0 else { return }
        generation += 1
        clearDeferredWork()
        readinessTask?.cancel()
        readinessTask = nil
        clearArtwork()
        artworkCache.removeAll()
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        if observesNotifications {
            DistributedNotificationCenter.default().removeObserver(self, name: Self.playerInfo, object: nil)
        }
    }

    func refresh() {
        commandFailed = false
        updateTarget(runningMusic())
        if artwork == nil && artworkTask == nil { artworkTrack = nil }
        if state.connection == .permissionDenied {
            state = State(snapshot: nil, connection: .checking)
        }
        requestRefresh()
    }

    func perform(_ command: PlaybackCommand) {
        startCommand(command)
    }

    func connect() {
        guard state.connection == .musicClosed else { return }
        startCommand(nil)
    }

    func seek(to seconds: Double, expecting track: PlaybackSnapshot.Track) {
        guard state.connection == .available, let snapshot = state.snapshot, snapshot.canSeek,
              let current = snapshot.track, current.representsSameTrack(as: track) else { return }
        perform(.seek(seconds, track))
    }

    func changeVolume(to percent: Int) {
        guard state.connection == .available, state.snapshot?.volume != nil else { return }
        perform(.setVolume(percent))
    }

    func toggleShuffle() {
        guard state.connection == .available, let enabled = state.snapshot?.shuffle else { return }
        perform(.setShuffle(!enabled))
    }

    func cycleRepeat() {
        guard state.connection == .available, let mode = state.snapshot?.repeatMode else { return }
        perform(.setRepeat(mode.next))
    }

    private func startCommand(_ command: PlaybackCommand?) {
        guard openWindows > 0, canSendCommand,
              processID != nil || command == .playPause || command == nil else { return }
        generation += 1
        clearDeferredWork()
        isSendingCommand = true
        commandFailed = false
        let initialGeneration = generation
        let previous = state.snapshot
        let initialTarget = processID
        if initialTarget == nil { publish(snapshot: nil, connection: .starting) }

        Task { [self] in
            var commandGeneration = initialGeneration
            do {
                let target: pid_t
                if let initialTarget = initialTarget {
                    target = initialTarget
                } else {
                    if let running = runningMusic() {
                        target = running
                    } else {
                        target = try await launchMusic()
                    }
                    guard openWindows > 0, processID == nil || processID == target else {
                        finishCommand()
                        return
                    }
                    updateTarget(target)
                    commandGeneration = generation
                }
                guard commandGeneration == generation else {
                    finishCommand()
                    return
                }
                if let command = command { try await music.send(command, to: target) }
                if commandGeneration == generation {
                    verification = command.map { CommandVerification(command: $0, previous: previous) }
                    requestRefresh()
                }
            } catch {
                if commandGeneration == generation {
                    let failure = error as? MusicError ?? .malformedReply
                    if processID == nil {
                        publish(snapshot: nil, connection: .musicClosed)
                        commandFailed = true
                        finishCommand()
                        return
                    }
                    commandFailed = failure != .permissionDenied && (failure != .notRunning || initialTarget == nil)
                    switch failure {
                    case .permissionDenied, .notRunning:
                        applyFailure(failure)
                    case .timedOut:
                        // A timed-out command may still take effect. Verify without resending it.
                        verification = command.map { CommandVerification(command: $0, previous: previous) }
                        requestRefresh()
                    default:
                        requestRefresh()
                    }
                }
            }
            finishCommand()
        }
    }

    func musicStarted(_ pid: pid_t) {
        guard openWindows > 0 else { return }
        updateTarget(pid)
        requestRefresh()
    }

    func musicStopped(_ pid: pid_t) {
        guard processID == pid else { return }
        updateTarget(nil)
    }

    private func waitForMusic(_ pid: pid_t) {
        guard openWindows > 0, state.connection != .starting, processID != pid else { return }
        readinessTask?.cancel()
        readinessTask = Task { [weak self] in
            do {
                try await MusicLifecycle.waitUntilReady(processID: pid)
                try Task.checkCancellation()
                self?.musicStarted(pid)
            } catch {
                // An external Music launch can be canceled independently of Luma.
            }
        }
    }

    func playbackHintReceived() {
        guard openWindows > 0, processID != nil, state.connection != .permissionDenied, failedReads == 0,
              hintTask == nil else { return }
        // Coalesce from the first hint so a continuous stream cannot postpone a refresh.
        hintTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled, let self = self else { return }
            self.hintTask = nil
            self.requestRefresh()
        }
    }

    private func requestRefresh() {
        guard openWindows > 0, processID != nil, state.connection != .permissionDenied else { return }
        pendingRefresh = true
        startReadIfNeeded()
    }

    private func startReadIfNeeded() {
        guard pendingRefresh, !isReading, !isSendingCommand, let target = processID else { return }
        pendingRefresh = false
        hintTask?.cancel()
        hintTask = nil
        pollTimer?.invalidate()
        pollTimer = nil
        retryTask?.cancel()
        retryTask = nil
        isReading = true
        let readGeneration = generation
        Task { [self] in
            if readGeneration == generation {
                do {
                    let snapshot = try await music.snapshot(for: target)
                    if readGeneration == generation {
                        failedReads = 0
                        publish(snapshot: snapshot, connection: .available)
                        updateArtwork(for: snapshot.track, in: target)
                        verifyCommand(using: snapshot)
                        schedulePoll()
                    }
                } catch {
                    if readGeneration == generation {
                        let failure = error as? MusicError ?? .malformedReply
                        applyFailure(failure)
                        verifyCommand(using: nil)
                        schedulePoll()
                    }
                }
            }
            isReading = false
            startReadIfNeeded()
        }
    }

    private func applyFailure(_ error: MusicError) {
        switch error {
        case .notRunning:
            updateTarget(nil)
        case .permissionDenied:
            clearDeferredWork()
            clearArtwork()
            publish(snapshot: nil, connection: .permissionDenied)
        default:
            failedReads = min(failedReads + 1, 3)
            pendingRefresh = false
            publish(snapshot: state.snapshot, connection: .stale(error))
        }
    }

    private func updateTarget(_ pid: pid_t?) {
        guard pid != processID || (state.connection == .checking && pid == nil) else { return }
        generation += 1
        processID = pid
        failedReads = 0
        commandFailed = false
        clearDeferredWork()
        clearArtwork()
        artworkCache.removeAll()
        publish(snapshot: nil, connection: pid == nil ? .musicClosed : .checking)
    }

    private func publish(snapshot: PlaybackSnapshot?, connection: Connection) {
        let newState = State(snapshot: snapshot, connection: connection)
        if state != newState { state = newState }
    }

    private func updateArtwork(for track: PlaybackSnapshot.Track?, in target: pid_t) {
        guard let track = track else {
            if artworkTrack != nil { clearArtwork() }
            return
        }
        guard artworkTrack?.representsSameTrack(as: track) != true else { return }
        clearArtwork()
        artworkTrack = track
        if let index = artworkCache.firstIndex(where: { $0.track.representsSameTrack(as: track) }) {
            let cached = artworkCache.remove(at: index)
            artworkCache.append(cached)
            artwork = cached.artwork
            return
        }
        artworkTask = Task { [weak self, music] in
            let image = try? await music.artwork(for: track, in: target)
            guard !Task.isCancelled, let self = self, self.processID == target,
                  self.artworkTrack?.representsSameTrack(as: track) == true else { return }
            self.artwork = image
            if let image = image {
                self.artworkCache.append((track, image))
                if self.artworkCache.count > 4 { self.artworkCache.removeFirst() }
            }
            self.artworkTask = nil
        }
    }

    private func clearArtwork() {
        artworkTask?.cancel()
        artworkTask = nil
        artworkTrack = nil
        artwork = nil
    }

    private func finishCommand() {
        isSendingCommand = false
        if state.connection == .starting { publish(snapshot: nil, connection: .musicClosed) }
        startReadIfNeeded()
    }

    private func clearDeferredWork() {
        pendingRefresh = false
        verification = nil
        hintTask?.cancel()
        hintTask = nil
        retryTask?.cancel()
        retryTask = nil
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func verifyCommand(using snapshot: PlaybackSnapshot?) {
        guard var attempt = verification, attempt.retries < 2, attempt.needsRetry(after: snapshot) else {
            verification = nil
            return
        }
        let delay: UInt64 = attempt.retries == 0 ? 300_000_000 : 700_000_000
        attempt.retries += 1
        verification = attempt
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self = self else { return }
            self.retryTask = nil
            self.requestRefresh()
        }
    }

    private func schedulePoll() {
        guard openWindows > 0, processID != nil, state.connection != .permissionDenied else { return }
        let interval: TimeInterval = failedReads > 1 ? 60 : failedReads == 1 ? 30 : 15
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] timer in
            let timerID = ObjectIdentifier(timer)
            Task { @MainActor [weak self] in
                guard let self = self, let current = self.pollTimer,
                      ObjectIdentifier(current) == timerID else { return }
                self.pollTimer = nil
                self.requestRefresh()
            }
        }
        timer.tolerance = 2
        pollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func startObserving() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let observer = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == MusicService.bundleID else { return }
                let pid = app.processIdentifier
                Task { @MainActor [weak self] in
                    if name == NSWorkspace.didLaunchApplicationNotification {
                        self?.waitForMusic(pid)
                    } else {
                        self?.musicStopped(pid)
                    }
                }
            }
            observers.append((workspace, observer))
        }
        let refreshOnActivation = [(NotificationCenter.default, NSApplication.didBecomeActiveNotification),
                                   (workspace, NSWorkspace.didWakeNotification)]
        for (center, name) in refreshOnActivation {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self = self, self.openWindows > 0 else { return }
                    self.updateTarget(self.runningMusic())
                    self.requestRefresh()
                }
            }
            observers.append((center, observer))
        }
        if !ProcessInfo.processInfo.arguments.contains("--no-music-notifications") {
            DistributedNotificationCenter.default().addObserver(
                self, selector: #selector(receivedPlayerInfo(_:)), name: Self.playerInfo,
                object: nil, suspensionBehavior: .deliverImmediately
            )
        }
    }

    @objc private func receivedPlayerInfo(_ notification: Notification) {
        playbackHintReceived()
    }
}
