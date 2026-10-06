import Foundation
@testable import InsightCore

@MainActor
enum PipelineChecks {
	static func run() async {
		Check.group("并行流式管线")

		let listener = try? TestHTTPServer()
		guard let server = listener else {
			Check.that(false, "无法启动本地测试服务器")
			return
		}
		try? await server.start()
		defer { server.stop() }

		// Many small chunks with a reasoning prelude, which is what a reasoning model actually
		// emits — the summary chain has to keep two separate buffers straight.
		server.stubSSE(path: "/v1/chat/completions", payloads: [
			Self.payload(reasoning: "分析中"),
			Self.payload(content: "这是一"),
			Self.payload(content: "段关于"),
			Self.payload(content: "快速排序"),
			Self.payload(content: "的说明。"),
		])

		// Snapshot first. These mutations must never go through `updateProvider`, which commits to
		// the real config.json — the checker has no business rewriting the user's settings. The
		// snapshot is put back at the end for the same reason.
		let savedProviders = Settings.shared.providers
		let secretKey = Secrets.Key.llmAPIKey(providerID: "deepseek")
		let savedSecret = Secrets.shared.value(secretKey)
		let savedProviderID = Settings.shared.llmProviderID
		let savedSummaryEnabled = Settings.shared.summaryEnabled
		let savedSource = Settings.shared.sourceLanguage
		let savedEngine = Settings.shared.translateEngine

		defer {
			Secrets.shared.set(savedSecret, for: secretKey)
			Settings.shared.providers = savedProviders
			Settings.shared.llmProviderID = savedProviderID
			Settings.shared.summaryEnabled = savedSummaryEnabled
			Settings.shared.sourceLanguage = savedSource
			Settings.shared.translateEngine = savedEngine
		}

		// Point the summary *and* the translation chain at the local server. Sending both through
		// the LLM translator is what makes this the two-concurrent-streams case rather than two
		// runs of the same single-stream path.
		Settings.shared.providers = savedProviders.map { provider in
			guard provider.id == "deepseek" else { return provider }
			var copy = provider
			copy.baseURL = server.baseURL("")
			copy.chatPath = "/v1/chat/completions"
			copy.modelsPaths = ["/v1/models"]
			copy.model = "test-model"
			copy.thinkingEnabled = false
			return copy
		}
		Secrets.shared.set("sk-test", for: secretKey)
		Settings.shared.llmProviderID = "deepseek"
		Settings.shared.summaryEnabled = true
		Settings.shared.sourceLanguage = Languages.autoID
		Settings.shared.translateEngine = .llm

		Check.that(Settings.shared.summaryReady, "配置就绪后 summaryReady 为真")

		let pipeline = InsightPipeline()
		pipeline.run("快速排序是一种高效的排序算法，平均时间复杂度为 O(n log n)。")

		// Wait for both chains to settle.
		let deadline = Date().addingTimeInterval(10)
		while Date() < deadline {
			if pipeline.summaryPhase == .done, pipeline.translationPhase == .done { break }
			try? await Task.sleep(nanoseconds: 20_000_000)
		}

		Check.that(pipeline.summaryPhase == .done, "总结链路完成（实际：\(pipeline.summaryPhase)）")
		Check.that(
			pipeline.translationPhase == .done, "翻译链路完成（实际：\(pipeline.translationPhase)）")
		Check.equal(
			pipeline.summary, "这是一段关于快速排序的说明。",
			"总结按到达顺序重组全部增量")
		Check.equal(pipeline.translationReasoning, "分析中", "翻译链路的思考内容独立累积")
		Check.equal(pipeline.detectedSource, "zh-Hans", "自动检测出源语言为简体中文")
		Check.that(
			pipeline.summaryFirstTokenMs ?? -1 > 0, "记录了总结的首字延迟")
		Check.that(
			pipeline.translationFirstTokenMs ?? -1 > 0, "记录了翻译的首字延迟")

		Check.group("截断")
		let long = String(repeating: "测试内容", count: 2000)  // 8000 chars
		pipeline.run(long)
		Check.that(pipeline.sourceText.count <= 5000, "超长输入被截断到 5000 字（\(pipeline.sourceText.count)）")
		Check.that(pipeline.truncationNote != nil, "截断时给出提示")

		Check.group("取消")
		pipeline.run("取消测试")
		try? await Task.sleep(nanoseconds: 30_000_000)
		pipeline.cancel()
		Check.that(
			!pipeline.summaryPhase.isBusy && !pipeline.translationPhase.isBusy,
			"取消后两条链路都不再是忙碌状态")

		Check.group("空输入")
		let idle = InsightPipeline()
		idle.run("   \n  ")
		Check.that(idle.summaryPhase == .idle, "空白输入不触发任何请求")

		// ── 仅翻译 / 仅总结 ─────────────────────────────────────────────────────────────────
		//
		// The point of the setting is that the switched-off chain never runs, and "never runs" is
		// not observable from the outside — an idle card looks the same whether the request was
		// skipped or merely slow. What is observable is `runIsSettled`: it is true only when
		// *neither* chain is busy and neither failed, so a 仅翻译 run that reports settled while
		// its translation has just landed is a run whose summary chain provably never started and
		// was never waited for.
		Check.group("仅翻译：总结链路根本不启动")
		Settings.shared.summaryEnabled = false
		Settings.shared.translationEnabled = true
		let translateOnly = InsightPipeline()
		translateOnly.run("Only translate this sentence, please.")
		Check.that(
			translateOnly.summaryPhase == .idle, "总结卡片停在「未启用」，而不是转圈等一个不会来的回复")
		// Bounded wait for the real condition. A fixed sleep here is the flake this suite already
		// learned about, and asserting straight away would be asserting the scheduler.
		let settleDeadline = Date().addingTimeInterval(5)
		while translateOnly.translationPhase != .done, Date() < settleDeadline {
			try? await Task.sleep(nanoseconds: 20_000_000)
		}
		Check.that(
			translateOnly.translationPhase == .done,
			"翻译链路照常发出（实际：\(translateOnly.translationPhase)）")
		Check.that(
			translateOnly.runIsSettled,
			"仅翻译的一轮在翻译落地时就结束了 —— 说明总结链路没有在等")

		Check.group("仅总结：翻译链路根本不启动")
		Settings.shared.summaryEnabled = true
		Settings.shared.translationEnabled = false
		let summarizeOnly = InsightPipeline()
		summarizeOnly.run("Only summarize this sentence, please.")
		Check.that(
			summarizeOnly.translationPhase == .idle, "翻译卡片停在「未启用」")
		Check.that(
			summarizeOnly.translation.isEmpty, "翻译结果为空 —— 没有花钱调翻译接口")
		Check.that(
			summarizeOnly.summaryPhase == .waiting || summarizeOnly.summaryPhase.isBusy,
			"总结链路照常发出（实际：\(summarizeOnly.summaryPhase)）")
		summarizeOnly.cancel()
		translateOnly.cancel()
		Settings.shared.translationEnabled = true

		Check.that(Settings.shared.providers.contains { $0.id == "deepseek" }, "服务商列表完整")
	}

	private static func payload(reasoning: String? = nil, content: String? = nil) -> String {
		var fields: [String] = []
		if let reasoning { fields.append("\"reasoning_content\":\"\(reasoning)\"") }
		if let content { fields.append("\"content\":\"\(content)\"") }
		return "{\"choices\":[{\"delta\":{\(fields.joined(separator: ","))}}]}"
	}
}
