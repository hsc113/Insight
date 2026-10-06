import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// A global hotkey, stored as a virtual key code plus Carbon modifiers.
///
/// Carbon is used rather than CGEventTap because `RegisterEventHotKey` does **not** require
/// Accessibility permission to register — the hotkeys keep working even if the user has not
/// yet granted it, and we only need Accessibility for reading the selection.
struct KeyCombo: Codable, Equatable, Hashable, Sendable {
	var keyCode: UInt16
	var carbonModifiers: UInt32

	/// The label AppKit itself reported for the key at record time.
	///
	/// This exists because some keys cannot be derived from their code at all: function keys
	/// live in the HID layer and have no entry in the keyboard-layout file, and published
	/// ANSI tables don't even agree on F3's code. Asking the event removes the guesswork — and
	/// gets Dvorak, AZERTY and IME layouts right for free, since `charactersIgnoringModifiers`
	/// is already layout-resolved.
	var displayOverride: String?

	init(keyCode: UInt16, carbonModifiers: UInt32, displayOverride: String? = nil) {
		self.keyCode = keyCode
		self.carbonModifiers = carbonModifiers
		self.displayOverride = displayOverride
	}

	// MARK: - Modifier bridging

	/// The same modifier set as `CGEvent` flags, for injection in the self test.
	var eventFlags: CGEventFlags {
		var flags: CGEventFlags = []
		if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.maskCommand) }
		if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.maskAlternate) }
		if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.maskShift) }
		if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.maskControl) }
		return flags
	}

	var eventModifiers: NSEvent.ModifierFlags {
		var flags: NSEvent.ModifierFlags = []
		if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
		if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
		if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
		if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
		return flags
	}

	init(event: NSEvent) {
		let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
		var carbon: UInt32 = 0
		if flags.contains(.control) { carbon |= UInt32(controlKey) }
		if flags.contains(.option) { carbon |= UInt32(optionKey) }
		if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
		if flags.contains(.command) { carbon |= UInt32(cmdKey) }
		keyCode = UInt16(event.keyCode)
		carbonModifiers = carbon
		displayOverride = nil
	}

	/// Builds a combo from a real event, keeping the label AppKit reported.
	static func from(_ event: NSEvent) -> KeyCombo {
		var combo = KeyCombo(event: event)
		combo.displayOverride = KeyCodeCatalog.label(from: event)
		return combo
	}

	var isFunctionKey: Bool { KeyCodeCatalog.isFunctionKey(keyCode) }

	var display: String {
		var out = ""
		if carbonModifiers & UInt32(controlKey) != 0 { out += "⌃" }
		if carbonModifiers & UInt32(optionKey) != 0 { out += "⌥" }
		if carbonModifiers & UInt32(shiftKey) != 0 { out += "⇧" }
		if carbonModifiers & UInt32(cmdKey) != 0 { out += "⌘" }
		out += label
		return out
	}

	private var label: String {
		// The catalog wins for function keys, because `displayOverride` is a snapshot taken when
		// the shortcut was recorded and configs saved before the F-key table was corrected still
		// contain `0x63 → "F8"`. The key code is the thing that actually fires, so the label has
		// to be re-derived from it rather than trusted. Character keys still prefer the recorded
		// label — there the table cannot answer, and `charactersIgnoringModifiers` already
		// resolved the user's layout.
		if let name = KeyCodeCatalog.functionKeyName(keyCode) { return name }
		if let displayOverride, !displayOverride.isEmpty { return displayOverride }
		return KeyCodeCatalog.displayName(
			for: keyCode, shifted: carbonModifiers & UInt32(shiftKey) != 0)
	}

	/// Whether a bare (modifier-free) combo may be claimed system-wide.
	///
	/// Function keys are exempt because they are never delivered as ordinary typing, so binding
	/// one globally cannot steal it from another app. Letters and digits are not exempt: a bare
	/// `D` would swallow that key everywhere. This is the rule that made F3/F4 recordable —
	/// it used to reject them, because F-keys carry no modifier by default.
	static func isSafeToClaim(keyCode: UInt16, hasModifiers: Bool) -> Bool {
		hasModifiers || KeyCodeCatalog.isFunctionKey(keyCode)
	}

	static let selection = KeyCombo(keyCode: KeyCodeCatalog.letter("d"), carbonModifiers: UInt32(optionKey))
	static let snip = KeyCombo(keyCode: KeyCodeCatalog.letter("s"), carbonModifiers: UInt32(optionKey))
}
