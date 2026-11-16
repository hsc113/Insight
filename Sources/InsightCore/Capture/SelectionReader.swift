import AppKit
import ApplicationServices

/// Reads the current text selection.
///
/// The standard three-step cascade for this job, trimmed to what matters: focused element →
/// element under the cursor → `AXSelectedTextMarkerRange` (which is what Safari and every
/// WebKit view actually answers to). No Chrome AppleScript bridge, and no clipboard in this file:
/// apps that expose no selection to Accessibility are handled one level up by `CopyCapture`,
/// which borrows the pasteboard and puts it back.
///
/// # Why the read is off the main thread, and why it is ordered the way it is
///
/// Every Accessibility call here is a **synchronous cross-process IPC**. On a heavy app — Xcode,
/// Chrome, anything Electron — the deepest path in this file was over a hundred round trips, which
/// measures at 30–400 ms and occasionally over a second. It used to run inside a `CGEventTap`
/// callback, and this tap is a `.defaultTap`: the entire system input pipeline is blocked until the
/// callback returns. That is the whole reason ⌥D felt unresponsive, and it is why the window only
/// appeared *after* the slowest part of the work.
///
/// So the read is `nonisolated` and takes the cursor position as a value. The caller samples
/// `NSEvent.mouseLocation` on the main actor — it has to, the pointer may have moved by the time a
/// background hop completes — and everything after that is a pure function of the AX tree.
///
/// The attempt order is cheapest-and-most-likely first, which is not the order it used to be in:
///
/// 1. focused element, `AXSelectedText` — one IPC, and correct in every native text control
/// 2. element under the cursor — one more IPC, correct when focus is elsewhere (a selection being
///    dragged in a window that isn't frontmost)
/// 3. the focused element's direct children, depth 1 — where WebKit keeps it
/// 4. the cursor element's direct children, depth 1
/// 5. the focused element's children, depth 2 — the expensive fallback, now last
///
/// The old order put step 5 *second*, so every WebKit page and every Electron document paid the
/// full tree walk before the one cheap call that would have answered it. `walkBudget` additionally
/// caps the total time: an unbounded AX walk on a pathological tree would otherwise hold the input
/// queue for as long as the slowest app took to answer, and a timeout that returns nothing is always
/// better than a stall.
enum SelectionReader {
	private static let kMarkerRange = "AXSelectedTextMarkerRange"
	private static let kStringForMarkerRange = "AXStringForTextMarkerRange"

	/// How deep the fallback tree walk goes. Two levels is what a WebKit selection needs; going
	/// deeper only adds IPC.
	static let maxDepth = 2
	/// Children inspected per level. 24/12 used to be tried across both passes, which is 36 AX calls
	/// before recursion even starts.
	static let breadth = 12
	/// Wall-clock ceiling for the whole read. Generous enough for a cold Xcode, short enough that a
	/// hostile app cannot make the hotkey feel broken.
	static let walkBudget: DispatchTimeInterval = .milliseconds(120)

	/// A cursor position sampled on the main actor.
	///
	/// `NSEvent.mouseLocation` has to be read on the main thread and *at press time*: the pointer
	/// will have moved by the time a background hop completes, and the element under the old
	/// position is the one that holds the selection.
	struct CursorSnapshot: Sendable {
		var appKitX: Double
		var appKitY: Double
		/// Height of the primary display, used to convert AppKit's bottom-left origin into the AX
		/// API's top-left one.
		var primaryHeight: Double

