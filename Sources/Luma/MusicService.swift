import AppKit
import Carbon
import ImageIO
import OSLog

struct PlaybackSnapshot: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case playing, paused, stopped, fastForwarding, rewinding, unknown
    }

    enum RepeatMode: Equatable, Sendable {
        case off, all, one

        fileprivate init?(descriptor: NSAppleEventDescriptor) {
            guard descriptor.descriptorType == typeEnumerated else { return nil }
            switch descriptor.enumCodeValue {
            case musicCode("kRpO"): self = .off
            case musicCode("kAll"): self = .all
            case musicCode("kRp1"): self = .one
            default: return nil
            }
        }

        fileprivate var code: OSType {
            switch self {
            case .off: return musicCode("kRpO")
            case .all: return musicCode("kAll")
            case .one: return musicCode("kRp1")
            }
        }

        var next: Self {
            switch self {
            case .off: return .all
            case .all: return .one
            case .one: return .off
            }
        }
    }

    struct Track: Equatable, Sendable {
        let title: String?
        let artist: String?
        let persistentID: String?
        var album: String? = nil
        var duration: Double? = nil
        var musicItemID: Int32? = nil

        func representsSameTrack(as other: Track) -> Bool {
            if let persistentID = persistentID, let otherID = other.persistentID {
                return persistentID == otherID
            }
            return title == other.title && artist == other.artist && album == other.album
        }
    }

    struct Position: Equatable, Sendable {
        let seconds: Double
        let uptime: TimeInterval
    }

    let status: Status
    let track: Track?
    var position: Position? = nil
    var volume: Int? = nil
    var shuffle: Bool? = nil
    var repeatMode: RepeatMode? = nil

    var canSeek: Bool {
        switch status {
        case .playing, .paused: return track?.duration != nil && position != nil
        default: return false
        }
    }

    func elapsed(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double? {
        guard let position = position, let duration = track?.duration else { return nil }
        let advance = status == .playing ? max(0, uptime - position.uptime) : 0
        return min(duration, max(0, position.seconds + advance))
    }
}

struct MusicArtwork: @unchecked Sendable {
    // ImageIO returns an immutable, already decoded thumbnail.
    let image: CGImage
}

struct MusicPlaylist: Identifiable, Hashable, Sendable {
    let id: Int32
    let name: String
}

enum MusicCollection: Hashable, Sendable {
    case songs, playlist(MusicPlaylist)
}

struct MusicPage: Sendable {
    let tracks: [PlaybackSnapshot.Track]
    let total: Int
}

enum PlaybackCommand: Equatable, Sendable {
    case previousTrack, playPause, nextTrack
    case playTrack(PlaybackSnapshot.Track, in: MusicCollection)
    case seek(Double, PlaybackSnapshot.Track), setVolume(Int)
    case setShuffle(Bool), setRepeat(PlaybackSnapshot.RepeatMode)
}

enum MusicError: Error, Equatable, Sendable {
    case notRunning, permissionDenied, timedOut, malformedReply, unsupported, trackChanged, appleEvent(Int)

    init(appleEventCode: Int) {
        switch appleEventCode {
        case -600, -609: self = .notRunning
        case -1743, -1744: self = .permissionDenied
        case -1712: self = .timedOut
        default: self = .appleEvent(appleEventCode)
        }
    }
}

protocol MusicControlling: Sendable {
    func snapshot(for processID: pid_t) async throws -> PlaybackSnapshot
    func send(_ command: PlaybackCommand, to processID: pid_t) async throws
    func artwork(for track: PlaybackSnapshot.Track, in processID: pid_t) async throws -> MusicArtwork?
}

extension MusicControlling {
    func artwork(for track: PlaybackSnapshot.Track, in processID: pid_t) async throws -> MusicArtwork? { nil }
}

final class MusicService: MusicControlling, @unchecked Sendable {
    static let bundleID = "com.apple.Music"

    private let queue = DispatchQueue(label: "Luma.MusicService", qos: .userInitiated)
    private let logger = Logger(subsystem: "com.fathirbrb.luma", category: "Music")

    func snapshot(for processID: pid_t) async throws -> PlaybackSnapshot {
        try await execute("Snapshot", for: processID) { target in
            let state = try Self.get(Self.property(musicCode("pPlS")), from: target)
            let status = try Self.decodeStatus(state)

            let track = try Self.currentTrack(from: target)
            let position = try track?.duration.flatMap { _ -> PlaybackSnapshot.Position? in
                guard let seconds = try Self.optionalProperty(musicCode("pPos"), from: target)?.number,
                      seconds >= 0 else { return nil }
                return .init(seconds: seconds, uptime: ProcessInfo.processInfo.systemUptime)
            }
            let volume = try Self.optionalProperty(musicCode("pVol"), from: target)?.integer
            let shuffle = try Self.optionalProperty(musicCode("pShE"), from: target)?
                .coerce(toDescriptorType: typeBoolean)?.booleanValue
            let repeatMode = try Self.optionalProperty(musicCode("pRpt"), from: target)
                .flatMap(PlaybackSnapshot.RepeatMode.init(descriptor:))
            return PlaybackSnapshot(status: status, track: track, position: position, volume: volume,
                                    shuffle: shuffle, repeatMode: repeatMode)
        }
    }

