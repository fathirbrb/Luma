import SwiftUI

struct ContentView: View {

    private let music = MusicService()

    @State private var title = "No track"
    @State private var artist = "Unknown artist"

    var body: some View {
        VStack(spacing: 24) {

            Image(systemName: "music.note")
                .font(.system(size: 65))
                .foregroundColor(.purple)

            Text(title)
                .font(.title2)
                .fontWeight(.semibold)

            Text(artist)
                .foregroundColor(.secondary)

            HStack(spacing: 30) {

                Button {
                    music.previousTrack()
                    refresh()
                } label: {
                    Image(systemName: "backward.fill")
                }

                Button {
                    music.playPause()
                    refresh()
                } label: {
                    Image(systemName: "playpause.fill")
                }

                Button {
                    music.nextTrack()
                    refresh()
                } label: {
                    Image(systemName: "forward.fill")
                }
            }
            .font(.system(size: 24))
            .buttonStyle(.plain)

            Button("Refresh") {
                refresh()
            }

        }
        .padding(30)
        .frame(minWidth: 400, minHeight: 320)
    }

    private func refresh() {
        title = music.getTitle()
        artist = music.getArtist()
    }
}