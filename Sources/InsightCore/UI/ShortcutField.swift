import AppKit
import SwiftUI

enum ShortcutTarget: Hashable {
	case selection
	case snip
}

/// One shared recorder so two shortcut fields can never install competing event monitors.
@MainActor
@Observable
final class ShortcutRecorder {
	static let shared = ShortcutRecorder()

	var isRecording: ShortcutTarget?

	private var monitor: Any?

	/// Applies a captured combo. The recorder owns *detection*; this owns *effect*, which keeps
	/// the settings view from having to stay alive and correctly wired for the recorder to do
	/// anything at all. (It previously declared an `onCapture` that nobody ever assigned, so
	/// pressing a key cancelled the recording and changed nothing.)
	private func apply(_ target: ShortcutTarget, _ combo: KeyCombo) {
		let settings = Settings.shared
		switch target {
		case .selection: settings.selectionHotkey = combo
		case .snip: settings.snipHotkey = combo
		}
		settings.commit()
		// Carbon has no "replace" — the old registration must be torn down or the change
		// silently does nothing.
		AppController.shared.registerHotkeys()
	}

	func begin(_ target: ShortcutTarget) {
		guard monitor == nil else { return }
		isRecording = target
		// Suspension is tied to *recording*, and belongs here rather than to the settings window's
		// lifetime — see `HotkeyCenter.isSuspended`. Arming it here also covers the one case that
		// matters: recording the key that is already bound to this very action.
		HotkeyCenter.shared.isSuspended = true

		monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
			guard let self, let target = self.isRecording else { return event }
			return self.handle(event, for: target)
		}
	}

	func cancel() {
		if let monitor { NSEvent.removeMonitor(monitor) }
		monitor = nil
		isRecording = nil
		HotkeyCenter.shared.isSuspended = false
	}

	private func handle(_ event: NSEvent, for target: ShortcutTarget) -> NSEvent? {
		let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

		// Escape is the universal "never mind".
		if event.keyCode == 53 {
			cancel()
			return nil
		}

		// Ignore presses that are only modifiers, otherwise recording ends the moment you
		// press the first of two.
		if event.keyCode == KeyCodeCatalog.shift
			|| event.keyCode == KeyCodeCatalog.control
			|| event.keyCode == KeyCodeCatalog.option
			|| event.keyCode == KeyCodeCatalog.capsLock
			|| event.keyCode == KeyCodeCatalog.fn
			|| event.keyCode == 0x37  // Command
		{
			return nil
		}

		guard KeyCombo.isSafeToClaim(keyCode: UInt16(event.keyCode), hasModifiers: !flags.isEmpty)
		else { return nil }

		cancel()
		// Keep the label AppKit reported rather than deriving one — see KeyCombo.displayOverride.
		apply(target, KeyCombo.from(event))
		return nil
	}
}

struct ShortcutField: View {
	let target: ShortcutTarget
	let title: String
	@Binding var combo: KeyCombo

	private var isRecording: Bool { ShortcutRecorder.shared.isRecording == target }

	var body: some View {
		LabeledContent(title) {
			HStack(spacing: 6) {
				Button {
					if isRecording {
						ShortcutRecorder.shared.cancel()
					} else {
						ShortcutRecorder.shared.begin(target)
					}
				} label: {
					Text(isRecording ? "按下快捷键…" : combo.display)
						.font(.system(size: 12, weight: .medium, design: .rounded))
						.monospacedDigit()
						.foregroundStyle(isRecording ? .orange : .primary)
						.frame(minWidth: 78)
						.padding(.vertical, 4)
						.background(
							RoundedRectangle(cornerRadius: 5)
								.fill(.quaternary.opacity(0.5))
						)
						.overlay(
							RoundedRectangle(cornerRadius: 5)
								.strokeBorder(.separator, lineWidth: 1)
						)
				}
				.buttonStyle(.plain)

				if isRecording {
					Button("取消") { ShortcutRecorder.shared.cancel() }
						.buttonStyle(.plain)
						.font(.system(size: 11))
						.foregroundStyle(.secondary)
				}
			}
		}
	}
}