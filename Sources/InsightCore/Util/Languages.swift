import Foundation
import NaturalLanguage

/// One language, expressed in each engine's own vocabulary.
///
/// Every MT vendor invented its own code table, so instead of five parallel dictionaries the
/// language list is filtered down to what the currently selected engine actually accepts —
/// you can't pick a target the engine will reject.
struct LanguageOption: Identifiable, Hashable {
	var id: String  // Insight's canonical code
	var name: String  // 简体中文
	var apple: String  // Locale.Language identifier
	var englishName: String  // used in LLM prompts
	var baidu: String?
	var tencent: String?
	var deepl: String?

	func code(for engine: MTEngine) -> String? {
		switch engine {
		case .llm, .apple: return apple
		case .baidu: return baidu
		case .tencent: return tencent
		case .deepl: return deepl
		}
	}

	var supportsBaidu: Bool { baidu != nil }
	var supportsTencent: Bool { tencent != nil }
	var supportsDeepL: Bool { deepl != nil }
}

enum Languages {
	static let all: [LanguageOption] = [
		.init(id: "zh-Hans", name: "简体中文", apple: "zh-Hans", englishName: "Simplified Chinese",
			baidu: "zh", tencent: "zh", deepl: "ZH-HANS"),
		.init(id: "zh-Hant", name: "繁体中文", apple: "zh-Hant", englishName: "Traditional Chinese",
			baidu: "cht", tencent: "zh", deepl: "ZH-HANT"),
		.init(id: "en", name: "英语", apple: "en", englishName: "English",
			baidu: "en", tencent: "en", deepl: "EN"),
		.init(id: "ja", name: "日语", apple: "ja", englishName: "Japanese",
			baidu: "jp", tencent: "ja", deepl: "JA"),
		.init(id: "ko", name: "韩语", apple: "ko", englishName: "Korean",
			baidu: "kor", tencent: "ko", deepl: "KO"),
		.init(id: "fr", name: "法语", apple: "fr", englishName: "French",
			baidu: "fra", tencent: "fr", deepl: "FR"),
		.init(id: "de", name: "德语", apple: "de", englishName: "German",
			baidu: "de", tencent: "de", deepl: "DE"),
		.init(id: "es", name: "西班牙语", apple: "es", englishName: "Spanish",
			baidu: "spa", tencent: "es", deepl: "ES"),
		.init(id: "ru", name: "俄语", apple: "ru", englishName: "Russian",
			baidu: "ru", tencent: "ru", deepl: "RU"),
		.init(id: "pt", name: "葡萄牙语", apple: "pt", englishName: "Portuguese",
			baidu: "pt", tencent: "pt", deepl: "PT"),
		.init(id: "it", name: "意大利语", apple: "it", englishName: "Italian",
			baidu: "it", tencent: "it", deepl: "IT"),
		.init(id: "nl", name: "荷兰语", apple: "nl", englishName: "Dutch",
			baidu: "nl", tencent: nil, deepl: "NL"),
		.init(id: "pl", name: "波兰语", apple: "pl", englishName: "Polish",
			baidu: "pl", tencent: nil, deepl: "PL"),
		.init(id: "tr", name: "土耳其语", apple: "tr", englishName: "Turkish",
			baidu: "tr", tencent: "tr", deepl: "TR"),
		.init(id: "id", name: "印尼语", apple: "id", englishName: "Indonesian",
			baidu: "id", tencent: nil, deepl: "ID"),
		.init(id: "ar", name: "阿拉伯语", apple: "ar", englishName: "Arabic",
			baidu: "ara", tencent: "ar", deepl: "AR"),
		.init(id: "th", name: "泰语", apple: "th", englishName: "Thai",
			baidu: "th", tencent: "th", deepl: nil),
		.init(id: "vi", name: "越南语", apple: "vi", englishName: "Vietnamese",
			baidu: "vie", tencent: "vi", deepl: nil),
	]

	static let autoID = "auto"
	static let autoDisplay = "自动识别"

	/// One entry in the panel's language menus.
	///
	/// Deliberately not a `LanguageOption`: that describes a language a *vendor* can be asked for,
	/// and `自动识别` has no vendor code on either side of a request.
	struct QuickLanguage: Identifiable, Hashable {
		var id: String
		var name: String
	}

	/// The languages offered by the panel's own pickers.
	///
	/// The settings page keeps the full per-engine list, because there you are configuring. The
	/// panel is for the common case and a one-line header, so it offers five — and no more, or the
	/// menu is taller than the card it sits in. `自动识别` is on the target side too: it resolves
	/// to whatever the source turned out to be (see `InsightPipeline.resolvedTarget`).
	static let quickIDs = [autoID, "zh-Hans", "zh-Hant", "en", "ja"]

	/// `quickIDs`, plus whatever the user actually has selected when that isn't one of them.
	///
	/// Without this, a target set to French in the settings page renders the picker with nothing
	/// ticked, which reads as "no language selected" rather than "a language not on this menu".
	static func quickLanguages(including selectedID: String?) -> [QuickLanguage] {
		var ids = quickIDs
		if let selectedID, !selectedID.isEmpty, !ids.contains(selectedID) { ids.append(selectedID) }
		return ids.map { QuickLanguage(id: $0, name: name($0)) }
	}

	static func option(_ id: String) -> LanguageOption? {
		all.first { $0.id == id }
	}

	static func name(_ id: String) -> String {
		if id == autoID { return autoDisplay }
		return option(id)?.name ?? id
	}

	static func englishName(_ id: String) -> String {
		if id == autoID { return "auto-detected language" }
		return option(id)?.englishName ?? id
	}

	/// Options the given engine can actually be asked for.
	static func supported(for engine: MTEngine) -> [LanguageOption] {
		all.filter { $0.code(for: engine) != nil }
	}

	static func code(_ id: String, for engine: MTEngine) -> String? {
		option(id)?.code(for: engine)
	}

	/// Resolve the `auto` placeholder. Uses NaturalLanguage, which is bundled with the OS —
	/// no model download, no network.
	static func detect(_ text: String) -> String {
		guard !text.isEmpty else { return "en" }
		let recognizer = NLLanguageRecognizer()
		recognizer.processString(text)
		guard let raw = recognizer.dominantLanguage?.rawValue else { return "en" }
		return normalize(detected: raw)
	}

	static func normalize(detected raw: String) -> String {
		switch raw {
		case "zh-Hans", "zh-Hans-CN", "zh-SG", "zh": return "zh-Hans"
		case "zh-Hant", "zh-Hant-TW", "zh-HK", "zh-MO": return "zh-Hant"
		case "en-US", "en-GB": return "en"
		default:
			if let match = all.first(where: { $0.id == raw }) { return match.id }
			// Fall back to a prefix match: `pt-BR` -> `pt`.
			if let prefix = raw.split(separator: "-").first.map(String.init),
				let match = all.first(where: { $0.id == prefix })
			{ return match.id }
			return "en"
		}
	}
}