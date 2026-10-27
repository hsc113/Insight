import AppKit
import Carbon
import ApplicationServices
import Darwin
import CoreGraphics

/// End-to-end self test, run with `Insight --selftest`.
///
/// Everything here is a thing that was reported broken and could not be caught by the offline
/// checks: whether a Carbon hotkey actually fires when the key is pressed, whether a secret
/// survives a restart, whether every menu row has a title, and whether the real LLM endpoint
/// streams. Prints a report and exits non-zero on failure.
@MainActor
enum SelfTest {
	private static var failures = 0
	private static var passes = 0
	private static var skips = 0

	static func run() async -> Never {
		print("Insight 自检\n" + String(repeating: "─", count: 52))

		setvbuf(stdout, nil, _IOLBF, 0)
		armWatchdog()
		permissions()
		await secrets()
		await hotkeys()
		await panelBehaviour()
		await draftReturnBinding()
		await clipboardFallback()
		await panelChrome()
		menu()
		settingsWindowHotkeys()
		await llm()

		print("\n" + String(repeating: "─", count: 52))
		let summary = skips > 0 ? "\(passes) 通过，\(failures) 失败，\(skips) 跳过" : "\(passes) 通过"
		print(failures == 0 ? "全部通过：\(summary)" : summary)
		exit(failures == 0 ? 0 : 1)
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

	private static var step = ""

	/// A skip is not a failure. Reporting it as one just trains you to ignore red.
	private static func skip(_ description: String) {
		skips += 1
		print("  – \(description)（跳过）")
	}

	private static func section(_ name: String) {
		step = name
		print("\n▸ \(name)")
	}

	/// A security prompt or a wedged securityd would otherwise hang the whole run silently.
	/// The watchdog names the step it was in, which is the only useful part of a hang.
	private static func armWatchdog(seconds: UInt64 = 150) {
		let expected = step
		Task { @MainActor in
			try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
			print("\n✗ 看门狗超时，卡在：\(step)（进入时为：\(expected)）")
			exit(2)
		}
	}

	// MARK: - Permissions

	private static func permissions() {
		section("权限")
		let accessibility = AXIsProcessTrusted()
		let accessibilityText = accessibility ? "已授权" : "未授权（划词与注入按键都不可用）"
		check(accessibility, "辅助功能：\(accessibilityText)")

		let screen = CGPreflightScreenCaptureAccess()
		let screenText = screen ? "已授权" : "未授权（截图翻译不可用）"
		check(screen, "屏幕录制：\(screenText)")
	}

	// MARK: - Secrets

/// Writes a key, reads it back, asserts the file mode, then clears up — the whole path a real
	/// API key takes when it is typed into the settings window.
	private static func secrets() async {
		section("密钥持久化")
		armWatchdog(seconds: 40)
		// In-memory only from here on: the test must not rewrite the user's config.json.
		Settings.persistenceEnabled = false

		let report = await Task.detached(priority: .userInitiated) { () -> String in
			let key = Secrets.Key.llmAPIKey(providerID: "selftest")
			let probe = "sk-selftest-\(Int.random(in: 1000...9999))"
			var lines: [String] = []

			Secrets.shared.set(probe, for: key)
			lines.append("写入后立即可读: \(Secrets.shared.value(key) == probe)")

			// Re-instantiate the facade the way a relaunch would, which re-reads the file.
			Secrets.shared.reloadFromDisk()
			lines.append("重读一致: \(Secrets.shared.value(key) == probe)")

			let attributes = try? FileManager.default.attributesOfItem(
				atPath: Secrets.shared.fileURLForTesting.path)
			let permissions = (attributes?[.posixPermissions] as? NSNumber)?.int16Value ?? 0
			lines.append(String(format: "文件权限: 0%o (0600=%@)", permissions, permissions == 0o600 ? "是" : "否"))

			Secrets.shared.delete(key)
			lines.append("删除后为空: \(Secrets.shared.value(key).isEmpty)")
			// Only the probe keys are touched. An earlier version called `removeEverything()` here
			// and deleted the user's real API keys — a test must never be able to do that — and a
			// later version left its own empty entries behind, which then showed up in the
			// secrets file forever.
			Secrets.shared.forget(Set([key]))
			return lines.joined(separator: "\n      ")
		}.value

		print("      " + report)
		check(report.contains("重读一致: true"), "重启后 API Key 不丢（写入 → 重新读盘 → 一致）")
		check(report.contains("是") && report.contains("文件权限"), "密钥文件权限为 0600")
		check(report.contains("写入后立即可读: true"), "写入后立即可读")
		check(report.contains("删除后为空: true"), "删除生效")
	}

	// MARK: - Hotkeys

	/// Registers real Carbon hotkeys and injects the matching key events. This is the only way to
	/// prove the hotkey path end to end: the offline checks can verify registration succeeds but
	/// not that the handler is ever reached.
	private static func hotkeys() async {
		section("全局快捷键（注入按键端到端验证）")
		armWatchdog(seconds: 30)
		guard AXIsProcessTrusted() else {
			check(false, "跳过：没有辅助功能权限，无法注入按键事件")
			return
		}

		let center = HotkeyCenter.shared
		guard center.start() else {
			check(false, "事件 tap 创建失败（辅助功能权限？）")
			return
		}

		// Each combo is registered, pressed and released on its own. Registering several against
		// the same id would silently replace the earlier one, since `register` unbinds first.
		let cases: [(String, KeyCombo)] = [
			("⌥D", KeyCombo(keyCode: KeyCodeCatalog.d, carbonModifiers: UInt32(optionKey))),
			("⌥F", KeyCombo(keyCode: KeyCodeCatalog.f, carbonModifiers: UInt32(optionKey))),
			// A bare function key — the case that was reported unrecordable.
			("F1（裸）", KeyCombo(keyCode: 0x7A, carbonModifiers: 0)),
			// And one with a modifier, to prove the modifier matching is not over-eager.
			("⌘⇧K", KeyCombo(
				keyCode: KeyCodeCatalog.k,
				carbonModifiers: UInt32(cmdKey) | UInt32(shiftKey))),
		]

		var firedCount = 0
		for (label, combo) in cases {
			let hits = Counter()
			center.register(.selection, combo: combo) { hits.increment() }
			check(center.isRegistered(.selection), "\(label) 注册成功")

			for tap in [CGEventTapLocation.cghidEventTap, .cgSessionEventTap] {
				press(combo: combo, tap: tap)
				try? await Task.sleep(nanoseconds: 150_000_000)
			}
			try? await Task.sleep(nanoseconds: 250_000_000)

			if hits.value > 0 { firedCount += 1 }
			check(hits.value > 0, "\(label) 按下后触发（\(hits.value) 次）")
			center.unregisterAll()
		}

		// A key that is not bound must not fire anything.
		let stray = Counter()
		center.register(.selection, combo: cases[0].1) { stray.increment() }
		press(keyCode: KeyCodeCatalog.z, flags: [.maskShift], tap: .cghidEventTap)
		try? await Task.sleep(nanoseconds: 300_000_000)
		check(stray.value == 0, "未绑定的按键不会误触发")
		center.unregisterAll()
		center.stop()

		let text = "\(firedCount)/\(cases.count) 个组合验证通过"
		check(firedCount == cases.count, text)
	}

	/// Injects one key press at a given tap location. `.cghidEventTap` is where a real keyboard
	/// event lands, `.cgSessionEventTap` is the session-level equivalent; which one the system
	/// accepts is itself worth checking, since a dropped synthetic event would look exactly like
	/// a broken hotkey.
	private static func press(keyCode: UInt16, flags: CGEventFlags, tap: CGEventTapLocation) {
		let down = CGEvent(
			keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true)
		down?.flags = flags
		down?.post(tap: tap)
		let up = CGEvent(
			keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: false)
		up?.flags = flags
		up?.post(tap: tap)
	}

	private static func press(combo: KeyCombo, tap: CGEventTapLocation) {
		press(keyCode: combo.keyCode, flags: combo.eventFlags, tap: tap)
	}

	private static func panelBehaviour() async {
		section("面板：Esc 关闭与窗口按钮")
		let panel = PanelController.shared
		panel.present(text: "Esc 关闭行为的验证文本")
		try? await Task.sleep(nanoseconds: 350_000_000)
		check(panel.panel.isVisible, "弹窗可以显示")
		check(
			panel.panel.styleMask.contains(.resizable) && panel.panel.styleMask.contains(.titled),
			"仍是可缩放面板（隐藏红黄绿按钮不等于丢掉标题栏样式）")
		for button in [
			panel.panel.standardWindowButton(.closeButton),
			panel.panel.standardWindowButton(.miniaturizeButton),
			panel.panel.standardWindowButton(.zoomButton),
		] {
			check(button?.isHidden ?? true, "一个系统窗口按钮已隐藏")
		}

		// Esc, injected for real rather than called directly.
		Settings.shared.closeOnOutsideClick = false
		for isDown in [true, false] {
			let event = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: isDown)
			event?.post(tap: .cghidEventTap)
		}
		try? await Task.sleep(nanoseconds: 450_000_000)
		check(!panel.panel.isVisible, "Esc 关闭弹窗")
		Settings.shared.closeOnOutsideClick = true
	}

