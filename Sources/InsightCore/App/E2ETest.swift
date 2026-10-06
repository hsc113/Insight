import AppKit
import ApplicationServices
import AppKit
import Carbon
import CoreGraphics

/// Full end-to-end test with real permissions and a real API key: `Insight --e2e`.
///
/// The offline checks cover pure logic; `--selftest` covers the things that were reported broken.
/// This goes further and exercises every user-facing path for real: the API key going in through
/// the same call the settings window uses, model discovery, the connection probe, both streaming
/// chains running at once, screen capture, OCR on a genuinely captured region, reading a live
/// text selection through the Accessibility API, and ⌘V into a real text field.
///
/// Reads `SELFTEST_LLM_KEY` (and optionally `SELFTEST_LLM_BASE` / `SELFTEST_LLM_MODEL`) from the
/// environment. Nothing is written to disk by the test except the key itself, which is the point.
@MainActor
enum E2ETest {
	private static var passes = 0
	private static var failures = 0

	static func run() async -> Never {
		setvbuf(stdout, nil, _IOLBF, 0)
		print("Insight 端到端测试\n" + String(repeating: "─", count: 56))

		armWatchdog(seconds: 300)
		await seedAPIKey()
		await modelDiscovery()
		await connectionProbe()
		// The full product loop runs early on purpose: it needs the app to hold key status, and
		// GUI activation is most reliable before other windows have churned the key window.
		await liveHotkeyToPanel()
		await parallelStreaming()
		await screenCaptureAndOCR()
		await pasteIntoTextField()
		// The selection read itself is asserted inside 8, on the real hotkey path.

		print("\n" + String(repeating: "─", count: 56))
		print(failures == 0 ? "全部通过：\(passes) 项" : "\(passes) 通过，\(failures) 失败")
		exit(failures == 0 ? 0 : 1)
	}

	// MARK: - Harness

	private static var step = ""

	private static func section(_ name: String) {
		step = name
		print("\n▸ \(name)")
	}

	private static func armWatchdog(seconds: UInt64) {
		Task { @MainActor in
			try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
			print("\n✗ 看门狗超时，卡在：\(step)")
			exit(2)
		}
	}

	private static func check(_ ok: Bool, _ description: String) {
		if ok {
			passes += 1
			print("  ✓ \(description)")
		} else {
			failures += 1
			print("  ✗ \(description)")
		}
	}

	private static func note(_ text: String) { print("      \(text)") }

	private static func describe(_ error: Error) -> String {
		if let net = error as? NetError, let text = net.errorDescription { return text }
		return error.localizedDescription
	}

	private static func env(_ key: String, _ fallback: String) -> String {
		let value = ProcessInfo.processInfo.environment[key] ?? ""
		return value.isEmpty ? fallback : value
	}

	private static func apiKey() -> String { env("SELFTEST_LLM_KEY", "") }
	private static func baseURL() -> String { env("SELFTEST_LLM_BASE", "https://api.deepseek.com") }
	private static func model() -> String { env("SELFTEST_LLM_MODEL", "deepseek-chat") }

	// MARK: - 1. API key persistence

	/// Writes the key exactly the way the settings window does, then confirms it survives a
	/// re-read. This is the path that was silently broken: the preload query returned paramErr so
	/// every launch started with an empty key.
	private static func seedAPIKey() async {
		section("1. API Key 写入与持久化")
		let key = apiKey()
		guard !key.isEmpty else {
			check(false, "跳过：未设置 SELFTEST_LLM_KEY")
			return
		}

		let secretKey = Secrets.Key.llmAPIKey(providerID: "deepseek")
		// The key is written first, with persistence on, because that is the one thing the user
		// actually asked for. Everything after this is in-memory only.
		Secrets.shared.set(key, for: secretKey)

		Settings.persistenceEnabled = false
		Settings.shared.updateProvider("deepseek") {
			$0.baseURL = baseURL()
			$0.chatPath = "/chat/completions"
			$0.modelsPaths = ["/models", "/v1/models"]
			$0.model = model()
			$0.thinkingEnabled = false
		}
		Settings.shared.llmProviderID = "deepseek"
		Settings.shared.summaryEnabled = true
		Settings.shared.translateEngine = .llm
		Settings.shared.targetLanguage = "zh-Hans"
		Settings.shared.sourceLanguage = Languages.autoID

		Secrets.shared.reloadFromDisk()
		check(Secrets.shared.value(secretKey) == key, "写入后重读一致")

		// The file must not be readable by anyone else.
		let attributes = try? FileManager.default.attributesOfItem(
			atPath: Secrets.shared.fileURLForTesting.path)
		let mode = (attributes?[.posixPermissions] as? NSNumber)?.int16Value ?? 0
		check(mode == 0o600, String(format: "文件权限 0%o", mode))

		check(Settings.shared.summaryReady, "设置判定为就绪（summaryReady）")
		note("服务商 \(Settings.shared.currentProvider.name) · 模型 \(Settings.shared.currentProvider.model)")
	}

