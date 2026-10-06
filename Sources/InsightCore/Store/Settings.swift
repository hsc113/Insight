import AppKit
import Foundation
import Observation
import ServiceManagement

// MARK: - Models

/// Which vendor dialect a provider speaks. Only matters for how "turn thinking off"
/// is expressed on the wire — the request/response shape is OpenAI-compatible throughout.
enum LLMFlavor: String, Codable, Sendable, CaseIterable {
	case openAI  // generic / user-supplied
	case deepSeek
	case zhipu
	case qwen
}

struct LLMProviderConfig: Codable, Identifiable, Equatable, Sendable {
	var id: String
	var name: String
	var flavor: LLMFlavor
	var baseURL: String
	var chatPath: String
	/// Tried in order; the first one that answers wins. Vendors disagree on whether the
	/// models endpoint lives at `/models` or `/v1/models`.
	var modelsPaths: [String]
	var model: String
	var models: [String]
	var thinkingEnabled: Bool
	var isBuiltin: Bool

	var hasKey: Bool { !Keychain.apiKey(forProvider: id).isEmpty }
	/// Not part of the encoded config — secrets live in `Secrets`.
	var apiKey: String {
		get { Secrets.shared.value(Secrets.Key.llmAPIKey(providerID: id)) }
		set { Secrets.shared.set(newValue, for: Secrets.Key.llmAPIKey(providerID: id)) }
	}

	var chatURL: URL? { URL(string: baseURL + chatPath) }
	var previewURL: String { (baseURL + chatPath).replacingOccurrences(of: "https://", with: "") }

	static func makeCustom(name: String = "自定义") -> LLMProviderConfig {
		LLMProviderConfig(
			id: "custom-" + UUID().uuidString.prefix(8),
			name: name,
			flavor: .openAI,
			baseURL: "",
			chatPath: "/v1/chat/completions",
			modelsPaths: ["/v1/models", "/models"],
			model: "",
			models: [],
			thinkingEnabled: false,
			isBuiltin: false)
	}

	static let builtins: [LLMProviderConfig] = [
		.init(
			id: "deepseek", name: "DeepSeek", flavor: .deepSeek,
			baseURL: "https://api.deepseek.com", chatPath: "/chat/completions",
			modelsPaths: ["/models", "/v1/models"],
			model: "deepseek-chat",
			models: ["deepseek-chat", "deepseek-reasoner"],
			thinkingEnabled: false, isBuiltin: true),
		.init(
			id: "zhipu", name: "智谱 GLM", flavor: .zhipu,
			baseURL: "https://open.bigmodel.cn/api/paas/v4", chatPath: "/chat/completions",
			modelsPaths: ["/models"],
			model: "glm-4-flash",
			models: ["glm-4-flash", "glm-4-plus", "glm-4-air"],
			thinkingEnabled: false, isBuiltin: true),
		.init(
			id: "qwen", name: "通义千问", flavor: .qwen,
			baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", chatPath: "/chat/completions",
			modelsPaths: ["/models"],
			model: "qwen-plus",
			models: ["qwen-plus", "qwen-turbo", "qwen-max", "qwen-flash"],
			thinkingEnabled: false, isBuiltin: true),
	]
}

enum MTEngine: String, Codable, CaseIterable, Identifiable, Sendable {
	case llm
	case apple
	case baidu
	case tencent
	case deepl

	var id: String { rawValue }

	var displayName: String {
		switch self {
		case .llm: return "大模型翻译"
		case .apple: return "Apple 系统翻译"
		case .baidu: return "百度翻译"
		case .tencent: return "腾讯交互翻译"
		case .deepl: return "DeepL"
		}
	}

	var needsCredential: Bool {
		switch self {
		case .baidu, .tencent, .deepl: return true
		case .llm, .apple: return false
		}
	}

	var supportsStreaming: Bool {
		self == .llm  // every HTTP MT API is request/response only
	}
}