	/// Return analysing the draft, ⇧Return being a newline — both driven by injected key events,
	/// because the whole mechanism is a local `NSEvent` monitor and calling `applyDraft()` directly
	/// would assert nothing about it.
	///
	/// The assertions are on `model.input` rather than on the pipeline's phase: `applyDraft` is the
	/// only writer of `input` from a draft, and waiting on a real request would make the check
	/// depend on the network.
	private static func draftReturnBinding() async {
		section("输入框：回车分析 / ⇧回车换行")
		armWatchdog(seconds: 30)
		let panel = PanelController.shared
		let model = panel.model

		panel.present(text: "面板里已有的内容")
		// Make the panel key so `handleReturn`'s `panel.isKeyWindow` guard passes, then expand the
		// editor. `InputStrip` auto-focuses it, which is what puts an `NSTextView` on the responder
		// chain — the third guard in `handleReturn`.
		let isKey = await makePanelKey(panel)
		model.inputExpanded = true
		model.draft = "第一行"
		let opened = await waitForEditor(panel, holding: "第一行")

		// Asserted separately from the behaviour below, because these are the two conditions
		// `handleReturn` gates on. Without them a failure reports "Return did nothing", which is
		// true and useless — with them it says which gate was shut. (This is exactly how the
		// auto-focus bug above was found: all five behaviour assertions failed and none of them
		// said why.)
		check(isKey, "前置：面板是 key 窗口（这是 handleReturn 的第一道门）")
		check(
			opened,
			"前置：展开输入框后光标落在文本框里，且内容已同步（不再靠固定 sleep）")

		pressReturn(flags: [])
		try? await Task.sleep(nanoseconds: 350_000_000)
		check(model.input == "第一行", "回车把草稿送进管线（model.input 被改写）")
		check(!model.inputExpanded, "回车分析后输入框收起")

		// Re-open and ask for a newline instead. This is the case that used to fail about a third of
		// the time: the editor is *rebuilt* here, so a fixed sleep had to guess how long that takes.
		model.inputExpanded = true
		model.draft = "第一行"
		let reopened = await waitForEditor(panel, holding: "第一行")
		check(reopened, "前置：重新展开后文本框就绪（这里原来靠固定 sleep，按键会落空）")

		pressReturn(flags: [.maskShift])
		// Wait for the press to *land*, then assert its content. Waiting for the content directly
		// would turn the two checks below into tautologies.
		let landed = await waitUntil { model.draft != "第一行" }
		check(model.inputExpanded, "⇧回车不收起输入框（没有触发分析）")
		check(landed && model.draft.count > "第一行".count, "⇧回车在草稿里插入了一个换行")
		check(model.draft.contains("\n"), "插入的是换行符而不是别的字符")

		// ⌘↘Return, from the old binding, still analyses — kept as a silent alias so the muscle
		// memory of the previous shortcut does not break.
		pressReturn(flags: [.maskCommand])
		try? await Task.sleep(nanoseconds: 350_000_000)
		check(model.input != "面板里已有的内容", "⌘回车仍然可用（静默别名）")

		model.inputExpanded = false
		panel.hide()
	}