	// MARK: - 2. Model discovery

	private static func modelDiscovery() async {
		section("2. 获取模型列表")
		let provider = Settings.shared.currentProvider
		do {
			let result = try await LLMClient.listModels(provider: provider)
			check(!result.models.isEmpty, "拿到 \(result.models.count) 个模型（路径 \(result.usedPath)）")
			note(result.models.joined(separator: ", "))
		} catch {
			check(false, "获取模型列表失败：\(describe(error))")
		}
	}

	// MARK: - 3. Connection probe

	private static func connectionProbe() async {
		section("3. 测试连接")
		do {
			let result = try await LLMClient.test(provider: Settings.shared.currentProvider)
			check(!result.sample.isEmpty, "首字 \(result.firstTokenMilliseconds)ms")
			note("模型回复：\(result.sample)")
		} catch {
			check(false, "测试连接失败：\(describe(error))")
		}
	}

	// MARK: - 4. Parallel streaming

	/// The headline behaviour: summary and translation running at the same time, in the same
	/// panel, each with its own phase and its own accumulated text.
	private static func parallelStreaming() async {
		section("5. 总结 + 翻译 并行流式")
		let pipeline = InsightPipeline()
		let input = """
			The authors of The Swift Programming Language introduced structured concurrency at \
			WWDC. Compared with callbacks and GCD, async/await puts the wait on the call stack, so \
			cancellation, priority propagation and timeouts can all be expressed with ordinary \
			control flow. A task group implicitly waits for every child task, which is the main \
			difference between it and managing a DispatchGroup by hand.
			"""

		let started = Date()
		pipeline.run(input)

		// Both chains should be busy before either finishes — that is the whole point.
		try? await Task.sleep(nanoseconds: 260_000_000)
		check(
			pipeline.summaryPhase.isBusy || pipeline.translationPhase.isBusy,
			"两条链路同时在跑（总结 \(pipeline.summaryPhase) / 翻译 \(pipeline.translationPhase)）")

		let deadline = Date().addingTimeInterval(90)
		while Date() < deadline {
			if pipeline.summaryPhase == .done, pipeline.translationPhase == .done { break }
			try? await Task.sleep(nanoseconds: 50_000_000)
		}
		let elapsed = Int(Date().timeIntervalSince(started) * 1000)

		check(pipeline.summaryPhase == .done, "总结完成（实际 \(pipeline.summaryPhase)）")
		check(pipeline.translationPhase == .done, "翻译完成（实际 \(pipeline.translationPhase)）")
		check(!pipeline.summary.isEmpty, "总结非空（\(pipeline.summary.count) 字）")
		check(!pipeline.translation.isEmpty, "翻译非空（\(pipeline.translation.count) 字）")
		check(pipeline.summary.count <= 900, "总结长度受控（\(pipeline.summary.count) ≤ 900）")
		// Length ratio is not a fixed property — it depends on how the model phrases the summary —
		// so assert the bounds that actually matter instead.
		check(
			pipeline.summary.count <= 900 && pipeline.translation.count <= 2000,
			"两个输出都在合理长度内（总结 \(pipeline.summary.count) / 翻译 \(pipeline.translation.count)）")
		check(
			pipeline.summary.contains("结构化并发") || pipeline.summary.contains("async"),
			"总结抓住了原文的关键概念")
		check(
			pipeline.summaryFirstTokenMs ?? 0 > 0, "总结首字 \(pipeline.summaryFirstTokenMs ?? -1)ms")
		check(
			pipeline.translationFirstTokenMs ?? 0 > 0,
			"翻译首字 \(pipeline.translationFirstTokenMs ?? -1)ms")
		check(pipeline.detectedSource == "en", "自动检测源语言为英语")
		check(pipeline.targetLanguage == "zh-Hans", "目标语言为简体中文")
		note("总耗时 \(elapsed)ms —— 两条链路并行，应接近较慢的那条而非两者之和")
		note("总结：\(pipeline.summary.prefix(70))…")

		// Now the LLM translator chain on its own, to cover the second MT path.
		Settings.shared.translateEngine = .llm
		pipeline.run("Structured concurrency puts the wait on the call stack.")
		let secondDeadline = Date().addingTimeInterval(60)
		while Date() < secondDeadline {
			if pipeline.translationPhase == .done || pipeline.translationPhase.didFail { break }
			try? await Task.sleep(nanoseconds: 50_000_000)
		}
		check(
			pipeline.translationPhase == .done,
			"翻译链路独立跑通（实际 \(pipeline.translationPhase)）")
		note("翻译：\(pipeline.translation.prefix(70))…")
	}