    func send(_ command: PlaybackCommand, to processID: pid_t) async throws {
        try await execute("Playback command", for: processID) { target in
            switch command {
            case .previousTrack:
                _ = try Self.sendEvent(musicCode("hook"), musicCode("Prev"), to: target)
            case .playPause:
                _ = try Self.sendEvent(musicCode("hook"), musicCode("PlPs"), to: target)
            case .nextTrack:
                _ = try Self.sendEvent(musicCode("hook"), musicCode("Next"), to: target)
            case .playTrack(let track, let collection):
                guard let id = track.musicItemID else { throw MusicError.unsupported }
                let item = try Self.object(musicCode("cTrk"), OSType(formUniqueID),
                                           .init(int32: id), in: Self.playlist(for: collection))
                let properties = try Self.get(Self.property(OSType(pProperties), of: item), from: target)
                guard let resolved = try Self.decodeTrack(properties), resolved.representsSameTrack(as: track) else {
                    throw MusicError.trackChanged
                }
                _ = try Self.sendEvent(musicCode("hook"), musicCode("Play"), to: target, object: item)
            case .seek(let seconds, let expectedTrack):
                guard seconds.isFinite else { throw MusicError.unsupported }
                guard let track = try Self.currentTrack(from: target),
                      track.representsSameTrack(as: expectedTrack) else { throw MusicError.trackChanged }
                guard let duration = track.duration else { throw MusicError.unsupported }
                try Self.set(musicCode("pPos"), to: .init(double: min(duration, max(0, seconds))), in: target)
            case .setVolume(let volume):
                let clamped = Int32(min(100, max(0, volume)))
                try Self.set(musicCode("pVol"), to: .init(int32: clamped), in: target)
            case .setShuffle(let enabled):
                try Self.set(musicCode("pShE"), to: .init(boolean: enabled), in: target)
            case .setRepeat(let mode):
                try Self.set(musicCode("pRpt"), to: .init(enumCode: mode.code), in: target)
            }
        }
    }

