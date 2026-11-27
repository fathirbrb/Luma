import Carbon
import Foundation

@main
@MainActor
struct PlaybackChecks {
    static func main() async throws {
        try checkDescriptors()
        try await checkCommandOrdering()
        try await checkMusicRestart()
        try await checkRefreshCoalescing()
        try await checkPermissionRetry()
        try await checkClosedMusic()
        try await checkTimedOutCommand()
        try await checkBoundedVerification()
        try checkProgress()
        try await checkSeekAndVolume()
        try await checkShuffleAndRepeat()
        try await checkLaunchFailure()
        try await checkPlaySelectedTrack()
        print("13 playback checks passed")
    }

    private static let playing = PlaybackSnapshot(
        status: .playing, track: .init(title: "First", artist: "First Artist", persistentID: "1")
    )
    private static let paused = PlaybackSnapshot(status: .paused, track: playing.track)
    private static let next = PlaybackSnapshot(
        status: .playing, track: .init(title: "Second", artist: "Second Artist", persistentID: "2")
    )

    private static func checkDescriptors() throws {
        try expect(try MusicService.decodeStatus(.init(enumCode: 0x6b505350)) == .playing, "Playing enum")
        try expect(try MusicService.decodeStatus(.init(enumCode: 0x6b505370)) == .paused, "Paused enum")
        try expect(try MusicService.decodeStatus(.init(enumCode: 0x6b505353)) == .stopped, "Stopped enum")
        try expect(try MusicService.decodeStatus(.init(enumCode: 0x6b505346)) == .fastForwarding, "Fast forwarding enum")
        try expect(try MusicService.decodeStatus(.init(enumCode: 0x6b505352)) == .rewinding, "Rewind enum")
        try expect(try MusicService.decodeStatus(.init(enumCode: 0)) == .unknown, "Unknown enum")
        do {
            _ = try MusicService.decodeStatus(.init(string: "playing"))
            throw Failure("Malformed playback state was accepted")
        } catch MusicError.malformedReply {}

        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(.init(string: "Español 🎵"), forKeyword: pName)
        record.setDescriptor(.init(typeCode: OSType(cMissingValue)), forKeyword: 0x70417274)
        record.setDescriptor(.init(string: "1A"), forKeyword: 0x70504953)
        let decoded = try MusicService.decodeTrack(record)
        try expect(decoded == .init(title: "Español 🎵", artist: nil, persistentID: "1A"), "Track fields")
        try expect(try MusicService.decodeTrack(.null()) == nil, "Null track")
        try expect(try MusicService.decodeTrack(.record()) == nil, "Empty track record")
        do {
            _ = try MusicService.decodeTrack(.list())
            throw Failure("Malformed track record was accepted")
        } catch MusicError.malformedReply {}
    }

    private static func checkCommandOrdering() async throws {
        let service = FakeMusic()
        let model = modelFor(service)
        model.windowOpened()
        defer { model.windowClosed() }
        try await eventually { await service.readCount == 1 }
        await service.finishRead(.success(playing))
        try await eventually { model.state.snapshot == playing }
        model.refresh()
        try await eventually { await service.readCount == 2 }
        model.perform(.nextTrack)
        model.perform(.nextTrack)
        try await eventually { await service.commandCount == 1 }
        await service.finishRead(.success(paused))
        await service.finishCommand(.success(()))
        try await eventually { await service.readCount == 3 }
        try expect(model.state.snapshot == playing, "A read started before the command replaced the confirmed snapshot")
        await service.finishRead(.success(next))
        try await eventually { model.state.snapshot == next }
        let commandCount = await service.commandCount
        try expect(commandCount == 1, "A second click was sent while a command was pending")
    }

    private static func checkMusicRestart() async throws {
        let service = FakeMusic()
        let model = modelFor(service)
        model.windowOpened()
        defer { model.windowClosed() }
        try await eventually { await service.readCount == 1 }
        model.musicStopped(101)
        try expect(model.state.connection == .musicClosed, "Music quit was ignored")
        model.musicStarted(102)
        await service.finishRead(.success(playing))
        try await eventually { await service.readCount == 2 }
        try expect(model.state.snapshot == nil, "Metadata from the terminated process was published")
        await service.finishRead(.success(next))
        try await eventually { model.state.snapshot == next }
        let targets = await service.readTargets
        try expect(targets == [101, 102], "Music relaunch did not change the target process")
    }