	/// The fallback path, end to end through the real funnel `handleCapturedText`: no selection
	/// anywhere, a canary on the pasteboard, and the panel has to show the canary **labelled**.
	/// The pipeline this starts fires against the configured provider, same as 回车分析 above.
	private static func clipboardFallback() async {
		section("剪贴板回退")
		armWatchdog(seconds: 40)

		let model = PanelController.shared.model
		let pasteboard = NSPasteboard.general
		let saved = pasteboard.string(forType: .string)
		defer {
			pasteboard.clearContents()
			if let saved { pasteboard.setString(saved, forType: .string) }
		}

		// The canary goes through `copy` so the read is exercised against a real pasteboard
		// round trip, not a fabricated model state.
		let canary = "Insight 剪贴板回退自检 \(Int.random(in: 1000...9999))"
		ClipboardWriter.copy(canary)

		let token = PanelController.shared.beginCapture(label: "读取选区…")
		AppController.shared.handleCapturedText(nil, token: token)
		check(model.input == canary, "无选区时改用剪贴板内容")
		check(model.sourceLabel == "来源：剪贴板", "面板标注「来源：剪贴板」")

		// A plain selection present clears the label — the badge must not stick to the panel.
		model.present(text: "一段普通的选中文本")
		check(model.sourceLabel == nil, "换成选区来源后标注消失")

		// Off means off: the empty clipboard exercises the same "give up" leg as a disabled
		// fallback, and both must land on the plain hint without touching the input.
		let fallback = Settings.shared.clipboardFallback
		Settings.shared.clipboardFallback = false
		defer { Settings.shared.clipboardFallback = fallback }
		pasteboard.clearContents()

		let token2 = PanelController.shared.beginCapture(label: "读取选区…")
		AppController.shared.handleCapturedText(nil, token: token2)
		check(model.transientHint == "没有检测到选中的文字", "关闭回退且剪贴板为空时给出提示")
		check(model.input == "一段普通的选中文本", "提示不动面板上已有的内容")
	}