/// What the panel does: translate, summarise, or both.
///
/// Stated as one value with three cases rather than as two free switches, because the two
/// switches are not independent — off and off leaves an app that runs a hotkey, reads a
/// selection and shows nothing, which is not a mode anyone wants and not a state any check can
/// describe. `allCases` is the whole of the UI's menu, so the third state cannot be reached by
/// accident.
enum FeatureMode: String, CaseIterable, Identifiable, Codable, Sendable {
	case translateOnly
	case summarizeOnly
	case both

	var id: String { rawValue }

	var displayName: String {
		switch self {
		case .translateOnly: return "仅翻译"
		case .summarizeOnly: return "仅总结"
		case .both: return "翻译与总结"
		}
	}

	var summarizes: Bool { self != .translateOnly }
	var translates: Bool { self != .summarizeOnly }

	/// The mode a pair of switches describes.
	///
	/// Off and off has no case to return, and this is a total function rather than a `nil`-returning
	/// one so that `Settings.featureMode` cannot fail: every caller gets an answer, and the answer
	/// for the impossible input is the harmless one. The input itself never arises from the UI —
	/// the three cases are what the picker offers — and a file that contains it is settled by
	/// `Settings.resolvedFeatureFlags` before anyone reads it.
	static func resolve(summary: Bool, translation: Bool) -> FeatureMode {
		switch (summary, translation) {
		case (true, true): return .both
		case (true, false): return .summarizeOnly
		case (false, true): return .translateOnly
		case (false, false): return .both
		}
	}
}

// MARK: - Store

@MainActor
@Observable
final class Settings {
	static let shared = Settings()

	/// Whether the first-run guide has been dealt with. Set when the guide is finished **or**
	/// closed — a guide that reopens on every launch because it decided the user had not finished
	/// is a prompt you cannot get rid of, which is worse than no guide.
	///
	/// Defaults to `false`, so an existing install sees the guide once after updating. That is
	/// deliberate: the people most likely to be missing a permission are the ones who installed
	/// an earlier build and never found the settings page.
	var hasCompletedOnboarding = false

	// What the panel is for. The two cards are independent chains, so each can be turned off on
	// its own; the panel then shrinks the switched-off card to its header instead of reserving
	// half the window for an empty box. See `FeatureMode` for why this is stated once and in
	// three values rather than as two unconstrained switches.
	var summaryEnabled = true
	var translationEnabled = true

	// Summary
	var summaryLanguage = "zh-Hans"
	var summaryMaxChars = 600

	// The two prompts. See `PromptPreset` for why there is one per slot and no list.
	//
	// The shipped text lives in code; only what the user changed is stored, field by field, so a
	// release can still improve a prompt for people who never edited it. That is the whole of the
	// state — no ids to select between, because there is nothing to select.
	var promptOverrides: [String: PromptOverride] = [:]

	// LLM
	var llmProviderID = "deepseek"
	var providers = LLMProviderConfig.builtins

	// Translation
	var translateEngine: MTEngine = .llm
	var sourceLanguage = "auto"
	var targetLanguage = "zh-Hans"
	var baiduAppID = ""
	var tencentSecretID = ""

	// Hotkeys
	var selectionHotkey = KeyCombo.selection
	var snipHotkey = KeyCombo.snip

	// Behaviour
	var launchAtLogin = false
	var panelTheme: PanelTheme = .glass
	/// Where the panel appears. The alternatives offer four and their users keep complaining that
	/// the window drifts to another display, so "remember where it was" is the default here.
	var windowPlacement: WindowPlacement = .remembered
	var pinWindow = false
	var closeOnOutsideClick = true
	/// Put the *source* text on the pasteboard as soon as it is captured — the selection for 划词,
	/// the recognised text for 截图.
	///
	/// On by default, and separate from `autoCopyOnClose` (the translation) on purpose: this one
	/// is about getting the text *out* of the app so it can be pasted somewhere else, which is the
	/// common case — you screenshot a formula and want it in your notes. Turning it off does not
	/// stop the source appearing in the panel.
	var autoCopySourceToClipboard = true
	var autoCopyOnClose = false
	var appearance = "system"
	var summaryCollapsed = false
	var translationCollapsed = false
	/// Fraction of the card area given to the summary card; the translation card takes the rest.
	/// Stored as a fraction rather than in points so the split survives a window resize and a
	/// change of display.
	var cardSplit = 0.5

