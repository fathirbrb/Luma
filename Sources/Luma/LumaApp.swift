import SwiftUI

@main
@MainActor
struct LumaApp: App {
    private let music: MusicService
    @StateObject private var playback: PlaybackModel

    init() {
        let music = MusicService()
        self.music = music
        _playback = StateObject(wrappedValue: PlaybackModel(music: music))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(playback: playback, music: music)
                .accentColor(Color(red: 0.57, green: 0.36, blue: 0.83))
        }
        .windowStyle(.titleBar)
    }
}
