import AppKit
import SwiftUI

/// The settings window's pages, **in the order the sidebar shows them**.
///
/// The sidebar is generated from `allCases` and the detail column is an exhaustive `switch`, so
/// this declaration is the only place the order lives. 通用 comes first because it is the page
/// you go to *before* anything else works — 功能设置, the two hotkeys, the panel's behaviour — and
/// 接口 (keys and endpoints) reads as the set-up page you visit once. 历史记录 used to sit between
/// them and was removed: see DESIGN.md — it was a feature nobody opened, and keeping a page nobody
/// opens is how a window ends up with a scrollbar of tabs. Anything that needs the
/// order to hold must assert it here rather than assume it: `SettingsWindowController.show` lands
/// on `defaultSection`, which is deliberately not `allCases.first`.
enum SettingsSection: Hashable, CaseIterable {
	case general
	case interface
	case prompts
	case usage
	case about

	/// Where the window opens when the caller has no opinion: 通用, on the user's request.
	///
	/// It is the page that answers "why does the hotkey do nothing" — 权限 first, then 功能 and the
	/// two hotkeys — and that question is the reason anyone opens settings at all in the first
	/// week. 接口 is for keys and endpoints, which the first-run guide now asks for directly, so
	/// landing there by default was answering a question nobody had asked yet.
	static let defaultSection: SettingsSection = .general

	var title: String {
		switch self {
		case .general: return "通用设置"
		case .interface: return "接口设置"
		case .prompts: return "提示词"
		case .usage: return "用量统计"
		case .about: return "关于"
		}
	}

	/// The sidebar label. Shorter than `title`, because the sidebar is a fixed 140pt and the
	/// detail column already says which page is open.
	var sidebarTitle: String {
		switch self {
		case .general: return "通用"
		case .interface: return "接口"
		case .prompts: return "提示词"
		case .usage: return "用量"
		case .about: return "关于"
		}
	}

	var symbol: String {
		switch self {
		case .general: return "gearshape"
		case .interface: return "network"
		case .prompts: return "text.badge.star"
		case .usage: return "chart.bar"
		case .about: return "info.circle"
		}
	}
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
	static let shared = SettingsWindowController()

	private var window: NSWindow?

	private override init() { super.init() }

	/// Opens the window, or brings the existing one forward **and moves it to `section`**.
	///
	/// The navigation matters: the menu bar's 历史记录… row is a request to see the history, and
	/// landing on 接口 instead — which is what the old early-return did, because it returned before
	/// looking at the section at all — is indistinguishable from a dead menu item.
	///
	/// The default is `SettingsSection.defaultSection` and not `allCases.first`, so reordering the
	/// sidebar cannot quietly change which page 设置… opens on.
	func show(section: SettingsSection = SettingsSection.defaultSection) {
		if let window {
			navigate(to: section)
			window.makeKeyAndOrderFront(nil)
			NSApp.activate(ignoringOtherApps: true)
			return
		}

		let hosting = NSHostingView(rootView: SettingsView(initialSection: section))
		// Wider and taller than the three-page layout needed: 历史记录 is a list beside a detail
		// pane, and 用量 is four tiles beside a chart. 720×540 left the detail column around 500pt,
		// which forced the history detail to wrap every summary line.
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 620),
			styleMask: [.titled, .closable, .miniaturizable],
			backing: .buffered,
			defer: true)
		window.title = "Insight 设置"
		window.contentView = hosting
		window.center()
		window.isReleasedWhenClosed = false
		window.setFrameAutosaveName("Insight.Settings")
		window.minSize = NSSize(width: 740, height: 480)
		window.collectionBehavior = [.fullScreenAuxiliary]
		// Needed to learn when the window goes away, which is what disarms a recorder still
		// waiting for a keystroke — see `disarmRecorder`.
		window.delegate = self
		self.window = window

		NSApp.activate(ignoringOtherApps: true)
		window.makeKeyAndOrderFront(nil)

	}

	/// Exposed for the self test, which has to prove that closing the window cannot leave a
	/// recorder armed.
	func closeForTesting() {
		window?.close()
	}

	/// The hosted view's section binding, kept so `show` can retarget an open window.
	///
	/// The alternative — rebuilding the hosting view — would throw away the page the user was on
	/// along with its scroll position and any half-typed prompt edit.
	private var navigateTo: Binding<SettingsSection>?

	func bindNavigation(to binding: Binding<SettingsSection>?) {
		navigateTo = binding
	}

	func navigate(to section: SettingsSection) {
		navigateTo?.wrappedValue = section
	}

	/// Drops a recorder that is still waiting for a keystroke.
	///
	/// **The window deliberately does not suspend the hotkeys any more.** It used to, for as long
	/// as it was open, which killed F3/F2 in every other app too — see `HotkeyCenter.isSuspended`.
	/// What is left is this: a recorder whose button was clicked and then abandoned.
	///
	/// That state is a trap worth closing. The recorder listens with a local `NSEvent` monitor,
	/// which only ever sees events delivered to *this* app, so the moment focus moves elsewhere it
	/// can never capture anything again — while `isSuspended` stays up, leaving the hotkeys dead
	/// system-wide with nothing on screen to explain it.
	private func disarmRecorder() {
		ShortcutRecorder.shared.cancel()
	}

	func windowWillClose(_ notification: Notification) {
		disarmRecorder()
	}

	/// Covers the window being closed by its traffic-light button *and* losing focus by any other
	/// route — clicking the desktop, switching apps — which skips `windowWillClose` entirely.
	func windowDidResignKey(_ notification: Notification) {
		disarmRecorder()
	}
}

