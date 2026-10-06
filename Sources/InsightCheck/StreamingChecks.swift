import Foundation
@testable import InsightCore

/// End-to-end coverage of the streaming path against a real socket: a chat completion arriving in
/// awkwardly-sized chunks, a reasoning channel, `[DONE]`, and a payload big enough to cross the
/// client's 4096-byte buffer-flush threshold.
enum StreamingChecks {
	static func run() async {
		await streaming()
		contentLengthParsing()
		await concurrency()
		await largePayload()
		await errorHandling()
		await connectionTest()
		await modelList()
		await modelListFallback()
	}

	// MARK: - Streaming

	private static func streaming() async {
		Check.group("流式客户端（SSE）")

		guard let server = try? TestHTTPServer(), (try? await server.start()) != nil else {
			Check.that(false, "无法启动本地测试服务器")
			return
		}
		defer { server.stop() }

		server.stubSSE(
			path: "/v1/chat/completions",
			payloads: [
				payload(reasoning: "想一下"),
				payload(content: "你好"),
				payload(content: "，世界"),
			])

		var provider = makeProvider(baseURL: server.baseURL(""))
		provider.apiKey = "sk-test"

		let sink = Accumulator()
		do {
			try await LLMClient.stream(
				provider: provider, systemPrompt: "s", userPrompt: "u",
				onReasoning: { sink.reasoning += $0 },
				onDelta: { sink.content += $0 })
			Check.equal(sink.content, "你好，世界", "跨多个分片重组出完整内容")
			Check.equal(sink.reasoning, "想一下", "reasoning_content 走思考通道而不是内容通道")
		} catch {
			Check.that(false, "流式请求抛出意外错误：\(error)")
		}
	}

	/// The header parsing that decides whether the server waits for a body before answering.
	///
	/// Asserted against hand-written headers rather than inferred from whether a request happened to
	/// work: "the POST tests mostly pass" is not a statement about `Content-Length` parsing.
	private static func contentLengthParsing() {
		Check.group("请求体长度解析")

		Check.equal(
			TestHTTPServer.contentLength(
				in: "POST /v1/chat/completions HTTP/1.1\r\nContent-Length: 2048"),
			2048, "读得出 Content-Length")
		Check.equal(
			TestHTTPServer.contentLength(
				in: "POST / HTTP/1.1\r\ncontent-length:0\r\nContent-Type: application/json"),
			0, "名字大小写不敏感")
		Check.equal(
			TestHTTPServer.contentLength(
				in: "POST / HTTP/1.1\r\nHost: 127.0.0.1:8080\r\nContent-Length:   7  \r\n\r\n"),
			7, "值两边的空白被吃掉")
		// The bug this guards: answering on `\r\n\r\n` alone leaves the body unread, and tearing
		// the socket down with data pending resets the connection.
		Check.that(
			TestHTTPServer.contentLength(in: "GET /v1/models HTTP/1.1\r\nHost: x") == nil,
			"GET 没有 Content-Length（所以立即响应）")
		Check.that(
			TestHTTPServer.contentLength(in: "POST / HTTP/1.1\r\nTransfer-Encoding: chunked") == nil,
			"没有 Content-Length 时不当成 0（那会立刻响应而不等 body）")
		Check.that(
			TestHTTPServer.contentLength(
				in: "POST / HTTP/1.1\r\nContent-Length: abc") == nil,
			"非数字的 Content-Length 被拒绝而不是当成 0")
	}

