import Foundation

/// Client for the four built-in vendors, all of which speak OpenAI's `/chat/completions`
/// dialect. The vendor-specific surface is exactly one thing — how "turn thinking off" is
/// spelled on the wire — so it is isolated in `thinkingParameters` rather than spread across
/// per-provider classes.
enum LLMClient {

	enum Purpose: Sendable {
		case summary
		case translate
	}

	// MARK: - Streaming

	/// - Parameter maxTokens: Optional output cap. Left off for translation — truncating a
	///   translation is worse than a long one — and set for the summary as a backstop.
	static func stream(
		provider: LLMProviderConfig,
		systemPrompt: String,
		userPrompt: String,
		maxTokens: Int? = nil,
		onReasoning: @Sendable @escaping (String) -> Void,
		onDelta: @Sendable @escaping (String) -> Void
	) async throws {
		guard let url = provider.chatURL else {
			throw NetError.badURL(provider.previewURL)
		}
		guard !provider.apiKey.isEmpty else {
			throw NetError.notConfigured("尚未配置 \(provider.name) 的 API Key")
		}
		guard !provider.model.isEmpty else {
			throw NetError.notConfigured("尚未选择模型")
		}

		let body = chatBody(
			provider: provider, systemPrompt: systemPrompt,
			userPrompt: userPrompt, maxTokens: maxTokens)
		var request = try HTTP.jsonRequest(
			url: url,
			headers: ["Authorization": "Bearer \(provider.apiKey)"],
			body: body)

		// A few vendors only emit SSE when told to.
		request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

		try await SSEClient.stream(request: request) { payload in
			guard let delta = contentDelta(from: payload) else { return }
			switch delta {
			case .content(let text): onDelta(text)
			case .reasoning(let text): onReasoning(text)
			}
		}
	}

	private enum Delta {
		case content(String)
		case reasoning(String)
	}

	private static func contentDelta(from payload: String) -> Delta? {
		guard let data = payload.data(using: .utf8),
			let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
		else { return nil }

		if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
			Log.error("stream error: \(message)")
			return .content("")
		}

		guard let choices = object["choices"] as? [[String: Any]],
			let delta = choices.first?["delta"] as? [String: Any]
		else { return nil }