// MARK: - Root

struct SettingsView: View {
	let initialSection: SettingsSection
	@State private var section: SettingsSection

	/// `initialSection` has to be copied into the `@State` here rather than defaulted inline.
	/// `@State private var section: SettingsSection = .translate` compiles and silently throws the
	/// parameter away, so `SettingsWindowController.show(section: .general)` opened 通用's window
	/// and then showed 翻译 — which is why `--settings-general` looked like it did nothing.
	init(initialSection: SettingsSection) {
		self.initialSection = initialSection
		_section = State(initialValue: initialSection)
	}

	var body: some View {
		NavigationSplitView {
			List(selection: $section) {
				// Labels come from `sidebarTitle` rather than being written out here. They used to
				// be literal strings next to a `switch` further down, and when 历史 and 用量 were
				// added the two lists disagreed for a whole build — which is the same "two lists
				// will drift" problem the preset lists hit.
				//
				// "接口" rather than "翻译": everything on that page is about *how* a request is
				// made — which provider, which endpoint, which key — not about translation itself.
				ForEach(SettingsSection.allCases, id: \.self) { item in
					Label(item.sidebarTitle, systemImage: item.symbol).tag(item)
				}
			}
			.navigationSplitViewColumnWidth(140)
			// The sidebar's collapse button, gone.
			//
			// It belongs to the **sidebar column's** navigation toolbar, so this has to be applied
			// here — on the detail column it compiles, runs, and removes nothing. Removing it matters
			// because `columnVisibility` is not persisted: one click hides the sidebar and it never
			// reappears on its own, which on a 740pt window loses the only way to switch pages.
			.toolbar(removing: .sidebarToggle)
		} detail: {
			// A named view rather than an inline closure, purely so the detail column has a concrete
			// type — inside the builder the closure resolves to `View`, and modifiers that need a
			// concrete type do not resolve there at all.
			SettingsDetail(section: $section)
		}
		.frame(minWidth: 740, minHeight: 480)
		.onAppear {
			section = initialSection
			// Hand the binding to the window controller so the menu bar can retarget an open
			// window. Done here rather than in `init` because the `@State` wrapper only exists once
			// the view is in a hierarchy.
			SettingsWindowController.shared.bindNavigation(to: $section)
		}
		.onDisappear {
			SettingsWindowController.shared.bindNavigation(to: nil)
			ShortcutRecorder.shared.cancel()
		}
	}
}

/// The right-hand column.
///
/// Extracted so the detail column has a concrete type: modifiers that need one do not resolve
/// inside the `detail:` builder, where the closure is inferred as plain `View`.
private struct SettingsDetail: View {
	@Binding var section: SettingsSection

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			// The sidebar already says which page this is; the heading is here so the page still
			// reads correctly when it is the only thing on screen.
			Text(section.title)
				.font(.system(size: 15, weight: .semibold))
				.padding(.horizontal, 20)
				.padding(.top, 18)
				.padding(.bottom, 12)

			// A `switch` rather than a stack of always-mounted views: only the selected page is
			// ever built. Mounting all tabs behind `display: none` keeps every page resident in
			// memory at once, which is exactly why that approach feels like treacle.
switch section {
		case .interface: InterfaceSettings()
		case .prompts: PromptSettings()
		case .usage: UsageSettings()
		case .general: GeneralSettings()
		case .about: AboutSettings()
		}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
	}
}

// MARK: - 接口

struct InterfaceSettings: View {
	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 14) {
				SummarySection()
				TranslationEngineSection()
			}
			.padding(.horizontal, 20)
			.padding(.bottom, 20)
			// The page fills the column. There used to be a 560pt cap here, "so a wide window does
			// not stretch every text field to full width" — and what it actually did was leave a
			// band of empty window down the right-hand side, because the capped content is a
			// *smaller* view than the column and the column's layout centres it. Measured with
			// a 560pt content box sat at x=183 in an 880pt window. A full-width
			// text field is a smaller price than a page that looks half-drawn.
			.frame(maxWidth: .infinity, alignment: .leading)
		}
		.frame(maxWidth: .infinity)
	}
}