    private static func checkRefreshCoalescing() async throws {
        let service = FakeMusic()
        let model = modelFor(service)
        model.windowOpened()
        model.windowOpened()
        defer { model.windowClosed() }
        try await eventually { await service.readCount == 1 }
        for _ in 0..<10 { model.playbackHintReceived() }
        try await Task.sleep(nanoseconds: 250_000_000)
        let initialReadCount = await service.readCount
        try expect(initialReadCount == 1, "Hints started a concurrent read")
        await service.finishRead(.success(playing))
        try await eventually { await service.readCount == 2 }
        model.windowClosed()
        await service.finishRead(.success(next))
        try await eventually { model.state.snapshot == next }
        let coalescedReadCount = await service.readCount
        try expect(coalescedReadCount == 2, "The open windows created duplicate reads")
        model.windowClosed()
        model.playbackHintReceived()
        try await Task.sleep(nanoseconds: 250_000_000)
        let closedReadCount = await service.readCount
        try expect(closedReadCount == 2, "A hint caused a read without an open window")
    }

    private static func checkPermissionRetry() async throws {
        let service = FakeMusic()
        let model = modelFor(service)
        model.windowOpened()
        defer { model.windowClosed() }
        try await eventually { await service.readCount == 1 }
        await service.finishRead(.failure(.permissionDenied))
        try await eventually { model.state.connection == .permissionDenied }
        model.playbackHintReceived()
        try await Task.sleep(nanoseconds: 250_000_000)
        let deniedReadCount = await service.readCount
        try expect(deniedReadCount == 1 && !model.canSendCommand, "Denied Automation was retried passively")
        model.refresh()
        try await eventually { await service.readCount == 2 }
        await service.finishRead(.success(paused))
        try await eventually { model.state.snapshot == paused }
    }

    private static func checkClosedMusic() async throws {
        let service = FakeMusic()
        let launcher = FakeLauncher()
        let model = PlaybackModel(
            music: service, runningMusic: { nil }, launchMusic: { try await launcher.prepare() }, observesNotifications: false
        )
        model.windowOpened()
        defer { model.windowClosed() }
        model.refresh()
        model.playbackHintReceived()
        try await eventually { await launcher.attempts == 1 }
        let closedReadCount = await service.readCount
        try expect(model.state.connection == .starting && closedReadCount == 0, "Music was queried before readiness")
        await launcher.complete(.success(101))
        try await eventually { await service.readCount == 1 }
        await service.finishRead(.success(paused))
        try await eventually { model.state.snapshot == paused }
        let connectedCommandCount = await service.commandCount
        try expect(connectedCommandCount == 0, "Connecting for browsing changed playback")
        model.musicStopped(101)
        model.windowClosed()
        model.windowOpened()
        model.refresh()
        model.playbackHintReceived()
        let unchangedAttempts = await launcher.attempts
        try expect(model.state.connection == .musicClosed && unchangedAttempts == 1, "Music relaunched after a quit")
        model.perform(.playPause)
        try await eventually { await launcher.attempts == 2 }
        await launcher.complete(.success(102))
        try await eventually { await service.commandCount == 1 }
        await service.finishCommand(.success(()))
        try await eventually { await service.readCount == 2 }
        await service.finishRead(.success(playing))
        try await eventually { model.state.snapshot == playing }
    }

    private static func checkTimedOutCommand() async throws {
        let service = FakeMusic()
        let model = modelFor(service)
        model.windowOpened()
        defer { model.windowClosed() }
        try await eventually { await service.readCount == 1 }
        await service.finishRead(.success(playing))
        try await eventually { model.state.snapshot == playing }
        model.perform(.playPause)
        try await eventually { await service.commandCount == 1 }
        await service.finishCommand(.failure(.timedOut))
        try await eventually { await service.readCount == 2 }
        await service.finishRead(.success(paused))
        try await eventually { model.state.snapshot == paused }
        let commandCount = await service.commandCount
        try expect(commandCount == 1 && model.commandFailed, "Timed-out command was retried or hidden")
    }

