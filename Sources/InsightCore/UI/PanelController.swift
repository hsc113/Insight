import AppKit
import Observation
import SwiftUI

/// Everything the result panel renders. Kept separate from `PanelController` so the SwiftUI
/// view observes plain properties while window and event handling stay in AppKit.
@MainActor
@Observable
final class PanelModel {
	var input = ""
	var draft = ""
	var inputExpanded = false
	var hint: String?
	var permission: Permissions.Permission?
	var isPinned = false
	/// Non-nil while Insight is still working out what was selected — reading the Accessibility
	/// tree for 划词, running Vision for 截图.
	///
	/// This is what makes the panel come up *before* the text is known. The window used to appear
	/// only after the slow part had finished, so every press read as "nothing happened" for a third
	/// of a second. Now it appears on the keypress and the label fills in.
	var captureLabel: String?
	/// A short, self-clearing notice. **Separate from `hint`** because `hint` is the empty state's
	/// placeholder — it only renders when there is no input — and a notice that wiped the previous
	/// answer would throw away work the user already paid for.
	var transientHint: String?
	var noticeToken = 0
	/// Set when the user edits the input and the collapsed preview needs to refresh.
	let pipeline = InsightPipeline()

	private var noticeTask: Task<Void, Never>?

	var isCapturing: Bool { captureLabel != nil }

	func present(text: String?) {
		permission = nil
		captureLabel = nil
		noticeTask?.cancel()
		transientHint = nil
		if let text {
			hint = nil
			input = text
			draft = text
			inputExpanded = false
			pipeline.run(text)
		} else {
			hint = "没有检测到文字"
			input = ""
			draft = ""
			inputExpanded = true
			pipeline.cancel()
		}
	}

	/// A capture has started. The previous result is left exactly where it is: it is about to be
	/// replaced, and if the read fails the user keeps the last answer instead of an empty panel.
	func beginCapture(label: String) {
		noticeTask?.cancel()
		transientHint = nil
		captureLabel = label
	}

	/// The capture finished, with or without text.
	func endCapture(hint message: String? = nil) {
		captureLabel = nil
		notice(message)
	}

	/// A short, self-clearing message about something that just happened — "已经写回去了",
	/// "没有检测到选中的文字". Never touches `input`, `summary` or `translation`: a message that
	/// wiped the answer the user was reading would be worse than no message.
	func notice(_ message: String?) {
		guard let message, !message.isEmpty else { return }
		transientHint = message
		// Token, not just a cancel: a notice raised *during* the wait must not be cleared by the
		// notice that was already scheduled when it was raised.
		noticeToken += 1
		let token = noticeToken
		noticeTask?.cancel()
		noticeTask = Task { [weak self] in
			try? await Task.sleep(nanoseconds: 1_600_000_000)
			guard !Task.isCancelled, let self, self.noticeToken == token else { return }
			self.transientHint = nil
		}
	}

	func presentPermission(_ permission: Permissions.Permission) {
		self.permission = permission
		hint = nil
		inputExpanded = false
		pipeline.cancel()
	}

	func expandInput() {
		draft = input
		inputExpanded = true
	}

	func collapseInput() {
		inputExpanded = false
	}

	/// Re-runs with whatever is currently in the editor.
	func applyDraft() {
		let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty else { return }
		input = text
		inputExpanded = false
		hint = nil
		pipeline.run(text)
	}

	func retry() {
		guard !input.isEmpty else { return }
		hint = nil
		pipeline.run(input)
	}

	/// Changing a language re-runs both chains against the current input, rather than waiting for
	/// the next hotkey press: the user changed the request, so showing the old answer would be
	/// stale rather than merely old. Input the pipeline can't re-run (a permission prompt, an OCR
	/// failure) has nothing to re-run, so it just leaves the setting to take effect next time.
	func setSourceLanguage(_ id: String) {
		guard Settings.shared.sourceLanguage != id else { return }
		Settings.shared.sourceLanguage = id
		Settings.shared.commit()
		retry()
	}

	func setTargetLanguage(_ id: String) {
		guard Settings.shared.targetLanguage != id else { return }
		Settings.shared.targetLanguage = id
		Settings.shared.commit()
		retry()
	}