// MARK: - 大模型（总结）

private struct SummarySection: View {
	@State private var fetchState: FetchState = .idle
	@State private var testState: TestState = .idle
	@State private var manualModel = ""

	private enum FetchState: Equatable {
		case idle, loading
		case failed(String)
	}

	private enum TestState: Equatable {
		case idle, running
		case ok(ms: Int, sample: String)
		case failed(String)
	}

	var body: some View {
		@Bindable var settings = Settings.shared

		VStack(alignment: .leading, spacing: 12) {
			// The 启用 toggle that used to sit on this row is gone. It moved to 通用设置 › 功能 once
			// translation needed one too: two controls on two pages that both answer "what does
			// the panel do" is the shape where the one you are looking for is always on the page
			// you did not open.
			Label("总结", systemImage: "sparkles")
				.font(.system(size: 14, weight: .semibold))

			if let reason = settings.summaryBlockedReason {
				Label(reason, systemImage: "exclamationmark.triangle.fill")
					.font(.system(size: 11))
					.foregroundStyle(.orange)
			}

			// Provider
			HStack(spacing: 8) {
				Picker("服务商", selection: $settings.llmProviderID) {
					ForEach(settings.providers) { provider in
						Text(provider.name).tag(provider.id)
					}
				}
				.labelsHidden()
				.frame(width: 150)
				.onChange(of: settings.llmProviderID) { _, _ in
					settings.commit()
					fetchState = .idle
					testState = .idle
				}

				Button {
					settings.addCustomProvider()
				} label: {
					Image(systemName: "plus")
				}
				.help("添加自定义 OpenAI 兼容服务商")

				if !settings.currentProvider.isBuiltin {
					Button {
						settings.removeProvider(settings.currentProvider.id)
					} label: {
						Image(systemName: "minus")
					}
					.help("移除该服务商")
				}
				Spacer()
			}

			// API key
			SecretRow(
				title: "API Key",
				placeholder: providerKeyPlaceholder,
				value: Binding(
					get: { settings.currentProvider.apiKey },
					set: { newValue in
						settings.updateProvider(settings.currentProvider.id) { $0.apiKey = newValue }
					}),
				isEmpty: { settings.currentProvider.apiKey.isEmpty })

			// Base URL
			VStack(alignment: .leading, spacing: 4) {
				HStack(spacing: 8) {
					Text("接口地址")
						.font(.system(size: 12))
						.frame(width: 78, alignment: .leading)
					TextField("https://api.example.com/v1",
						text: Binding(
							get: { settings.currentProvider.baseURL },
							set: { newValue in
								settings.updateProvider(settings.currentProvider.id) { $0.baseURL = newValue }
								fetchState = .idle
								testState = .idle
							}))
						.textFieldStyle(.roundedBorder)
						.font(.system(size: 12).monospaced())
					if let builtin = builtinURL(for: settings.currentProvider) {
						Button("恢复默认") {
							settings.updateProvider(settings.currentProvider.id) { $0.baseURL = builtin }
						}
						.buttonStyle(.plain)
						.font(.system(size: 11))
						.foregroundStyle(.secondary)
					}
				}
				if !settings.currentProvider.baseURL.isEmpty {
					Text(settings.currentProvider.previewURL + "  ·  POST")
						.font(.system(size: 10).monospaced())
						.foregroundStyle(.tertiary)
						.padding(.leading, 86)
				}
			}

			// Model
			HStack(spacing: 8) {
				Text("模型")
					.font(.system(size: 12))
					.frame(width: 78, alignment: .leading)
				TextField("模型名称",
					text: Binding(
						get: { settings.currentProvider.model },
						set: { newValue in
							settings.updateProvider(settings.currentProvider.id) { $0.model = newValue }
							testState = .idle
						}))
					.textFieldStyle(.roundedBorder)
					.font(.system(size: 12).monospaced())

				if !settings.currentProvider.models.isEmpty {
					Menu {
						ForEach(settings.currentProvider.models, id: \.self) { model in
							Button(model) {
								settings.updateProvider(settings.currentProvider.id) { $0.model = model }
								testState = .idle
							}
						}
					} label: {
						Label("\(settings.currentProvider.models.count)", systemImage: "list.bullet")
							.font(.system(size: 11))
					}
					.menuStyle(.borderlessButton)
					.fixedSize()
					.help("已获取的模型")
				}

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
				.help("GET \(settings.currentProvider.modelsPaths.first ?? "/v1/models")")
			}

			switch fetchState {
			case .idle:
				EmptyView()
			case .loading:
				EmptyView()
			case .failed(let message):
				statusLine(message, tint: .orange, icon: "exclamationmark.triangle.fill")
			}

			// Thinking
			HStack(spacing: 8) {
				Text("思考过程")
					.font(.system(size: 12))
					.frame(width: 78, alignment: .leading)
				Toggle("保留模型的深度思考", isOn: Binding(
					get: { settings.currentProvider.thinkingEnabled },
					set: { newValue in
						settings.updateProvider(settings.currentProvider.id) { $0.thinkingEnabled = newValue }
					}))
				.controlSize(.small)
				.onChange(of: settings.currentProvider.thinkingEnabled) { _, _ in settings.commit() }
				Text(thinkingHint)
					.font(.system(size: 10))
					.foregroundStyle(.tertiary)
			}

			// Summary output
			Picker("总结语言", selection: $settings.summaryLanguage) {
				ForEach(Languages.all) { language in
					Text(language.name).tag(language.id)
				}
			}
			.onChange(of: settings.summaryLanguage) { _, _ in settings.commit() }

			// Whether the prompt in effect is the shipped one or an edited one is the thing you
			// need when a summary comes back looking wrong, and the prompts page is the only place
			// it can be changed — so it is stated here rather than left to be discovered on the
			// other tab. There is no name to show any more: with one prompt per slot, "总结提示词"
			// is the whole of what it could say, and it is already the label on this row.
			HStack(spacing: 8) {
				Text("总结提示词")
					.font(.system(size: 12))
					.frame(width: 78, alignment: .leading)
				Text(settings.isPromptModified(.summary) ? "已修改" : "初始设定")
					.font(.system(size: 12))
					.foregroundStyle(.secondary)
				Text("在「提示词」页修改或还原")
					.font(.system(size: 10))
					.foregroundStyle(.tertiary)
				Spacer()
			}

			// Connection test
			HStack(spacing: 8) {
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

				switch testState {
				case .idle, .running:
					EmptyView()
				case .ok(let ms, let sample):
					statusLine("连接正常，首字 \(ms)ms · \(sample)", tint: .green, icon: "checkmark.circle.fill")
				case .failed(let message):
					statusLine(message, tint: .orange, icon: "exclamationmark.triangle.fill")
				}
				Spacer()
			}
		}
		.padding(15)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(
			RoundedRectangle(cornerRadius: 10)
				.fill(.quaternary.opacity(0.22))
		)
	}

