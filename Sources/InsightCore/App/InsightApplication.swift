import AppKit

public enum InsightApplication {
	/// Boots the accessory app. Deliberately not the SwiftUI `App` lifecycle: a programmatic
	/// `NSApplication` with one delegate is measurably cheaper to start (no scene graph, no
	/// `WindowGroup`, no `MenuBarExtra` bridging) and gives direct ownership of the two windows
	/// we do have.
	@MainActor
	public static func run() {
		if CommandLine.arguments.contains("--e2e") {
			let app = NSApplication.shared
			// The main menu is part of what is under test here, not just for the running app.
			AppMenu.install()
			app.setActivationPolicy(.accessory)
			// Needs a live run loop: it injects key events, activates windows and waits on the
			// network, none of which can complete before `run()`.
			let delegate = AppDelegate()
			app.delegate = delegate
			withExtendedLifetime(delegate) {
				Task { @MainActor in
					try? await Task.sleep(nanoseconds: 500_000_000)
					await E2ETest.run()
				}
				app.run()
			}
			return
		}

		let app = NSApplication.shared
		// Installed before the delegate so the Edit menu exists by the time any window can be
		// focused — without it ⌘X/⌘C/⌘V do nothing, because those travel the main menu.
		AppMenu.install()

		let delegate = AppDelegate()
		// NSApplication.delegate is weak, so the delegate is retained here for the lifetime of
		// the run loop.
		withExtendedLifetime(delegate) {
			app.delegate = delegate
			app.setActivationPolicy(.accessory)
			app.run()
		}
	}
}