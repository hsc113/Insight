import Foundation

/// Canned stream used by `Insight --demo`.
///
/// Two reasons it exists: the panel's layout can be checked before any API key is configured,
/// and the streaming presentation (cumulative growth, coalesced repaint, elapsed badge) can be
/// exercised without spending tokens.
@MainActor
enum DemoStream {
	static let sampleInput = """
		The authors of The Swift Programming Language introduced structured concurrency at WWDC. \
		Compared with callbacks and GCD, async/await puts the *wait* on the call stack, so \
		cancellation, priority propagation and timeouts can all be expressed with ordinary control \
		flow. A task group implicitly waits for every child task, which is the main difference \
		between it and managing a DispatchGroup by hand.
		"""

	/// Shaped like a real response — a gist line, then bullets with the important parts in
	/// `**bold**` — because a single plain paragraph cannot exercise the summary card's Markdown
	/// renderer, and `--demo` is the only way to look at the panel without an API key.
	private static let sampleSummary = """
		Apple 在 WWDC 上发布了 Swift 结构化并发，把「等待」从回调搬进了调用栈。
		- async/await 让**等待出现在调用栈上**，因此取消、优先级传播和超时都能用普通控制流表达
		- 相比回调与 GCD，写法更接近同步代码，可读性明显提升
		- TaskGroup 会**隐式等待所有子任务**，这是它与手工管理 DispatchGroup 的主要区别
		"""

	private static let sampleReasoning = """
		原文是技术性散文，可提炼的事实有三个：(1) async/await 让等待出现在调用栈上；(2) 因此取消、\
		优先级传播和超时可以用普通控制流表达；(3) TaskGroup 隐式等待子任务，这是与手工 DispatchGroup \
		的主要差别。首句是背景信息，不进入摘要。
		"""

	private static let sampleTranslation = """
		《Swift 编程语言》的作者在 WWDC 上介绍了结构化并发。与回调和 GCD 相比，async/await 的核心\
		优势在于让「等待」直接出现在调用栈上，因此取消、优先级传播和超时都可以用常规的控制流来表达。\
		TaskGroup 会隐式地等待每一个子任务结束，这正是它与在 TaskGroup 之外手工管理 DispatchGroup \
		之间的主要区别。
		"""

	static func run(_ pipeline: InsightPipeline) {
		pipeline.prepareDemo(input: sampleInput, source: "en", target: "zh-Hans")
		// The demo follows 功能设置 rather than forcing both on. `prepareDemo` has already left the
		// switched-off chain at `.idle`, and feeding it here would put text into a card that is a
		// one-line strip — visible only as the strip refusing to stay small.
		let mode = Settings.shared.featureMode

		Task { @MainActor in
			// The reasoning stream starts first and runs on its own, exactly like a reasoning
			// model: it must not hold back the answer.
			async let reasoning: Void = mode.summarizes
				? emit(sampleReasoning) { pipeline.appendSummaryReasoning($0) }
				: ()
			async let summary: Void = mode.summarizes
				? emit(sampleSummary) { pipeline.appendSummary($0) }
				: ()
			async let translation: Void = mode.translates
				? emit(sampleTranslation) { pipeline.appendTranslation($0) }
				: ()
			_ = await (reasoning, summary, translation)
			// Once. A switched-off chain keeps its `.idle`, because `.idle` is what "off" looks
			// like everywhere else in this pipeline — and the compact card renders from the
			// setting, not from the phase.
			pipeline.finishDemo()
		}
	}

	/// Emits short pieces with a small delay through the same coalescing path the real pipeline
	/// uses, so repaint behaviour is representative rather than an instant block.
	@MainActor
	private static func emit(_ text: String, apply: @MainActor (String) -> Void) async {
		var delivered = ""
		var isFirst = true
		for piece in tokenize(text) {
			try? await Task.sleep(nanoseconds: isFirst ? 320_000_000 : 12_000_000)
			delivered += piece
			apply(delivered)
			isFirst = false
		}
	}

	private static func tokenize(_ text: String) -> [String] {
		var pieces: [String] = []
		var current = ""
		for character in text {
			current.append(character)
			if current.count >= 2 || character == " " || character == "\n" {
				pieces.append(current)
				current = ""
			}
		}
		if !current.isEmpty { pieces.append(current) }
		return pieces
	}
}