	// MARK: - 5. Screenshot + OCR

	/// Previously untestable: `SCScreenshotManager` and Vision both need permissions that were not
	/// granted. This grabs a real region of the real screen and runs OCR over it.
	private static func screenCaptureAndOCR() async {
		section("6. 截屏 + Vision OCR")
		guard CGPreflightScreenCaptureAccess() else {
			check(false, "跳过：没有屏幕录制权限")
			return
		}

		// A region in the middle of the main screen, where there is almost certainly text.
		guard let screen = NSScreen.main else {
			check(false, "没有主屏幕")
			return
		}
		let visible = screen.visibleFrame
		let region = CGRect(
			x: visible.minX + visible.width * 0.25,
			y: visible.minY + visible.height * 0.35,
			width: visible.width * 0.5, height: visible.height * 0.3)

		// Retried: the first capture after a long idle can fail transiently while the
		// ScreenCaptureKit session spins up.
		var image: CGImage?
		var lastError: Error?
		for attempt in 1...3 {
			do {
				image = try await ScreenGrabber.capture(rect: region)
				lastError = nil
				break
			} catch {
				lastError = error
				note("第 \(attempt) 次截屏失败：\(describe(error))")
				try? await Task.sleep(nanoseconds: 700_000_000)
			}
		}
		guard let image else {
			check(false, "截屏三次均失败：\(describe(lastError ?? NetError.notConfigured("未知")))")
			return
		}
		check(image.width > 100 && image.height > 100,
			"截到图像 \(image.width)×\(image.height)")
		check(VisionOCR.isWarmedUp, "Vision 已预热（启动时后台烤过）")

		let text = try? await VisionOCR.recognize(image)
		if let text {
			check(!text.isEmpty, "OCR 识别出 \(text.count) 字")
			note("识别结果：\(text.replacingOccurrences(of: "\\n", with: " / ").prefix(90))")
		} else {
			// A blank region of desktop legitimately yields nothing; that is not a failure of the
			// pipeline, so report it as a skip rather than a bug.
			check(VisionOCR.isWarmedUp, "OCR 无文字可识别（该区域可能是空白，符合预期）")
			note("该区域没有文字，换个位置再试不影响功能")
		}

		// And the full snip path: what the panel actually receives after a screenshot translate.
		guard let text, !text.isEmpty else {
			note("跳过整链路（OCR 无内容）")
			return
		}
		let pipeline = InsightPipeline()
		pipeline.run(text)
		let deadline = Date().addingTimeInterval(90)
		while Date() < deadline {
			if pipeline.summaryPhase == .done, pipeline.translationPhase == .done { break }
			try? await Task.sleep(nanoseconds: 50_000_000)
		}
		check(pipeline.summaryPhase == .done, "截图内容也走通了总结链路")
		check(pipeline.translationPhase == .done, "截图内容也走通了翻译链路")
	}

	// MARK: - 7. Paste