	/// Many requests at once, each with a multi-kilobyte POST body, all against one server.
	///
	/// This is the regression test for a flake that only ever surfaced as a *pipeline* assertion
	/// (`翻译链路完成（实际：waiting）`, ~5% of runs, hitting whichever of the two chains lost the
	/// race). Two independent causes, both on the server side:
	///
	/// 1. It answered as soon as the headers were in, leaving the POST body unread in the receive
	///    buffer. `NWConnection.cancel()` is abortive — with unread data it sends RST — so the
	///    client's own write or read failed with `NSURLErrorNetworkConnectionLost (-1005)`.
	/// 2. After the last three bytes it fell into the empty-slice branch by accident, which reached
	///    the same `cancel()` with no drain having happened at all.
	///
	/// The prompts Insight actually sends are a few kilobytes, which is exactly the size range where
	/// (1) bites, so the bodies here are deliberately that size rather than a token one.
	private static func concurrency() async {
		Check.group("并发请求不丢连接")

		guard let server = try? TestHTTPServer(), (try? await server.start()) != nil else {
			Check.that(false, "无法启动本地测试服务器")
			return
		}
		defer { server.stop() }

		server.stubSSE(
			path: "/v1/chat/completions",
			payloads: [
				payload(reasoning: "想一下"),
				payload(content: "并发"),
				payload(content: "的一条回应"),
			])

		var provider = makeProvider(baseURL: server.baseURL(""))
		provider.apiKey = "sk-test"

		// Big enough to be split across several sends by URLSession, which is what exposed the
		// unread-body case: a small body often arrives in one write and is consumed with the headers.
		let body = String(repeating: "这是一段用来撑大请求体的中文文字。", count: 60)

		let attempts = 8
		let sinks = (0..<attempts).map { _ in Accumulator() }
		let failures = FailureBox()

		await withTaskGroup(of: Void.self) { group in
			for index in 0..<attempts {
				group.addTask {
					do {
						// Bounded on purpose. `withTaskGroup` waits for every child, so a request that
						// never completes would hang the whole checker rather than fail it — and a test
						// that can hang is worse than the flake it exists to catch. Each request races a
						// deadline, so the slowest path here is a failure with a name on it.
						try await withThrowingTaskGroup(of: Void.self) { inner in
							inner.addTask {
								try await LLMClient.stream(
									provider: provider,
									systemPrompt: "系统提示词",
									userPrompt: body,
									onReasoning: { sinks[index].reasoning += $0 },
									onDelta: { sinks[index].content += $0 })
							}
							inner.addTask {
								try await Task.sleep(nanoseconds: Self.requestDeadline)
								throw DeadlineExceeded()
							}
							try await inner.next()
							inner.cancelAll()
						}
					} catch {
						failures.record(error)
					}
				}
			}
		}

		Check.that(
			failures.messages.isEmpty,
			"\(attempts) 条并发请求全部成功（失败：\(failures.messages.count)）"
				+ (failures.messages.first.map { "，首个：\($0)" } ?? ""))
		for (index, sink) in sinks.enumerated() where failures.messages.isEmpty {
			Check.that(
				sink.content == "并发的一条回应",
				"第 \(index + 1) 条拿到完整内容（实际：\(sink.content.debugDescription)）")
		}
	}

	/// The client only scans its buffer every 4096 bytes and once the stream ends. A completion
	/// longer than that has to survive a mid-stream flush as well as the final one.
	private static func largePayload() async {
		Check.group("长响应跨缓冲区刷新")

		guard let server = try? TestHTTPServer(), (try? await server.start()) != nil else {
			Check.that(false, "无法启动本地测试服务器")
			return
		}
		defer { server.stop() }

		let piece = String(repeating: "翻译", count: 300)  // ~1800 bytes per SSE line
		var payloads: [String] = []
		for _ in 0..<6 { payloads.append(payload(content: piece)) }
		server.stubSSE(path: "/v1/chat/completions", payloads: payloads)

		var provider = makeProvider(baseURL: server.baseURL(""))
		provider.apiKey = "sk-test"

		let sink = Accumulator()
		do {
			try await LLMClient.stream(
				provider: provider, systemPrompt: "", userPrompt: "",
				onReasoning: { _ in }, onDelta: { sink.content += $0 })
			Check.equal(sink.content.count, piece.count * 6, "超过 4KB 的响应完整重组（\(sink.content.count) 字）")
			Check.that(!sink.content.contains("data:"), "SSE 帧前缀未被混入正文")
			Check.that(!sink.content.contains("[DONE]"), "[DONE] 不会进入正文")
		} catch {
			Check.that(false, "长响应抛出意外错误：\(error)")
		}
	}

	// MARK: - Errors

	private static func errorHandling() async {
		Check.group("错误处理")

		guard let server = try? TestHTTPServer(), (try? await server.start()) != nil else {
			Check.that(false, "无法启动本地测试服务器")
			return
		}
		defer { server.stop() }

		let body = #"{"error":{"message":"Authentication Fails, Your api key is invalid"}}"#
		server.stub(
			path: "/v1/chat/completions",
			response: .init(status: 401, contentType: "application/json", body: Data(body.utf8)))

		var provider = makeProvider(baseURL: server.baseURL(""))
		provider.apiKey = "sk-bad"

		do {
			try await LLMClient.stream(
				provider: provider, systemPrompt: "", userPrompt: "",
				onReasoning: { _ in }, onDelta: { _ in })
			Check.that(false, "鉴权失败时应当抛错")
		} catch let error as NetError {
			// Surfacing the provider's own message rather than a bare status code is the
			// difference between an actionable message and "HTTP 401".
			Check.equal(
				error.errorDescription, "Authentication Fails, Your api key is invalid",
				"401 时透传服务商自己的错误信息")
		} catch {
			Check.that(false, "期望 NetError，得到 \(error)")
		}
	}

	// MARK: - Connection test