    private static func checkBoundedVerification() async throws {
        let service = FakeMusic()
        let model = modelFor(service)
        model.windowOpened()
        defer { model.windowClosed() }
        try await eventually { await service.readCount == 1 }
        await service.finishRead(.success(playing))
        try await eventually { model.state.snapshot == playing }
        model.perform(.nextTrack)
        try await eventually { await service.commandCount == 1 }
        await service.finishCommand(.success(()))
        for count in 2...4 {
            try await eventually { await service.readCount == count }
            await service.finishRead(.success(playing))
        }
        try await Task.sleep(nanoseconds: 800_000_000)
        let reads = await service.readCount
        let commands = await service.commandCount
        try expect(reads == 4 && commands == 1, "An unchanged track triggered unbounded verification")
    }

    private static func checkProgress() throws {
        let track = PlaybackSnapshot.Track(title: "Song", artist: nil, persistentID: "A", duration: 100)
        let sample = PlaybackSnapshot.Position(seconds: 20, uptime: 10)
        let playing = PlaybackSnapshot(status: .playing, track: track, position: sample)
        let paused = PlaybackSnapshot(status: .paused, track: track, position: sample)
        let stopped = PlaybackSnapshot(status: .stopped, track: track, position: sample)
        try expect(playing.elapsed(at: 14) == 24 && playing.elapsed(at: 1_000) == 100, "Playback interpolation")
        try expect(paused.elapsed(at: 14) == 20 && paused.canSeek, "Paused position")
        try expect(!stopped.canSeek, "Stopped playback exposed seeking")
    }

    private static func checkSeekAndVolume() async throws {
        let service = FakeMusic()
        let model = modelFor(service)
        let track = PlaybackSnapshot.Track(title: "Song", artist: nil, persistentID: "A", duration: 100)
        let snapshot = PlaybackSnapshot(status: .paused, track: track,
                                        position: .init(seconds: 20, uptime: 10), volume: 60)
        model.windowOpened()
        defer { model.windowClosed() }
        try await eventually { await service.readCount == 1 }
        await service.finishRead(.success(snapshot))
        try await eventually { model.state.snapshot == snapshot }
        model.seek(to: 75, expecting: next.track!)
        model.seek(to: 35, expecting: track)
        try await eventually { await service.commandCount == 1 }
        let seek = await service.lastCommand
        try expect(seek == .seek(35, track), "Seek applied to the wrong track")
        await service.finishCommand(.success(()))
        try await eventually { await service.readCount == 2 }
        await service.finishRead(.success(snapshot))
        model.changeVolume(to: 29)
        try await eventually { await service.commandCount == 2 }
        let volume = await service.lastCommand
        try expect(volume == .setVolume(29), "Volume command did not preserve the target")
        await service.finishCommand(.success(()))
        try await eventually { await service.readCount == 3 }
        await service.finishRead(.success(snapshot))
    }

    private static func modelFor(_ service: FakeMusic) -> PlaybackModel {
        PlaybackModel(music: service, runningMusic: { 101 }, observesNotifications: false)
    }

    private static func checkPlaySelectedTrack() async throws {
        let service = FakeMusic()
        let model = modelFor(service)
        let track = PlaybackSnapshot.Track(title: "Selected", artist: "Artist", persistentID: "55", musicItemID: 42)
        let collection = MusicCollection.playlist(.init(id: 20, name: "Playlist"))
        let command = PlaybackCommand.playTrack(track, in: collection)
        model.windowOpened()
        defer { model.windowClosed() }
        try await eventually { await service.readCount == 1 }
        await service.finishRead(.success(.init(status: .stopped, track: nil)))
        try await eventually { model.state.connection == .available }
        model.perform(command)
        try await eventually { await service.commandCount == 1 }
        let forwarded = await service.lastCommand
        try expect(forwarded == command, "Selected track or playlist was lost")
        await service.finishCommand(.success(()))
        try await eventually { await service.readCount == 2 }
        await service.finishRead(.success(.init(status: .playing, track: track)))
        try await eventually { model.state.snapshot?.track == track }
    }