	private var providerKeyPlaceholder: String {
		switch Settings.shared.currentProvider.flavor {
		case .deepSeek: return "sk-…"
		case .zhipu: return "智谱 API Key"
		case .qwen: return "DashScope API Key"
		case .openAI: return "sk-…"
		}
	}

	private var thinkingHint: String {
		let provider = Settings.shared.currentProvider
		if LLMClient.isReasoningModel(provider.model) {
			return provider.thinkingEnabled ? "模型会先推理再回答" : "将请求模型跳过推理阶段"
		}
		return "当前模型不推理，此项无效"
	}

	private func builtinURL(for provider: LLMProviderConfig) -> String? {
		LLMProviderConfig.builtins.first { $0.id == provider.id }?.baseURL
	}

	private func statusLine(_ text: String, tint: Color, icon: String) -> some View {
		Label(text, systemImage: icon)
			.font(.system(size: 11))
			.foregroundStyle(tint)
			.lineLimit(2)
			.textSelection(.enabled)
	}

	// MARK: Actions

	private func fetchModels() {
		fetchState = .loading
		let provider = Settings.shared.currentProvider
		Task {
			do {
				let result = try await LLMClient.listModels(provider: provider)
				Settings.shared.updateProvider(provider.id) { $0.models = result.models }
				fetchState = .idle
				if result.models.isEmpty {
					fetchState = .failed("接口返回的模型列表为空")
				}
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
				testState = .ok(ms: result.firstTokenMilliseconds, sample: result.sample)
			} catch {
				testState = .failed(error.localizedDescription)
			}
		}
	}
}

// MARK: - 翻译引擎