	/// First few characters and last few characters — the user asked to see the ends of the
	/// input rather than a middle truncation, so they can tell whether the selection is what
	/// they think it is.
	var collapsedPreview: String {
		let head = 22
		let tail = 22
		guard input.count > head + tail else { return input }
		return String(input.prefix(head)) + " … " + String(input.suffix(tail))
	}
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
	static let shared = PanelController()

	let model = PanelModel()
	let panel: NSPanel

	private var globalMonitor: Any?
	private var localMonitor: Any?
	private var localClickMonitor: Any?
	private var hasPresentedOnce = false
	/// Bumped for every capture. See `beginCapture`.
	private var captureGeneration = 0

	private override init() {
		let settings = Settings.shared

		panel = NSPanel(
			contentRect: Self.restoredFrame(),
			styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
			backing: .buffered,
			defer: true)

		super.init()

		// A plain resizable NSPanel. Dropping drag-resize and allowing only width dragging would
		// force the app to predict content height and animate the frame; letting the scroll view
		// clip instead means no such prediction subsystem exists at all.
		panel.titleVisibility = .hidden
		panel.titlebarAppearsTransparent = true

		// Hide the three traffic lights. `.titled` and `.resizable` have to stay in the style mask
		// — they are what lets the system resize and move the window — so the buttons themselves
		// are hidden rather than the chrome being dropped. The header supplies its own close
		// button, and Esc / ⌘W still work because `.closable` is still set.
		for button in [
			panel.standardWindowButton(.closeButton),
			panel.standardWindowButton(.miniaturizeButton),
			panel.standardWindowButton(.zoomButton),
		] {
			button?.isHidden = true
		}
		// Deliberately NOT `isMovableByWindowBackground`. It looks like the cheap way to let the
		// panel be dragged from anywhere, and it was — until the divider arrived. The hosting view
		// is a single `NSView`, so AppKit starts a window drag the moment a mouse-down lands on it,
		// before SwiftUI's gesture recogniser has decided anything: dragging the split handle moved
		// the *window* instead of the split. The top bar drags the window instead, which is what a
		// title bar is for, and it has the side benefit that selecting text inside a card can no
		// longer drag the panel out from under the pointer.
		panel.isMovableByWindowBackground = false
		panel.hidesOnDeactivate = false
		panel.isReleasedWhenClosed = false
		panel.becomesKeyOnlyIfNeeded = false
		panel.level = .floating
		panel.collectionBehavior = [
			.transient, .ignoresCycle, .fullScreenAuxiliary, .moveToActiveSpace,
		]
		panel.minSize = NSSize(width: 380, height: 260)
		panel.delegate = self
		panel.isRestorable = false
		panel.hidesOnDeactivate = false
		// Nothing animates a frame change. The default is `.documentWindow`, and a programmatic
		// `setFrame` under it eases rather than snaps — which is exactly the "一跳一跳" look if any
		// code path ever animates a move. Declaring `.none` removes the whole class of problem.
		panel.animationBehavior = .none
		panel.setAccessibilityLabel("Insight 翻译结果")

		// `PanelHostingView`, not a bare `NSHostingView`: the top bar's window drag is AppKit's.
		// See that file for why a SwiftUI `DragGesture` tracked the pointer at half speed.
		let hosting: PanelHostingView<ResultView> = PanelHostingView(
			rootView: ResultView(model: model, panel: panel))
		hosting.autoresizingMask = [.width, .height]
		panel.contentView = hosting

		model.isPinned = settings.pinWindow
		applyLevel()
		installMonitors()
	}

	// MARK: - Presentation

	func present(text: String?) {
		model.present(text: text)
		show()
	}

	/// A small popover for looking up a word selected inside the result. Separate from the main
	/// panel on purpose: replacing the whole panel with a one-word lookup loses the translation
	/// the user was reading.
	func lookup(word: String) {
		let model = self.model
		model.pipeline.cancel()
		lookupOverlay?.removeFromSuperview()

		let pipeline = model.pipeline
		pipeline.run(word)

		let card = LookupCard(word: word, pipeline: pipeline) { [weak self] in
			self?.lookupOverlay?.removeFromSuperview()
			self?.lookupOverlay = nil
		}
		embed(card)
	}

