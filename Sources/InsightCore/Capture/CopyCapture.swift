import AppKit

/// Reading the selection by pressing ⌘C for the user — the fallback for apps whose Accessibility
/// tree does not expose `AXSelectedText` (most Chromium pages, Electron apps, PDF viewers, WeChat).
///
/// `SelectionReader` answers first and for free. This only runs when it came up empty, and without
/// it that case used to end in the clipboard fallback — which translates whatever the user copied
/// *last time*, not the text they just dragged over. That is the "I selected something, pressed F3,
/// and it translated something else" bug.
///
/// # Why the old "no forced ⌘C" objection does not apply here
///
/// It was written when a background clipboard watcher also ran: the watcher saw our own ⌘C and
/// popped the panel again, and the two fought the user's own ⌘C. The watcher is gone, nothing
/// observes the pasteboard any more, and this runs only on an explicit F3 press. What is left of
/// the objection is "don't leave the user's clipboard clobbered", which is what the snapshot and
/// restore are for.
///
/// # Shape
///
/// 1. Snapshot every item on the pasteboard, every type — not just the string, or a copied image or
///    file would come back as nothing.
/// 2. Post ⌘C and wait for `changeCount` to move. **The pasteboard is not cleared first**: if the app
///    copies nothing (no selection), the user's clipboard was never touched and there is nothing to
///    restore, which is the failure mode that cannot lose data.
/// 3. Read the text, then put the snapshot back.
///
/// The side effects are closures so the order of operations can be checked without a real target app.
struct CopyCapture: Sendable {
	typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]

	var changeCount: @Sendable () -> Int
	var snapshot: @Sendable () -> Snapshot
	var restore: @Sendable (Snapshot) -> Void
	var sendCopy: @Sendable () -> Void
	var readText: @Sendable () -> String?
	/// How long to wait for the target app to answer ⌘C. Slow apps (a cold Electron window) need
	/// well over 100 ms; an app with no selection never answers, so this is also the cost of
	/// "nothing selected" and has to stay short enough to feel like the usual empty answer.
	var timeout: TimeInterval = 0.35
	var pollInterval: TimeInterval = 0.015

	/// - Returns: the cleaned selection, or `nil` when the app copied nothing.
	/// Blocks for up to `timeout`; call it off the main thread.
	func selectedText() -> String? {
		let before = changeCount()
		let saved = snapshot()
		sendCopy()

		let deadline = Date().addingTimeInterval(timeout)
		while changeCount() == before {
			if Date() >= deadline { return nil }
			Thread.sleep(forTimeInterval: pollInterval)
		}

		let text = readText()
		restore(saved)
		return text.flatMap(SelectionReader.clean)
	}

	/// The process that should receive ⌘C: the frontmost app, unless that is us (or unknown), in
	/// which case there is no one to address and the event goes to the HID tap instead.
	///
	/// **Why the event is addressed to a process at all.** The panel is shown — and made key — before
	/// the selection is read, and a `.nonactivatingPanel` that is key receives keystrokes even though
	/// the app that owns it is not active. A ⌘C posted to the HID tap therefore lands in *our own
	/// panel*, copies nothing, and the capture falls through to the stale clipboard: the "I selected
	/// something and it translated what I copied last time" bug. Measured against TextEdit with a key
	/// panel on screen: HID-tap delivery (with either event-source state) changed the pasteboard 0
	/// times out of 2, `postToPid` 1 out of 1.
	static func targetPID(frontmost: pid_t?, own: pid_t) -> pid_t? {
		guard let frontmost, frontmost != own else { return nil }
		return frontmost
	}

	/// The real pasteboard and a real synthetic ⌘C, addressed to `targetPID` when there is one.
	/// Sampled by the caller on the main actor, at press time, for the same reason the cursor is:
	/// it is a fact about the moment of the press.
	static func live(targetPID: pid_t?) -> CopyCapture {
		CopyCapture(
			changeCount: { NSPasteboard.general.changeCount },
			snapshot: {
				(NSPasteboard.general.pasteboardItems ?? []).map { item in
					var entry: [NSPasteboard.PasteboardType: Data] = [:]
					for type in item.types {
						if let data = item.data(forType: type) { entry[type] = data }
					}
					return entry
				}
			},
			restore: { saved in
				let pasteboard = NSPasteboard.general
				pasteboard.clearContents()
				let items = saved.map { entry -> NSPasteboardItem in
					let item = NSPasteboardItem()
					for (type, data) in entry { item.setData(data, forType: type) }
					return item
				}
				if !items.isEmpty { pasteboard.writeObjects(items) }
			},
			sendCopy: {
				// `.hidSystemState` with explicit flags, the same source the proven ⌘V write-back
				// uses. The hotkey's own modifiers cannot leak in through `postToPid`, which does not
				// merge the physical modifier state.
				let source = CGEventSource(stateID: .hidSystemState)
				let down = CGEvent(keyboardEventSource: source, virtualKey: KeyCodeCatalog.c, keyDown: true)
				let up = CGEvent(keyboardEventSource: source, virtualKey: KeyCodeCatalog.c, keyDown: false)
				down?.flags = [.maskCommand]
				up?.flags = [.maskCommand]
				if let targetPID {
					down?.postToPid(targetPID)
					up?.postToPid(targetPID)
				} else {
					down?.post(tap: .cghidEventTap)
					up?.post(tap: .cghidEventTap)
				}
			},
			readText: { NSPasteboard.general.string(forType: .string) }
		)
	}

	/// Snapshot / restore only — for checks that never send a key.
	static var live: CopyCapture { live(targetPID: nil) }
}
