import Foundation

final class MusicService {

    private func execute(_ command: String) -> String {
        let source = """
        tell application "Music"
            \(command)
        end tell
        """

        var error: NSDictionary?

        let script = NSAppleScript(source: source)
        let result = script?.executeAndReturnError(&error)

        if let error = error {
            print("AppleScript Error: \(error)")
            return "Unavailable"
        }

        return result?.stringValue ?? ""
    }

    func playPause() {
        _ = execute("playpause")
    }

    func nextTrack() {
        _ = execute("next track")
    }

    func previousTrack() {
        _ = execute("previous track")
    }

    func getTitle() -> String {
        execute("get name of current track")
    }

    func getArtist() -> String {
        execute("get artist of current track")
    }
}