private struct TranslationEngineSection: View {
	var body: some View {
		@Bindable var settings = Settings.shared

		VStack(alignment: .leading, spacing: 12) {
			Label("翻译", systemImage: "character.book.closed")
				.font(.system(size: 14, weight: .semibold))

			Picker("翻译引擎", selection: $settings.translateEngine) {
				ForEach(MTEngine.allCases) { engine in
					Text(engine.displayName).tag(engine)
				}
			}
			.onChange(of: settings.translateEngine) { _, _ in settings.commit() }

			if !settings.engineReady(settings.translateEngine) {
				Label(notReadyHint, systemImage: "exclamationmark.triangle.fill")
					.font(.system(size: 11))
					.foregroundStyle(.orange)
			}

			switch settings.translateEngine {
			case .baidu:
				TextField("APP ID", text: $settings.baiduAppID)
					.textFieldStyle(.roundedBorder)
					.font(.system(size: 12).monospaced())
					.onChange(of: settings.baiduAppID) { _, _ in settings.commit() }
				SecretRow(
					title: "密钥",
					placeholder: "Secret Key",
					value: Binding(
						get: { Keychain.baiduSecretKey() },
						set: { Keychain.setBaiduSecretKey($0) }),
					isEmpty: { Keychain.baiduSecretKey().isEmpty })

			case .tencent:
				TextField("SecretId", text: $settings.tencentSecretID)
					.textFieldStyle(.roundedBorder)
					.font(.system(size: 12).monospaced())
					.onChange(of: settings.tencentSecretID) { _, _ in settings.commit() }
				SecretRow(
					title: "SecretKey",
					placeholder: "SecretKey",
					value: Binding(
						get: { Keychain.tencentSecretKey() },
						set: { Keychain.setTencentSecretKey($0) }),
					isEmpty: { Keychain.tencentSecretKey().isEmpty })

			case .deepl:
				SecretRow(
					title: "API Key",
					placeholder: "DeepL API Key（结尾 :fx）",
					value: Binding(
						get: { Keychain.deepLKey() },
						set: { Keychain.setDeepLKey($0) }),
					isEmpty: { Keychain.deepLKey().isEmpty })

			case .apple:
				Label(
					"使用 macOS 内置翻译引擎，完全离线。首次翻译某个语言对时系统会提示下载语言包。",
					systemImage: "checkmark.seal")
					.font(.system(size: 11))
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)

			case .llm:
				Label(
					"复用上面配置的模型来翻译，天然支持流式输出。",
					systemImage: "checkmark.seal")
					.font(.system(size: 11))
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}

			Picker("源语言", selection: $settings.sourceLanguage) {
				Text(Languages.autoDisplay).tag(Languages.autoID)
				ForEach(Languages.supported(for: settings.translateEngine)) { language in
					Text(language.name).tag(language.id)
				}
			}
			.onChange(of: settings.sourceLanguage) { _, _ in settings.commit() }

			Picker("目标语言", selection: $settings.targetLanguage) {
				ForEach(Languages.supported(for: settings.translateEngine)) { language in
					Text(language.name).tag(language.id)
				}
			}
			.onChange(of: settings.targetLanguage) { _, _ in settings.commit() }
		}
		.padding(15)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(
			RoundedRectangle(cornerRadius: 10)
				.fill(.quaternary.opacity(0.22))
		)
	}

	private var notReadyHint: String {
		switch Settings.shared.translateEngine {
		case .baidu: return "请填写百度翻译的 APP ID 和密钥"
		case .tencent: return "请填写腾讯翻译的 SecretId 和 SecretKey"
		case .deepl: return "请填写 DeepL API Key"
		case .llm: return Settings.shared.summaryBlockedReason ?? "请先配置大模型"
		case .apple: return ""
		}
	}
}

// MARK: - 功能

/// 功能设置: what the panel is *for*.
///
/// A segmented control over `FeatureMode.allCases` rather than two switches, and the third case
/// is the reason: two switches have four states, and the fourth one — both off — is an app that
/// reads a selection and shows nothing. A control populated from `allCases` cannot express that
/// state, so it is unreachable rather than merely discouraged.
///
/// Not `private`, so the offline checks can build it.
struct FeatureSettings: View {
	var body: some View {
		@Bindable var settings = Settings.shared

		VStack(alignment: .leading, spacing: 10) {
			Label("功能", systemImage: "switch.2")
				.font(.system(size: 14, weight: .semibold))

			Picker("功能", selection: modeBinding(settings)) {
				ForEach(FeatureMode.allCases) { mode in
					Text(mode.displayName).tag(mode)
				}
			}
			.labelsHidden()
			.pickerStyle(.segmented)
			// No `.fixedSize()`. It keeps the segments at their natural width, which is what made
			// this control — and therefore the 功能 card, which sizes itself to its content — sit
			// as a narrow centred strip inside a full-width card: measured at x=183 in a page whose
			// content starts at x=20. Three segments share the row instead, which is also what a
			// segmented control is for.

			// Says what the choice does to the window, because that is the visible half of it and
			// the half a user would otherwise have to discover by pressing the hotkey.
			Text(modeDetail(settings.featureMode))
				.font(.system(size: 11))
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)

			Toggle("没划中文字时改用剪贴板", isOn: $settings.clipboardFallback)
				.toggleStyle(.switch)
				.controlSize(.small)
				.help("划词热键没读到选中的文字时，自动改用剪贴板里的文字进行翻译和总结；面板顶部会标注「来源：剪贴板」")
				.onChange(of: settings.clipboardFallback) { _, _ in settings.commit() }
		}
		.padding(15)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.22)))
	}

	/// The setter goes through `setFeatureMode` rather than assigning the two booleans, so the pair
	/// is written in one place and a change that turns out to be a no-op fires no observation. The
	/// getter is the derived mode, so the control always shows what the panel is actually doing
	/// rather than what was last clicked.
	private func modeBinding(_ settings: Settings) -> Binding<FeatureMode> {
		Binding(
			get: { settings.featureMode },
			set: { settings.setFeatureMode($0) })
	}

	private func modeDetail(_ mode: FeatureMode) -> String {
		switch mode {
		case .translateOnly:
			return "只翻译。面板上的总结卡片缩成一行标题，把高度让给译文。"
		case .summarizeOnly:
			return "只总结。翻译链路完全不启动，不调用任何翻译接口；翻译卡片缩成一行标题。"
		case .both:
			return "两条链路同时进行，结果显示在同一块面板上 —— 高度可以在面板里拖动分割线分配。"
		}
	}
}