		@MainActor
		static func current() -> CursorSnapshot? {
			guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero })
			else { return nil }
			let cursor = NSEvent.mouseLocation
			return CursorSnapshot(
				appKitX: cursor.x, appKitY: cursor.y, primaryHeight: primary.frame.height)
		}
	}

	/// - Returns: the trimmed selection, or `nil` if nothing usable was selected.
	nonisolated static func selectedText(cursor: CursorSnapshot?) -> String? {
		guard AXIsProcessTrusted() else { return nil }
		let deadline = DispatchTime.now() + walkBudget
		let system = AXUIElementCreateSystemWide()

		var focused: AXUIElement?
		if let element = elementAttribute(system, kAXFocusedUIElementAttribute) {
			focused = readable(element)
			if let focused, let text = selectedText(from: focused) { return clean(text) }
		}

		let underCursor = readable(elementUnderCursor(cursor))

		// Cheap, and the one that answers for a selection being dragged in a window that is not
		// frontmost.
		if let underCursor, underCursor != focused {
			if let text = selectedText(from: underCursor) { return clean(text) }
		}

		// Web views and table cells keep the selection on a descendant rather than on the element
		// that reports focus.
		if let focused, let text = selectedTextInChildren(of: focused, depth: 1, deadline: deadline) {
			return clean(text)
		}
		if let underCursor,
			let text = selectedTextInChildren(of: underCursor, depth: 1, deadline: deadline)
		{
			return clean(text)
		}

		// The expensive one, last: only reached when every single-call attempt came up empty.
		if let focused, let text = selectedTextInChildren(of: focused, depth: maxDepth, deadline: deadline) {
			return clean(text)
		}

		return nil
	}

	/// The main-thread convenience, for callers that are not on the hot path (the self test).
	@MainActor
	static func selectedText() -> String? {
		selectedText(cursor: .current())
	}

	// MARK: - AX plumbing

	/// Drops elements that belong to **this** process.
	///
	/// Insight's own panel is an Accessibility client like any other text view, so clicking into a
	/// result and selecting a word makes *our* text view the focused element — and the naive read
	/// then dutifully hands the panel's own output back as the "selection", which is why this file
	/// used to need a separate `isPanelFocused()` special case in `AppController` before it read
	/// anything. Comparing pids removes the need for that ordering entirely: the document selection
	/// always wins, and "the user selected something inside the panel" becomes simply *no selection
	/// outside Insight*, which the caller can ask about separately and cheaply.
	private static func readable(_ element: AXUIElement?) -> AXUIElement? {
		guard let element else { return nil }
		var pid: pid_t = 0
		guard AXUIElementGetPid(element, &pid) == .success else { return nil }
		return pid == getpid() ? nil : element
	}

	private static func elementAttribute(
		_ element: AXUIElement, _ attribute: String
	) -> AXUIElement? {
		var value: CFTypeRef?
		guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
			let value
		else { return nil }
		return (value as! AXUIElement)
	}

	private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
		var value: CFTypeRef?
		guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
			return nil
		}
		return value as? String
	}

	private static func valueAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
		var value: CFTypeRef?
		guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
			return nil
		}
		return value
	}

	private static func arrayAttribute(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
		var value: CFTypeRef?
		guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
			let array = value as? [AXUIElement]
		else { return [] }
		return array
	}

	/// Converts AppKit's bottom-left cursor position into the Accessibility API's top-left
	/// global space, which is measured from the top of the *primary* display.
	private static func elementUnderCursor(_ cursor: CursorSnapshot?) -> AXUIElement? {
		guard let cursor else { return nil }
		let axX = Float(cursor.appKitX)
		let axY = Float(cursor.primaryHeight - cursor.appKitY)
		var element: AXUIElement?
		let status = AXUIElementCopyElementAtPosition(
			AXUIElementCreateSystemWide(), axX, axY, &element)
		guard status == .success else { return nil }
		return element
	}

	// MARK: - Selection extraction

	private static func selectedText(from element: AXUIElement) -> String? {
		if let text = stringAttribute(element, kAXSelectedTextAttribute as String),
			!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		{
			return text
		}
		return markerRangeText(from: element)
	}

	private static func markerRangeText(from element: AXUIElement) -> String? {
		guard let range = valueAttribute(element, kMarkerRange) else { return nil }
		var value: CFTypeRef?
		let status = AXUIElementCopyParameterizedAttributeValue(
			element, kStringForMarkerRange as CFString, range, &value)
		guard status == .success else { return nil }
		return value as? String
	}

	/// Breadth-first, with a wall-clock check between siblings.
	///
	/// Breadth-first rather than depth-first on purpose: the direct children are the ones that
	/// matter, and a depth-first pass that dives into the first subtree can spend the whole budget
	/// without ever looking at a sibling of the node that is actually the text view.
	private static func selectedTextInChildren(
		of element: AXUIElement, depth: Int, deadline: DispatchTime
	) -> String? {
		guard depth > 0 else { return nil }
		var level = arrayAttribute(element, kAXChildrenAttribute as String)
		// Bounded so a pathological tree (a huge spreadsheet, a long document) can never stall the
		// hotkey path even when the app answers instantly.
		level = Array(level.prefix(breadth))

		for remaining in stride(from: depth - 1, through: 0, by: -1) {
			if DispatchTime.now() >= deadline { return nil }
			var next: [AXUIElement] = []
			for child in level {
				if let text = selectedText(from: child), !text.isEmpty { return text }
			}
			if remaining == 0 { break }
			for child in level {
				guard DispatchTime.now() < deadline else { return nil }
				next.append(contentsOf: arrayAttribute(child, kAXChildrenAttribute as String).prefix(breadth))
			}
			level = next
		}
		return nil
	}

	// MARK: - Cleanup

	static func clean(_ text: String) -> String? {
		var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
		// Selections dragged across wrapped lines arrive with a newline per visual row.
		// Collapse runs of them so the LLM prompt isn't shredded.
		while result.contains("\n\n\n") {
			result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
		}
		return result.isEmpty ? nil : result
	}
}