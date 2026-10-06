import AppKit
import SwiftUI

/// The first-run guide: grant the two permissions, then point Insight at a model.
///
/// **A separate window, not a sheet over the settings window.** The three things it asks for all
/// happen *outside* it — one click in System Settings, one authorisation dialog, one API key from
/// a browser tab — so it has to survive losing focus, being covered, and the user wandering off
/// for five minutes. A sheet is modal to a window that nothing here needs.
///
/// **Both permissions are required to finish.** Each one guards a headline feature — 辅助功能 the
/// hotkeys and 划词, 屏幕录制 截图翻译 — and each fails the same silent way: a keypress, and
/// nothing on screen. A guide that lets you past the second one ships exactly the confusion it
/// exists to prevent. The API key is the only optional item: only 总结 needs a model, translation
/// runs offline on Apple's engine.
struct OnboardingView: View {
	let onFinish: () -> Void

	@State private var missing = Permissions.missing
	@State private var fetchState = FetchState.idle
	@State private var testState = TestState.idle

	private enum FetchState: Equatable {
		case idle, loading, failed(String), loaded(Int)
	}

	private enum TestState: Equatable {
		case idle, running
		case ok(ms: Int)
		case failed(String)
	}

	/// Polled rather than refreshed on a button press: granting 辅助功能 means leaving for System
	/// Settings and coming back, and the status has to be right when the user returns — the
	/// alternative is a guide that still says "未授权" after a successful grant, which teaches
	/// people that the button did not work.
	private let permissionTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

	/// Whether the screen-recording grant has landed but this process cannot see it yet.
	///
	/// `CGPreflightScreenCaptureAccess()` reflects the *process's* authorisation, and macOS grants
	/// that on the next launch — which `Permissions.Permission.screenRecording.detail` already says
	/// in as many words ("开启后需重新启动应用"). With the permission now required to finish, that
	/// turn of events would leave the user staring at a guide whose only exits are 稍后再说 and
	/// quitting the app, so it gets its own affordance instead.
	///
	/// Set when the user presses 打开设置 for screen recording: from then on, "still missing" is
	/// interpreted as "granted, pending a relaunch" rather than as "you did not do it". Deliberately
	/// not a poll of the system state — there is no API that answers "granted but not yet live",
	/// and inventing one out of timing would be guessing.
	@State private var screenRecordingRequested = false

	/// What the guide will not let you past: **both** permissions.
	///
	/// 辅助功能 because without it the hotkeys do nothing at all, and 屏幕录制 because without it
	/// 截图翻译 does nothing at all — and the two failures look identical from the outside: a
	/// keypress and no window. Asking for them one at a time, with the second one optional, means
	/// the user who skips it meets that silence later, with no guide on screen to explain it.
	///
	/// The API key is **not** part of this. Only 总结 needs a model; translation runs offline on
	/// Apple's engine, so a key is a choice about which features you want rather than a
	/// prerequisite for the app working.
	private var canFinish: Bool {
		Self.canFinish(missing: missing, screenRecordingRequested: screenRecordingRequested)
	}

