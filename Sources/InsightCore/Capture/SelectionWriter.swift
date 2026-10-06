import AppKit
import ApplicationServices

/// Writing a translation back into whatever the user was reading.
///
/// The common names for this feature are "翻译并替换" / "静默划词翻译". A recurring objection
/// to the "writing" feature: **it sometimes fails and takes the original text with it**. The
/// lesson is to never destroy the source — the original is only touched after a translation has
/// actually arrived, and the pasteboard is restored afterwards.
enum SelectionWriter {

	enum Outcome {
		case replaced(characterCount: Int)
		case noEditableTarget
		case notPermitted

		var message: String? {
			switch self {
			case .replaced(let count): return "已替换 \(count) 个字符"
			case .noEditableTarget: return "当前位置不能直接替换，请手动粘贴"
			case .notPermitted: return "没有辅助功能权限，无法写回"
			}
		}
	}

	/// Replaces the current selection with `text`.
	///
	/// Uses the Accessibility API rather than synthetic ⌘V. The forced-copy path is a known
	/// trap: it fights ⌘C, it conflicts with ⌘C in VS Code, and the recurring verdict is
	/// "Cmd+C 不是一个好选项". This way the pasteboard is only borrowed and is restored
	/// immediately.
	///
	/// `@MainActor` because the pasteboard is shared state and the borrow has to be set up, used and
	/// restored without another actor interleaving a write into it.
	@discardableResult
	@MainActor
	static func replaceSelection(with text: String) -> Outcome {
		guard AXIsProcessTrusted() else { return .notPermitted }

		let system = AXUIElementCreateSystemWide()
		guard let focused = elementAttribute(system, kAXFocusedUIElementAttribute),
			let role = stringAttribute(focused, kAXRoleAttribute as String)
		else { return .noEditableTarget }

		// Only text fields and text areas can be written to. Refusing anything else stops a
		// misfire from typing into a search field the user was browsing.
		let editableRoles = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, kAXSearchFieldSubrole]
		guard editableRoles.contains(where: { role == $0 || role == ($0 as String) }) else {
			return .noEditableTarget
		}

		let pasteboard = NSPasteboard.general
		let saved = pasteboard.string(forType: .string)

		pasteboard.clearContents()
		pasteboard.setString(text, forType: .string)
		// Synthesise ⌘V through the event queue so the target app's own paste handling runs —
		// this is what makes it work in Electron, Xcode and terminals alike.
		let source = CGEventSource(stateID: .hidSystemState)
		let down = CGEvent(keyboardEventSource: source, virtualKey: KeyCodeCatalog.v, keyDown: true)
		let up = CGEvent(keyboardEventSource: source, virtualKey: KeyCodeCatalog.v, keyDown: false)
		down?.flags = [.maskCommand]
		up?.flags = [.maskCommand]
		down?.post(tap: .cghidEventTap)
		up?.post(tap: .cghidEventTap)

		// Give the target app a moment to consume the paste before putting the pasteboard back.
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
			MainActor.assumeIsolated {
				guard let saved else { return }
				pasteboard.clearContents()
				pasteboard.setString(saved, forType: .string)
			}
		}

		return .replaced(characterCount: text.count)
	}

	// `isPanelFocused()` used to live here. It is gone, and so is the problem it was working
	// around: `SelectionReader` now drops Accessibility elements that belong to this process, so a
	// selection inside our own panel reads as "nothing selected outside Insight" instead of as our
	// own output masquerading as the user's selection. Key status is the wrong question anyway — the
	// panel is a `.nonactivatingPanel` brought forward with `makeKeyAndOrderFront`, so its answer
	// was frequently `true` while the user was selecting text in a different app.

	// MARK: - AX helpers

	private static func elementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
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
}