	private func embed<Content: View>(_ view: Content) {
		let hosting = NSHostingView(rootView: AnyView(view))
		let container = NSView(frame: panel.contentView?.bounds ?? .zero)
		container.autoresizingMask = [.width, .height]
		hosting.frame = container.bounds
		hosting.autoresizingMask = [.width, .height]
		container.addSubview(hosting)
		panel.contentView?.addSubview(container)
		lookupOverlay = container
	}

	private var lookupOverlay: NSView?

	// MARK: - 写回原文

	/// Writes the translation over the selection in the source document — also known as
	/// 「翻译并替换」 or 「静默划词翻译」.
	///
	/// The text comes from the pipeline, not from a copy kept elsewhere. There used to be a
	/// `Settings.lastTranslation` for exactly this, and it was **never assigned** — the field was
	/// cleared at the start of every run and read on the write-back path, and nothing in between ever
	/// wrote it, so the feature silently did nothing. A second copy of the translation is the bug:
	/// the pipeline is the only thing that holds the streamed text, and `PanelController` owns the
	/// pipeline. Reading it from there cannot drift, and there is nothing left to forget.
	///
	/// The outcome is asynchronous — the panel has to go away before the synthetic ⌘V, and the
	/// Accessibility write takes its own moment — so it comes back as a notice instead of a return
	/// value. The old code returned `.replaced(characterCount: 0)` immediately and dropped the real
	/// result on the floor, which meant a failure to write back was indistinguishable from success.
	func replaceSelectionWithTranslation() {
		// Read before `hide()`: the panel is not torn down on hide, but the guard needs a value and it
		// is clearer to take it up front.
		let text = model.pipeline.translation
		guard Self.canWriteBack(text) else {
			model.notice("还没有译文可以写回")
			return
		}
		hide()

		// Let the panel go away before synthesising the keystroke. Two reasons, and the second one
		// is the real one: Insight would otherwise receive its own ⌘V, and `SelectionWriter` asks
		// the Accessibility API for the **focused element** — which, while our panel still holds key
		// status, would be our own text view rather than the document.
		Task { @MainActor in
			try? await Task.sleep(nanoseconds: 150_000_000)
			let outcome = SelectionWriter.replaceSelection(with: text)
			model.notice(outcome.message)
		}
	}

	/// Whether `text` is worth writing over someone's selection.
	///
	/// Empty — or whitespace, which an engine can return when it has nothing to say — must never be
	/// written: it would replace the user's words with nothing at all, and that is the one failure
	/// mode this feature has that does not announce itself. The same predicate gates
	/// 「关闭窗口时复制译文」, because "is there a translation" is one question with two answers.
	///
	/// `nonisolated` so `translationToCopyOnClose` can stay a pure function of its two arguments —
	/// which is what makes the policy assertable without touching the pasteboard.
	nonisolated static func canWriteBack(_ text: String) -> Bool {
		!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
	}

	/// Whether there is anything to write back. Drives the button's enabled state, and shares its
	/// predicate with the guard in `replaceSelectionWithTranslation` so they cannot disagree.
	var canReplaceSelection: Bool {
		Self.canWriteBack(model.pipeline.translation)
	}

	func presentPermissions(_ permission: Permissions.Permission) {
		model.presentPermission(permission)
		show()
	}

	// MARK: - Capture

	/// Marks a capture in flight and puts the window up **before** the text is known.
	///
	/// This is the ordering the whole hotkey path is built around. `ClipboardWriter` then feeds the
	/// panel and the pipeline starts, all of which happen after the Accessibility read returns — so
	/// the three things the user perceives as one action (copy, window, analysis) are: window
	/// immediately, copy and analysis a few tens of milliseconds later, with the panel already on
	/// screen to receive them.
	///
	/// - Returns: A token for `isCurrentCapture`. A read that has since been superseded is dropped
	///   rather than replacing fresher content — pressing ⌥D twice quickly must not let the slower
	///   first read land second.
	@discardableResult
	func beginCapture(label: String) -> Int {
		captureGeneration += 1
		let token = captureGeneration
		model.beginCapture(label: label)
		// `show()` is a no-op in the ordering sense when the panel is already up: it never calls
		// `orderOut`, so an open panel is updated in place instead of hidden and re-shown. That
		// matters because the global mouse monitor will have hidden it on the mouse-down that
		// started the selection, and hide-then-show across two runloop turns is a visible flash
		// plus a full SwiftUI re-layout.
		show()
		return token
	}

