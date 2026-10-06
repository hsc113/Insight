import AppKit
import Carbon
import Foundation

/// Names for virtual key codes.
///
/// An earlier version of this file carried a hand-written table of glyphs. It was wrong in
/// ways that are embarrassing to enumerate: it claimed `0x2D` was `-` (it is `n`), `0x3B` was
/// `;` (it is Control), `0x40` was Space (it is F17) and `0x7E` was Return (it is the up arrow).
///
/// So character keys are no longer hardcoded at all. `UCKeyTranslate` is asked what the *current
/// keyboard layout* actually produces for a given key code, which means the table is correct by
/// construction and stays correct on Dvorak, AZERTY and IME layouts.
///
/// Only the keys that produce no character need names of their own, and those were each verified
/// against the layout rather than guessed.
enum KeyCodeCatalog {
	// Letters and digits the defaults use.
	static let a: UInt16 = 0x00, s: UInt16 = 0x01, d: UInt16 = 0x02, f: UInt16 = 0x03
	static let h: UInt16 = 0x04, g: UInt16 = 0x05, z: UInt16 = 0x06, x: UInt16 = 0x07
	static let c: UInt16 = 0x08, v: UInt16 = 0x09, b: UInt16 = 0x0B, q: UInt16 = 0x0C
	static let w: UInt16 = 0x0D, e: UInt16 = 0x0E, r: UInt16 = 0x0F, y: UInt16 = 0x10
	static let t: UInt16 = 0x11, o: UInt16 = 0x1F, p: UInt16 = 0x23, l: UInt16 = 0x25
	static let k: UInt16 = 0x28, j: UInt16 = 0x26, n: UInt16 = 0x2D, m: UInt16 = 0x2E

	/// ANSI virtual key codes. Verified against the layout: 0x38/0x3A/0x3B/0x3C/0x3D/0x3E/0x3F
	/// produce no character, which is what identifies them as the modifier row.
	static let shift: UInt16 = 0x38
	static let capsLock: UInt16 = 0x39
	static let option: UInt16 = 0x3A
	static let control: UInt16 = 0x3B
	static let rightShift: UInt16 = 0x3C
	static let rightOption: UInt16 = 0x3D
	static let rightControl: UInt16 = 0x3E
	static let fn: UInt16 = 0x3F
	static let escape: UInt16 = 0x35
	static let returnKey: UInt16 = 0x24
	static let tab: UInt16 = 0x30
	static let space: UInt16 = 0x31
	static let forwardDelete: UInt16 = 0x75

	static func letter(_ lowercased: Character) -> UInt16 {
		let base = Character(String(lowercased).lowercased())
		return Character.ansiLetters[base] ?? 0x00
	}

	// MARK: - Non-character keys

	/// Every code here was verified to produce no character under `UCKeyTranslate` — that is what
	/// distinguishes a modifier or navigation key from a key that merely has no glyph.
	private static let namedKeys: [UInt16: String] = [
		returnKey: "↩",
		tab: "⇥",
		space: "␣",
		0x33: "⌫",  // Delete, i.e. backspace. Forward-delete is 0x75.
		forwardDelete: "⌦",
		escape: "esc",
		shift: "⇧",
		rightShift: "⇧",
		capsLock: "⇪",
		control: "⌃",
		rightControl: "⌃",
		option: "⌥",
		rightOption: "⌥",
		fn: "fn",
		0x37: "⌘",
		0x36: "⌘",
		0x4C: "⌅",  // keypad Enter
		0x7B: "←",
		0x7C: "→",
		0x7D: "↓",
		0x7E: "↑",
		0x73: "↖",
		0x74: "⇞",
		0x77: "↘",
		0x79: "⇟",
	]

	/// Function keys, transcribed from the SDK's own `HIToolbox/Events.h` (`kVK_F1`…`kVK_F20`)
	/// rather than from a published ANSI table.
	///
	/// These are **not** contiguous, and the codes are **not** in numeric order, which is exactly
	/// how the previous table went wrong: F3 is `0x63` — *after* F5/F6/F7 — while F8/F9/F10 are
	/// `0x64`/`0x65`/`0x6D`. A table written as "F1, F2, F4, then F5…F7, then the next four codes"
	/// therefore labelled `0x63` as F8, `0x64` as F9 and `0x65` as F10, and had no entry at all
	/// for F10's real code `0x6D`. Binding F3 worked perfectly — only the label was a lie.
	private static let functionKeys: [UInt16: String] = [
		0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4",
		0x60: "F5", 0x61: "F6", 0x62: "F7", 0x64: "F8",
		0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
		0x69: "F13", 0x6B: "F14", 0x71: "F15", 0x6A: "F16",
		0x40: "F17", 0x4F: "F18", 0x50: "F19", 0x5A: "F20",
	]

	/// The table above is the authority for F1–F20. The range test still exists so a keyboard
	/// reporting F21+ is treated as a function key (and so a bare one may be claimed globally)
	/// even though there is no label for it.
	static func isFunctionKey(_ code: UInt16) -> Bool {
		functionKeys[code] != nil || (code >= 0x60 && code <= 0x6F) || (code >= 0x7A && code <= 0x7E)
	}

	static func functionKeyName(_ code: UInt16) -> String? { functionKeys[code] }

	// MARK: - Labels

	static func displayName(for keyCode: UInt16, shifted: Bool) -> String {
		if let name = functionKeys[keyCode] { return name }
		if let name = namedKeys[keyCode] { return name }
		guard let plain = layoutGlyph(for: keyCode) else { return "键\(keyCode)" }
		// Letters always show uppercase, matching how macOS renders shortcut menus: `⌥D`, never
		// `⌥d`. Shift only changes punctuation and digits, which the ANSI pairs fix.
		if shifted { return applyShift(to: plain) }
		let upper = plain.uppercased()
		return plain.count == 1 && upper.count == 1 && upper != plain ? upper : plain
	}

