import AppKit

/// Putting captured text on the pasteboard.
///
/// The opposite of `SelectionWriter`, and deliberately so: that one *borrows* the pasteboard for a
/// synthetic ⌘V and puts the previous contents straight back, because overwriting someone's
/// clipboard as a side effect of a translation would be hostile. This one is the feature — the
/// user's explicit request is "put this text where I can paste it" — so nothing is restored.
enum ClipboardWriter {
	/// Writes `text` and returns whether the pasteboard accepted it.
	@discardableResult
	@MainActor
	static func copy(_ text: String) -> Bool {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return false }
		let pasteboard = NSPasteboard.general
		pasteboard.clearContents()
		guard pasteboard.setString(trimmed, forType: .string) else {
			Log.capture("clipboard write refused")
			return false
		}
		Log.capture("copied \(trimmed.count) chars to clipboard")
		return true
	}

	/// Reads text back off the pasteboard, trimmed; nil when there is no text (images, files,
	/// empty). The read half of the clipboard fallback — `handleCapturedText` calls this only
	/// after the selection read came up empty and the user asked for the fallback in settings.
	///
	/// The first read of another app's text makes macOS show its own pasteboard-consent prompt,
	/// which is fine: a feature that reads the clipboard should be seen to ask.
	@MainActor
	static func pastedText() -> String? {
		guard let text = NSPasteboard.general.string(forType: .string) else { return nil }
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.isEmpty ? nil : trimmed
	}
}