    private static func checkLaunchFailure() async throws {
        let service = FakeMusic()
        let launcher = FakeLauncher()
        let model = PlaybackModel(music: service, runningMusic: { nil },
                                  launchMusic: { try await launcher.prepare() }, observesNotifications: false)
        model.windowOpened()
        defer { model.windowClosed() }
        try await eventually { await launcher.attempts == 1 }
        await launcher.complete(.failure(.timedOut))
        try await eventually { model.state.connection == .musicClosed && model.commandFailed }
        model.connect()
        try await eventually { await launcher.attempts == 2 }
        await launcher.complete(.success(103))
        try await eventually { await service.readCount == 1 }
        await service.finishRead(.success(paused))
        try await eventually { model.state.snapshot == paused }
    }

    private static func checkShuffleAndRepeat() async throws {
        let service = FakeMusic()
        let model = modelFor(service)
        let modes = PlaybackSnapshot(status: .paused, track: playing.track, shuffle: false, repeatMode: .off)
        model.windowOpened()
        defer { model.windowClosed() }
        try await eventually { await service.readCount == 1 }
        await service.finishRead(.success(modes))
        try await eventually { model.state.snapshot == modes }
        model.toggleShuffle()
        try await eventually { await service.commandCount == 1 }
        let shuffle = await service.lastCommand
        try expect(shuffle == .setShuffle(true), "Shuffle did not toggle the observed value")
        await service.finishCommand(.success(()))
        try await eventually { await service.readCount == 2 }
        await service.finishRead(.success(modes))
        model.cycleRepeat()
        try await eventually { await service.commandCount == 2 }
        let repeatCommand = await service.lastCommand
        try expect(repeatCommand == .setRepeat(.all), "Repeat did not cycle from Off to All")
        await service.finishCommand(.success(()))
        try await eventually { await service.readCount == 3 }
        await service.finishRead(.success(paused))
        try await eventually { model.state.snapshot == paused }
        model.toggleShuffle()
        model.cycleRepeat()
        let unchangedCount = await service.commandCount
        try expect(unchangedCount == 2, "Unsupported playback modes were written")
    }

    private static func eventually(_ ready: () async -> Bool, in scenario: String = #function) async throws {
        for _ in 0..<200 {
            if await ready() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw Failure("Expected an asynchronous playback update in \(scenario)")
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(message) }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}

private actor FakeLauncher {
    private(set) var attempts = 0
    private var pending: CheckedContinuation<pid_t, Error>?

    func prepare() async throws -> pid_t {
        attempts += 1
        return try await withCheckedThrowingContinuation { pending = $0 }
    }

    func complete(_ result: Result<pid_t, MusicError>) {
        pending?.resume(with: result.mapError { $0 as Error })
        pending = nil
    }
}

private actor FakeMusic: MusicControlling {
    private(set) var readTargets: [pid_t] = []
    private(set) var commandCount = 0
    private(set) var lastCommand: PlaybackCommand?
    private var reads: [CheckedContinuation<PlaybackSnapshot, Error>] = []
    private var commands: [CheckedContinuation<Void, Error>] = []
    var readCount: Int { readTargets.count }

    func snapshot(for processID: pid_t) async throws -> PlaybackSnapshot {
        readTargets.append(processID)
        return try await withCheckedThrowingContinuation { reads.append($0) }
    }

    func send(_ command: PlaybackCommand, to processID: pid_t) async throws {
        commandCount += 1
        lastCommand = command
        try await withCheckedThrowingContinuation { commands.append($0) }
    }

    func finishRead(_ result: Result<PlaybackSnapshot, MusicError>) {
        reads.removeFirst().resume(with: result.mapError { $0 as Error })
    }

    func finishCommand(_ result: Result<Void, MusicError>) {
        commands.removeFirst().resume(with: result.mapError { $0 as Error })
    }
}
