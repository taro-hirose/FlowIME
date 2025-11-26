import Cocoa

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Main app bundle identifier (FlowIME)
    private let hostBundleID = "FlowIME-Xcode.FlowIME"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        ensureHost()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.ensureHost()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let b = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier else { return }
            if b == self?.hostBundleID { self?.ensureHost() }
        }
    }

    private func ensureHost() {
        // If already running, nothing to do
        let isRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == hostBundleID }
        guard !isRunning else { return }

        // Resolve main app URL relative to helper bundle location
        var url = Bundle.main.bundleURL
        // Helper is at Host.app/Contents/Library/LoginItems/FlowIMEHelper.app
        for _ in 0..<4 { url.deleteLastPathComponent() } // -> Host.app

        if FileManager.default.fileExists(atPath: url.path) {
            _ = NSWorkspace.shared.open(url)
            NSLog("[Helper] ensure open host at: %@", url.path)
            return
        }

        // Fallback: launch by bundle identifier (if installed elsewhere)
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: hostBundleID) {
            _ = NSWorkspace.shared.open(appURL)
            NSLog("[Helper] ensure open host by bundle id at: %@", appURL.path)
        } else {
            NSLog("[Helper] failed to locate host app")
        }
    }
}