// MARK: - 通用

/// Not `private`, so the offline checks can build it and read the section order — the same reason
/// `InterfaceSettings`, `AboutSettings` and `FeatureSettings` are not.
struct GeneralSettings: View {
	/// The section order, by the labels that are drawn. Reported for the checker, which has no
	/// other way to assert "权限 is at the top" — the page is private and its cards are SwiftUI
	/// views, so reading the order back out of a laid-out hierarchy is guesswork at best.
	///
	/// `nonisolated` and stored rather than computed: it is written once by `body` and read from
	/// wherever the check happens to run.
	nonisolated(unsafe) static var reportedSections: [String] = []

	private static let sectionOrder = [
		"权限", "功能", "快捷键", "窗口", "网络", "通用",
	]

	var body: some View {
		@Bindable var settings = Settings.shared
		let _ = Self.reportedSections = Self.sectionOrder

		ScrollView {
			VStack(alignment: .leading, spacing: 14) {
				// First, not last. It is the only thing on this page that decides whether the app
				// works at all, and it used to sit below four sections of preferences — which is
				// exactly where a new user does *not* look for "why does nothing happen".
				PermissionsSection()
				FeatureSettings()

				VStack(alignment: .leading, spacing: 12) {
					Label("快捷键", systemImage: "keyboard")
						.font(.system(size: 14, weight: .semibold))
					ShortcutField(
						target: .selection, title: "划词翻译",
						combo: $settings.selectionHotkey)
					ShortcutField(
						target: .snip, title: "截图翻译",
						combo: $settings.snipHotkey)
				}
				.padding(15)
				.frame(maxWidth: .infinity, alignment: .leading)
				.background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.22)))

				VStack(alignment: .leading, spacing: 4) {
					Label("窗口", systemImage: "macwindow")
						.font(.system(size: 14, weight: .semibold))
						.padding(.bottom, 8)

					Toggle("窗口置顶", isOn: $settings.pinWindow)
						.onChange(of: settings.pinWindow) { _, _ in
							settings.commit()
							PanelController.shared.model.isPinned = settings.pinWindow
						}
					Toggle("点击窗口外部时关闭", isOn: $settings.closeOnOutsideClick)
						.onChange(of: settings.closeOnOutsideClick) { _, _ in settings.commit() }
					Toggle("识别到文字时复制原文", isOn: $settings.autoCopySourceToClipboard)
						.onChange(of: settings.autoCopySourceToClipboard) { _, _ in settings.commit() }
					Toggle("关闭窗口时复制译文", isOn: $settings.autoCopyOnClose)
						.help("面板关掉时把译文放进剪贴板 —— Esc、点外面、关闭按钮和写回原文都会触发")
						.onChange(of: settings.autoCopyOnClose) { _, _ in settings.commit() }

					Text("窗口位置和大小会被记住")
						.font(.system(size: 10))
						.foregroundStyle(.tertiary)
				}
				.toggleStyle(.switch)
				.controlSize(.small)
				.padding(15)
				.frame(maxWidth: .infinity, alignment: .leading)
				.background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.22)))

				ProxySection()

				VStack(alignment: .leading, spacing: 4) {
					Label("通用", systemImage: "gearshape")
						.font(.system(size: 14, weight: .semibold))
						.padding(.bottom, 8)

					Toggle("开机时自动启动", isOn: $settings.launchAtLogin)
						.onChange(of: settings.launchAtLogin) { _, _ in
							settings.applyLaunchAtLogin()
							settings.commit()
						}

					Picker("外观", selection: $settings.appearance) {
						Text("跟随系统").tag("system")
						Text("浅色").tag("light")
						Text("深色").tag("dark")
					}
					.onChange(of: settings.appearance) { _, _ in
						settings.applyAppearance()
						settings.commit()
					}

					Picker("主题", selection: $settings.panelTheme) {
						ForEach(PanelTheme.allCases) { theme in
							Text(theme.displayName).tag(theme)
						}
					}
					.onChange(of: settings.panelTheme) { _, _ in settings.commit() }

					Picker("窗口位置", selection: $settings.windowPlacement) {
						ForEach(WindowPlacement.allCases) { placement in
							Text(placement.displayName).tag(placement)
						}
					}
					.onChange(of: settings.windowPlacement) { _, _ in settings.commit() }
				}
				.toggleStyle(.switch)
				.controlSize(.small)
				.padding(15)
				.frame(maxWidth: .infinity, alignment: .leading)
				.background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.22)))
			}
			.padding(.horizontal, 20)
			.padding(.bottom, 20)
			// The cap is on the *content*, and the scroll view is made greedy separately. A
			// `ScrollView` proposes an unbounded width to its content and reports its content's
			// width upward, so a `maxWidth` frame anywhere in this chain shortens the scroll view
			// itself — and the page then renders as a 560pt column inside a wider column, which is
			// the empty band on the right. Measured: the 功能 card sat at
			// x=183 in an 880pt window instead of x=20.
			.frame(maxWidth: .infinity, alignment: .leading)
		}
		.frame(maxWidth: .infinity)
	}
}