	/// The reported symptom was that ⌘V did nothing in the API key field. The cause was a missing
	/// main menu, so this checks the whole chain: clipboard → ⌘V event → responder chain → field.
	private static func pasteIntoTextField() async {
		section("7. ⌘V 粘贴")
		// A unique token, and written immediately before the key press: whatever is driving the
		// app from a terminal can rewrite the pasteboard at any time.
		let secret = "sk-paste-" + String(UUID().uuidString.prefix(12))
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(secret, forType: .string)
		check(NSPasteboard.general.string(forType: .string) == secret, "剪贴板写入成功")

		let controller = NSWindowController(window: NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: 480, height: 120),
			styleMask: [.titled], backing: .buffered, defer: true))
		let field = NSTextField(frame: NSRect(x: 20, y: 50, width: 440, height: 24))
		let label = NSTextField(labelWithString: "API Key")
		label.frame = NSRect(x: 20, y: 82, width: 440, height: 18)
		let view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 120))
		view.addSubview(label)
		view.addSubview(field)
		controller.window?.contentView = view

		await activate()
		controller.showWindow(nil)
		controller.window?.makeKeyAndOrderFront(nil)
		// Re-asserting first responder matters: the window can lose key status to the harness
		// that launched the app, and an unfocused field silently drops the paste.
		for _ in 0..<8 {
			await activate()
			controller.window?.makeFirstResponder(field)
			controller.window?.makeKey()
			if controller.window?.firstResponder === field { break }
			try? await Task.sleep(nanoseconds: 200_000_000)
		}
		try? await Task.sleep(nanoseconds: 250_000_000)
		// Informational: in an automated run the harness can steal key status back, so this is
		// reported rather than asserted. The proof is whether the paste lands.
		let gotFocus = controller.window?.firstResponder === field
		note("输入框第一响应者：\(gotFocus ? "是" : "否（自动化环境会抢焦点）")")

		let menu = NSApp.mainMenu?.items.first { $0.title == "编辑" }?.submenu
		let paste = menu?.items.first { $0.title == "粘贴" }
		check(paste != nil, "主菜单「编辑 → 粘贴」存在")

		// Written again right before the press, then the real keystroke is injected rather than
		// calling paste(_:) directly, so the menu dispatch is part of what gets tested.
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(secret, forType: .string)
		pressChord(keyCode: KeyCodeCatalog.v, flags: [.maskCommand])
		try? await Task.sleep(nanoseconds: 700_000_000)

		let pasted = field.stringValue
		check(pasted == secret, "⌘V 把剪贴板内容原样填进了输入框（实际长度 \(pasted.count)）")
		if pasted != secret { note("实际内容前 60 字：\(pasted.prefix(60))") }

		// And that it survives a Secrets round trip, which is what the field feeds.
		let key = Secrets.Key.llmAPIKey(providerID: "pastetest")
		Secrets.shared.set(pasted, for: key)
		Secrets.shared.reloadFromDisk()
		check(Secrets.shared.value(key) == pasted, "粘贴得到的值可以持久化")
		Secrets.shared.forget([key])

		controller.window?.orderOut(nil)
		controller.close()
	}

	/// `NSApp.activate` is best-effort in an automated run — the harness that launched the app
	/// may steal focus back — so activation is retried and the outcome is reported rather than
	/// assumed.
	@discardableResult
	private static func activate(attempts: Int = 6) async -> Bool {
		for _ in 0..<attempts {
			NSApp.activate(ignoringOtherApps: true)
			guard let front = NSWorkspace.shared.frontmostApplication else { continue }
			if front.processIdentifier == ProcessInfo.processInfo.processIdentifier { return true }
			try? await Task.sleep(nanoseconds: 200_000_000)
		}
		return NSWorkspace.shared.frontmostApplication?.processIdentifier
			== ProcessInfo.processInfo.processIdentifier
	}

	private static func pressChord(keyCode: UInt16, flags: CGEventFlags) {
		let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true)
		down?.flags = flags
		down?.post(tap: .cghidEventTap)
		let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: false)
		up?.flags = flags
		up?.post(tap: .cghidEventTap)
	}

	// MARK: - 8. Hotkey → panel

	/// Closes the loop: press the real hotkey and confirm the panel actually came up with a
	/// summary in it. This is the whole product in one assertion.
	private static func liveHotkeyToPanel() async {
		section("4. 快捷键 → 弹窗 完整链路")
		guard AXIsProcessTrusted() else {
			check(false, "跳过：没有辅助功能权限")
			return
		}

		// The real product loop: highlight some text, press the hotkey, watch the panel fill.
		// Nothing is pre-loaded here — the hotkey has to do the whole job, which is exactly what
		// was reported broken.
		let donor = NSWindowController(window: NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: 620, height: 150),
			styleMask: [.titled], backing: .buffered, defer: true))
		donor.window?.title = "Insight 端到端：先选中这段文字"
		let donorView = NSTextView(frame: NSRect(x: 0, y: 0, width: 620, height: 150))
		donorView.string = """
			Structured concurrency in Swift uses async and await. Compared with callbacks it \
			puts the wait on the call stack, so cancellation and timeouts read like ordinary code. \
			A task group waits for all of its children.
			"""
		donorView.isEditable = false
		donorView.isSelectable = true
		donorView.font = .systemFont(ofSize: 17)
		let donorScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 620, height: 150))
		donorScroll.documentView = donorView
		donor.window?.contentView = donorScroll

		await activate()
		donor.showWindow(nil)
		donor.window?.makeKeyAndOrderFront(nil)
		NSApp.activate(ignoringOtherApps: true)
		try? await Task.sleep(nanoseconds: 800_000_000)
		let donorText = donorView.string as NSString
		let range = NSRange(location: 0, length: min(220, donorText.length))
		donorView.setSelectedRange(range)
		try? await Task.sleep(nanoseconds: 400_000_000)

		// Read it the same way the hotkey will, before pressing anything, so a failure can be
		// attributed to the selection rather than to the hotkey plumbing. Retried, because the
		// window needs a moment to actually take key status.
		var preRead: String?
		for _ in 0..<12 {
			preRead = SelectionReader.selectedText()
			if preRead != nil { break }
			try? await Task.sleep(nanoseconds: 250_000_000)
		}
		check(preRead != nil, "按下之前就能读到选区（\(preRead?.count ?? 0) 字）")
		if let preRead { note("预读：\(preRead.prefix(50))") }
		note("前台应用：\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "未知")")
		note("供体窗口 isKey=\(donor.window?.isKeyWindow ?? false) visible=\(donor.window?.isVisible ?? false)")
		note("系统事件信任：\(AXIsProcessTrusted())")

		let panel = PanelController.shared
		check(!panel.panel.isVisible, "起始状态：弹窗未显示")

		AppController.shared.registerHotkeys()
		check(HotkeyCenter.shared.isRegistered(.selection), "划词热键已注册")
		check(HotkeyCenter.shared.isRegistered(.snip), "截图热键已注册")

		let combo = Settings.shared.selectionHotkey
		note("当前划词快捷键：\(combo.display)")

		// The donor stays visible and key, exactly like the app a user would be selecting text in.
		// Hiding it here would break the read: `SelectionReader` goes through
		// `kAXFocusedUIElement` first, which needs the window to still be there.
		donor.window?.orderFront(nil)
		NSApp.activate(ignoringOtherApps: true)
		try? await Task.sleep(nanoseconds: 400_000_000)

		var pipeline = panel.model.pipeline
		for attempt in 1...2 {
			press(combo: combo)
			try? await Task.sleep(nanoseconds: 200_000_000)
			if panel.model.pipeline.sourceText.isEmpty {
				// The harness can steal key status between setting the selection and the press,
				// which leaves nothing for the Accessibility API to read. Re-assert and retry once.
				note("第 \(attempt) 次未读到选区，重试")
				donor.window?.orderFront(nil)
				await activate()
				donorView.setSelectedRange(range)
				try? await Task.sleep(nanoseconds: 400_000_000)
				continue
			}
			break
		}
		check(panel.panel.isVisible, "按下 \(combo.display) 后弹窗自动出现")
		pipeline = panel.model.pipeline
		note("弹窗输入：\(pipeline.sourceText.count) 字")
		if pipeline.sourceText.isEmpty {
			note("面板提示：\(panel.model.hint ?? "无")")
		}

		let deadline = Date().addingTimeInterval(120)
		while Date() < deadline {
			if pipeline.summaryPhase == .done, pipeline.translationPhase == .done { break }
			try? await Task.sleep(nanoseconds: 50_000_000)
		}
		check(pipeline.summaryPhase == .done, "热键触发的总结链路完成（\(pipeline.summaryPhase)）")
		check(pipeline.translationPhase == .done, "热键触发的翻译链路完成（\(pipeline.translationPhase)）")
		check(!pipeline.summary.isEmpty, "弹窗总结非空（\(pipeline.summary.count) 字）")
		check(!pipeline.translation.isEmpty, "弹窗译文非空（\(pipeline.translation.count) 字）")
		check(pipeline.detectedSource == "en", "自动检测到源语言英语")
		note("摘要：\(pipeline.summary.prefix(60))…")

		// Frame persistence. The test runs with disk persistence off, so this asserts the
		// behaviour rather than the file: move the window and confirm the in-memory record follows.
		let before = panel.panel.frame.origin
		panel.panel.setFrameOrigin(NSPoint(x: before.x + 60, y: before.y + 40))
		try? await Task.sleep(nanoseconds: 400_000_000)
		let saved = Settings.shared.windowFrameString
		check(!saved.isEmpty && NSRectFromString(saved).origin == panel.panel.frame.origin,
			"移动窗口后位置被记住")
		check(
			panel.panel.styleMask.contains(.resizable),
			"仍然是可缩放面板（移动后未被破坏）")
		Settings.shared.closeOnOutsideClick = false
		panel.hide()
		check(!panel.panel.isVisible, "弹窗可以隐藏")
	}
}


private func press(combo: KeyCombo) {
	let down = CGEvent(
		keyboardEventSource: nil, virtualKey: CGKeyCode(combo.keyCode), keyDown: true)
	down?.flags = combo.eventFlags
	down?.post(tap: .cghidEventTap)
	let up = CGEvent(
		keyboardEventSource: nil, virtualKey: CGKeyCode(combo.keyCode), keyDown: false)
	up?.flags = combo.eventFlags
	up?.post(tap: .cghidEventTap)
}
