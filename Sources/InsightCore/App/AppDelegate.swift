import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
	private var menuBar: MenuBarController?

	func applicationDidFinishLaunching(_ notification: Notification) {
		Settings.shared.applyAppearance()
		AppController.shared.start()

		if CommandLine.arguments.contains("--selftest") {
			// Must run inside the run loop: it injects key events and waits on network replies,
			// neither of which can complete if the main thread is blocked before `app.run()`.
			Task { @MainActor in
				try? await Task.sleep(nanoseconds: 400_000_000)
				await SelfTest.run()
			}
		}
		menuBar = MenuBarController(
			onSelectionTranslate: { AppController.shared.selectionTranslate() },
			onSnipTranslate: { AppController.shared.snipTranslate() },
			onToggleSummary: { Settings.shared.toggleSummary() },
			onToggleTranslation: { Settings.shared.toggleTranslation() },
			onOpenSettings: { SettingsWindowController.shared.show() })
	}

	func applicationWillTerminate(_ notification: Notification) {
		Settings.shared.saveNow()
		// The ledger debounces, so a run that finished in the last half second would otherwise be
		// lost on quit — and quitting is exactly when someone quits: right after a result arrived.
		UsageLedger.shared.saveNow()
	}

	func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}