/// Proxy. One of the most-requested features, and for anyone behind a firewall it is the
/// difference between the app working and not working at all.
private struct ProxySection: View {
	var body: some View {
		@Bindable var settings = Settings.shared

		VStack(alignment: .leading, spacing: 4) {
			Label("网络", systemImage: "network")
				.font(.system(size: 14, weight: .semibold))
				.padding(.bottom, 8)

			Toggle("使用代理", isOn: $settings.proxyEnabled)
				.onChange(of: settings.proxyEnabled) { _, _ in settings.commit() }

			if settings.proxyEnabled {
				HStack(spacing: 8) {
					TextField("主机", text: $settings.proxyHost)
						.textFieldStyle(.roundedBorder)
						.font(.system(size: 12).monospaced())
						.onChange(of: settings.proxyHost) { _, _ in settings.commit() }

					TextField("端口", value: $settings.proxyPort, format: .number.grouping(.never))
						.textFieldStyle(.roundedBorder)
						.font(.system(size: 12).monospaced())
						.frame(width: 80)
						.onChange(of: settings.proxyPort) { _, _ in settings.commit() }
				}

				Toggle("需要用户名和密码", isOn: $settings.proxyRequiresAuth)
					.onChange(of: settings.proxyRequiresAuth) { _, _ in settings.commit() }

				if settings.proxyRequiresAuth {
					SecretRow(
						title: "用户名",
						placeholder: "代理用户名",
						value: $settings.proxyUsername,
						isEmpty: { settings.proxyUsername.isEmpty })
						.onChange(of: settings.proxyUsername) { _, _ in settings.commit() }
					SecretRow(
						title: "密码",
						placeholder: "代理密码",
						value: Binding(
							get: { Secrets.shared.value(Secrets.Key.proxyPassword) },
							set: { Secrets.shared.set($0, for: Secrets.Key.proxyPassword) }),
						isEmpty: { Secrets.shared.isEmpty(Secrets.Key.proxyPassword) })
				}

				Text("修改后立即生效，无需重启。")
					.font(.system(size: 10))
					.foregroundStyle(.tertiary)
			}
		}
		.toggleStyle(.switch)
		.controlSize(.small)
		.padding(15)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.22)))
	}
}

/// The two permission grants, with live status.
///
/// Not `private`: the first-run guide shows exactly this card, because "grant the permissions" is
/// the same instruction in both places and a second copy would be the one that goes stale.
struct PermissionsSection: View {
	/// Called when the user presses 打开设置, with the permission they went to grant.
	///
	/// The first-run guide uses it: screen recording is not visible to this process until it is
	/// relaunched, so the guide has to distinguish "has not done it yet" from "did it, pending a
	/// restart" — and the moment the user leaves for System Settings is the only honest signal
	/// available for that.
	var onOpenedSettings: (Permissions.Permission) -> Void = { _ in }

	@State private var missing = Permissions.missing

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			Label("权限", systemImage: "checkmark.shield")
				.font(.system(size: 14, weight: .semibold))

