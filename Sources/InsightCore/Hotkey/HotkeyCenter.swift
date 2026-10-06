import AppKit
import CoreGraphics

/// Global hotkeys.
///
/// **Implementation note — this used to use Carbon `RegisterEventHotKey` and was replaced.**
/// Carbon registers without any user permission and swallows the key, which made it look like
/// the right choice. But it could not be verified: injecting a synthetic `CGEvent` reaches a
/// global `NSEvent` monitor (which the self test confirmed, 6 of 6 events) and still never
/// reaches a Carbon hotkey handler, because hotkey matching happens in the window server's
/// hardware dispatch path and ignores synthetic events. Registration reported success and the
/// callback was never entered once — for either synthetic or, per the user's report, real presses.
///
/// A `CGEventTap` needs Accessibility permission, which this app already requires to read the
/// selection, so it adds nothing to ask for. In exchange it is verifiable, and it can swallow the
/// event, so a bound key does not also reach every other app.
final class HotkeyCenter {
	static let shared = HotkeyCenter()

	enum ID: String, CaseIterable {
		case selection
		case snip
	}

	private var tap: CFMachPort?
	private var runLoopSource: CFRunLoopSource?

	/// Keyed by a packed keycode + modifier signature so lookup is O(1) per key press.
	private var bindings: [UInt64: ID] = [:]
	private var handlers: [ID: () -> Void] = [:]
	private var suspended = false
	private let lock = NSLock()

	private init() {}

	/// Whether a matching key press is left alone instead of being dispatched to its handler.
	///
	/// Set only while a `ShortcutRecorder` is capturing a keystroke — a key press then means
	/// "record this", not "do the thing".
	///
	/// **This used to be set for the whole lifetime of the settings window, and that was a bug.**
	/// Opening 设置 suspended the hotkeys until you closed it, so F3/F2 were dead *everywhere* —
	/// including in the document you were actually working in — for as long as a settings window
	/// happened to be open, whether or not it was in front. From inside the app it looked like
	/// "the hotkey stopped working" with no cause on screen, and closing a window you had
	/// forgotten about silently fixed it.
	///
	/// Suspending is *not* the same as unregistering: the binding stays intact, so the hotkey
	/// comes back with nothing to re-register.
	var isSuspended: Bool {
		get { lock.withLock { suspended } }
		set { lock.withLock { suspended = newValue } }
	}

	// MARK: - Lifecycle