	// Proxy. A top-voted request in every comparable app's issue tracker.
	/// Proxy support is also the cheapest possible win — a few lines per request.
	var proxyEnabled = false
	var proxyHost = ""
	var proxyPort = 7890
	var proxyRequiresAuth = false
	var proxyUsername = ""
	/// The proxy password lives in the secrets file, not in config.json.

	// Window frame, NSStringFromRect. Kept here rather than NSWindow's autosave so it can be
	// read synchronously on the hotkey path.
	var windowFrameString = ""

	private var saveTask: Task<Void, Never>?

	/// When false, nothing is written to disk. The test modes turn this on after seeding so a
	/// test run can never rewrite the user's real configuration — an earlier version of the
	/// self test called `Secrets.removeEverything()` and deleted the actual API keys.
	static var persistenceEnabled = true

	private init() {
		load()
		publishProxySettings()
	}

	/// Decodes a stored config, tolerating fields it doesn't contain.
	///
	/// Decoding `Persisted` directly throws `keyNotFound` on a missing key, and `load()`'s only
	/// failure path is to abandon the entire file and keep the defaults — so **one absent field
	/// silently reset every setting**, API keys and hotkeys included. That is not hypothetical: it
	/// is what adding `cardSplit` to a config that predated it would have done, and what deleting
	/// a single key by hand does today.
	///
	/// Rather than make all thirty fields optional — which duplicates every default and lets the
	/// two lists drift — the stored dictionary is merged onto a fully-populated one first, so an
	/// unknown-to-the-file field takes its default and everything else survives. Costs one extra
	/// encode/decode at launch and makes adding a field safe forever.
	///
	/// The one state the file itself can be in and the UI cannot is "both features off", so the
	/// pair is settled here rather than in `load()`. `load()` is not the only reader — the checks
	/// decode configs directly, and so would anything else that ever wants to inspect a stored
	/// file — and a rule that only holds on one of two paths is not a rule. The prompt overrides
	/// are pruned here for the same reason, and that one was a real bug: the pruning lived in
	/// `load()` alone, so a decoded config came back carrying an override for `summary.paper` — a
	/// preset this build does not ship — and nothing on the load path would ever have removed it.
	static func decodeConfig(_ data: Data, defaults: Persisted) -> Persisted? {
		guard var stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			let fallback = try? JSONSerialization.jsonObject(
				with: JSONEncoder().encode(defaults)) as? [String: Any]
		else { return nil }

		// `translationEnabled` is `Bool?` in `Persisted` because a config written before it existed
		// has no such key. Filling an absent key from `defaults` would fill it from the *current*
		// in-memory value, which is not the same thing as the field's own default: decode a config
		// while 仅总结 happens to be selected and the app writes "translation off" back into it.
		// The `?? true` belongs here, at the field, before the merge can speak for it.
		stored["translationEnabled"] =
			stored["translationEnabled"] ?? defaults.translationEnabled ?? true
		// Same reason as the line above, one field along: absent means "not yet seen", which is
		// `false`, and taking it from `defaults` would mean taking it from whatever this session
		// happens to have set.
		stored["hasCompletedOnboarding"] = stored["hasCompletedOnboarding"] ?? false
		for (key, value) in fallback where stored[key] == nil { stored[key] = value }

		let settled = resolvedFeatureFlags(
			summary: stored["summaryEnabled"] as? Bool ?? defaults.summaryEnabled,
			translation: stored["translationEnabled"] as? Bool ?? true)
		stored["summaryEnabled"] = settled.summary
		stored["translationEnabled"] = settled.translation
		// Only when the key is there. Writing `[:]` for an absent one would blank the default the
		// merge above just filled in, which is the difference between "this config has no edits"
		// and "this config has no edits *now*" — and the second one silently discards the prompt
		// the user is looking at.
		if stored["promptOverrides"] != nil {
			stored["promptOverrides"] = prunedPromptOverrides(stored["promptOverrides"])
		}
		guard let merged = try? JSONSerialization.data(withJSONObject: stored) else { return nil }
		return try? JSONDecoder().decode(Persisted.self, from: merged)
	}

