import Cocoa

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private let viewModel = UsageViewModel()
    private let notifyMonitor = AgentNotifyMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !terminateIfAlreadyRunning() else { return }
        statusBarController = StatusBarController(viewModel: viewModel)
        statusBarController?.setup()
        viewModel.startMonitoring()
        AgentNotifySettingsMigrator.migrateIfNeeded()
        notifyMonitor.start()
        registerLoginItemIfNeeded()
        syncLoginItemState()
    }

    /// Terminate this instance if another copy is already running.
    /// Returns `true` if this process should exit.
    private func terminateIfAlreadyRunning() -> Bool {
        // Skip during unit tests — test host shares the bundle identifier.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return false
        }

        let others = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? ""
        ).filter { $0 != .current }

        guard !others.isEmpty else { return false }
        NSApp.terminate(nil)
        return true
    }

    /// On first launch, register as a login item when the default is enabled.
    private func registerLoginItemIfNeeded() {
        let defaults = UserDefaults.standard
        let key = "launchAtLogin"
        // Only act on first launch (key not yet written by user)
        guard defaults.object(forKey: key) == nil else { return }
        defaults.set(true, forKey: key)
        try? LoginItemManager.setEnabled(true)
    }

    /// Keep the actual login-item registration in sync with the stored preference.
    /// Covers cases where registration failed on an earlier launch (e.g. the app
    /// was running from a build directory instead of /Applications).
    private func syncLoginItemState() {
        let defaults = UserDefaults.standard
        let key = "launchAtLogin"
        guard defaults.object(forKey: key) != nil else { return }

        let enabled = defaults.bool(forKey: key)
        do {
            if enabled, !LoginItemManager.isEnabled {
                try LoginItemManager.setEnabled(true)
            } else if enabled, LoginItemManager.isEnabled {
                // Re-register so the login item points at this copy of the app
                // (e.g. after moving from a build directory to /Applications).
                try LoginItemManager.setEnabled(false)
                try LoginItemManager.setEnabled(true)
            } else if !enabled, LoginItemManager.isEnabled {
                try LoginItemManager.setEnabled(false)
            }
        } catch {
            // Ignore — the next launch retries.
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        viewModel.stopMonitoring()
        notifyMonitor.stop()
    }
}