	func isCurrentCapture(_ token: Int) -> Bool { token == captureGeneration }

	/// The capture finished without usable text.
	func endCapture(hint message: String? = nil) {
		model.endCapture(hint: message)
	}

	/// A selection made inside the panel's own result.
	///
	/// Bounded breadth-first rather than two hardcoded levels. The old walk was
	/// `contentView.subviews.flatMap { $0.subviews }`, which reaches exactly two levels of the
	/// SwiftUI view tree — and SwiftUI nests deeper than that, so the `NSTextView` was usually not
	/// found at all and the lookup silently did nothing.
	///
	/// - Returns: `nil` unless there really is a short selection inside the panel; a whole
	///   paragraph selected by accident is not a word lookup.
	func selectedTextInsidePanel() -> String? {
		guard let root = panel.contentView else { return nil }
		var level = [root]
		var visited = 0
		for _ in 0..<Self.panelWalkDepth {
			var next: [NSView] = []
			for view in level {
				visited += 1
				guard visited <= Self.panelWalkLimit else { return nil }
				if let text = selectedText(in: view) { return text }
				next.append(contentsOf: view.subviews.prefix(Self.panelWalkBreadth))
			}
			level = next
			if level.isEmpty { break }
		}
		return nil
	}

	/// Deep enough for SwiftUI's own nesting, shallow enough that a pathological hierarchy cannot
	/// stall the keypress.
	private static let panelWalkDepth = 6
	private static let panelWalkBreadth = 8
	private static let panelWalkLimit = 200

	private func selectedText(in view: NSView) -> String? {
		guard let textView = view as? NSTextView else { return nil }
		let range = textView.selectedRange()
		guard range.length > 0 else { return nil }
		let text = (textView.string as NSString).substring(with: range)
			.trimmingCharacters(in: .whitespacesAndNewlines)
		return text.isEmpty || text.count > 120 ? nil : text
	}

	private func show() {
		// Clamp to whichever screen the cursor is on, in case the saved frame now points at a
		// display that isn't attached — shipping a multi-monitor bug here is easy and has
		// happened more than once.
		clampToVisibleScreen()

		if !hasPresentedOnce {
			hasPresentedOnce = true
		}
		installMonitors()
		// `makeKeyAndOrderFront` on a `.nonactivatingPanel` makes it key for text editing
		// without pulling the user out of the app they were reading in.
		panel.makeKeyAndOrderFront(nil)
		updateLevelFromSettings()
	}

	func hide() {
		copyTranslationOnCloseIfAsked()
		panel.orderOut(nil)
		removeMonitors()
	}

	/// 「关闭窗口时复制译文」.
	///
	/// Implemented here rather than on the close button because the setting's promise is about the
	/// panel *going away*, and the panel goes away on Esc, on the ✕, on an outside click and on the
	/// write-back path. Hooking only the ✕ would leave the other four silently not doing it — which
	/// is how this ended up as a toggle with no code behind it at all.
	private func copyTranslationOnCloseIfAsked() {
		guard let text = Self.translationToCopyOnClose(
			autoCopyOnClose: Settings.shared.autoCopyOnClose,
			translation: model.pipeline.translation)
		else { return }
		ClipboardWriter.copy(text)
	}

	/// What 关闭窗口时复制译文 would copy, given the settings and the current translation.
	///
	/// Pure and static so the checker can assert the *policy* instead of trying to observe a
	/// pasteboard side effect — which is what made an earlier version of this check pass for the
	/// wrong reason: the fixture write it compared against had already bumped `changeCount`.
	nonisolated static func translationToCopyOnClose(
		autoCopyOnClose: Bool, translation: String
	) -> String? {
		guard autoCopyOnClose, canWriteBack(translation) else { return nil }
		return translation
	}