	/// The rule, as a pure function so it can be asserted rather than only observed: **both**
	/// permissions, except when screen recording has been asked for and is only waiting on the
	/// relaunch that makes it visible to this process.
	///
	/// The waiting case is not a hole in the rule — it is the rule applied to a permission the
	/// running process cannot see yet. Without it the user is stuck: they granted it, the system
	/// says so, and `CGPreflightScreenCaptureAccess()` keeps returning `false` until they quit.
	static func canFinish(
		missing: [Permissions.Permission], screenRecordingRequested: Bool
	) -> Bool {
		if missing.isEmpty { return true }
		return screenRecordingRequested && missing == [.screenRecording]
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			header
			Divider()
			ScrollView {
				VStack(alignment: .leading, spacing: 14) {
					// The callback is what turns "still missing" into "waiting for a relaunch" for
					// screen recording — see `needsRelaunchForScreenRecording`.
					PermissionsSection(onOpenedSettings: { permission in
						if permission == .screenRecording { screenRecordingRequested = true }
					})
					modelSection
				}
				.padding(20)
				.frame(maxWidth: .infinity, alignment: .leading)
			}
			Divider()
			footer
		}
		.frame(width: 520, height: 560)
		.onReceive(permissionTimer) { _ in
			let now = Permissions.missing
			if now != missing { missing = now }
		}
	}

	// MARK: - Chrome

	private var header: some View {
		VStack(alignment: .leading, spacing: 4) {
			Text("开始使用 Insight")
				.font(.system(size: 16, weight: .semibold))
			Text("两步就好：先开两项权限，再填一个模型（可选）。之后选中文字按 ⌥D 即可。")
				.font(.system(size: 11.5))
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
		}
		.padding(.horizontal, 20)
		.padding(.top, 18)
		.padding(.bottom, 12)
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	private var footer: some View {
		HStack(spacing: 10) {
			if needsRelaunchForScreenRecording {
				Label("屏幕录制已授权，需要重新启动一次", systemImage: "arrow.clockwise.circle.fill")
					.font(.system(size: 11))
					.foregroundStyle(.orange)
			} else if missing.isEmpty {
				Label("权限已就绪", systemImage: "checkmark.circle.fill")
					.font(.system(size: 11))
					.foregroundStyle(.green)
			} else {
				// Names the one that is still missing rather than saying "some permission": with two
				// of them, "权限未开启" leaves the user to work out which.
				Label(
					"还需要开启\(missing.map(\.title).joined(separator: "和"))",
					systemImage: "exclamationmark.triangle.fill")
					.font(.system(size: 11))
					.foregroundStyle(.orange)
			}

			Spacer()

			if needsRelaunchForScreenRecording {
				Button("重新启动") { relaunch() }
					.controlSize(.small)
			}

			Button("稍后再说") { finish() }
				.buttonStyle(.plain)
				.font(.system(size: 11.5))
				.foregroundStyle(.secondary)

			Button("完成") { finish() }
				.buttonStyle(.borderedProminent)
				.controlSize(.regular)
				.disabled(!canFinish)
				.help(canFinish ? "开始使用" : "两项权限都是对应功能能用的前提")
		}
		.padding(.horizontal, 20)
		.padding(.vertical, 12)
	}

	/// Whether the screen-recording grant has landed but this process cannot see it yet.
	///
	/// `CGPreflightScreenCaptureAccess()` reflects the *process's* authorisation, and macOS grants
	/// that on the next launch — `Permissions.Permission.screenRecording.detail` already says so in
	/// as many words ("开启后需重新启动应用"). With the permission now required to finish, that
	/// turn of events would leave the user in front of a guide whose only exits are 稍后再说 and
	/// quitting, so it gets its own affordance instead.
	///
	/// Set when the user opens System Settings for screen recording: from then on, "still missing"
	/// reads as "granted, pending a relaunch" rather than "you did not do it". Deliberately not a
	/// poll — there is no API that answers "granted but not yet live", and inventing one out of
	/// timing would be guessing.
	private var needsRelaunchForScreenRecording: Bool {
		!missing.isEmpty && Self.canFinish(
			missing: missing, screenRecordingRequested: screenRecordingRequested)
	}

	/// Restarts the app so the screen-recording grant takes effect for the new process.
	///
	/// The grant is recorded against the bundle, not the process, so nothing has to be authorised
	/// twice. There is no `NSApplication.relaunch()` — that is UIKit — so this opens a *fresh* copy
	/// and exits: `openApplication` starts a new process rather than activating this one, which is
	/// what makes the new process pick the permission up. `createsNewApplicationInstance` is what
	/// forces that when this bundle is already known to LaunchServices.
	private func relaunch() {
		Settings.shared.hasCompletedOnboarding = true
		Settings.shared.commit()
		Settings.shared.saveNow()

		let configuration = NSWorkspace.OpenConfiguration()
		configuration.createsNewApplicationInstance = true
		NSWorkspace.shared.openApplication(
			at: Bundle.main.bundleURL, configuration: configuration
		) { _, _ in
			// Exiting either way. If the new instance failed to start, staying alive would leave
			// the user with two half-states and no explanation, and the flag is already recorded.
			DispatchQueue.main.async { NSApp.terminate(nil) }
		}
	}

	private func finish() {
		// Marked done on *either* button, including 稍后再说: a guide that comes back because it
		// decided you did not finish is a prompt you cannot dismiss. What is still missing shows up
		// where it is actionable — the 权限 card at the top of 通用设置, the panel's permission
		// page, and the menu bar's blocked-reason title.
		Settings.shared.hasCompletedOnboarding = true
		Settings.shared.commit()
		onFinish()
	}

	// MARK: - Model

	private var modelSection: some View {
		@Bindable var settings = Settings.shared

		return VStack(alignment: .leading, spacing: 10) {
			HStack {
				Label("模型", systemImage: "sparkles")
					.font(.system(size: 14, weight: .semibold))
				Text("可选")
					.font(.system(size: 10))
					.foregroundStyle(.tertiary)
				Spacer()
			}

			Picker("服务商", selection: $settings.llmProviderID) {
				ForEach(settings.providers) { provider in
					Text(provider.name).tag(provider.id)
				}
			}
			.labelsHidden()
			.frame(maxWidth: 220)
			.onChange(of: settings.llmProviderID) { _, _ in
				settings.commit()
				fetchState = .idle
				testState = .idle
			}

			SecretRow(
				title: "API Key",
				placeholder: "sk-…",
				value: Binding(
					get: { settings.currentProvider.apiKey },
					set: { newValue in
						settings.updateProvider(settings.currentProvider.id) { $0.apiKey = newValue }
					}),
				isEmpty: { settings.currentProvider.apiKey.isEmpty })

			HStack(spacing: 8) {
				Button {
					fetchModels()
				} label: {
					if case .loading = fetchState {
						ProgressView().controlSize(.small)
					} else {
						Text("获取模型列表")
					}
				}
				.disabled(fetchState == .loading || settings.currentProvider.baseURL.isEmpty)

				Button {
					testConnection()
				} label: {
					if case .running = testState {
						ProgressView().controlSize(.small)
					} else {
						Text("测试连接")
					}
				}
				.disabled(testState == .running)
			}
			.controlSize(.small)

			status

			Text("不进总结也能用：翻译引擎选 Apple 系统翻译就完全离线，不填这里也能划词翻译。")
				.font(.system(size: 10))
				.foregroundStyle(.tertiary)
				.fixedSize(horizontal: false, vertical: true)

			Text("密钥只存在本机 ~/Library/Application Support/Insight/secrets.json，权限 0600。")
				.font(.system(size: 10))
				.foregroundStyle(.tertiary)
				.fixedSize(horizontal: false, vertical: true)
		}
		.padding(15)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.22)))
	}

	@ViewBuilder
	private var status: some View {
		switch (fetchState, testState) {
		case (.failed(let message), _):
			line(message, .orange, "exclamationmark.triangle.fill")
		case (.loaded(let count), _) where count == 0:
			line("接口返回的模型列表为空", .orange, "exclamationmark.triangle.fill")
		case (.loaded(let count), _):
			line("已获取 \(count) 个模型 · 当前 \(Settings.shared.currentProvider.model)", .green, "checkmark.circle.fill")
		case (_, .failed(let message)):
			line(message, .orange, "exclamationmark.triangle.fill")
		case (_, .ok(let ms)):
			line("连接正常，首字 \(ms)ms", .green, "checkmark.circle.fill")
		default:
			EmptyView()
		}
	}

	private func line(_ text: String, _ tint: Color, _ icon: String) -> some View {
		Label(text, systemImage: icon)
			.font(.system(size: 11))
			.foregroundStyle(tint)
			.lineLimit(2)
			.textSelection(.enabled)
	}

	private func fetchModels() {
		fetchState = .loading
		let provider = Settings.shared.currentProvider
		Task {
			do {
				let result = try await LLMClient.listModels(provider: provider)
				Settings.shared.updateProvider(provider.id) { $0.models = result.models }
				// Pick the first one when the provider is still on its placeholder: a list the user
				// has to copy a name out of is a step this guide exists to remove.
				if Settings.shared.currentProvider.model.isEmpty, let first = result.models.first {
					Settings.shared.updateProvider(provider.id) { $0.model = first }
				}
				fetchState = .loaded(result.models.count)
			} catch {
				fetchState = .failed(error.localizedDescription)
			}
		}
	}

	private func testConnection() {
		testState = .running
		let provider = Settings.shared.currentProvider
		Task {
			do {
				let result = try await LLMClient.test(provider: provider)
				testState = .ok(ms: result.firstTokenMilliseconds)
			} catch {
				testState = .failed(error.localizedDescription)
			}
		}
	}
}

