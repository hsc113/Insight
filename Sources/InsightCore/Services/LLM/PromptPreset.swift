import Foundation

/// Which half of the request a prompt governs.
///
/// Summary and translation get **separate** prompts rather than one prompted twice. They are
/// changed for unrelated reasons — someone rewriting their code summary has no business having
/// their translation prompt reset — and one text covering both would mean every edit to one half
/// drags the other along.
enum PromptSlot: String, Codable, CaseIterable, Identifiable, Sendable {
	case summary
	case translation

	var id: String { rawValue }

	var displayName: String {
		switch self {
		case .summary: return "总结"
		case .translation: return "翻译"
		}
	}

	/// SF Symbol used by the slot switcher.
	var symbol: String {
		switch self {
		case .summary: return "sparkles"
		case .translation: return "character.book.closed"
		}
	}
}

/// One editable prompt: the shipped default, with whatever the user changed folded in.
///
/// **There is exactly one per slot.** Earlier versions shipped three built-ins per slot (日常 /
/// 论文 / 代码 · 默认 / 直译 / 口语) plus user-created ones, a list to pick between and a plus
/// button — and the list was the part nobody used. Two of the three were a paragraph of
/// difference, so the honest description of the old UI was "three ways to write the same
/// instruction, two of which you never opened". What survives is the part that earned its place:
/// the shipped text can be edited, and 还原 puts it back byte for byte. There is no stored name
/// either — with one prompt per slot a name would have exactly one legal value, and nothing left
/// to display it.
struct PromptPreset: Codable, Identifiable, Equatable, Sendable {
	var id: String
	var slot: PromptSlot
	/// Role and style contract. The system message — see `Prompts.Request`.
	var system: String
	/// The instruction, with `{{…}}` placeholders. The user message.
	var user: String

}

/// The subset of a shipped prompt a user has actually changed.
///
/// Stored per field rather than as a whole replacement so that a release can still improve a
/// shipped prompt for users who never touched it. `nil` means "keep what ships"; a field the user
/// deliberately blanked is `""`, which is a different thing and must survive.
///
/// `name` is read back from older configs and ignored — the field it overrode no longer exists.
/// Dropping it from the type would make those configs fail to decode, which is the one outcome
/// `Settings.decodeConfig` exists to prevent.
struct PromptOverride: Codable, Equatable, Sendable {
	var name: String?
	var system: String?
	var user: String?

	static func empty() -> PromptOverride { PromptOverride() }

	/// Whether this override would change anything. Only the two fields that still exist count:
	/// a config whose sole edit was a rename is, by this build's reckoning, unmodified.
	var isEmpty: Bool { system == nil && user == nil }
}

// MARK: - The two shipped prompts

extension PromptPreset {
	enum BuiltinID {
		static let summary = "summary.default"
		static let translation = "translation.default"
	}

	/// The prompt that ships for a slot.
	///
	/// One `switch` rather than two statics read from different places: `Settings.prompt(for:)`
	/// and the checker both need "the factory text for this slot", and the second copy of that
	/// mapping is how a restore starts restoring the wrong thing.
	static func builtin(for slot: PromptSlot) -> PromptPreset {
		switch slot {
		case .summary: return summaryDefault
		case .translation: return translationDefault
		}
	}

	// MARK: Summary

	/// The summary prompt.
	///
	/// This is the prompt that used to say *"信息多则写到覆盖原文全部关键点为止"* — and that
	/// single sentence is why summaries arrived as a complete list of the source's points rather
	/// than the few that mattered. Instructing the model on what it **must not miss** produces an
	/// exhaustive inventory; the rule now runs the other way round, from what may be *dropped*:
	/// keep a point only if removing it would misrepresent the text.
	///
	/// The cap is hard on purpose. A soft "as many as the information warrants" is what it said
	/// before, and models read it as a licence.
	///
	/// The 论文 and 代码 variants that used to sit beside this one are gone; the parts of them that
	/// carried real information are folded in below — preserving identifiers and numbers verbatim,
	/// and "only when deleting it would misrepresent the text" — which is most of what they were
	/// buying, without asking the user to choose before they have read anything.
	static let summaryDefault = PromptPreset(
		id: BuiltinID.summary,
		slot: .summary,
		system: """
			你是一名专业的文本摘要助手。你只做概括，不解读、不评价、不补充原文没有的内容。
			你的输出会直接显示在阅读器里，所以格式必须严格照做。
			""",
		user: """
			用{{summaryLanguage}}输出，格式：

			第一段：一句话概括全文的核心结论。不加标题、不加序号、不超过 40 字。
			空一行。
			之后逐行列出要点，每行以 "- " 开头，**最多 4 条**。最关键的信息用两个星号包起来加粗（**像这样**），一条里最多加粗一处。

			只留最重要的：
			- 能合并成一条的要点就合并，一条也不要拆开
			- 一句话就说得清的，不要单列成一条
			- 只有删掉之后会误解原文的，才值得留。宁可少写，也不要把原文每句话都变成要点

			禁止：
			- 不要输出 ``` 代码块
			- 不要输出"总结："、"要点："、"以下是"这类标签
			- 不要用"本文"、"这篇文章"、"作者认为"、"综上所述"

			内容要求：
			1. 全文不超过 {{maxChars}} 字（原文共 {{inputChars}} 字）
			2. 只写原文明确写出的内容，不补充背景、推测、观点
			3. 人名、数字、结论、专有名词、函数名和文件路径逐字保留，不要改写、翻译或四舍五入

			格式示例（只示意排版，不要照抄条数和内容）：
			新模型把上下文长度提升到四倍，API 价格下降六成
			- 上下文提升到 **4 倍**，价格 **下降 60%**
			- 首批 API 明天开放，速率限制为 **每分钟 1200 次**

			待概括的文本：
			{{text}}
			""")

