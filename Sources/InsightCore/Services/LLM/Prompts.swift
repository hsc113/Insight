import Foundation

/// Prompts live in one place so the summary/translation contract is auditable at a glance.
///
/// The **shape** of a request is fixed and not configurable, because the role/user split is
/// load-bearing:
///
/// - The common shape puts the role and the style contract in the *system* message and leaves the
///   *user* message as nothing but an instruction plus the text, wrapped in `"""` fences. The
///   fence is deliberate — it cites OpenAI's prompt-engineering guidance and exists so the model
///   can't mistake a line of the source text for an instruction addressed to it.
/// - The same shape separates the role prompt (system) from the command prompt (user) and
///   hard-prefixes every request with `Only reply the result and nothing else.` The summarizer
///   role is worth keeping in spirit: *"you can only summarize the text, don't interpret it"* —
///   the failure mode is a commentary on the text, not a summary.
///
/// What *is* configurable is the wording, through `PromptPreset` — the user can edit any preset
/// in either half, restore a built-in to what shipped, or define their own.
///
/// # Why the summary used to be too long, and what actually fixed it
///
/// The old prompt said only `总长度不超过 \(maxChars) 字` — a ceiling with no target, and LLMs
/// treat a ceiling as a budget to approach. It also said, explicitly and at length:
///
/// > 要点条数和详略由原文的信息量决定 … 信息多则写到覆盖原文全部关键点为止
///
/// That second sentence was the actual bug, and the reasoning behind it was wrong in an
/// interesting way. The intent was *"don't force filler bullets onto a one-line notice, and don't
/// cap a dense transcript too low"* — both real. But the only way to express that in a prompt is
/// to state a rule about **coverage**, and a rule about coverage is read as *"produce a complete
/// inventory"*. The model then dutifully lists everything, and the summary ends up the same length
/// as the original with more line breaks.
///
/// The rule now runs from the other end — from what may be **dropped**:
///
/// > 只有删掉之后会误解原文的，才值得留。宁可少写，也不要把原文每句话都变成要点
///
/// plus a hard cap, because a soft "as many as the information warrants" is precisely what it said
/// before. The three supporting changes:
///
/// 1. **Scale the budget to the input** (`lengthBudget`) instead of always offering the ceiling, so
///    a two-sentence selection doesn't get a 600-character summary allowance. The share dropped
///    from 20% to 12% for the same reason the coverage rule had to go.
/// 2. **Forbid the padding moves by name** — no preamble, no "本文 / 作者认为 / 综上所述", no added
///    background. Naming them beats a generic "be concise", because they are the moves the model
///    actually reaches for when a length target feels loose.
/// 3. **Forbid structure the source doesn't have.** Bullets and headings are how a summary doubles
///    in perceived length without adding a single fact.
///
/// # The Markdown structure
///
/// The summary is deliberately shaped — one line of gist, then bullets with the important parts
/// in `**bold**` — because that is the shape people actually re-read in a panel this small. Each
/// of the three dimensions is covered only in part, and never as a combination: a summariser can
/// be absent entirely, a summarise mode can emit plain prose, and a translate prompt can be
/// user-configurable (`{{target_language}}` / `{{text}}`) with no Markdown handling. There is no
/// ready-made combination to copy. What *is* worth keeping is the surrounding craft:
///
/// - An `<example>`-style block that **pins the exact output shape**. It is labelled as showing
///   layout only, not the bullet count, because a fixed number in the example gets copied
///   verbatim no matter what the instruction says.
/// - **Preserve verbatim** for identifiers — numbers, names and conclusions have to survive the
///   compression byte for byte, so they are called out by name.
enum Prompts {
	/// The system message carries identity and the style contract; the user message carries the
	/// instruction and the text. Bundled into one value so a caller can't build a half-old,
	/// half-new pair of prompts.
	struct Request: Equatable, Sendable {
		var system: String
		var user: String
	}

	/// The values a preset's template may interpolate.
	///
	/// One type serves both halves because the substitution table is built from the slot: a summary
	/// template has no source/target language, and a translation template has no budget. Two
	/// context types would mean two render paths that could disagree.
	struct Context: Equatable, Sendable {
		var input: String
		var summaryLanguage: String
		/// Translation only, and **already carrying its trailing space** so a template can read
		/// `{{sourceLanguage}}text` — "the following English text into …" vs "the following text
		/// into …" only reads naturally when there is a source to name. Empty means 自动识别.
		var sourceName: String
		var targetName: String
		/// Summary only. Already scaled by `lengthBudget`, not the raw setting.
		var budget: Int

		init(
			input: String, summaryLanguage: String = "", sourceName: String = "",
			targetName: String = "", budget: Int = 0
		) {
			self.input = input
			self.summaryLanguage = summaryLanguage
			self.sourceName = sourceName
			self.targetName = targetName
			self.budget = budget
		}

