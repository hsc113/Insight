import Foundation

/// Owns one run of the pipeline: a piece of text in, a summary and a translation out,
/// both streaming at the same time.
///
/// Two independent chains rather than a `TaskGroup`, because they fail independently — a
/// missing Tencent key must not take the summary down with it, and each side needs its own
/// cancel, its own retry and its own error state.
@MainActor
@Observable
final class InsightPipeline {

	enum Phase: Equatable {
		case idle
		case waiting
		case streaming
		case done
		case failed(String)

var isBusy: Bool { self == .waiting || self == .streaming }

		var didFail: Bool {
			if case .failed = self { return true }
			return self == .idle
		}

		/// Whether this chain gave up *after trying*. Distinct from `didFail`, which is also true for
		/// `.idle` — and `.idle` here means "disabled", not "broken".
		var failed: Bool {
			if case .failed = self { return true }
			return false
		}
	}

	enum Delta: Sendable {
		case content(String)
		case reasoning(String)
	}

	// Inputs
	private(set) var sourceText = ""
	private(set) var detectedSource = ""
	private(set) var targetLanguage = ""

	// Outputs
	private(set) var summary = ""
	private(set) var summaryReasoning = ""
	private(set) var summaryPhase: Phase = .idle
	private(set) var summaryFirstTokenMs: Int?

	private(set) var translation = ""
	private(set) var translationReasoning = ""
	private(set) var translationPhase: Phase = .idle
	private(set) var translationFirstTokenMs: Int?

	/// Apple translation is driven by SwiftUI's `translationTask`, which owns the session
	/// lifetime. The pipeline hands over a request and waits for `completeApple`.
	private(set) var appleRequest: AppleTranslationRequest?

	struct AppleTranslationRequest: Identifiable, Equatable, Sendable {
		let id = UUID()
		var text: String
		var source: String?  // nil = auto-detect
		var target: String
	}

	/// Shown above the cards when the input had to be cut down.
	private(set) var truncationNote: String?

	private var generation = 0
	private var summaryTask: Task<Void, Never>?
	private var translationTask: Task<Void, Never>?
	private var flushTask: Task<Void, Never>?
	private var pendingSummary = ""
	private var pendingTranslation = ""
	private static let coalesceInterval: UInt64 = 33_000_000  // ~30fps

	/// Per-run bookkeeping for `settleRun`. `summaryFinished` / `translationFinished` say a chain
	/// has stopped producing; `hasRunSettled` is the once-only latch; `runHasStarted` keeps the
	/// latch from firing for a pipeline that was never given anything to do.
	private var summaryFinished = false
	private var translationFinished = false
	private var hasRunSettled = false
	private var runHasStarted = false

	/// Long selections blow past every vendor's per-request limit (Baidu's is 5k characters).
	/// Better to say so than to fail with an opaque 400.
	private static let maxInputChars = 5000

	// MARK: - Lifecycle

	func run(_ text: String) {
		// Bill and file the *previous* run before anything is reset. A run that was still
		// streaming when the key was pressed again really did consume a request and really did
		// produce a partial summary, so it is recorded (as partial) rather than dropped.
		settleRun()
		cancel()
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return }

		let token = generation + 1
		generation = token

		let limited = limitedInput(trimmed)
		sourceText = limited
		truncationNote = limited.count < trimmed.count
			? "输入过长，仅处理前 \(Self.maxInputChars) 个字符"
			: nil

		summaryFinished = false
		translationFinished = false
		hasRunSettled = false
		runHasStarted = true
		UsageLedger.shared.noteInput(limited.count)

		let settings = Settings.shared
		// Resolved once: every one of these reads touches observable state, and the hotkey path
		// should do the minimum amount of work before the panel is on screen.
		let summaryEnabled = settings.summaryEnabled && settings.summaryReady
		// 仅总结 means exactly that: the translation chain is never started, so no request is paid
		// for and no engine is contacted. Resolved here rather than checked inside the chain, so a
		// switched-off card leaves its phase at `.idle` — which is what the panel renders as "off"
		// rather than as "still working".
		let translationEnabled = settings.translationEnabled
		let detected = settings.sourceLanguage == Languages.autoID
			? Languages.detect(limited)
			: settings.sourceLanguage
		detectedSource = detected
		targetLanguage = Self.resolvedTarget(settings.targetLanguage, detectedSource: detected)

		resetOutput()
		summaryPhase = summaryEnabled ? .waiting : .idle
		translationPhase = translationEnabled ? .waiting : .idle

