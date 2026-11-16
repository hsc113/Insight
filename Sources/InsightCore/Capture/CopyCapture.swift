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

	/// The real pasteboard and a real synthetic ⌘C.
	static let live = CopyCapture(
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
			// `.privateState`, not `.hidSystemState`: the hotkey may still be physically held with
			// its own modifiers (⌥D), and the combined state would turn ⌘C into ⌘⌥C. With a private
			// source the flags are exactly the ones set below.
			let source = CGEventSource(stateID: .privateState)
			let down = CGEvent(keyboardEventSource: source, virtualKey: KeyCodeCatalog.c, keyDown: true)
			let up = CGEvent(keyboardEventSource: source, virtualKey: KeyCodeCatalog.c, keyDown: false)
			down?.flags = [.maskCommand]
			up?.flags = [.maskCommand]
			down?.post(tap: .cghidEventTap)
			up?.post(tap: .cghidEventTap)
		},
		readText: { NSPasteboard.general.string(forType: .string) }
	)
}