		static func summary(input: String, languageName: String, maxChars: Int) -> Context {
			Context(
				input: input,
				summaryLanguage: languageName,
				budget: lengthBudget(inputLength: input.count, maxChars: maxChars))
		}

		static func translate(
			input: String, sourceName: String?, targetName: String
		) -> Context {
			Context(input: input, sourceName: sourceName.map { "\($0) " } ?? "", targetName: targetName)
		}

		func values(for slot: PromptSlot) -> [String: String] {
			var out = ["text": Prompts.fence(input)]
			switch slot {
			case .summary:
				out["summaryLanguage"] = summaryLanguage
				out["maxChars"] = String(budget)
				out["inputChars"] = String(input.count)
			case .translation:
				out["sourceLanguage"] = sourceName
				out["targetLanguage"] = targetName
			}
			return out
		}
	}

	// MARK: - Building

	/// The request built from the prompt in force. `prompt` is a `PromptPreset`, which is the
	/// shipped text with the user's edits already folded in — see `Settings.prompt(for:)`.
	static func summary(prompt: PromptPreset, context: Context) -> Request {
		makeRequest(prompt, context)
	}

	static func translate(prompt: PromptPreset, context: Context) -> Request {
		makeRequest(prompt, context)
	}

	private static func makeRequest(_ prompt: PromptPreset, _ context: Context) -> Request {
		Request(
			system: render(
				preset: prompt, template: systemMessage(for: prompt), context: context,
				appendsSourceIfMissing: false),
			user: render(
				preset: prompt, template: prompt.user, context: context,
				appendsSourceIfMissing: true))
	}

	/// The **shipped** prompt for the slot, ignoring the user's edits.
	///
	/// The checks and the live self test want the factory text rather than the user's version —
	/// otherwise an edited prompt would silently change what the assertions are about, and the
	/// self test would be testing the user's own words back at them.
	static func summary(languageName: String, maxChars: Int, input: String) -> Request {
		summary(
			prompt: PromptPreset.builtin(for: .summary),
			context: .summary(input: input, languageName: languageName, maxChars: maxChars))
	}

	/// The shipped translation prompt, ignoring the user's edits. Same reason as above.
	static func translate(sourceName: String?, targetName: String, input: String) -> Request {
		translate(
			prompt: PromptPreset.builtin(for: .translation),
			context: .translate(input: input, sourceName: sourceName, targetName: targetName))
	}

	/// - Parameter appendsSourceIfMissing: Whether a template that never mentions `{{text}}` gets
	///   the source appended. True for the user message, **false for the system one**: the role
	///   contract must not carry the text, or the source lands in the same message that defines
	///   what a summariser is and the model has to tell them apart. The system half is written by
	///   us and always has its own shape, so the safety net isn't needed there.
	private static func render(
		preset: PromptPreset, template: String, context: Context,
		appendsSourceIfMissing: Bool
	) -> String {
		PromptTemplate.render(
			template: template, input: context.input, values: context.values(for: preset.slot),
			appendsSourceIfMissing: appendsSourceIfMissing)
	}

	/// The system message actually sent.
	///
	/// A role field the user emptied must not become an empty system message — several gateways
	/// reject that with an opaque 400, and the user would have no way to see the cause. Falling
	/// back to the shipped role for the slot keeps a half-finished preset working, which is the
	/// difference between "my edit did nothing" and "my edit broke the app".
	private static func systemMessage(for preset: PromptPreset) -> String {
		guard !preset.system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			return PromptPreset.builtin(for: preset.slot).system
		}
		return preset.system
	}

	/// Summary length as a function of the input, capped by the user's setting.
	///
	/// Proportional on purpose: a fixed cap rewards the model for filling it. **12%**, down from
	/// the 20% that used to sit here — the whole point of the rewrite is that most of a summary's
	/// length is padding, and 20% of a long selection is a lot of padding. The floor is 70 because
///   the shape is mandatory — a one-line gist *plus* at least one bullet — and less than that
	///   leaves the structure with no room to say anything.
	///
	/// The user's ceiling wins **outright, floor included**: they typed the number, and quietly
	/// raising it is the one outcome they cannot correct from the settings page (there is no field
	/// for `summaryMaxChars`). The floor only ever lifts the proportional share, which is a
	/// default being wrong rather than a decision being overridden.
	static func lengthBudget(inputLength: Int, maxChars: Int) -> Int {
		let proportional = Int((Double(inputLength) * 0.12).rounded())
		return min(maxChars, max(70, proportional))
	}

	// MARK: - Shared

	/// Fences untrusted input. Without it, source text containing something shaped like an
	/// instruction ("忽略以上要求…") is read as an instruction rather than as text to translate.
	static func fence(_ text: String) -> String {
		"\"\"\"\n\(text)\n\"\"\""
	}
}