	/// `UCKeyTranslate`'s `modifierKeyState` is ignored for `kUCKeyActionDisplay` — it always
	/// answers with the unshifted glyph — so the shifted form is derived instead. Uppercasing
	/// covers every letter on every layout; the ANSI punctuation and digit pairs are fixed.
	static func applyShift(to glyph: String) -> String {
		let upper = glyph.uppercased()
		if upper != glyph { return upper }
		guard glyph.count == 1, let character = glyph.first else { return glyph }
		return shiftedGlyph(for: character) ?? glyph
	}

	/// The label AppKit reported for a real key event. Function keys report "F3" and friends;
	/// character keys report the layout-resolved glyph.
	///
	/// The event is asked *before* `functionKeys`, so its own answer wins for function keys. Both
	/// agree now that the table is transcribed from the SDK header, but the table is a constant and
	/// the event is the truth — and getting that ordering wrong is invisible until a user reports
	/// that F3 is labelled F8.
	static func label(from event: NSEvent) -> String? {
		let code = UInt16(event.keyCode)

		if let name = event.charactersIgnoringModifiers {
			if isFunctionKeyLabel(name) { return name }
			if name.count == 1, let scalar = name.unicodeScalars.first {
				if CharacterSet.whitespaces.contains(scalar) { return "␣" }
				// A control character means this key has no glyph of its own — an arrow, a
				// function key, a modifier — so fall through to the named glyphs rather than
				// giving up. Bailing out here would drop the label for every arrow key.
				if !CharacterSet.controlCharacters.contains(scalar) {
					if event.modifierFlags.contains(.shift) { return applyShift(to: name) }
					let upper = name.uppercased()
					return upper.count == 1 && upper != name ? upper : name
				}
			}
		}
		if let name = functionKeys[code] { return name }
		if let name = namedKeys[code] { return name }
		if let glyph = layoutGlyph(for: code) {
			return event.modifierFlags.contains(.shift) ? applyShift(to: glyph) : glyph
		}
		return nil
	}

	/// `AppKit` reports function keys as `F1`…`F20`. Matching the shape rather than testing for a
	/// leading "F" keeps a layout whose dead-key sequences happen to start with "F" from being
	/// reported as a function key.
	static func isFunctionKeyLabel(_ name: String) -> Bool {
		guard name.count >= 2, name.hasPrefix("F"),
			let number = Int(name.dropFirst())
		else { return false }
		return (1...20).contains(number)
	}

	static func shiftedGlyph(for character: Character) -> String? {
		let table: [Character: Character] = [
			"1": "!", "2": "@", "3": "#", "4": "$", "5": "%",
			"6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
			"-": "_", "=": "+", "[": "{", "]": "}", "\\": "|",
			";": ":", "'": "\"", ",": "<", ".": ">", "/": "?", "`": "~",
		]
		return table[character].map(String.init)
	}

	// MARK: - Keyboard layout

	/// The current keyboard layout's data, retained for the process lifetime.
	///
	/// The input source is held too: `TISGetInputSourceProperty` returns a borrowed pointer, and
	/// letting the source go would leave the layout data dangling.
	private static let layoutSource: TISInputSource? = {
		TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
	}()

	private static let layoutData: CFData? = {
		guard let layoutSource,
			let data = TISGetInputSourceProperty(layoutSource, kTISPropertyUnicodeKeyLayoutData)
		else { return nil }
		return unsafeBitCast(data, to: CFData.self)
	}()

	private static var keyboardType: UInt32 { UInt32(LMGetKbdType()) }

	/// Asks the layout what character this key code produces. Returns `nil` for keys that
	/// produce nothing, which is the signal to fall back to a named glyph.
	static func layoutGlyph(for keyCode: UInt16) -> String? {
		// Rebinding has to happen per call: the pointer `withMemoryRebound` hands out is only
		// valid inside the closure. Caching it in a `static let` yields a dangling pointer, which
		// happens to work for the unshifted lookup and returns garbage for the shifted one.
		guard let layoutData, let bytes = CFDataGetBytePtr(layoutData) else { return nil }
		let capacity = CFDataGetLength(layoutData)

		var deadState: UInt32 = 0
		var length = 0
		var chars = [UniChar](repeating: 0, count: 8)
		let status = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: capacity) { layout in
			UCKeyTranslate(
				layout, keyCode, UInt16(kUCKeyActionDisplay), 0,
				keyboardType, 0, &deadState, 8, &length, &chars)
		}
		guard status == noErr, length > 0 else { return nil }

		// Control and private-use scalars mean this key has no printable glyph of its own —
		// that is exactly the signal for a function key, an arrow key or a modifier.
		var scalars: [Unicode.Scalar] = []
		for code in chars[0..<length] {
			guard let scalar = Unicode.Scalar(code) else { return nil }
			if scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
				|| (0xF700...0xF8FF).contains(scalar.value)
			{
				return nil
			}
			scalars.append(scalar)
		}
		return String(String.UnicodeScalarView(scalars))
	}
}

// MARK: - ANSI letter codes

private extension Character {
	/// `ev_keycode.h` ANSI letters. Only the ones the defaults and recorder tests need.
	static let ansiLetters: [Character: UInt16] = [
		"a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06,
		"x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E,
		"r": 0x0F, "y": 0x10, "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15,
		"6": 0x16, "5": 0x17, "9": 0x19, "7": 0x1A, "0": 0x1D, "o": 0x1F, "u": 0x20,
		"i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28, "n": 0x2D, "m": 0x2E,
	]
}