    func artwork(for track: PlaybackSnapshot.Track, in processID: pid_t) async throws -> MusicArtwork? {
        try await execute("Artwork", for: processID) { target in
            guard let current = try Self.currentTrack(from: target),
                  current.representsSameTrack(as: track) else { return nil }
            let artwork = try Self.object(musicCode("cArt"), OSType(formAbsolutePosition),
                                          .init(int32: 1), in: Self.property(musicCode("pTrk")))
            let value: NSAppleEventDescriptor
            do {
                value = try Self.get(Self.property(musicCode("pRaw"), of: artwork), from: target)
            } catch MusicError.appleEvent {
                return nil
            }
            let data = value.data
            guard !data.isEmpty, data.count <= 16 * 1024 * 1024,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 600,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary),
                  let confirmed = try Self.currentTrack(from: target),
                  confirmed.representsSameTrack(as: track) else { return nil }
            return MusicArtwork(image: image)
        }
    }

    func playlists(for processID: pid_t) async throws -> [MusicPlaylist] {
        try await execute("Playlists", for: processID) { target in
            let playlistClass = musicCode("cUsP")
            let count = try Self.count(playlistClass, in: nil, from: target)
            guard count > 0 else { return [] }
            let allBytes = NSAppleEventDescriptor(enumCode: OSType(kAEAll)).data
            guard let ordinal = NSAppleEventDescriptor(descriptorType: OSType(typeAbsoluteOrdinal), data: allBytes) else {
                throw MusicError.malformedReply
            }
            let all = try Self.object(playlistClass, OSType(formAbsolutePosition), ordinal)
            let records = try Self.get(Self.property(OSType(pProperties), of: all), from: target)
            return try Self.elements(in: records, expectingOne: count == 1).compactMap { record in
                guard let id = record.forKeyword(OSType(pID))?.integer, id > 0,
                      let name = record.text(pName),
                      record.forKeyword(OSType(pClass))?.typeCodeValue != musicCode("cFoP")
                else { return nil }
                return MusicPlaylist(id: Int32(id), name: name)
            }
        }
    }

    static let pageSize = 60

    func tracks(in collection: MusicCollection, offset: Int, for processID: pid_t) async throws -> MusicPage {
        try await execute("Library page", for: processID) { target in
            let playlist = try Self.playlist(for: collection)
            let trackClass = musicCode("cTrk")
            let total = try Self.count(trackClass, in: playlist, from: target)
            guard offset >= 0, offset < total else { return MusicPage(tracks: [], total: total) }
            let end = min(total, offset + Self.pageSize)
            guard let currentContainer = NSAppleEventDescriptor(descriptorType: OSType(typeCurrentContainer), data: nil) else {
                throw MusicError.malformedReply
            }
            let range = NSAppleEventDescriptor.record()
            range.setDescriptor(try Self.object(trackClass, OSType(formAbsolutePosition),
                                                .init(int32: Int32(offset + 1)), in: currentContainer),
                                forKeyword: keyAERangeStart)
            range.setDescriptor(try Self.object(trackClass, OSType(formAbsolutePosition),
                                                .init(int32: Int32(end)), in: currentContainer),
                                forKeyword: keyAERangeStop)
            guard let bounds = range.coerce(toDescriptorType: OSType(typeRangeDescriptor)) else {
                throw MusicError.malformedReply
            }
            let items = try Self.object(trackClass, OSType(formRange), bounds, in: playlist)
            let records = try Self.get(Self.property(OSType(pProperties), of: items), from: target)
            let tracks = try Self.elements(in: records, expectingOne: end - offset == 1).map {
                try Self.decodeTrack($0) ?? PlaybackSnapshot.Track(title: nil, artist: nil, persistentID: nil)
            }
            return MusicPage(tracks: tracks, total: total)
        }
    }

    private static func playlist(for collection: MusicCollection) throws -> NSAppleEventDescriptor {
        switch collection {
        case .songs:
            return try object(musicCode("cLiP"), OSType(formAbsolutePosition), .init(int32: 1))
        case .playlist(let selected):
            return try object(musicCode("cUsP"), OSType(formUniqueID), .init(int32: selected.id))
        }
    }

    private static func currentTrack(from target: NSAppleEventDescriptor) throws -> PlaybackSnapshot.Track? {
        do {
            let properties = try property(OSType(pProperties), of: property(musicCode("pTrk")))
            return try decodeTrack(get(properties, from: target))
        } catch MusicError.appleEvent(-1728) {
            return nil
        }
    }

    private static func optionalProperty(_ code: OSType, from target: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor? {
        do {
            return try get(property(code), from: target)
        } catch MusicError.appleEvent {
            return nil
        }
    }

    private static func count(
        _ type: OSType, in container: NSAppleEventDescriptor?, from target: NSAppleEventDescriptor
    ) throws -> Int {
        let reply = try sendEvent(kAECoreSuite, kAECountElements, to: target, object: container ?? .null(),
                                  parameters: [keyAEObjectClass: .init(typeCode: type)])
        guard let count = reply.paramDescriptor(forKeyword: keyDirectObject)?.integer, count >= 0 else {
            throw MusicError.malformedReply
        }
        return count
    }

    private static func elements(
        in descriptor: NSAppleEventDescriptor, expectingOne: Bool
    ) throws -> [NSAppleEventDescriptor] {
        if expectingOne, descriptor.isRecordDescriptor, descriptor.descriptorType != typeObjectSpecifier {
            return [descriptor]
        }
        guard descriptor.descriptorType == typeAEList else { throw MusicError.malformedReply }
        return (0..<descriptor.numberOfItems).compactMap { descriptor.atIndex($0 + 1) }
    }

    private static func set(
        _ propertyCode: OSType, to value: NSAppleEventDescriptor, in target: NSAppleEventDescriptor
    ) throws {
        _ = try sendEvent(kAECoreSuite, kAESetData, to: target, object: property(propertyCode),
                          parameters: [keyAEData: value])
    }

    private func execute<Value: Sendable>(
        _ name: String,
        for processID: pid_t,
        _ operation: @escaping @Sendable (NSAppleEventDescriptor) throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let start = DispatchTime.now().uptimeNanoseconds
                let result = Result {
                    guard let app = NSRunningApplication(processIdentifier: processID),
                          app.bundleIdentifier == Self.bundleID, !app.isTerminated else {
                        throw MusicError.notRunning
                    }
                    // A process address keeps a passive read from launching Music if it quits.
                    return try operation(NSAppleEventDescriptor(processIdentifier: processID))
                }
                let elapsed = (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                if case .failure(let error) = result {
                    let code = (error as? MusicError).map { String(describing: $0) } ?? "unexpected"
                    self.logger.debug("\(name, privacy: .public) failed: \(code, privacy: .public) (\(elapsed, privacy: .public) ms)")
                } else {
                    self.logger.debug("\(name, privacy: .public) completed in \(elapsed, privacy: .public) ms")
                }
                continuation.resume(with: result)
            }
        }
    }

    private static func property(
        _ code: OSType,
        of container: NSAppleEventDescriptor = .null()
    ) throws -> NSAppleEventDescriptor {
        try object(cProperty, OSType(formPropertyID), .init(typeCode: code), in: container)
    }

    private static func object(
        _ type: OSType, _ form: OSType, _ key: NSAppleEventDescriptor, in container: NSAppleEventDescriptor = .null()
    ) throws -> NSAppleEventDescriptor {
        let specifier = NSAppleEventDescriptor.record()
        specifier.setDescriptor(.init(typeCode: type), forKeyword: AEKeyword(keyAEDesiredClass))
        specifier.setDescriptor(.init(enumCode: form), forKeyword: AEKeyword(keyAEKeyForm))
        specifier.setDescriptor(key, forKeyword: AEKeyword(keyAEKeyData))
        specifier.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        guard let object = specifier.coerce(toDescriptorType: typeObjectSpecifier) else {
            throw MusicError.malformedReply
        }
        return object
    }

    private static func get(
        _ specifier: NSAppleEventDescriptor,
        from target: NSAppleEventDescriptor
    ) throws -> NSAppleEventDescriptor {
        let reply = try sendEvent(kAECoreSuite, kAEGetData, to: target, object: specifier)
        guard let value = reply.paramDescriptor(forKeyword: keyDirectObject) else {
            throw MusicError.malformedReply
        }
        return value
    }

    private static func sendEvent(
        _ eventClass: AEEventClass,
        _ id: AEEventID,
        to target: NSAppleEventDescriptor,
        object: NSAppleEventDescriptor? = nil,
        parameters: [AEKeyword: NSAppleEventDescriptor] = [:]
    ) throws -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: eventClass,
            eventID: id,
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        if let object = object {
            event.setParam(object, forKeyword: keyDirectObject)
        }
        for (key, value) in parameters { event.setParam(value, forKeyword: key) }
        do {
            let reply = try event.sendEvent(options: [.waitForReply, .canInteract], timeout: 3)
            if let code = reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value, code != 0 {
                throw MusicError(appleEventCode: Int(code))
            }
            return reply
        } catch let error as MusicError {
            throw error
        } catch {
            throw MusicError(appleEventCode: (error as NSError).code)
        }
    }

    static func decodeStatus(_ value: NSAppleEventDescriptor) throws -> PlaybackSnapshot.Status {
        guard value.descriptorType == typeEnumerated else { throw MusicError.malformedReply }
        switch value.enumCodeValue {
        case musicCode("kPSP"): return .playing
        case musicCode("kPSp"): return .paused
        case musicCode("kPSS"): return .stopped
        case musicCode("kPSF"): return .fastForwarding
        case musicCode("kPSR"): return .rewinding
        default: return .unknown
        }
    }

    static func decodeTrack(_ value: NSAppleEventDescriptor) throws -> PlaybackSnapshot.Track? {
        if value.descriptorType == typeNull || value.typeCodeValue == cMissingValue { return nil }
        guard value.isRecordDescriptor, value.descriptorType != typeObjectSpecifier else {
            throw MusicError.malformedReply
        }
        let title = value.text(pName)
        let artist = value.text(musicCode("pArt"))
        let persistentID = value.text(musicCode("pPIS"))
        let album = value.text(musicCode("pAlb"))
        let duration = value.forKeyword(musicCode("pDur"))?.number.flatMap { $0 > 0 ? $0 : nil }
        let itemID = value.forKeyword(OSType(pID))?.integer.flatMap { $0 > 0 ? Int32($0) : nil }
        guard title != nil || artist != nil || persistentID != nil || album != nil else { return nil }
        return PlaybackSnapshot.Track(title: title, artist: artist, persistentID: persistentID,
                                      album: album, duration: duration, musicItemID: itemID)
    }
}

private extension NSAppleEventDescriptor {
    func text(_ key: OSType) -> String? {
        guard let field = forKeyword(key), field.descriptorType != typeNull,
              field.typeCodeValue != cMissingValue,
              let text = field.stringValue, !text.isEmpty else { return nil }
        return text
    }

    var number: Double? {
        guard let value = coerce(toDescriptorType: typeIEEE64BitFloatingPoint)?.doubleValue,
              value.isFinite else { return nil }
        return value
    }

    var integer: Int? {
        coerce(toDescriptorType: typeSInt32).map { Int($0.int32Value) }
    }
}

private func musicCode(_ text: StaticString) -> OSType {
    assert(text.utf8CodeUnitCount == 4)
    return text.withUTF8Buffer { bytes in
        bytes.reduce(0) { ($0 << 8) | OSType($1) }
    }
}