	/// The overrides that name a prompt this build still ships, and nothing else.
	///
	/// A config from the version with three prompts per slot carries `summary.paper` and the like.
	/// Keeping them would mean nothing can ever display them, they survive every future write, and
	/// a later release cannot clean them up — so they are dropped at the door, on every path that
	/// reads a config. Takes and returns `Any?` because it runs on the raw JSON dictionary, before
	/// there is a `Persisted` to talk about: an override whose *shape* is also wrong is dropped by
	/// the decode that follows, and has to be allowed through this far in order for that to happen
	/// rather than the whole file being rejected.
	static func prunedPromptOverrides(_ raw: Any?) -> [String: Any] {
		let known = Set(PromptSlot.allCases.map { PromptPreset.builtin(for: $0).id })
		guard let dictionary = raw as? [String: Any] else { return [:] }
		return dictionary.filter { known.contains($0.key) }
	}

	/// The two feature flags, with the panel's one invariant applied: something is always on.
	///
	/// A config file is hand-editable and `translationEnabled` is optional in it, so this is where
	/// "off and off" — a hotkey that reads a selection and shows nothing — becomes "summary only".
	/// The UI never produces the pair, but the file can contain it, and the alternative to
	/// deciding here is deciding nowhere: the panel would render two empty header strips.
	static func resolvedFeatureFlags(
		summary: Bool, translation: Bool
	) -> (summary: Bool, translation: Bool) {
		(summary || translation) ? (summary, translation) : (true, false)
	}

	/// Mirrors the proxy settings into the lock-protected value the URLSession layer reads.
	func publishProxySettings() {
		ProxySettingsCache.update(
			ProxySettings(
				isEnabled: proxyEnabled && !proxyHost.isEmpty,
				host: proxyHost,
				port: proxyPort,
				requiresAuth: proxyRequiresAuth,
				username: proxyUsername,
				password: Secrets.shared.value(Secrets.Key.proxyPassword)))
	}

	// MARK: - Derived

	/// The usable range for `cardSplit`. A card squeezed below ~15% of a 260pt-tall panel is
	/// shorter than its own header, which reads as broken rather than small.
	static let cardSplitRange: ClosedRange<Double> = 0.15...0.85

	/// Single clamp for `cardSplit`, shared by the load path and the drag handler.
	///
	/// Two callers clamping independently is how they drift apart, and the drift is invisible:
	/// `config.json` is hand-editable, so a stale or hand-typed 1.4 would hand the translation
	/// card a negative height and push the summary off the panel.
	static func clampCardSplit(_ value: Double) -> Double {
		min(max(value, cardSplitRange.lowerBound), cardSplitRange.upperBound)
	}

	var currentProvider: LLMProviderConfig {
		providers.first { $0.id == llmProviderID } ?? providers[0]
	}

	/// Computed from the in-memory secret cache, so it is safe to call from the hotkey path.
	var summaryReady: Bool {
		let provider = currentProvider
		return !provider.apiKey.isEmpty && !provider.baseURL.isEmpty && !provider.model.isEmpty
	}

	/// A short, honest description of why the summary can't run yet — used by the menu item,
	/// the panel banner and the settings sheet.
	var summaryBlockedReason: String? {
		if !summaryEnabled { return nil }
		if currentProvider.baseURL.isEmpty { return "尚未配置大模型接口地址" }
		if currentProvider.apiKey.isEmpty { return "尚未配置 \(currentProvider.name) 的 API Key" }
		if currentProvider.model.isEmpty { return "尚未选择模型" }
		return nil
	}

	func provider(withID id: String) -> LLMProviderConfig? {
		providers.first { $0.id == id }
	}

	func updateProvider(_ id: String, _ mutate: (inout LLMProviderConfig) -> Void) {
		guard let index = providers.firstIndex(where: { $0.id == id }) else { return }
		mutate(&providers[index])
		commit()
	}