	// MARK: Translation

	/// The translation prompt.
	///
	/// The system contract is the standard one — including the clause that the result must read as
	/// a native speaker's rather than as a gloss — plus the clause that inline code, identifiers and
	/// paths survive byte for byte, which is the whole of what the old 直译 variant was for. A
	/// translation that keeps `captureRegion(_:)` intact *and* reads naturally is what the one
	/// remaining prompt should produce; asking the user to pick between the two up front was the
	/// part that never worked, because you cannot know which you needed until you see the output.
	static let translationDefault = PromptPreset(
		id: BuiltinID.translation,
		slot: .translation,
		system: """
			You are a translation expert. You translate and nothing else: no commentary, no \
			notes, no restating the source. Understand proper nouns, idioms, metaphors and \
			allusions in context and render them the way a native speaker would. The result \
			must read as natural, fluent {{targetLanguage}}, not as a gloss. Inline code, \
			identifiers, file paths, CLI flags, option names and version numbers are not prose: \
			keep them byte for byte.
			""",
		user: """
			Translate the following {{sourceLanguage}}text into {{targetLanguage}}. Preserve the \
			paragraph structure and line breaks of the source. Leave code spans, identifiers and \
			paths in their original form. Only return the translated text, with no surrounding \
			quotes and no additional notes.

			{{text}}
			""")
}

// MARK: - Template rendering

/// Turns a preset's `{{…}}` template into the string that goes on the wire.
///
/// The rules here are the contract between a user-editable prompt and the request it produces:
///
/// - **`{{text}}` expands to the fenced source**, fences included. The fence is not written into
///   the template because a custom prompt that omits the placeholder must still get fenced text
///   (see the second rule), and doing that in one place is the only way the two paths cannot
///   disagree.
/// - **A template that never mentions `{{text}}` gets the fenced text appended.** Dropping the
///   source is otherwise a silent failure: the request goes out, the model dutifully answers a
///   prompt with nothing to summarise, and the user sees a confident summary of nothing. Appending
///   is not the same as the model following the instruction, but it is strictly better than a
///   request with no subject.
enum PromptTemplate {
	/// Every placeholder a template may use. Rendered into the settings UI as a cheat sheet, and
	/// asserted against in the checker so a typo in a built-in cannot pass unnoticed.
	static let knownKeys = [
		"text", "summaryLanguage", "sourceLanguage", "targetLanguage", "maxChars", "inputChars",
	]

	static func token(_ key: String) -> String { "{{\(key)}}" }

	/// The placeholders that mean anything for a slot.
	///
	/// A summary prompt has no source or target language and a translation prompt has no budget,
	/// so listing all six in both cheat sheets is how a `{{maxChars}}` ends up in a translation
	/// where it resolves to nothing and disappears without a word.
	static func keys(for slot: PromptSlot) -> [String] {
		switch slot {
		case .summary: return ["text", "summaryLanguage", "maxChars", "inputChars"]
		case .translation: return ["text", "sourceLanguage", "targetLanguage"]
		}
	}

	/// The placeholders a template actually references, in no particular order.
	static func keys(in template: String) -> [String] {
		knownKeys.filter { template.contains(token($0)) }
	}

	/// - Parameters:
	///   - appendsSourceIfMissing: Whether a template with no `{{text}}` gets the source appended.
	///     See `Prompts` — it is on for the user half and off for the system half.
	static func render(
		template: String, input: String, values: [String: String],
		appendsSourceIfMissing: Bool = true
	) -> String {
		var out = template
		// Read before substituting — afterwards the token is gone and there is nothing left to test.
		let mentionsText = out.contains(token("text"))
		// Blank every placeholder the caller had no value for, before substituting the rest. A
		// template that reaches for `{{maxChars}}` on the translation side would otherwise put a
		// literal `{{maxChars}}` on the wire, and the model would ignore it — which is
		// indistinguishable from "the prompt is just weak", i.e. the bug would be undebuggable.
		for key in knownKeys where values[key] == nil {
			out = out.replacingOccurrences(of: token(key), with: "")
		}
		for (key, value) in values {
			out = out.replacingOccurrences(of: token(key), with: value)
		}
		guard !mentionsText, appendsSourceIfMissing else { return out }
		let fenced = Prompts.fence(input)
		return out.isEmpty ? fenced : out + "\n\n" + fenced
	}
}