	// MARK: - Frame

	private static func restoredFrame() -> NSRect {
		let settings = Settings.shared
		guard !settings.windowFrameString.isEmpty else {
			return defaultFrame(for: settings.windowPlacement)
		}
		let saved = NSRectFromString(settings.windowFrameString)
		guard saved.width > 0, saved.height > 0 else {
			return defaultFrame(for: settings.windowPlacement)
		}
		// "Remembered" honours the stored frame; the other modes recompute it every time, which
		// is what "follow the cursor" means.
		if settings.windowPlacement != .remembered {
			return defaultFrame(for: settings.windowPlacement)
		}
		let clamped = Self.clampToScreen(saved)
		return clamped.width >= 380 && clamped.height >= 260
			? clamped : defaultFrame(for: .remembered)
	}

	private static let defaultSize = CGSize(width: 480, height: 470)

	private static func defaultFrame(for placement: WindowPlacement) -> NSRect {
		let size = defaultSize
		let screen: NSScreen?
		switch placement {
		case .centered:
			screen = NSScreen.main
		case .cursor, .remembered:
			let cursor = NSEvent.mouseLocation
			screen = NSScreen.screens.first { $0.frame.contains(cursor) } ?? NSScreen.main
		}
		guard let visible = screen?.visibleFrame else {
			return NSRect(origin: .zero, size: size)
		}

		let origin: CGPoint
		switch placement {
		case .centered:
			origin = CGPoint(
				x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
		case .cursor:
			// Slightly right of and above the pointer so the panel never covers the text that
			// was just selected.
			let cursor = NSEvent.mouseLocation
			origin = CGPoint(x: cursor.x + 18, y: cursor.y + 24)
		case .remembered:
			origin = CGPoint(x: visible.minX + 24, y: visible.maxY - size.height - 24)
		}
		return clamp(
			NSRect(origin: origin, size: size), to: visible, minimum: defaultSize)
	}

	private static func clamp(
		_ rect: NSRect, to visible: NSRect, minimum: CGSize
	) -> NSRect {
		var result = rect
		result.size.width = max(result.size.width, minimum.width)
		result.size.height = max(result.size.height, minimum.height)
		result.origin.x = min(max(result.origin.x, visible.minX + 8), visible.maxX - result.width - 8)
		result.origin.y = min(max(result.origin.y, visible.minY + 8), visible.maxY - result.height - 8)
		return result
	}

	private static func clampToScreen(_ rect: NSRect) -> NSRect {
		let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main
		guard let visible = screen?.visibleFrame else { return rect }
		var result = rect
		result.size.width = max(result.size.width, 380)
		result.size.height = max(result.size.height, 260)
		result.origin.x = min(max(result.origin.x, visible.minX), visible.maxX - result.width)
		result.origin.y = min(max(result.origin.y, visible.minY), visible.maxY - result.height)
		return result
	}

	private func clampToVisibleScreen() {
		let target = Self.clampToScreen(panel.frame)
		if target != panel.frame {
			panel.setFrame(target, display: true)
		}
	}

	// MARK: - NSWindowDelegate

	// `windowDidMove` used to write the frame straight to `config.json`, which meant one debounced
	// Task scheduled and cancelled per mouse-moved event — sixty to a hundred and twenty times a
	// second, for the whole duration of a drag. The frame is kept in memory instead and written
	// once, on a debounce, so a drag that ends cleanly still saves immediately.

	func windowDidResize(_ notification: Notification) { persistFrameSoon() }
	func windowDidMove(_ notification: Notification) { persistFrameSoon() }

	func windowWillClose(_ notification: Notification) {
		persistFrameNow()
		removeMonitors()
	}

	private var frameSaveTask: Task<Void, Never>?

	private func persistFrameSoon() {
		frameSaveTask?.cancel()
		frameSaveTask = Task { [weak self] in
			try? await Task.sleep(nanoseconds: 400_000_000)
			guard !Task.isCancelled else { return }
			self?.persistFrameNow()
		}
	}

	private func persistFrameNow() {
		frameSaveTask?.cancel()
		frameSaveTask = nil
		Settings.shared.windowFrameString = NSStringFromRect(panel.frame)
		Settings.shared.commit()
	}

	func windowDidResignKey(_ notification: Notification) {
		// Deliberately does *not* hide. Resigning key is not the same as being clicked outside:
		// it also happens when a menu is tracking, when a popover opens, on a space switch, and
		// on any app switch. Hiding here meant the panel closed the instant you opened the
		// language menu inside it — before the menu could act on the click. Outside clicks are
		// detected from the actual mouse events instead, in `handleOutsideClick`.
	}

	// MARK: - Pin / level

	private func applyLevel() {
		// Not `kCGMaximumWindowLevel` — that level covers tooltips.
		panel.level = model.isPinned ? .statusBar : .floating
	}

	private func updateLevelFromSettings() {
		model.isPinned = Settings.shared.pinWindow
		applyLevel()
	}

	func togglePin() {
		model.isPinned.toggle()
		Settings.shared.pinWindow = model.isPinned
		Settings.shared.commit()
		applyLevel()
	}

	// MARK: - Event monitors

	private func installMonitors() {
		guard globalMonitor == nil, localMonitor == nil, localClickMonitor == nil else { return }

		localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
			guard let self else { return event }
			return self.handleKey(event) ? nil : event
		}

		// Clicks inside our own process never reach a *global* monitor, so without this the
		// panel survived a click on the settings window or the status-bar item. Neither
		// `leftMouseDown` nor `rightMouseDown` is swallowed: the click still has to reach
		// whatever the user actually clicked.
		localClickMonitor = NSEvent.addLocalMonitorForEvents(
			matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
		) { [weak self] event in
			MainActor.assumeIsolated { self?.handleOutsideClick(at: Self.screenPoint(of: event)) }
			return event
		}

		globalMonitor = NSEvent.addGlobalMonitorForEvents(
			matching: [.leftMouseDown, .rightMouseDown, .keyDown]
		) { [weak self] event in
			MainActor.assumeIsolated {
				guard let self, self.panel.isVisible else { return }
				if event.type == .keyDown {
					// Esc closes even when the panel has lost key status, which is the behaviour
					// we want. A global observer cannot swallow the event, so Esc also
					// reaches the frontmost app — harmless, and worth the reliability.
					if event.keyCode == 53 { self.hide() }
				} else {
					self.handleOutsideClick(at: Self.screenPoint(of: event))
				}
			}
		}
	}

