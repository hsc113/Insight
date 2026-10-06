import AppKit

/// The menu-bar presence. Rebuilt from scratch on every open (`menuNeedsUpdate`) so its state
/// can never drift from `Settings` — there are only a handful of items, and correctness matters
/// more than the microseconds.
///
/// **「开机自启」and「历史记录…」were removed on the user's request.** Both still exist, they are
/// just not in this menu any more: launch-at-login has its switch in 通用设置, and history has a
/// whole 历史 page in the settings window. Repeating them here only made the menu longer than the
/// two things it exists to do — fire the two hotkeys and get to the settings.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
	private let statusItem: NSStatusItem
	private let onSelectionTranslate: () -> Void
	private let onSnipTranslate: () -> Void
	private let onToggleSummary: () -> Void
	private let onToggleTranslation: () -> Void
	private let onOpenSettings: () -> Void

	private lazy var summaryItem = NSMenuItem()
	private lazy var translationItem = NSMenuItem()
	private lazy var selectionItem = NSMenuItem()
	private lazy var snipItem = NSMenuItem()

	init(
		onSelectionTranslate: @escaping () -> Void,
		onSnipTranslate: @escaping () -> Void,
		onToggleSummary: @escaping () -> Void,
		onToggleTranslation: @escaping () -> Void,
		onOpenSettings: @escaping () -> Void
	) {
		self.onSelectionTranslate = onSelectionTranslate
		self.onSnipTranslate = onSnipTranslate
		self.onToggleSummary = onToggleSummary
		self.onToggleTranslation = onToggleTranslation
		self.onOpenSettings = onOpenSettings
		statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
		super.init()

		statusItem.button?.image = Self.makeIcon()
		statusItem.button?.toolTip = "Insight"
		statusItem.button?.setAccessibilityLabel("Insight")

		let menu = NSMenu()
		menu.delegate = self
		menu.autoenablesItems = false
		statusItem.menu = menu

		summaryItem.target = self
		summaryItem.action = #selector(toggleSummary)
		translationItem.target = self
		translationItem.action = #selector(toggleTranslation)
		selectionItem.target = self
		selectionItem.action = #selector(selectionTranslate)
		snipItem.target = self
		snipItem.action = #selector(snipTranslate)

		let settingsItem = NSMenuItem(
			title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
		settingsItem.target = self
		let quitItem = NSMenuItem(title: "退出 Insight", action: #selector(quit), keyEquivalent: "q")
		quitItem.target = self

		// Both feature switches sit together at the top, because they are one decision — what the
		// panel is for — expressed as two ticks. They are also the two rows that change their own
		// title (see `menuNeedsUpdate`), which reads as a group rather than as menu noise.
		menu.addItem(summaryItem)
		menu.addItem(translationItem)
		menu.addItem(.separator())
		menu.addItem(selectionItem)
		menu.addItem(snipItem)
		menu.addItem(.separator())
		menu.addItem(settingsItem)
		menu.addItem(.separator())
		menu.addItem(quitItem)
	}

	// MARK: - NSMenuDelegate

	func menuNeedsUpdate(_ menu: NSMenu) {
		let settings = Settings.shared

		// "启用总结" carries its own warning state, so the menu bar is where the user finds
		// out that summary is on but unusable — rather than a mystery error in the panel.
		if settings.summaryEnabled {
			summaryItem.state = settings.summaryReady ? .on : .mixed
			summaryItem.title =
				settings.summaryReady ? "启用总结" : "启用总结（\(settings.summaryBlockedReason ?? "未配置")）"
		} else {
			summaryItem.state = .off
			summaryItem.title = "启用总结"
		}

		// Translation has no key to be missing — every engine either ships with the system or
		// reports its own configuration error inside the panel — so this row is a plain tick.
		translationItem.state = settings.translationEnabled ? .on : .off
		translationItem.title = "启用翻译"

		selectionItem.title = "划词翻译"
		selectionItem.keyEquivalent = ""
		attachShortcut(selectionItem, settings.selectionHotkey)
		snipItem.title = "截图翻译"
		snipItem.keyEquivalent = ""
		attachShortcut(snipItem, settings.snipHotkey)
	}

	private func attachShortcut(_ item: NSMenuItem, _ combo: KeyCombo) {
		item.view = nil
		item.attributedTitle = NSAttributedString(
			string: item.title + "\t" + combo.display,
			attributes: [.font: NSFont.menuFont(ofSize: 0)])
	}

	// MARK: - Actions

	@objc private func toggleSummary() {
		let settings = Settings.shared
		settings.toggleSummary()
		if settings.summaryEnabled, settings.summaryBlockedReason != nil {
			onOpenSettings()
		}
	}

	/// Dropping the last feature is refused, so this is a plain toggle — the refusal lives in
	/// `Settings`, where the segmented control on 通用设置 reaches the same one rule.
	@objc private func toggleTranslation() {
		Settings.shared.toggleTranslation()
	}

	@objc private func selectionTranslate() { onSelectionTranslate() }
	@objc private func snipTranslate() { onSnipTranslate() }
	@objc private func openSettings() { onOpenSettings() }

	@objc private func quit() {
		Settings.shared.saveNow()
		NSApp.terminate(nil)
	}

	/// Menu rows as the user would see them. Used by the self test to catch a blank row, which is
	/// what an `NSMenuItem` created without a title looks like in a menu bar.
	static func debugTitles() -> [String] {
		let probe = MenuBarController(
			onSelectionTranslate: {}, onSnipTranslate: {},
			onToggleSummary: {}, onToggleTranslation: {}, onOpenSettings: {})
		guard let menu = probe.statusItem.menu, let delegate = menu.delegate else { return [] }
		// `menuNeedsUpdate` is an *optional* protocol method, so it has to be called through
		// the question mark even though this class definitely implements it.
		delegate.menuNeedsUpdate?(menu)
		let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
		probe.statusItem.menu = nil
		return titles
	}

	// MARK: - Icon

	/// Same idea as the app icon: one thick bar (summary) above two thin ones (translation).
	/// Drawn as a template image so the menu bar tints it for light/dark automatically.
	private static func makeIcon() -> NSImage {
		let side: CGFloat = 15
		let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
			let path = NSBezierPath()
			let barHeight: CGFloat = 2.2
			let gap: CGFloat = 2.4
			let widths: [CGFloat] = [10.4, 8.8, 6.6]
			let totalHeight = barHeight * 3 + gap * 2
			var y = (side - totalHeight) / 2
			for width in widths {
				let rect = NSRect(x: (side - width) / 2, y: y, width: width, height: barHeight)
				path.appendRoundedRect(rect, xRadius: barHeight / 2, yRadius: barHeight / 2)
				y += barHeight + gap
			}
			NSColor.black.setFill()
			path.fill()
			return true
		}
		image.isTemplate = true
		return image
	}
}