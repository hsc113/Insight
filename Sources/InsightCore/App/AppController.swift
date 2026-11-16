import AppKit

/// Wires hotkeys to the capture paths to the panel. The only place that knows the whole flow.
@MainActor
final class AppController {
	static let shared = AppController()

	private init() {}

	func start() {
		// Before the hotkeys, so a keypress in the first moments still lands on a usable ledger
		// rather than on top of it.
		UsageLedger.shared.load()

		HotkeyCenter.shared.start()
		registerHotkeys()
		presentOnboardingIfNeeded()
		// `--settings-general` on its own is enough. `contains(_:)` on `[String]` is an exact
		// element match, so testing only for "--settings" meant the documented one-flag invocation
		// opened no window at all — the argument block was simply never entered.
		//
		// `--settings` now lands where 设置… lands, rather than on 接口: there is one default page,
		// and a dev flag that opens a different one is a flag that lies about the app's behaviour.
		if CommandLine.arguments.contains("--settings")
			|| CommandLine.arguments.contains("--settings-general")
		{
			Task { @MainActor in
				try? await Task.sleep(nanoseconds: 400_000_000)
				SettingsWindowController.shared.show()
			}
		}
		if CommandLine.arguments.contains("--demo") {
			Task { @MainActor in
				try? await Task.sleep(nanoseconds: 600_000_000)
				PanelController.shared.present(text: DemoStream.sampleInput)
				DemoStream.run(PanelController.shared.model.pipeline)
			}
		}
		if CommandLine.arguments.contains("--snapshot") {
			Snapshot.run()
		}
		// Vision's first text-recognition request compiles a model and can take over a minute
		// on a cold cache (measured at 60–120s). Do it on a background utility queue now
		// so the first 截图翻译 isn't the one that pays for it.
		VisionOCR.warmUp()
		warmPanel()
	}

	/// The first-run guide, on a normal launch and only on a normal launch.
	///
	/// Every other entry point is a deliberate act — `--demo` to look at the panel, `--selftest`
	/// and `--e2e` to run checks, `--settings` to open the settings window — and a window arriving
	/// on top of any of them is at best noise and at worst a test that cannot finish. So the flag
	/// check is exclusive rather than a permission list: **no flag at all** is the only launch that
	/// gets the guide.
	private func presentOnboardingIfNeeded() {
		let launchesWithAFlag = CommandLine.arguments.dropFirst().contains { $0.hasPrefix("--") }
		guard !launchesWithAFlag, OnboardingWindowController.shouldPresent else { return }
		Task { @MainActor in
			try? await Task.sleep(nanoseconds: 500_000_000)
			OnboardingWindowController.shared.show()
		}
	}

	/// Building the panel means creating an `NSPanel` and rendering its SwiftUI hierarchy, which
	/// costs a couple of hundred milliseconds. Doing that lazily would put the whole cost on the
	/// first hotkey press, so it is paid here instead — after launch, when the user is not yet
	/// waiting on anything.
	private func warmPanel() {
		Task { @MainActor in
			try? await Task.sleep(nanoseconds: 1_200_000_000)
			let start = DispatchTime.now()
			_ = PanelController.shared
			Log.ui("panel warm in \(Self.ms(start))ms")
		}
	}

	func registerHotkeys() {
		let settings = Settings.shared
		HotkeyCenter.shared.register(.selection, combo: settings.selectionHotkey) { [weak self] in
			self?.selectionTranslate()
		}
		HotkeyCenter.shared.register(.snip, combo: settings.snipHotkey) { [weak self] in
			self?.snipTranslate()
		}
	}

	// MARK: - 划词翻译

	/// Three steps, in this order, deliberately.
	///
	/// 1. **The window goes up immediately.** It used to go up last, after the Accessibility read
	///    and the pasteboard write — and since the read is synchronous cross-process IPC that can
	///    take 30–400 ms on a heavy app, every press began with a third of a second of nothing.
	/// 2. **The Accessibility read leaves the main thread**, so neither it nor anything it waits on
	///    blocks input while it runs.
	/// 3. **Copy, then analyse**, back on the main actor, into a panel that is already on screen.
	///
	/// Steps 1 and 2 are why this reads as one action rather than a sequence.
	func selectionTranslate() {
		guard Permissions.hasAccessibility else {
			Permissions.requestAccessibility()
			PanelController.shared.presentPermissions(.accessibility)
			return
		}

		// Sampled here, on the main actor, because the pointer will have moved by the time the
		// background read gets going and the element under the *current* position is not the one
		// holding the selection.
		let cursor = SelectionReader.CursorSnapshot.current()
		// A word selected inside our own result is a lookup, not a new capture — and ⌘C would copy
		// *that* word and turn the lookup into a fresh translation. Decided here, on the main actor,
		// where the panel's views can be read.
		let allowCopy = PanelController.shared.selectedTextInsidePanel() == nil
		let token = PanelController.shared.beginCapture(label: "读取选区…")
		let started = DispatchTime.now()

		// `AppController.shared` rather than a captured `self`: it is a singleton, so there is no
		// instance to keep alive, and the detached closure is only alive for the length of the read.
		Task.detached(priority: .userInitiated) {
			let text = AppController.readSelection(
				ax: { SelectionReader.selectedText(cursor: cursor) },
				allowCopy: allowCopy, copy: .live)
			await MainActor.run {
				// A read that has been superseded must not land: pressing ⌥D twice quickly would
				// otherwise let the slower first read overwrite the second one's content.
				guard PanelController.shared.isCurrentCapture(token) else { return }
				Log.capture("selection \(text?.count ?? 0) chars in \(Self.ms(started))ms")
				AppController.shared.handleCapturedText(text, token: token)
			}
		}
	}