	private static func connectionTest() async {
		Check.group("测试连接")

		guard let server = try? TestHTTPServer(), (try? await server.start()) != nil else {
			Check.that(false, "无法启动本地测试服务器")
			return
		}
		defer { server.stop() }

		server.stubSSE(
			path: "/v1/chat/completions", payloads: [payload(content: "ok")])
		var provider = makeProvider(baseURL: server.baseURL(""))
		provider.apiKey = "sk-test"

		do {
			let result = try await LLMClient.test(provider: provider)
			Check.equal(result.sample, "ok", "测试连接读到模型回复")
			Check.that(
				result.firstTokenMilliseconds > 0,
				"首字延迟为正数（\(result.firstTokenMilliseconds)ms）")
		} catch {
			Check.that(false, "测试连接抛出意外错误：\(error)")
		}

		// No stub for this path, so the server 404s and the probe must surface that rather than
		// claiming success.
		var bare = provider
		bare.chatPath = "/v1/nope"
		do {
			_ = try await LLMClient.test(provider: bare)
			Check.that(false, "错误路径时应当抛错")
		} catch {
			Check.that(true, "错误路径给出错误而不是误报成功")
		}
	}

	// MARK: - Model list

	private static func modelList() async {
		Check.group("模型列表")

		guard let server = try? TestHTTPServer(), (try? await server.start()) != nil else {
			Check.that(false, "无法启动本地测试服务器")
			return
		}
		defer { server.stop() }

		let body = """
			{"data":[
			  {"id":"gpt-4o"},
			  {"id":"text-embedding-3-large"},
			  {"id":"dall-e-3"},
			  {"id":"whisper-1"},
			  {"id":"o3-mini"},
			  {"id":"bge-reranker-v2"},
			  {"id":"qwen-plus"}
			]}
			"""
		server.stub(path: "/v1/models", response: .init(
			contentType: "application/json", body: Data(body.utf8)))

		var provider = makeProvider(baseURL: server.baseURL(""))
		provider.apiKey = "sk-test"

		do {
			let result = try await LLMClient.listModels(provider: provider)
			Check.equal(
				result.models, ["gpt-4o", "o3-mini", "qwen-plus"],
				"过滤掉非对话模型（embedding / dall-e / whisper / rerank）")
			Check.equal(result.usedPath, "/v1/models", "命中第一个候选路径")
		} catch {
			Check.that(false, "获取模型列表失败：\(error)")
		}
	}

	private static func modelListFallback() async {
		Check.group("模型列表路径回退")

		guard let server = try? TestHTTPServer(), (try? await server.start()) != nil else {
			Check.that(false, "无法启动本地测试服务器")
			return
		}
		defer { server.stop() }

		// `/v1/models` is deliberately not stubbed, so it 404s and the second candidate must be
		// tried. DeepSeek in particular only documents `/models`.
		server.stub(path: "/models", response: .init(
			contentType: "application/json",
			body: Data(#"{"data":[{"id":"deepseek-chat"}]}"#.utf8)))

		var provider = makeProvider(baseURL: server.baseURL(""))
		provider.modelsPaths = ["/v1/models", "/models"]
		provider.apiKey = "sk-test"

		do {
			let result = try await LLMClient.listModels(provider: provider)
			Check.equal(result.models, ["deepseek-chat"], "回退到 /models 成功")
			Check.equal(result.usedPath, "/models", "记录实际使用的路径")
		} catch {
			Check.that(false, "路径回退失败：\(error)")
		}
	}

	// MARK: - Helpers

	private static func payload(reasoning: String? = nil, content: String? = nil) -> String {
		var fields: [String] = []
		if let reasoning { fields.append("\"reasoning_content\":\"\(reasoning)\"") }
		if let content { fields.append("\"content\":\"\(content)\"") }
		return "{\"choices\":[{\"delta\":{\(fields.joined(separator: ","))}}]}"
	}

	private static func makeProvider(baseURL: String) -> LLMProviderConfig {
		var provider = LLMProviderConfig.makeCustom()
		provider.baseURL = baseURL
		provider.model = "test-model"
		return provider
	}

	/// `LLMClient`'s callbacks are `@Sendable`, so accumulation happens behind a lock.
	private final class Accumulator: @unchecked Sendable {
		private let lock = NSLock()
		private var _content = ""
		private var _reasoning = ""

		var content: String {
			get { lock.withLock { _content } }
			set { lock.withLock { _content = newValue } }
		}

		var reasoning: String {
			get { lock.withLock { _reasoning } }
			set { lock.withLock { _reasoning = newValue } }
		}
	}

	/// Ten seconds per request — ten times what the loopback path needs, so a slow machine does not
	/// manufacture a failure.
	private static let requestDeadline: UInt64 = 10_000_000_000

	struct DeadlineExceeded: Error {}

	/// Collects the failures of a concurrent group. Lock-guarded for the same reason as
	/// `Accumulator`: each task reports from its own executor.
	private final class FailureBox: @unchecked Sendable {
		private let lock = NSLock()
		private var _messages: [String] = []

		var messages: [String] { lock.withLock { _messages } }

		func record(_ error: Error) {
			lock.withLock { _messages.append(error.localizedDescription) }
		}
	}
}