// MARK: - Window

/// Owns the guide's window. Same shape as `SettingsWindowController`, and for the same reason:
/// the app has no scene graph to hang a `WindowGroup` off.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
	static let shared = OnboardingWindowController()

	private var window: NSWindow?

	private override init() { super.init() }

	static var shouldPresent: Bool {
		!Settings.shared.hasCompletedOnboarding
	}

	func show() {
		if let window {
			window.makeKeyAndOrderFront(nil)
			NSApp.activate(ignoringOtherApps: true)
			return
		}

		let hosting = NSHostingView(rootView: OnboardingView(onFinish: { [weak self] in
			self?.close()
		}))
		// No `.resizable`: the content is a fixed two-card column, and a resizable guide is one
		// more thing to get wrong at the moment the user is deciding whether to trust the app.
		let window = NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
			styleMask: [.titled, .closable],
			backing: .buffered,
			defer: true)
		window.title = "开始使用 Insight"
		window.contentView = hosting
		window.center()
		window.isReleasedWhenClosed = false
		window.delegate = self
		window.collectionBehavior = [.fullScreenAuxiliary]
		self.window = window

		NSApp.activate(ignoringOtherApps: true)
		window.makeKeyAndOrderFront(nil)
	}

	/// Closing the window counts as dealing with the guide. See `OnboardingView.finish`.
	func windowWillClose(_ notification: Notification) {
		if !Settings.shared.hasCompletedOnboarding {
			Settings.shared.hasCompletedOnboarding = true
			Settings.shared.commit()
		}
	}

	private func close() {
		window?.close()
		window = nil
	}
}