	/// - Returns: `false` when the tap could not be created, which in practice means
	///   Accessibility permission is missing.
	@discardableResult
	func start() -> Bool {
		lock.withLock {
			guard tap == nil else { return true }
			let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
			let selfPointer = Unmanaged.passUnretained(self).toOpaque()
			// A C function pointer cannot capture, so the instance comes back through `userInfo`.
			let callback: CGEventTapCallBack = { _, type, event, userInfo in
				guard let userInfo else { return Unmanaged.passUnretained(event) }
				let center = Unmanaged<HotkeyCenter>.fromOpaque(userInfo).takeUnretainedValue()
				// A tap is disabled by the system if its callback overruns the budget. Re-enable
				// rather than silently losing the hotkey from then on.
				if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
					center.reenable()
					return Unmanaged.passUnretained(event)
				}
				guard type == .keyDown else { return Unmanaged.passUnretained(event) }
				return center.handle(event)
			}

			guard let port = CGEvent.tapCreate(
				tap: .cgSessionEventTap,
				place: .headInsertEventTap,
				options: .defaultTap,
				eventsOfInterest: mask,
				callback: callback,
				userInfo: selfPointer
			) else {
				Log.error("CGEventTap 创建失败（辅助功能权限？）")
				return false
			}

			let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
			CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
			CGEvent.tapEnable(tap: port, enable: true)
			tap = port
			runLoopSource = source
			Log.ui("hotkey tap installed")
			return true
		}
	}

	func stop() {
		unregisterAll()
		let (port, source) = lock.withLock { () -> (CFMachPort?, CFRunLoopSource?) in
			defer { tap = nil; runLoopSource = nil }
			return (tap, runLoopSource)
		}
		if let source { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
		if let port { CGEvent.tapEnable(tap: port, enable: false) }
	}

	private func reenable() {
		lock.withLock {
			if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
		}
	}

	// MARK: - Bindings

	func register(_ id: ID, combo: KeyCombo, handler: @escaping () -> Void) {
		unregister(id)
		lock.withLock {
			bindings[signature(keyCode: combo.keyCode, modifiers: combo.eventModifiers)] = id
			handlers[id] = handler
		}
		Log.ui("registered \(id.rawValue) -> \(combo.display)")
	}

	func unregister(_ id: ID) {
		lock.withLock {
			for (signature, bound) in bindings where bound == id {
				bindings.removeValue(forKey: signature)
			}
			handlers.removeValue(forKey: id)
		}
	}

	func unregisterAll() {
		lock.withLock {
			bindings.removeAll()
			handlers.removeAll()
		}
	}

	func isRegistered(_ id: ID) -> Bool {
		lock.withLock { handlers[id] != nil }
	}

	private func signature(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> UInt64 {
		var value = UInt64(keyCode)
		if modifiers.contains(.command) { value |= 1 << 16 }
		if modifiers.contains(.option) { value |= 1 << 17 }
		if modifiers.contains(.shift) { value |= 1 << 18 }
		if modifiers.contains(.control) { value |= 1 << 19 }
		return value
	}

	// MARK: - Dispatch

	/// - Returns: `nil` to swallow the event, so a bound key does not also fire in whatever app
	///   the user is working in.
	private func handle(_ event: CGEvent) -> Unmanaged<CGEvent>? {
		let rawCode = event.getIntegerValueField(.keyboardEventKeycode)
		let flags = eventFlags(event.flags)

		let key = signature(keyCode: UInt16(truncatingIfNeeded: rawCode), modifiers: flags)
		let id: ID? = lock.withLock { bindings[key] }
		guard let id, let handler = lock.withLock({ handlers[id] }) else {
			return Unmanaged.passUnretained(event)
		}

		// Suspended: a recorder is capturing, so the press is *input*, not a command. Only the
		// handler is skipped — the event is deliberately **passed through, not swallowed**.
		//
		// This tap is a head-inserted session tap, which runs upstream of every application's event
		// queue, so returning `nil` here means no app ever sees the key. The recorder listens with
		// a local `NSEvent` monitor, which only sees events already delivered to this app — so
		// swallowing would mean the recorder never observed the press at all, and a shortcut could
		// never be reassigned to the key it already had. Passing it through is what lets you record
		// F3 as F3.
		guard !lock.withLock({ suspended }) else {
			Log.ui("hotkey \(id.rawValue) left for the recorder")
			return Unmanaged.passUnretained(event)
		}

		Log.ui("hotkey fired: \(id.rawValue)")
		// **Always** deferred, even when the tap callback is already on the main thread.
		//
		// This is a `.defaultTap`, so the whole system input pipeline waits for this function to
		// return. The handler used to run inline, which meant everything `selectionTranslate()` does
		// — a bounded-but-still-large Accessibility walk, a synchronous pasteboard write, and
		// `makeKeyAndOrderFront` laying out the SwiftUI tree — happened with the keyboard held
		// hostage: the source app froze, and the panel only appeared after all of it.
		//
		// Deferring costs one runloop turn and buys two things: the F3 key-up is delivered to the
		// source app before Insight starts working, and the tap returns while the window is coming
		// up. The event is still swallowed either way, so nothing leaks through.
		//
		// A second press landing before the first handler runs is not a problem either — the
		// capture path is idempotent per press, and `PanelModel.beginCapture` drops the result of a
		// read that has since been superseded.
		DispatchQueue.main.async(execute: handler)
		return nil
	}

	private func eventFlags(_ raw: CGEventFlags) -> NSEvent.ModifierFlags {
		var flags: NSEvent.ModifierFlags = []
		if raw.contains(.maskCommand) { flags.insert(.command) }
		if raw.contains(.maskAlternate) { flags.insert(.option) }
		if raw.contains(.maskShift) { flags.insert(.shift) }
		if raw.contains(.maskControl) { flags.insert(.control) }
		return flags
	}
}