	private static func pressReturn(flags: CGEventFlags) {
		for isDown in [true, false] {
			let event = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: isDown)
			event?.flags = flags
			event?.post(tap: .cghidEventTap)
		}
	}

	/// The window drag, the capture states, and the stores — the parts that only exist once the
	/// window has been built.
	private static func panelChrome() async {
		section("面板：拖拽区、采集状态、历史与统计")
		armWatchdog(seconds: 30)
		let panel = PanelController.shared
		let model = panel.model

		check(
			panel.panel.contentView is PanelHostingView<ResultView>,
			"面板用的是 PanelHostingView（拖拽交给 AppKit，不是 SwiftUI 手势）")
		check(
			panel.panel.animationBehavior == .none,
			"关闭了 frame 动画（.documentWindow 会把程序化移动变成缓动）")
		check(
			panel.panel.isMovableByWindowBackground == false,
			"仍然不走背景拖拽（会抢走分割条的手势）")

		// The drag strip has to be the real 30pt at the real top-right corner, or the three buttons
		// would be unclickable and the window would be harder to grab than it looks.
		let bounds = panel.panel.contentView?.bounds ?? .zero
		let inStrip = { (x: CGFloat, y: CGFloat) in
			PanelHostingView<ResultView>.isInDragStrip(
				NSPoint(x: x, y: y), bounds: bounds)
		}
		check(bounds.width > 0, "面板已经有内容视图")
		check(
			inStrip(40, bounds.height - 1), "标题栏可拖动")
		check(
			!inStrip(40, bounds.height - PanelChrome.dragStripHeight - 1),
			"标题栏下方不可拖动（否则抢走分割条）")
		check(
			!inStrip(bounds.width - 10, bounds.height - 1), "三个按钮不可拖动")

		// Capture states: the window must come up *before* the text is known, and a capture that
		// finds nothing must not take the previous answer with it.
		panel.present(text: "上一次的结果")
		try? await Task.sleep(nanoseconds: 250_000_000)
		let token = panel.beginCapture(label: "读取选区…")
		check(model.isCapturing, "开始采集后进入采集状态")
		check(panel.panel.isVisible, "采集一开始就显示面板（不等选区读完）")
		check(model.input == "上一次的结果", "采集不清空上一次的输入")
		check(panel.isCurrentCapture(token), "刚拿到的 token 是最新的")
		panel.beginCapture(label: "读取选区…")
		check(!panel.isCurrentCapture(token), "过期的采集 token 会被识别")
		panel.endCapture(hint: "没有检测到选中的文字")
		check(!model.isCapturing, "结束后回到空闲")
		check(model.transientHint != nil, "给一句提示")
		check(model.input == "上一次的结果", "提示之后输入还在")
		panel.hide()

		// The store, at the level the settings page reads it.
		let today = UsageDay.key()
		check(UsageDay.isValidKey(today), "用量统计的日期键合法")

		// The ranges are nested — 今天 ⊆ 近 7 天 ⊆ 近 30 天 ⊆ 全部 — and that holds on **every**
		// date, which is what makes it worth asserting.
		//
		// This used to assert 今天 ≥ 昨天, which is not an invariant at all: at the start of a day
		// today's counter is zero while yesterday's is not. It passed on the day it was written and
		// went red the next morning, with a real previous day's data on disk — a smoke check that
		// cries wolf once a day is worse than no smoke check. `.yesterday` is deliberately absent
		// from the chain: it is not nested with today.
		let nested: [UsageRange] = [.today, .last7, .last30, .all]
		let calls = nested.map { UsageLedger.shared.totals($0).totalCalls }
		check(
			zip(calls, calls.dropFirst()).allSatisfy { $0 <= $1 },
			"用量区间嵌套：今天 ≤ 近7天 ≤ 近30天 ≤ 全部（实测 \(calls.map(String.init).joined(separator: " ≤ "))）")
	}

	/// Makes the panel the key window, retrying until it takes.
	///
	/// `makeKeyAndOrderFront` is a request, not a command: it is not synchronous with the window
	/// server, and macOS **silently declines it** while an activation is in flight. `--selftest`
	/// runs in a process launched in the background, which makes that likely rather than rare —
	/// measured at roughly one run in three.
	///
	/// The failure is worth this much code because of how it presents: the section reports eight
	/// failures, seven of which say "回车没有把草稿送进管线" and are consequences, and the one that
	/// names the cause is buried first in the list. A precondition that quietly does not hold turns
	/// one broken line into a page of misleading ones.
	private static func makePanelKey(_ panel: PanelController) async -> Bool {
		for _ in 0..<10 {
			panel.panel.makeKeyAndOrderFront(nil)
			if await waitUntil(timeout: 300_000_000, { panel.panel.isKeyWindow }) { return true }
		}
		return panel.panel.isKeyWindow
	}

	/// Bounded wait for a condition to become true.
	///
	/// Every fixed `sleep` in a key-injection test is a race that passes until the machine is busy.
	@discardableResult
	private static func waitUntil(
		timeout: UInt64 = 2_000_000_000, _ condition: () -> Bool
	) async -> Bool {
		let deadline = DispatchTime.now().uptimeNanoseconds + timeout
		while DispatchTime.now().uptimeNanoseconds < deadline {
			if condition() { return true }
			try? await Task.sleep(nanoseconds: 20_000_000)
		}
		return condition()
	}

	/// Waits for the panel's `TextEditor` to be on the responder chain **and holding `text`**.
	///
	/// `isTextInputResponder` alone is not enough: it says *a* text view is there, not that it is
	/// the one the panel just built or that it has picked up the binding yet. An injected key goes
	/// to the first responder, so a press delivered a moment early is not queued — it is lost
	/// silently. That is why the ⇧回车 check failed about a third of the time while every
	/// neighbouring assertion passed: the two behaviour assertions only depend on `handleReturn`
	/// deciding not to act, which is synchronous, and the two content assertions depend on the key
	/// actually reaching a live text view.
	///
	/// The budget is deliberately generous. Building the `TextEditor` the first time pulls in the
	/// whole text system, and measured on this machine that occasionally lands in the 2–8 second
	/// range — slow, but not wrong. A tight timeout here does not make the test stricter, it makes
	/// it report the machine's mood. Because the wait is bounded, the success path still costs
	/// nothing.
	/// How long the editor is given to exist and pick up the binding. See `waitForEditor`.
	private static let editorReadyBudget: UInt64 = 8_000_000_000

	private static func waitForEditor(
		_ panel: PanelController, holding text: String
	) async -> Bool {
		await waitUntil(timeout: editorReadyBudget) {
			guard panel.panel.isKeyWindow,
				PanelController.isTextInputResponder(panel.panel.firstResponder),
				let view = textView(in: panel.panel.firstResponder)
			else { return false }
			// `window ===` rules out a stale text view left over from the collapsed state: its
			// string would satisfy the equality while receiving nothing.
			return view.window === panel.panel && view.string == text
		}
	}

	private static func textView(in responder: Any?) -> NSTextView? {
		var node = responder
		while let view = node as? NSView {
			if let text = view as? NSTextView { return text }
			node = view.nextResponder
		}
		return nil
	}

	// MARK: - Settings window and hotkeys

	/// Opening 设置 must not touch the hotkeys, and only a *recorder* may suspend them.
	///
	/// It used to suspend them for the entire lifetime of the window, so F3/F2 were dead
	/// **everywhere** — including in the document you were actually working in — for as long as a
	/// settings window happened to be open, frontmost or not. The bug was invisible from inside the
	/// app: it presented as "the hotkey stopped working" with no cause on screen, and closing a
	/// window you had forgotten about silently fixed it. Nothing asserted otherwise, so nothing
	/// caught it.
	private static func settingsWindowHotkeys() {
		section("设置窗口与热键")
		let center = HotkeyCenter.shared
		let recorder = ShortcutRecorder.shared
		let wasSuspended = center.isSuspended
		center.isSuspended = false

		SettingsWindowController.shared.show(section: .general)
		check(
			!center.isSuspended,
			"打开设置窗口后热键仍然有效（这里曾被暂停整个窗口的生命周期）")

		// The one legitimate suspension: a key press is input to the recorder, not a command.
		recorder.begin(.selection)
		check(center.isSuspended, "开始录制快捷键时热键暂停")
		check(recorder.isRecording == .selection, "录制状态已置起")
		recorder.cancel()
		check(!center.isSuspended, "取消录制后热键立即恢复")

		// Arm it and take the window away, which is the state that would otherwise strand the
		// suspension: the recorder's local monitor can never see another app's keystrokes, so it
		// would wait forever with nothing on screen to explain dead hotkeys.
		recorder.begin(.snip)
		SettingsWindowController.shared.closeForTesting()
		check(recorder.isRecording == nil, "窗口关闭后录制状态被清掉")
		check(!center.isSuspended, "因此暂停不会悬在半空")

		center.isSuspended = wasSuspended
	}

	// MARK: - Menu

	/// The 开机自启 row shipped with no title at all, which is how a blank row appears in a
	/// menu bar — and how "NSMenuItem" ends up looking like the label.
	private static func menu() {
		section("菜单栏菜单")
		let rows = MenuBarController.debugTitles()
		for row in rows {
			let blank = row.trimmingCharacters(in: .whitespaces).isEmpty
			let label = blank ? "<空行>" : "「\(row)」"
			check(!blank, "\(label) 有标题")
		}
		check(rows.count == 6, "共 \(rows.count) 个可见项")
		check(
			rows.contains("退出 Insight") && rows.contains("设置…"),
			"保留了退出和设置")
		// The two feature rows are the only place 功能设置 is visible from outside the settings
		// window, so both are asserted present rather than merely non-blank: dropping one when the
		// other feature is the last one on would hide the refusal instead of explaining it.
		//
		// Matched by prefix, because 启用总结 carries the blocked-reason suffix (`启用总结（未配置…）`)
		// whenever the LLM is not fully configured — which is the state a fresh machine is in, so an
		// exact match here would have quietly made this check depend on the tester's API key.
		check(
			rows.contains { $0.hasPrefix("启用总结") } && rows.contains { $0.hasPrefix("启用翻译") },
			"总结和翻译各有一个开关（关掉最后一个会被拒绝，但按钮不能被动态藏起来）")
		// The rows carry the live shortcut as `title\tcombo`, so assert the whole string rather than
		// a prefix: the useful property is that the menu tells you the hotkey you actually have,
		// and a stale one is exactly what a hand-written prefix test would wave through.
		let settings = Settings.shared
		check(
			rows.contains("划词翻译\t\(settings.selectionHotkey.display)"),
			"划词翻译显示当前快捷键 \(settings.selectionHotkey.display)")
		check(
			rows.contains("截图翻译\t\(settings.snipHotkey.display)"),
			"截图翻译显示当前快捷键 \(settings.snipHotkey.display)")
		// Removed on the user's request. Asserted *absent*, because the regression worth catching
		// is a menu that quietly grows them back.
		check(
			!rows.contains("历史记录…") && !rows.contains("开机自启"),
			"「历史记录…」和「开机自启」已从菜单栏移除（各自在设置窗口里仍有入口）")

		let main = NSApp.mainMenu
		check(main != nil, "主菜单已安装（⌘V 粘贴依赖它）")
		let edit = main?.items.first { $0.title == "编辑" }?.submenu
		check(edit != nil, "存在「编辑」菜单")
		let paste = edit?.items.first { $0.title == "粘贴" }
		check(paste?.keyEquivalent == "v", "「粘贴」绑定了 ⌘V")
		check(
			edit?.items.contains { $0.title == "全选" && $0.keyEquivalent == "a" } ?? false,
			"「全选」绑定了 ⌘A")
	}

	// MARK: - LLM

	/// Talks to the real endpoint with the key in the environment. This is the only way to know
	/// that streaming, the prompt shape and the reasoning channel all actually work together.
	private static func llm() async {
		section("大模型流式（真实端点）")
		armWatchdog(seconds: 100)

		guard let key = ProcessInfo.processInfo.environment["SELFTEST_LLM_KEY"],
			!key.isEmpty
		else {
			skip("未设置 SELFTEST_LLM_KEY，跳过真实端点测试")
			return
		}
		let base = ProcessInfo.processInfo.environment["SELFTEST_LLM_BASE"] ?? "https://api.deepseek.com"
		let model = ProcessInfo.processInfo.environment["SELFTEST_LLM_MODEL"] ?? "deepseek-flash"

		// Assigning `provider.apiKey` writes through to `Secrets` — that computed setter *is* the
		// storage path — and this provider's id is random, so without the guard each run left a
		// `llm.custom-XXXX.apiKey` entry in the user's real secrets file. The on-disk round trip
		// was already verified by `secrets()` above; nothing past that point may reach the disk.
		// `set()` still updates the in-memory store, so `LLMClient` reads the key back fine.
		Secrets.persistenceEnabled = false

		var provider = LLMProviderConfig.makeCustom()
		provider.baseURL = base
		provider.model = model
		provider.apiKey = key

		let sample = """
			The authors of The Swift Programming Language introduced structured concurrency at WWDC. \
			Compared with callbacks and GCD, async/await puts the wait on the call stack, so \
			cancellation, priority propagation and timeouts can be expressed with ordinary control \
			flow. A task group implicitly waits for every child task.
			"""
		let summaryRequest = Prompts.summary(
			languageName: "简体中文", maxChars: 60, input: sample)

		// Lock-guarded sinks rather than captured `var`s. `LLMClient`'s callbacks are `@Sendable`, so
		// `var summary = ""` mutated inside one is a data race — and it is a *warning* today only
		// because the package builds in Swift 5 language mode. In Swift 6 it is an error, and by then
		// there is a pile of it to unpick. The same shape as `Counter` at the bottom of this file and
		// as `LLMClient`'s own `ResultBox`.
		let summarySink = TextSink()
		let reasoningSink = TextSink()

		do {
			try await LLMClient.stream(
				provider: provider,
				systemPrompt: summaryRequest.system,
				userPrompt: summaryRequest.user,
				onReasoning: { reasoningSink.append($0) },
				onDelta: { summarySink.append($0) })
		} catch {
			failures += 1
			print("  ✗ 流式请求失败：\(Self.describe(error))")
		}

		let summary = summarySink.text
		let reasoning = reasoningSink.text
		check(!summary.isEmpty, "总结非空（\(summary.count) 字）")
		check(summary.count <= 400, "总结长度受控（\(summary.count) ≤ 400）")
		print("      总结：\(summary.prefix(60))…")

		// Same endpoint, but the translation chain, to prove a second concurrent request works.
		let secondSink = TextSink()
		let translateRequest = Prompts.translate(
			sourceName: "English", targetName: "Simplified Chinese",
			input: "Structured concurrency puts the wait on the call stack.")
		do {
			try await LLMClient.stream(
				provider: provider,
				systemPrompt: translateRequest.system,
				userPrompt: translateRequest.user,
				onReasoning: { _ in },
				onDelta: { secondSink.append($0) })
		} catch {
			secondSink.append("错误：\(Self.describe(error))")
		}
		let second = secondSink.text
		check(!second.isEmpty && !second.hasPrefix("错误"), "翻译链路也通：\(second.prefix(40))…")

		// The two channels must stay separate. The old assertion here was
		// `reasoning.isEmpty || reasoning.count > 0`, which is true for every string that has ever
		// existed — a check that can never fail is worse than no check, because it looks like
		// coverage. What is actually worth asserting is that the reasoning text never leaked into
		// the answer, which is the failure this whole two-buffer arrangement exists to prevent.
		if reasoning.isEmpty {
			check(true, "本次没有思考内容（非推理模型，跳过通道分离检查）")
		} else {
			check(
				!summary.contains(reasoning),
				"思考内容没有混进正文（思考 \(reasoning.count) 字 / 正文 \(summary.count) 字）")
		}
	}

	private static func describe(_ error: Error) -> String {
		if let net = error as? NetError, let text = net.errorDescription { return text }
		return error.localizedDescription
	}
}

/// Thread-safe counter for the hotkey callbacks, which arrive on the Carbon event path.
private final class Counter: @unchecked Sendable {
	private let lock = NSLock()
	private var count = 0
	func increment() { lock.withLock { count += 1 } }
	var value: Int { lock.withLock { count } }
}

/// Thread-safe text sink for `LLMClient`'s `@Sendable` streaming callbacks.
///
/// Appends from whatever executor the stream happens to deliver on, and is read once after the
/// request settles — which is the only place reading it is safe, and the only place this code reads
/// it.
private final class TextSink: @unchecked Sendable {
	private let lock = NSLock()
	private var storage = ""

	func append(_ chunk: String) {
		lock.withLock { storage += chunk }
	}

	var text: String { lock.withLock { storage } }
}