		// Both chains start now. Whichever model answers first fills its card first; neither
		// waits on the other.
		if summaryEnabled {
			summaryTask = Task { [weak self] in
				await self?.runSummary(input: limited, token: token)
			}
		}
		if translationEnabled {
			translationTask = Task { [weak self] in
				await self?.runTranslation(input: limited, token: token)
			}
		}
		// A disabled chain never starts, so it never reaches the `defer` that would have marked it
		// finished — and the exactly-once settle would wait forever on a chain that isn't coming.
		// Marking them here, on the main actor, is what lets a 仅总结 run settle and be filed.
		if !summaryEnabled { summaryFinished = true }
		if !translationEnabled { translationFinished = true }
		settleIfBothChainsFinished()
	}

	func cancel() {
		generation += 1
		summaryTask?.cancel()
		translationTask?.cancel()
		summaryTask = nil
		translationTask = nil
		flushTask?.cancel()
		flushTask = nil
		pendingSummary = ""
		pendingTranslation = ""
		appleRequest = nil
		if summaryPhase.isBusy { summaryPhase = .idle }
		if translationPhase.isBusy { translationPhase = .idle }
	}

	private func limitedInput(_ text: String) -> String {
		guard text.count > Self.maxInputChars else { return text }
		return String(text.prefix(Self.maxInputChars))
	}

	/// The panel's language menus offer 自动识别 on the *target* side too, so a language pair
	/// isn't fixed forever — with 自动识别 the target becomes whatever the source turned out to be,
	/// which for a Chinese selection means "clean this up" rather than "translate it".
	///
	/// Every engine is asked for a concrete language here: `MTRequest` with `auto` as the target
	/// is either rejected or silently mistranslated, and `Locale.Language` has no notion of auto
	/// at all.
	nonisolated static func resolvedTarget(_ target: String, detectedSource: String) -> String {
		guard target == Languages.autoID else { return target }
		return detectedSource == Languages.autoID ? "en" : detectedSource
	}

	// MARK: - Settling

	/// Bills the run, **exactly once**, when both chains have settled — and, for a run that was
	/// still in flight, from the top of the *next* `run`.
	///
	/// The latch is the whole contract, and it is why this is a safe place to count output. Both
	/// chains call in as they land, and a run superseded by a second keypress is settled from the
	/// top of that next run; without the latch the same run would be billed twice, and a run that
	/// was cut short would be billed zero times.
	///
	/// The `runHasStarted` guard is what keeps a pipeline that was never given anything to do from
	/// reporting a run: without it, both chains sit at `.idle`, `didFail` is true for both, and a
	/// pipeline that was merely *constructed* would bill two failures.
	private func settleRun() {
		guard runHasStarted, !hasRunSettled else { return }
		hasRunSettled = true

		// Character counts and failures are settled here rather than in each chain, so a run that
		// was cut short still reports the text it *did* produce. Requests are counted when they go
		// out, not here — a chain that never reached the network cost nothing, and one that was
		// cancelled mid-stream still cost a full request.
		UsageLedger.shared.noteOutput(summary: summary.count, translation: translation.count)
		if summaryPhase.didFail { UsageLedger.shared.noteFailure() }
		if translationPhase.didFail { UsageLedger.shared.noteFailure() }
	}

	private func settleIfBothChainsFinished() {
		guard summaryFinished, translationFinished else { return }
		settleRun()
	}

	/// Whether the last run got as far as it was going to: nothing still streaming, nothing failed.
	///
	/// A chain that was never started (summary disabled) counts as settled — otherwise a
	/// translation-only setup could never be considered complete. A chain that *failed* does not,
	/// which is the whole point: re-pressing the hotkey on an unchanged selection must still re-run
	/// when the last attempt errored, because that is what the user is asking for.
	var runIsSettled: Bool {
		!summaryPhase.isBusy && !translationPhase.isBusy
			&& !summaryPhase.failed && !translationPhase.failed
	}

	private func resetOutput() {
		summary = ""
		summaryReasoning = ""
		translation = ""
		translationReasoning = ""
		summaryFirstTokenMs = nil
		translationFirstTokenMs = nil
		appleRequest = nil
	}

	// MARK: - Summary chain

	private func runSummary(input: String, token: Int) async {
		// `defer`, not the end of the `do`: every exit path below has to count — including the
		// `return` on a stale token and the early `return` in the cancellation branch. A run that
		// was superseded must still settle, or its history row and its request count are lost.
		defer {
			summaryFinished = true
			settleIfBothChainsFinished()
		}

		let settings = Settings.shared
		let provider = settings.currentProvider
		let languageName = Languages.name(settings.summaryLanguage)
		let request = Prompts.summary(
			prompt: settings.summaryPrompt,
			context: .summary(
				input: input,
				languageName: languageName,
				maxChars: settings.summaryMaxChars))
		// A backstop against a runaway generation, not the primary length control — the prompt's
		// budget is. Twice the budget plus a little, because a CJK character is not reliably one
		// token and a truncation would cut mid-sentence, so this only ever fires on a model that
		// ignored the instruction entirely. It used to be three times; the prompt's cap is now the
		// primary control and this only has to catch a runaway.
		let ceiling = Prompts.lengthBudget(
			inputLength: input.count, maxChars: settings.summaryMaxChars) * 2 + 64

		UsageLedger.shared.noteRequest(.llm)
		let deltas = Self.stream { emit in
			try await LLMClient.stream(
				provider: provider,
				systemPrompt: request.system,
				userPrompt: request.user,
				maxTokens: ceiling,
				onReasoning: { emit(.reasoning($0)) },
				onDelta: { emit(.content($0)) })
		}

		let start = DispatchTime.now()
		var sawContent = false
		var collected = ""

		do {
			for try await delta in deltas {
				guard token == generation else { return }
				if summaryPhase == .waiting { summaryPhase = .streaming }
				switch delta {
				case .content(let text):
					if !sawContent {
						sawContent = true
						summaryFirstTokenMs = Self.milliseconds(since: start)
					}
					collected += text
					pendingSummary += text
				case .reasoning(let text):
					summaryReasoning += text
				}
				scheduleFlush()
			}
			guard token == generation else { return }
			flushNow()
			if !collected.isEmpty {
				summaryPhase = .done
			} else {
				summaryPhase = .failed("模型没有返回内容")
			}
		} catch is CancellationError {
			return
		} catch {
			guard token == generation else { return }
			flushNow()
			summaryPhase = .failed(Self.describe(error))
		}
	}

	// MARK: - Translation chain

	private func runTranslation(input: String, token: Int) async {
		let settings = Settings.shared
		let start = DispatchTime.now()
		var sawContent = false
		let source = settings.sourceLanguage
		let target = Self.resolvedTarget(
			settings.targetLanguage, detectedSource: detectedSource)
		// Apple hands the session to SwiftUI's `translationTask`, so this chain is not finished
		// when it returns — `completeApple` is what finishes it. Marking it done here would settle
		// the run, and the history row would be written before the translation existed.
		var awaitingApple = false
		defer {
			if !awaitingApple {
				translationFinished = true
				settleIfBothChainsFinished()
			}
		}

		/// Feeds either the streaming LLM path or the request/response MT path into the same
		/// coalescing buffer, so the card behaves identically for both.
		func consume(_ text: String, _ isFirst: Bool) {
			if isFirst && !sawContent {
				sawContent = true
				translationFirstTokenMs = Self.milliseconds(since: start)
			}
			pendingTranslation += text
			translationPhase = .streaming
			scheduleFlush()
		}

		do {
			switch settings.translateEngine {
			case .llm:
				let provider = settings.currentProvider
				let request = Prompts.translate(
					prompt: settings.translationPrompt,
					context: .translate(
						input: input,
						sourceName: source == Languages.autoID
							? nil : Languages.englishName(source),
						targetName: Languages.englishName(target)))
				UsageLedger.shared.noteRequest(.llm)
				let deltas = Self.stream { emit in
					try await LLMClient.stream(
						provider: provider,
						systemPrompt: request.system,
						userPrompt: request.user,
						onReasoning: { emit(.reasoning($0)) },
						onDelta: { emit(.content($0)) })
				}
				var collected = ""
				for try await delta in deltas {
					guard token == generation else { return }
					switch delta {
					case .content(let text):
						let isFirst = !sawContent
						collected += text
						consume(text, isFirst)
					case .reasoning(let text):
						translationReasoning += text
					}
				}
				guard token == generation else { return }
				flushNow()
				translationPhase = collected.isEmpty ? .failed("模型没有返回内容") : .done

			case .apple:
				awaitingApple = true
				appleRequest = AppleTranslationRequest(
					text: input,
					source: source == Languages.autoID ? nil : source,
					target: target)
				// Resolved by `completeApple` from the SwiftUI translationTask.

			case .baidu, .tencent, .deepl:
				let translator = try Self.makeMTTranslator(settings.translateEngine)
				// Counted here rather than in `noteOutput` at settle time, so a translated result
				// that arrived and was then superseded still shows as a call that was billed.
				UsageLedger.shared.noteRequest(.mt)
				let translated = try await translator.translate(
					MTRequest(text: input, source: source, target: target))
				guard token == generation else { return }
				consume(translated, !sawContent)
				flushNow()
				translationPhase = .done
			}
		} catch is CancellationError {
			return
		} catch {
			guard token == generation else { return }
			flushNow()
			translationPhase = .failed(Self.describe(error))
		}
	}

	/// Called by the view once SwiftUI's translationTask has produced a result.
	func completeApple(id: UUID, result: Result<String, Error>) {
		guard let request = appleRequest, request.id == id else { return }
		appleRequest = nil
		switch result {
		case .success(let text):
			translation = text
			translationPhase = .done
		case .failure(let error):
			translationPhase = .failed(Self.describe(error))
		}
		// This is what finishes the Apple chain, so this is where a run using it settles.
		translationFinished = true
		settleIfBothChainsFinished()
	}

	static func makeMTTranslator(_ engine: MTEngine) throws -> MTTranslating {
		let settings = Settings.shared
		switch engine {
		case .baidu:
			guard settings.baiduConfigured else { throw NetError.notConfigured("请先填写百度翻译的 APP ID 和密钥") }
			return BaiduTranslator(appID: settings.baiduAppID, secretKey: Keychain.baiduSecretKey())
		case .tencent:
			guard settings.tencentConfigured else {
				throw NetError.notConfigured("请先填写腾讯翻译的 SecretId 和 SecretKey")
			}
			return TencentTranslator(secretID: settings.tencentSecretID, secretKey: Keychain.tencentSecretKey())
		case .deepl:
			guard settings.deepLConfigured else { throw NetError.notConfigured("请先填写 DeepL API Key") }
			return DeepLTranslator(apiKey: Keychain.deepLKey(), tier: .free)
		case .apple, .llm:
			throw NetError.notConfigured("该引擎不支持离线调用")
		}
	}

	// MARK: - Coalescing

	/// Streaming callbacks can land dozens of times per second. Redrawing on each one wastes
	/// the main thread and makes the text visibly stutter, so deltas accumulate and the
	/// committed string advances at most every ~33ms.
	private func scheduleFlush() {
		guard flushTask == nil else { return }
		flushTask = Task { [weak self] in
			try? await Task.sleep(nanoseconds: Self.coalesceInterval)
			guard !Task.isCancelled else { return }
			self?.flushTask = nil
			self?.flushNow()
		}
	}

	private func flushNow() {
		flushTask?.cancel()
		flushTask = nil
		if !pendingSummary.isEmpty {
			summary += pendingSummary
			pendingSummary = ""
		}
		if !pendingTranslation.isEmpty {
			translation += pendingTranslation
			pendingTranslation = ""
		}
	}

	// MARK: - Demo support

	/// Feeds used by `Insight --demo`. They reuse the real coalescing buffer rather than
	/// assigning directly, so the demo exercises the same repaint path as a live completion.
	///
	/// Phases follow 功能设置, like `run` does: `--demo` with 仅总结 selected has to show the panel
	/// the user would actually get, which is half the reason the flag exists. A switched-off chain
	/// stays `.idle`, and `DemoStream` does not feed it.
	func prepareDemo(input: String, source: String, target: String) {
		cancel()
		generation += 1
		sourceText = input
		detectedSource = source
		targetLanguage = target
		truncationNote = nil
		resetOutput()
		let mode = Settings.shared.featureMode
		summaryPhase = mode.summarizes ? .streaming : .idle
		translationPhase = mode.translates ? .streaming : .idle
		summaryFirstTokenMs = nil
		translationFirstTokenMs = nil
	}

	func appendSummaryReasoning(_ text: String) {
		summaryReasoning = text
	}

	func appendSummary(_ text: String) {
		if summaryFirstTokenMs == nil { summaryFirstTokenMs = 340 }
		summary = text
	}

	func appendTranslation(_ text: String) {
		if translationFirstTokenMs == nil { translationFirstTokenMs = 290 }
		translation = text
	}

	func finishDemo() {
		flushNow()
		summaryPhase = .done
		translationPhase = .done
	}

	// MARK: - Helpers

	private static func stream(
		_ body: @escaping @Sendable (@escaping @Sendable (Delta) -> Void) async throws -> Void
	) -> AsyncThrowingStream<Delta, Error> {
		AsyncThrowingStream { continuation in
			let task = Task {
				do {
					try await body { continuation.yield($0) }
					continuation.finish()
				} catch {
					continuation.finish(throwing: error)
				}
			}
			continuation.onTermination = { _ in task.cancel() }
		}
	}

	private static func milliseconds(since start: DispatchTime) -> Int {
		Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
	}

	private static func describe(_ error: Error) -> String {
		if let netError = error as? NetError, let description = netError.errorDescription {
			return description
		}
		if let localized = error as? LocalizedError, let description = localized.errorDescription {
			return description
		}
		return error.localizedDescription
	}
}