	// MARK: - Feature mode

	/// The two switches as one of the three modes the settings page offers. Derived, never
	/// stored: `config.json` keeps the two booleans, so a build that predates 功能设置 still reads
	/// a config written by this one.
	var featureMode: FeatureMode {
		FeatureMode.resolve(summary: summaryEnabled, translation: translationEnabled)
	}

	/// The one place the two feature flags are written together, so both entry points — the
	/// segmented control on 通用设置 and the menu bar — go through one assignment instead of two
	/// that could disagree.
	///
	/// `requested` is applied as given. The guard is a backstop rather than a code path: no
	/// `FeatureMode` case turns both cards off, so it cannot fire today, and it exists so that a
	/// fourth case added later has to be a decision rather than an accident. The state it refuses
	/// is unreachable from the UI by construction, which is the point of using three values; a
	/// hand-edited file that contains it is settled in `resolvedFeatureFlags`.
	func setFeatureMode(_ requested: FeatureMode) {
		guard requested.summarizes || requested.translates else { return }
		// Compared before assigning, so an unchanged flag does not fire an observation for
		// nothing — the panel re-renders from these.
		if summaryEnabled != requested.summarizes { summaryEnabled = requested.summarizes }
		if translationEnabled != requested.translates { translationEnabled = requested.translates }
		commit()
	}

	/// Menu-bar toggle. Turning it on without a usable LLM config would only surface as an
	/// error inside the panel, so the menu item reads `summaryBlockedReason` and routes the
	/// user straight to the right settings page instead.
	///
	/// Refused when translation is the only thing left on: a menu row that appears to do nothing
	/// is worse than one that was never offered, but the two feature rows are also the only place
	/// the mode can be seen from outside the settings window, so removing one dynamically would be
	/// worse still. `debugTitles` asserts both rows are always present.
	func toggleSummary() {
		if summaryEnabled, !translationEnabled { return }
		summaryEnabled.toggle()
		commit()
	}

	/// The same toggle for translation, with the same refusal in the other direction.
	func toggleTranslation() {
		if translationEnabled, !summaryEnabled { return }
		translationEnabled.toggle()
		commit()
	}

	func addCustomProvider() {
		let provider = LLMProviderConfig.makeCustom()
		providers.append(provider)
		llmProviderID = provider.id
		commit()
	}

	func removeProvider(_ id: String) {
		guard providers.first(where: { $0.id == id })?.isBuiltin == false else { return }
		providers.removeAll { $0.id == id }
		// Remove the entry outright. Blanking the value left an orphan behind, so repeatedly
		// adding and removing custom providers accumulated one dead key each time.
		Secrets.shared.forget([Secrets.Key.llmAPIKey(providerID: id)])
		if llmProviderID == id { llmProviderID = providers.first?.id ?? "deepseek" }
		commit()
	}

	// MARK: - The two prompts

	/// The prompt in force for a slot: what ships, with the user's edits folded in.
	///
	/// Never nil and never empty-handed. There is no selection to resolve and nothing to fall back
	/// from — the earlier version could hand back a prompt belonging to the wrong slot, or a
	/// built-in from a future release this build had never heard of, and the fallback chain for
	/// both of those was the bug surface. One prompt per slot has neither failure mode.
	func prompt(for slot: PromptSlot) -> PromptPreset {
		resolved(PromptPreset.builtin(for: slot))
	}

	var summaryPrompt: PromptPreset { prompt(for: .summary) }
	var translationPrompt: PromptPreset { prompt(for: .translation) }

	private func resolved(_ preset: PromptPreset) -> PromptPreset {
		guard let override = promptOverrides[preset.id] else { return preset }
		var result = preset
		// An empty string here is the user having cleared the field, which is different from
		// having left it alone — hence `if let` rather than a nil-coalescing default.
		if let system = override.system { result.system = system }
		if let user = override.user { result.user = user }
		return result
	}

	/// Whether the prompt for this slot differs from what shipped. Drives the 还原 button — a
	/// restore offered when there is nothing to restore just teaches people to ignore the button.
	func isPromptModified(_ slot: PromptSlot) -> Bool {
		promptOverrides[PromptPreset.builtin(for: slot).id]?.isEmpty == false
	}