	/// Accessibility first, because it is free and does not touch anything; a synthetic ⌘C only when
	/// that found nothing. Apps that do not expose `AXSelectedText` (Chromium pages, Electron, PDF
	/// viewers) used to fall through to the clipboard fallback, which translates the *previous* copy
	/// rather than the text just dragged over — the F3-translates-the-wrong-thing bug. See
	/// `CopyCapture` for why the old "no forced ⌘C" decision was reversed.
	///
	/// Takes both readers as values so the order can be checked without a real target app.
	nonisolated static func readSelection(
		ax: @Sendable () -> String?, allowCopy: Bool, copy: CopyCapture
	) -> String? {
		if let text = ax() { return text }
		guard allowCopy else { return nil }
		return copy.selectedText()
	}

	/// The capture landed. A document selection always wins; the panel's own selection is only
	/// consulted when there is none, which is the case this file used to get wrong by checking it
	/// first — the panel is a `.nonactivatingPanel` brought forward with `makeKeyAndOrderFront`, so
	/// `isKeyWindow` is often still true while the user has a fresh selection in their document, and
	/// the second ⌥D turned into a lookup of a word from the *first* result.
	/// Not `private` for the same reason as the checkable views: the self test drives the whole
	/// capture→fallback→panel path through this one funnel, and a copy just for the test would
	/// not be the same path.
	func handleCapturedText(_ text: String?, token: Int) {
		let panel = PanelController.shared
		if let text {
			// Re-pressing the key on an unchanged selection whose last attempt finished cleanly.
			// Re-running would spend a request to reproduce the answer already on screen. A run that
			// *failed* still re-runs, because that is what pressing the key again means.
			if text == panel.model.input, panel.model.pipeline.runIsSettled {
				panel.endCapture(hint: "和当前内容相同，已跳过")
				return
			}
			captureSource(text)
			panel.present(text: text)
			return
		}

		// Nothing outside Insight was selected. A short selection inside our own result is the word
		// lookup, and it gets its own small card so the translation the user was reading survives.
		if let word = panel.selectedTextInsidePanel() {
			Log.capture("word lookup in panel: \(word)")
			panel.lookup(word: word)
			return
		}

		// Still nothing: the clipboard fallback, when the user has it on. The press was an
		// explicit ask, the panel labels the result 「来源：剪贴板」, and `captureSource` is
		// skipped — the text is already on the pasteboard, writing it back would only bump the
		// change count.
		if Settings.shared.clipboardFallback, let clipped = ClipboardWriter.pastedText() {
			Log.capture("clipboard fallback: \(clipped.count) chars")
			panel.present(text: clipped, source: .clipboard)
			return
		}

		panel.endCapture(hint: "没有检测到选中的文字")
	}

	/// Puts freshly captured text on the pasteboard, if the user asked for that.
	///
	/// Called for both entry points (selection and screenshot) because from here on they are the
	/// same thing: text Insight obtained on the user's behalf. Skipped for a word looked up inside
	/// the panel — that word came from our own output, and copying it back would fight whatever the
	/// user was doing with the clipboard before they pressed the key.
	private func captureSource(_ text: String) {
		guard Settings.shared.autoCopySourceToClipboard else { return }
		ClipboardWriter.copy(text)
	}

	// MARK: - 截图翻译

	func snipTranslate() {
		guard Permissions.hasScreenRecording else {
			Permissions.requestScreenRecording()
			PanelController.shared.presentPermissions(.screenRecording)
			return
		}

		let started = DispatchTime.now()
		SnipController.shared.begin { image in
			guard let image else { return }
			// The overlay is gone by now, so the panel goes up immediately and shows "识别中…"
			// while Vision runs. A full-resolution screenshot takes a second or more, and the previous
			// result stays readable behind the notice the whole time.
			let token = PanelController.shared.beginCapture(label: "识别截图中…")
			Task { @MainActor in
				Log.capture("snip captured in \(Self.ms(started))ms, recognizing…")
				do {
					let text = try await VisionOCR.recognize(image)
					guard PanelController.shared.isCurrentCapture(token) else { return }
					Log.capture("recognized \(text.count) chars in \(Self.ms(started))ms total")
					self.captureSource(text)
					PanelController.shared.present(text: text)
				} catch {
					// A failed OCR must not empty a panel that already had an answer in it.
					PanelController.shared.endCapture(hint: "截图识别失败：\(error.localizedDescription)")
				}
			}
		}
	}

	private static func ms(_ start: DispatchTime) -> Int {
		Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
	}
}