		// DeepSeek, GLM and Qwen all surface chain-of-thought under `reasoning_content`.
		if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
			return .reasoning(reasoning)
		}
		if let content = delta["content"] as? String, !content.isEmpty {
			return .content(content)
		}
		return nil
	}

	/// Internal rather than private so `insight-check` can assert on the assembled body — the
	/// `max_tokens` rule below is invisible on the wire otherwise.
	static func chatBody(
		provider: LLMProviderConfig, systemPrompt: String, userPrompt: String, maxTokens: Int? = nil
	) -> [String: Any] {
		var body: [String: Any] = [
			"model": provider.model,
			"stream": true,
			"messages": [
				["role": "system", "content": systemPrompt],
				["role": "user", "content": userPrompt],
			],
		]
		// `willReason`, not `isReasoningModel`: on DeepSeek the *toggle* decides, and the current
		// models are not named like reasoning models. Measured on `deepseek-flash`: with thinking
		// on, `max_tokens: 8` produced `completion_tokens: 8, reasoning_tokens: 8` and an empty
		// answer — the whole cap went to the chain of thought.
		if let maxTokens, maxTokens > 0, !willReason(provider) {
			// Reasoning models bill `max_tokens` against the chain of thought as well as the
			// answer, so a cap sized for the summary gets spent on thinking and can truncate the
			// answer to nothing. There the prompt's own budget is the length control, which is
			// where it has to be; this is only a backstop against a model ignoring it.
			body["max_tokens"] = maxTokens
		}
		body.merge(thinkingParameters(provider: provider)) { _, new in new }
		return body
	}

	/// Each vendor spells "don't think" differently, and several reject the field outright on
	/// their non-reasoning models — so this only fires for models where it is both meaningful
	/// and accepted.
	static func thinkingParameters(provider: LLMProviderConfig) -> [String: Any] {
		let on = provider.thinkingEnabled
		switch provider.flavor {
		case .deepSeek:
			// DeepSeek used to bind thinking to the model name (`deepseek-reasoner` always
			// reasoned, `deepseek-chat` never did). The V4 models broke that: `deepseek-flash`
			// and `deepseek-v4-pro` ship with **thinking on by default**, and the docs put the
			// switch in the request body. So this is the one vendor where the field is sent
			// unconditionally — including `enabled`, because a model whose default is on has to
			// hear "off" from us or the user's choice is silently ignored. Measured against the
			// live API: no field → `reasoning_content` in the stream; `disabled` → none.
			return ["thinking": ["type": on ? "enabled" : "disabled"]]
		case .zhipu:
			guard isReasoningModel(provider.model) else { return [:] }
			return ["thinking": ["type": on ? "enabled" : "disabled"]]
		case .qwen:
			guard isReasoningModel(provider.model) else { return [:] }
			return ["enable_thinking": on]
		case .openAI:
			guard isReasoningModel(provider.model) else { return [:] }
			return ["reasoning_effort": on ? "medium" : "none"]
		}
	}

	/// Everything else in the body hangs off "will this request reason": the output cap has to be
	/// withheld, and the UI's hint has to say something true.
	///
	/// Kept separate from `isReasoningModel` because the name is not the whole story any more —
	/// see `.deepSeek` in `thinkingParameters`.
	static func willReason(_ provider: LLMProviderConfig) -> Bool {
		if provider.flavor == .deepSeek { return provider.thinkingEnabled }
		return isReasoningModel(provider.model)
	}

	static func isReasoningModel(_ model: String) -> Bool {
		let lower = model.lowercased()
		let markers = [
			"reasoner", "thinking", "reason", "r1", "qwq", "qwen3",
			"-o1", "-o3", "-o4", "o1-", "o3-", "o4-",
			"gpt-5", "glm-4.5", "glm-4.6",
		]
		return markers.contains { lower.contains($0) }
	}

	// MARK: - Model list

	struct ModelListResult: Sendable {
		var models: [String]
		var usedPath: String
	}

	static func listModels(provider: LLMProviderConfig) async throws -> ModelListResult {
		guard !provider.baseURL.isEmpty else { throw NetError.notConfigured("尚未配置接口地址") }
		var lastError: Error?

		for path in provider.modelsPaths {
			let urlString = provider.baseURL + path
			guard let url = URL(string: urlString) else { continue }
			var request = URLRequest(url: url)
			request.httpMethod = "GET"
			request.setValue("Bearer \(provider.apiKey)", forHTTPHeaderField: "Authorization")
			request.setValue("application/json", forHTTPHeaderField: "Accept")

			do {
				let data = try await HTTP.data(for: request)
				let models = parseModels(from: data)
				guard !models.isEmpty else { continue }
				return ModelListResult(models: models, usedPath: path)
			} catch {
				lastError = error
				Log.net("model list failed at \(path): \(error.localizedDescription)")
			}
		}
		throw lastError ?? NetError.notConfigured("获取模型列表失败")
	}

	private static func parseModels(from data: Data) -> [String] {
		guard let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
		let raw: [[String: Any]]?
		if let list = object as? [[String: Any]] {
			raw = list
		} else if let dict = object as? [String: Any] {
			raw = (dict["data"] as? [[String: Any]]) ?? (dict["models"] as? [[String: Any]])
			if raw == nil, let strings = (dict["data"] as? [String]) ?? (dict["models"] as? [String]) {
				return strings.filter(isChatModel).sorted()
			}
		} else {
			raw = nil
		}

		guard let raw else { return [] }
		let models = raw.compactMap { entry -> String? in
			if let id = entry["id"] as? String { return id }
			if let name = entry["name"] as? String { return name }
			if let model = entry["model"] as? String { return model }
			return nil
		}
		return models.filter(isChatModel).sorted()
	}

	/// A raw `/v1/models` response lists far more than chat models. Everything below is either
	/// non-chat or a size variant the user doesn't want in a dropdown.
	private static func isChatModel(_ id: String) -> Bool {
		let lower = id.lowercased()
		let excluded = [
			"text-embedding", "embedding", "dall-e", "tts-", "whisper", "moderation",
			"whisper-", "tts", "davinci", "babbage", "moderations", "rerank", "bge-",
			"stable-diffusion", "flux-", "kolors", "clip-", "omni-moderation", "guard",
		]
		if excluded.contains(where: { lower.contains($0) }) { return false }
		if lower.hasSuffix("-latest") { return true }
		if lower.hasSuffix("-v1:0") || lower.contains(":latest") { return false }
		return true
	}

	// MARK: - Connectivity test

	struct TestResult: Sendable {
		var firstTokenMilliseconds: Int
		var sample: String
	}

	/// Sends a real minimal generation rather than a `GET /models`: some gateways happily
	/// return 200 from the models endpoint with an invalid key, so only an actual completion
	/// proves the credentials and the model both work.
	static func test(provider: LLMProviderConfig) async throws -> TestResult {
		guard let url = provider.chatURL else { throw NetError.badURL(provider.previewURL) }
		guard !provider.apiKey.isEmpty else {
			throw NetError.notConfigured("请先填写 API Key")
		}
		guard !provider.model.isEmpty else {
			throw NetError.notConfigured("请先选择模型")
		}

		var body: [String: Any] = [
			"model": provider.model,
			"stream": true,
			"max_tokens": 8,
			"messages": [["role": "user", "content": "hi"]],
		]
		body.merge(thinkingParameters(provider: provider)) { _, new in new }

		var request = try HTTP.jsonRequest(
			url: url, headers: ["Authorization": "Bearer \(provider.apiKey)"], body: body)
		request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

		let start = DispatchTime.now()
		let box = ResultBox()
		try await SSEClient.stream(request: request) { payload in
			guard box.text.isEmpty else { return }
			guard let data = payload.data(using: .utf8),
				let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
				let choices = object["choices"] as? [[String: Any]],
				let delta = choices.first?["delta"] as? [String: Any],
				let content = delta["content"] as? String, !content.isEmpty
			else { return }
			box.text = content
			box.elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
		}

		guard !box.text.isEmpty else {
			throw NetError.notConfigured("连接成功但模型没有返回内容，请检查模型名称")
		}
		return TestResult(
			firstTokenMilliseconds: Int(box.elapsed / 1_000_000),
			sample: box.text)
	}

	/// `SSEClient` hands payloads to a `@Sendable` closure, so mutable accumulation needs to
	/// be behind a lock.
	private final class ResultBox: @unchecked Sendable {
		private let lock = NSLock()
		private var _text = ""
		private var _elapsed: UInt64 = 0

		var text: String {
			get { lock.withLock { _text } }
			set { lock.withLock { _text = newValue } }
		}

		var elapsed: UInt64 {
			get { lock.withLock { _elapsed } }
			set { lock.withLock { _elapsed = newValue } }
		}
	}
}