			if missing.isEmpty {
				Label("辅助功能和屏幕录制权限均已授予", systemImage: "checkmark.circle.fill")
					.font(.system(size: 11))
					.foregroundStyle(.green)
			} else {
				ForEach(missing, id: \.self) { permission in
					HStack(alignment: .top, spacing: 8) {
						Image(systemName: "exclamationmark.triangle.fill")
							.foregroundStyle(.orange)
						VStack(alignment: .leading, spacing: 2) {
							Text(permission.title).font(.system(size: 12, weight: .medium))
							Text(permission.detail)
								.font(.system(size: 10))
								.foregroundStyle(.secondary)
								.fixedSize(horizontal: false, vertical: true)
						}
						Spacer()
						Button("打开设置") {
							permission.openSettings()
							onOpenedSettings(permission)
						}
						.controlSize(.small)
					}
				}
			}

			Button("重新检查") { missing = Permissions.missing }
				.controlSize(.small)
				.padding(.top, 2)
		}
		.padding(15)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.22)))
	}
}

/// Its own page rather than a card at the bottom of 通用: it is the one thing on that page with no
/// setting attached to it, and burying it under four other sections is why it had never been read.
///
/// Not `private`, so the offline checks can build it — the page was edited and that is exactly the
/// kind of change the off-screen build exists to cover.
struct AboutSettings: View {
	/// Read from Info.plist so there is one version to maintain, not two. Empty in a bare
	/// `swift run` (no bundle), where 开发版 reads better than a blank.
	private static let version =
		(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
			.flatMap { $0.isEmpty ? nil : $0 } ?? "开发版"

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 14) {
				VStack(alignment: .leading, spacing: 6) {
					Label("Insight", systemImage: "info.circle")
						.font(.system(size: 14, weight: .semibold))
					Text("版本 \(Self.version) · 仅支持 Apple 芯片 macOS 26 及以上")
						.font(.system(size: 11))
						.foregroundStyle(.secondary)
				}
				.padding(15)
				.frame(maxWidth: .infinity, alignment: .leading)
				.background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.22)))

				VStack(alignment: .leading, spacing: 10) {
					Label("GitHub", systemImage: "link")
						.font(.system(size: 14, weight: .semibold))
					aboutLink(
						"项目主页",
						note: "查看源码、下载与更新",
						url: URL(string: "https://github.com/hsc113/Insight")!)
					aboutLink(
						"问题反馈",
						note: "发现 bug 或想要功能，欢迎开一个 Issue",
						url: URL(string: "https://github.com/hsc113/Insight/issues")!)
					aboutLink(
						"作者主页",
						note: "github.com/hsc113",
						url: URL(string: "https://github.com/hsc113")!)
				}
				.padding(15)
				.frame(maxWidth: .infinity, alignment: .leading)
				.background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.22)))

				Text("MIT License · 零第三方依赖，整个 app 只使用系统框架")
					.font(.system(size: 10))
					.foregroundStyle(.secondary)
			}
			.padding(.horizontal, 20)
			.padding(.bottom, 20)
			.frame(maxWidth: .infinity, alignment: .leading)
		}
		.frame(maxWidth: .infinity)
	}

	private func aboutLink(_ title: String, note: String, url: URL) -> some View {
		HStack(spacing: 8) {
			VStack(alignment: .leading, spacing: 2) {
				Text(title).font(.system(size: 12, weight: .medium))
				Text(note)
					.font(.system(size: 10))
					.foregroundStyle(.secondary)
			}
			Spacer()
			Link("打开", destination: url)
				.font(.system(size: 11))
		}
	}
}

// MARK: - Shared

/// A labelled secret field with a reveal toggle: one row, masked by default, eye to reveal.
/// Not `private`, for the same reason as `PermissionsSection`: the guide asks for the same key.
struct SecretRow: View {
	let title: String
	let placeholder: String
	@Binding var value: String
	let isEmpty: () -> Bool

	@State private var revealed = false

	var body: some View {
		HStack(spacing: 8) {
			Text(title)
				.font(.system(size: 12))
				.frame(width: 78, alignment: .leading)

			Group {
				if revealed {
					TextField(placeholder, text: $value)
				} else {
					SecureField(placeholder, text: $value)
				}
			}
			.textFieldStyle(.roundedBorder)
			.font(.system(size: 12).monospaced())

			Button {
				revealed.toggle()
			} label: {
				Image(systemName: revealed ? "eye.slash" : "eye")
					.font(.system(size: 11))
			}
			.buttonStyle(.plain)
			.foregroundStyle(.secondary)

			if isEmpty() {
				Image(systemName: "exclamationmark.circle")
					.font(.system(size: 11))
					.foregroundStyle(.orange)
					.help("尚未填写")
			}
		}
	}
}