	/// Records an edit. **Only the fields that actually differ are stored**, which is what lets a
	/// later release improve the shipped text for someone who never touched that field — and an
	/// edit that puts the text back exactly as it shipped drops the override entirely, so the
	/// 已修改 marker cannot outlive the change it was reporting.
	func updatePrompt(_ edited: PromptPreset) {
		let builtin = PromptPreset.builtin(for: edited.slot)
		var override = promptOverrides[builtin.id] ?? .empty()
		override.system = edited.system == builtin.system ? nil : edited.system
		override.user = edited.user == builtin.user ? nil : edited.user
		if override.isEmpty {
			promptOverrides.removeValue(forKey: builtin.id)
		} else {
			promptOverrides[builtin.id] = override
		}
		commit()
	}

	/// Restores a slot's prompt to exactly what ships, byte for byte. Dropping the whole override
	/// rather than writing the shipped text back into it is what makes this a *restore*: the field
	/// goes back to being untouched, so a future release can still improve it.
	func restorePrompt(_ slot: PromptSlot) {
		promptOverrides.removeValue(forKey: PromptPreset.builtin(for: slot).id)
		commit()
	}

	// MARK: - Credentials

	var baiduConfigured: Bool {
		!baiduAppID.isEmpty && !Keychain.baiduSecretKey().isEmpty
	}

	var tencentConfigured: Bool {
		!tencentSecretID.isEmpty && !Keychain.tencentSecretKey().isEmpty
	}

	var deepLConfigured: Bool { !Keychain.deepLKey().isEmpty }

	func engineReady(_ engine: MTEngine) -> Bool {
		switch engine {
		case .llm: return summaryReady
		case .apple: return true
		case .baidu: return baiduConfigured
		case .tencent: return tencentConfigured
		case .deepl: return deepLConfigured
		}
	}

	// MARK: - Persistence

	private static var configURL: URL {
		let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
		return base.appendingPathComponent("Insight/config.json")
	}

	func load() {
		guard Self.persistenceEnabled else { return }
		guard let data = try? Data(contentsOf: Self.configURL),
			let json = Self.decodeConfig(data, defaults: snapshot())
		else { return }

		// `?? true`, not `?? false`: every config written before 功能设置 existed has no such key,
		// and for those users translation was the whole point of the app. Reading them back with
		// translation switched off would look exactly like the feature having been deleted.
		//
		// The pair then goes through `resolvedFeatureFlags`, which `decodeConfig` has already
		// applied — so this is a read of one rule, not a second place the rule is written down.
		let features = Self.resolvedFeatureFlags(
			summary: json.summaryEnabled, translation: json.translationEnabled ?? true)
		summaryEnabled = features.summary
		translationEnabled = features.translation
		summaryLanguage = json.summaryLanguage
		summaryMaxChars = json.summaryMaxChars
		translateEngine = json.translateEngine
		sourceLanguage = json.sourceLanguage
		targetLanguage = json.targetLanguage
		baiduAppID = json.baiduAppID
		tencentSecretID = json.tencentSecretID
		selectionHotkey = json.selectionHotkey
		snipHotkey = json.snipHotkey
		launchAtLogin = json.launchAtLogin
		pinWindow = json.pinWindow
		closeOnOutsideClick = json.closeOnOutsideClick
		autoCopySourceToClipboard = json.autoCopySourceToClipboard ?? true
		autoCopyOnClose = json.autoCopyOnClose
		appearance = json.appearance
		summaryCollapsed = json.summaryCollapsed
		translationCollapsed = json.translationCollapsed
		// Clamped on read: the file is hand-editable and a stale value outside the usable range
		// would collapse one card to nothing.
		cardSplit = Self.clampCardSplit(json.cardSplit ?? 0.5)
		panelTheme = PanelTheme(rawValue: json.panelTheme) ?? .glass
		windowPlacement = WindowPlacement(rawValue: json.windowPlacement) ?? .remembered
		proxyEnabled = json.proxyEnabled
		proxyHost = json.proxyHost
		proxyPort = json.proxyPort
		proxyRequiresAuth = json.proxyRequiresAuth
		proxyUsername = json.proxyUsername
		windowFrameString = json.windowFrameString

		// `?? false`, and stated here rather than left to the merge: `decodeConfig` fills an
		// absent key from the *current* value, so without this a config written before the guide
		// existed would read back as "already seen" if anything had set the flag this session.
		hasCompletedOnboarding = json.hasCompletedOnboarding ?? false
		// The two prompts. The shipped text comes from code, so only the user's edits are read
		// back — and `decodeConfig` has already dropped the ones naming a prompt this build does
		// not ship, so there is nothing left to filter here. The old `customPresets` array and the
		// two selection ids are ignored outright: decoding drops unknown keys, so they simply stop
		// being written, and the text is not lost — this build's prompt is a superset of the parts
		// of the three that carried real information.
		promptOverrides = json.promptOverrides ?? [:]

		// Merge persisted providers over the built-ins so a new release can ship new
		// presets without clobbering the user's keys.
		var merged = LLMProviderConfig.builtins
		for saved in json.providers {
			if let index = merged.firstIndex(where: { $0.id == saved.id }) {
				merged[index] = saved
			} else if !saved.isBuiltin {
				merged.append(saved)
			}
		}
		providers = merged
		llmProviderID = json.llmProviderID
		if provider(withID: llmProviderID) == nil { llmProviderID = providers.first?.id ?? "deepseek" }

		applyLaunchAtLogin()
	}