	private func removeMonitors() {
		for monitor in [globalMonitor, localMonitor, localClickMonitor].compactMap({ $0 }) {
			NSEvent.removeMonitor(monitor)
		}
		globalMonitor = nil
		localMonitor = nil
		localClickMonitor = nil
	}

	/// The click position in AppKit's global screen space, taken from the event itself.
	///
	/// `NSEvent.mouseLocation` is the obvious thing to reach for and is wrong here: it reflects
	/// the *current* pointer position, which has already moved on by the time a monitor callback
	/// runs for a click the user has since dragged elsewhere.
	static func screenPoint(of event: NSEvent) -> NSPoint {
		if let window = event.window {
			return window.convertPoint(toScreen: event.locationInWindow)
		}
		return NSEvent.mouseLocation
	}

	private func handleKey(_ event: NSEvent) -> Bool {
		let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
		switch event.keyCode {
		case 53:  // esc — dismiss the word lookup first, then the panel
			if lookupOverlay != nil {
				lookupOverlay?.removeFromSuperview()
				lookupOverlay = nil
			} else {
				hide()
			}
			return true
		case 36:  // return — analyse, with ⇧ return left as a newline
			return handleReturn(flags)
		case 18:  // R
			if flags.contains(.command) {
				model.retry()
				return true
			}
			return false
		case 35:  // P
			if flags.contains(.command) {
				togglePin()
				return true
			}
			return false
		case 8:  // C, with ⇧ — 写回原文
			// A local monitor only ever sees keys delivered to *this app*, so ⌘⇧C cannot collide
			// with whatever the document app has bound to it (⌘⇧C is Copy Style in Safari). Only the
			// two flags matter here; the plain ⌘C case falls through to `super`, which is how ⌘C keeps
			// working inside the draft editor.
			if flags.contains(.command), flags.contains(.shift) {
				replaceSelectionWithTranslation()
				return true
			}
			return false
		default:
			return false
		}
	}

