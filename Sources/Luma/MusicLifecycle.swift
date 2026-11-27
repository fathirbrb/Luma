import AppKit

enum MusicLifecycle {
    static func readyProcessID() -> pid_t? {
        guard let app = runningApplication(), app.isFinishedLaunching else { return nil }
        return app.processIdentifier
    }

    @MainActor
    static func prepare() async throws -> pid_t {
        let app: NSRunningApplication
        if let running = runningApplication() {
            app = running
        } else {
            let workspace = NSWorkspace.shared
            guard let url = workspace.urlForApplication(withBundleIdentifier: MusicService.bundleID) else {
                throw MusicError.notRunning
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.hides = true
            configuration.addsToRecentItems = false
            configuration.promptsUserIfNeeded = false
            app = try await workspace.openApplication(at: url, configuration: configuration)
        }

        return try await waitUntilReady(app)
    }

    @MainActor
    static func waitUntilReady(processID: pid_t) async throws {
        guard let app = NSRunningApplication(processIdentifier: processID),
              app.bundleIdentifier == MusicService.bundleID else { throw MusicError.notRunning }
        _ = try await waitUntilReady(app)
    }

    @MainActor
    private static func waitUntilReady(_ app: NSRunningApplication) async throws -> pid_t {
        // Workspace can report a launch before Music can process events.
        for _ in 0..<50 {
            try Task.checkCancellation()
            guard !app.isTerminated else { throw MusicError.notRunning }
            if app.isFinishedLaunching { return app.processIdentifier }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw MusicError.timedOut
    }

    private static func runningApplication() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: MusicService.bundleID)
            .first(where: { !$0.isTerminated })
    }
}