	/// Debounced write. The config is a few kilobytes, so this stays cheap; the debounce
	/// keeps a drag on the shortcut recorder from writing on every keypress.
	func commit() {
		publishProxySettings()
		guard Self.persistenceEnabled else { return }
		saveTask?.cancel()
		saveTask = Task { [weak self] in
			try? await Task.sleep(nanoseconds: 250_000_000)
			guard !Task.isCancelled else { return }
			self?.saveNow()
		}
	}

	/// The current settings as a `Persisted`.
	///
	/// Shared by the writer and by `decodeConfig`'s fallback so there is exactly one list of what
	/// gets stored — two would drift, and the drifted one would be the fallback that silently
	/// replaces the user's values.
	func snapshot() -> Persisted {
		Persisted(
			hasCompletedOnboarding: hasCompletedOnboarding,
			summaryEnabled: summaryEnabled,
			translationEnabled: translationEnabled,
			summaryLanguage: summaryLanguage,
			summaryMaxChars: summaryMaxChars,
			translateEngine: translateEngine,
			sourceLanguage: sourceLanguage,
			targetLanguage: targetLanguage,
			baiduAppID: baiduAppID,
			tencentSecretID: tencentSecretID,
			selectionHotkey: selectionHotkey,
			snipHotkey: snipHotkey,
			launchAtLogin: launchAtLogin,
			pinWindow: pinWindow,
			closeOnOutsideClick: closeOnOutsideClick,
			autoCopySourceToClipboard: autoCopySourceToClipboard,
			autoCopyOnClose: autoCopyOnClose,
			appearance: appearance,
			summaryCollapsed: summaryCollapsed,
			translationCollapsed: translationCollapsed,
			cardSplit: cardSplit,
			panelTheme: panelTheme.rawValue,
			windowPlacement: windowPlacement.rawValue,
			proxyEnabled: proxyEnabled,
			proxyHost: proxyHost,
			proxyPort: proxyPort,
			proxyRequiresAuth: proxyRequiresAuth,
			proxyUsername: proxyUsername,
			windowFrameString: windowFrameString,
			promptOverrides: promptOverrides,
			llmProviderID: llmProviderID,
			providers: providers)
	}