	/// Return inside the draft editor analyses it; ⇧Return is a newline and must reach the text view.
	///
	/// **Why a local event monitor and not a SwiftUI `.onKeyPress`.** A local monitor is called
	/// *before* the event reaches the responder chain, so returning `true` here means
	/// `NSTextView.insertNewline(_:)` never runs. `.onKeyPress` would be the natural SwiftUI way and
	/// does not work: the text view has already consumed Return by the time SwiftUI sees it. The
	/// alternative — wrapping `NSTextView` in an `NSViewRepresentable` and overriding
	/// `insertNewline(_:)` — works too, but it means giving up SwiftUI's own `TextEditor`, and with
	/// it `.textSelection`, theme following and the binding, for the sake of one key.
	///
	/// The "is the monitor even running?" worry does not apply: the panel's `TextEditor` receives
	/// these keystrokes today, and they only reach it *through* `NSApp.sendEvent`, which is precisely
	/// when local monitors are consulted.
	///
	/// The panel-key guard is not a nicety. Without it, Return pressed in the **settings** window —
	/// whose API-key and prompt fields are text inputs too — would run a translation, because the
	/// monitor sees every key the app receives. The old code had this bug and required ⌘.
	private func handleReturn(_ flags: NSEvent.ModifierFlags) -> Bool {
		guard panel.isKeyWindow, model.inputExpanded else { return false }
		// ⇧Return is a newline; it has to travel on to `insertNewline(_:)`.
		guard !flags.contains(.shift) else { return false }
		// Without this, Return with focus parked on the 收起 button would analyse instead of
		// collapsing.
		guard Self.isTextInputResponder(panel.firstResponder) else { return false }
		guard !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
		model.applyDraft()
		return true
	}

	/// Whether `responder` is a text input.
	///
	/// Walks the chain rather than testing one type: SwiftUI wraps its `TextEditor` in extra views,
	/// so the first responder is sometimes the text view and sometimes a container above it. Static
	/// and pure so the checker can assert it against real views instead of a real keystroke.
	static func isTextInputResponder(_ responder: Any?) -> Bool {
		var node = responder
		while let view = node as? NSView {
			if view is NSTextView || view is NSTextField { return true }
			node = view.nextResponder
		}
		return false
	}

/// Hides the panel for a click that landed outside it.
	///
	/// Hit testing has to include windows the panel *owns* but does not *contain*: SwiftUI renders a
	/// `Menu` or `Picker` as an `NSMenu`, which AppKit tracks in a separate window that is
	/// positioned outside the panel's frame. Testing the panel frame alone made choosing a
	/// language dismiss the panel before the picker could act on the click.
	///
	/// Suspended while a capture is in flight. Screenshot OCR can take over a second, and a click
	/// anywhere during it would otherwise close a panel that is mid-read — and close it *after* the
	/// work was already paid for.
	private func handleOutsideClick(at point: NSPoint) {
		guard panel.isVisible, !model.isPinned, Settings.shared.closeOnOutsideClick else { return }
		guard !model.isCapturing else { return }
		guard !isInsidePanelUI(point) else { return }
		hide()
	}

	private func isInsidePanelUI(_ point: NSPoint) -> Bool {
		if panel.frame.contains(point) { return true }
		return panelOwnedWindowFrames.contains { $0.contains(point) }
	}

	private var panelOwnedWindowFrames: [CGRect] {
		NSApp.windows.compactMap { window in
			guard window !== panel, window.isVisible, window.frame.width > 0 else { return nil }
			// Menu and popover windows have no public type to test against, so they are matched by
			// the class name AppKit gives them. They are the only windows SwiftUI opens from a
			// control inside the panel, and all of them are transient — nothing needs to be torn
			// down here, they close with the menu.
			let className = NSStringFromClass(type(of: window))
			guard className.contains("Menu") || className.contains("Popover") else { return nil }
			return window.frame
		}
	}
}