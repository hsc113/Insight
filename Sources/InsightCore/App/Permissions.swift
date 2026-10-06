import AppKit
import ApplicationServices
import CoreGraphics

enum Permissions {
	// MARK: - Accessibility (required to read the selection)

	static var hasAccessibility: Bool {
		AXIsProcessTrusted()
	}

	/// Triggers the system prompt. On a repeat denial macOS stops showing it, so the caller
	/// should fall back to `openAccessibilitySettings`.
	static func requestAccessibility() {
		let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
		_ = AXIsProcessTrustedWithOptions(options)
	}

	static func openAccessibilitySettings() {
		if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
			NSWorkspace.shared.open(url)
		}
	}

	// MARK: - Screen recording (required to screenshot)

	static var hasScreenRecording: Bool {
		CGPreflightScreenCaptureAccess()
	}

	static func requestScreenRecording() {
		_ = CGRequestScreenCaptureAccess()
	}

	static func openScreenRecordingSettings() {
		if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
			NSWorkspace.shared.open(url)
		}
	}

	// MARK: - Aggregate

	static var missing: [Permission] {
		var result: [Permission] = []
		if !hasAccessibility { result.append(.accessibility) }
		if !hasScreenRecording { result.append(.screenRecording) }
		return result
	}

	enum Permission {
		case accessibility
		case screenRecording

		var title: String {
			switch self {
			case .accessibility: return "辅助功能权限"
			case .screenRecording: return "屏幕录制权限"
			}
		}

		var detail: String {
			switch self {
			case .accessibility:
				return "读取划词内容需要辅助功能权限。开启后无需重启应用。"
			case .screenRecording:
				return "截图翻译需要屏幕录制权限。开启后需重新启动应用。"
			}
		}

		var openSettings: () -> Void {
			switch self {
			case .accessibility: openAccessibilitySettings
			case .screenRecording: openScreenRecordingSettings
			}
		}
	}
}