	func saveNow() {
		publishProxySettings()
		guard Self.persistenceEnabled else { return }
		saveTask?.cancel()
		saveTask = nil
		let persisted = snapshot()
		guard let data = try? JSONEncoder().encode(persisted) else { return }
		let url = Self.configURL
		try? FileManager.default.createDirectory(
			at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		try? data.write(to: url, options: Data.WritingOptions.atomic)
	}

	// MARK: - Side effects

	func applyLaunchAtLogin() {
		guard SMAppService.mainApp.status == .enabled else {
			if launchAtLogin { try? SMAppService.mainApp.register() }
			return
		}
		if !launchAtLogin { try? SMAppService.mainApp.unregister() }
	}

	func applyAppearance() {
		switch appearance {
		case "light": NSApp.appearance = NSAppearance(named: .aqua)
		case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
		default: NSApp.appearance = nil
		}
	}

	// MARK: - Codable shape

	struct Persisted: Codable {
		/// Optional like everything added after the first release: absent in every config written
		/// before the first-run guide existed, and the default is `false`, so a missing key must
		/// decode as "not yet seen". `decodeConfig`'s merge would fill it from the current
		/// in-memory value otherwise, which is the bug that ate `translationEnabled`.
		var hasCompletedOnboarding: Bool?
		var summaryEnabled: Bool
		/// Optional, like `autoCopySourceToClipboard`: absent in every config written before
		/// 功能设置 existed, and the default is `true`, so a missing key must not decode as `false`.
		/// It survives the merge in `decodeConfig` either way — the `??` is what makes it survive a
		/// config that *does* contain the key.
		var translationEnabled: Bool?
		var summaryLanguage: String
		var summaryMaxChars: Int
		var translateEngine: MTEngine
		var sourceLanguage: String
		var targetLanguage: String
		var baiduAppID: String
		var tencentSecretID: String
		var selectionHotkey: KeyCombo
		var snipHotkey: KeyCombo
		var launchAtLogin: Bool
		var pinWindow: Bool
		var closeOnOutsideClick: Bool
		/// Optional: absent in every config written before this setting existed, and the
		/// default is `true`, so it must not decode as `false`.
		var autoCopySourceToClipboard: Bool?
		var autoCopyOnClose: Bool
		var appearance: String
		var summaryCollapsed: Bool
		var translationCollapsed: Bool
		/// Optional so that a `config.json` written by an older build still decodes.
		///
		/// Every other field here is non-optional, which makes adding one a landmine: `load()`
		/// discards the whole file when decoding throws, so a missing key does not fall back to a
		/// default — it silently resets the user's API keys, hotkeys and window position. An
		/// optional field with a `??` default is the only kind that can be added safely.
		var cardSplit: Double?
		var panelTheme: String
		var windowPlacement: String
		var proxyEnabled: Bool
		var proxyHost: String
		var proxyPort: Int
		var proxyRequiresAuth: Bool
		var proxyUsername: String
		var windowFrameString: String
		/// Optional, like the two fields above it: a config written before editable prompts existed
		/// has none of these, and the tolerant decode fills them from the current defaults. Making
		/// them non-optional would also work — `decodeConfig` merges onto a fully-populated
		/// dictionary — but the `??` is one character and immune to a future decode path that
		/// forgets the merge.
		///
		/// `customPresets`, `summaryPresetID` and `translatePresetID` used to live here. They are
		/// gone rather than kept-and-ignored: this struct decodes with unknown keys dropped, so a
		/// config from the multi-preset version loads fine, and the three obsolete keys stop being
		/// written the first time anything is saved. Keeping them would have left a permanent
		/// three-line lie about a selection that no longer exists.
		var promptOverrides: [String: PromptOverride]?
		var llmProviderID: String
		var providers: [LLMProviderConfig]
	}

}
/// Where the result panel appears. The alternatives offer right / centre / mouse / last and their
/// users keep filing bugs about the window following the cursor onto the wrong display, so
/// remembering the position is the default here and the other modes are opt-in.
enum WindowPlacement: String, CaseIterable, Identifiable, Sendable {
	case remembered
	case cursor
	case centered

	var id: String { rawValue }

	var displayName: String {
		switch self {
		case .remembered: return "记住上次位置"
		case .cursor: return "跟随鼠标"
		case .centered: return "屏幕中心"
		}
	}
}
