import CryptoKit
import Foundation

/// A machine-translation request in Insight's own language ids. Vendors translate these into
/// their own code tables inside their implementation.
struct MTRequest: Sendable {
	var text: String
	var source: String  // canonical id, or "auto"
	var target: String  // canonical id
}

protocol MTTranslating: Sendable {
	func translate(_ request: MTRequest) async throws -> String
}

// MARK: - 百度翻译

struct BaiduTranslator: MTTranslating {
	let appID: String
	let secretKey: String

	func translate(_ request: MTRequest) async throws -> String {
		guard let to = Languages.code(request.target, for: .baidu) else {
			throw NetError.notConfigured("百度翻译不支持目标语言 \(Languages.name(request.target))")
		}
		let from = request.source == Languages.autoID ? "auto" : (Languages.code(request.source, for: .baidu) ?? "auto")
		let salt = String(UUID().uuidString.prefix(8))
		let sign = Crypto.md5Hex(appID + request.text + salt + secretKey)

		let body: [String: Any] = [
			"q": request.text,
			"from": from,
			"to": to,
			"appid": appID,
			"salt": salt,
			"sign": sign,
		]
		guard let url = URL(string: "https://fanyi-api.baidu.com/api/trans/vip/translate") else {
			throw NetError.badURL("baidu")
		}
		let data = try await HTTP.data(for: try HTTP.jsonRequest(url: url, body: body))
		guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
			throw NetError.decoding(String(data: data, encoding: .utf8) ?? "")
		}
		if let errorCode = object["error_code"] as? String, errorCode != "52000" {
			throw NetError.notConfigured(
				"百度翻译错误 \(errorCode)：\(object["error_msg"] as? String ?? "未知错误")")
		}
		guard let results = object["trans_result"] as? [[String: Any]] else {
			throw NetError.notConfigured("百度翻译没有返回结果")
		}
		let pieces = results.compactMap { $0["dst"] as? String }
		guard !pieces.isEmpty else { throw NetError.notConfigured("百度翻译没有返回结果") }
		return pieces.joined(separator: "\n")
	}
}

// MARK: - 腾讯交互翻译 (TMT)

struct TencentTranslator: MTTranslating {
	let secretID: String
	let secretKey: String

	private static let host = "tmt.tencentcloudapi.com"
	private static let service = "tmt"
	private static let version = "2018-03-21"
	private static let action = "TextTranslate"
	private static let algorithm = "TC3-HMAC-SHA256"

	func translate(_ request: MTRequest) async throws -> String {
		guard let target = Languages.code(request.target, for: .tencent) else {
			throw NetError.notConfigured(
				"腾讯交互翻译不支持目标语言 \(Languages.name(request.target))")
		}
		let source = request.source == Languages.autoID
			? "auto"
			: (Languages.code(request.source, for: .tencent) ?? "auto")

		let payload: [String: Any] = [
			"SourceText": request.text,
			"Source": source,
			"Target": target,
			"ProjectId": 0,
		]
		let bodyData = try JSONSerialization.data(withJSONObject: payload)

		let timestamp = Int(Date().timeIntervalSince1970)
		let date = Self.ymd(timestamp)
		let contentType = "application/json; charset=utf-8"

		// Canonical request must list headers lowercase and sorted, and end with a blank line
		// before the signed-headers list and the payload hash.
		let canonicalHeaders = "content-type:\(contentType)\nhost:\(Self.host)\n"
		let signedHeaders = "content-type;host"
		let canonicalRequest = [
			"POST", "/", "",
			canonicalHeaders,
			signedHeaders,
			Crypto.sha256Hex(bodyData),
		].joined(separator: "\n")

		let stringToSign = [
			Self.algorithm, String(timestamp), "\(date)/\(Self.service)/tc3_request",
			Crypto.sha256Hex(Data(canonicalRequest.utf8)),
		].joined(separator: "\n")

		let secretDate = Crypto.hmac(key: Data("TC3\(secretKey)".utf8), message: date)
		let secretService = Crypto.hmac(key: secretDate, message: Self.service)
		let secretSigning = Crypto.hmac(key: secretService, message: "tc3_request")
		let signature = Crypto.hmac(key: secretSigning, message: stringToSign)
			.map { String(format: "%02hhx", $0) }.joined()

		let authorization = """
			\(Self.algorithm) Credential=\(secretID)/\(date)/\(Self.service)/tc3_request, \
			SignedHeaders=\(signedHeaders), Signature=\(signature)
			"""

		guard let url = URL(string: "https://\(Self.host)") else {
			throw NetError.badURL(Self.host)
		}
		var request = URLRequest(url: url)
		request.httpMethod = "POST"
		request.httpBody = bodyData
		request.setValue(contentType, forHTTPHeaderField: "Content-Type")
		request.setValue(Self.host, forHTTPHeaderField: "Host")
		request.setValue(Self.action, forHTTPHeaderField: "X-TC-Action")
		request.setValue(Self.version, forHTTPHeaderField: "X-TC-Version")
		request.setValue(String(timestamp), forHTTPHeaderField: "X-TC-Timestamp")
		request.setValue(authorization, forHTTPHeaderField: "Authorization")

		let data = try await HTTP.data(for: request)
		guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
			throw NetError.decoding(String(data: data, encoding: .utf8) ?? "")
		}
		if let error = object["ResponseError"] as? [String: Any] {
			let code = error["Code"] as? String ?? "?"
			let message = error["Message"] as? String ?? "未知错误"
			throw NetError.notConfigured("腾讯翻译错误 \(code)：\(message)")
		}
		guard let response = object["Response"] as? [String: Any],
			let targetText = response["TargetText"] as? String
		else {
			throw NetError.notConfigured("腾讯翻译没有返回结果")
		}
		return targetText
	}

	private static func ymd(_ timestamp: Int) -> String {
		let formatter = DateFormatter()
		formatter.dateFormat = "yyyy-MM-dd"
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.timeZone = TimeZone(identifier: "UTC")
		return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
	}
}

// MARK: - DeepL

struct DeepLTranslator: MTTranslating {
	let apiKey: String
	/// `api-free` and `api` behave differently; the user picks in settings.
	let tier: DeepLTier

	enum DeepLTier: String, Sendable, CaseIterable {
		case free, pro
		var host: String { self == .free ? "https://api-free.deepl.com" : "https://api.deepl.com" }
		var displayName: String { self == .free ? "DeepL Free" : "DeepL Pro" }
	}

	func translate(_ request: MTRequest) async throws -> String {
		guard let target = Languages.code(request.target, for: .deepl) else {
			throw NetError.notConfigured("DeepL 不支持目标语言 \(Languages.name(request.target))")
		}

		var body: [String: Any] = [
			"text": chunkedText(request.text),
			"target_lang": target,
		]
		if request.source != Languages.autoID, let source = Languages.code(request.source, for: .deepl) {
			body["source_lang"] = source
		} else {
			body["source_lang"] = "auto"
		}

		guard let url = URL(string: "\(tier.host)/v2/translate") else {
			throw NetError.badURL(tier.host)
		}
		var urlRequest = try HTTP.jsonRequest(
			url: url,
			headers: ["Authorization": "DeepL-Auth-Key \(apiKey)"],
			body: body)
		// DeepL's own API uses `text` as an array and rejects the singular form.
		urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

		let data = try await HTTP.data(for: urlRequest)
		guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			let translations = object["translations"] as? [[String: Any]]
		else {
			throw NetError.decoding(String(data: data, encoding: .utf8) ?? "")
		}
		let pieces = translations.compactMap { $0["text"] as? String }
		guard !pieces.isEmpty else { throw NetError.notConfigured("DeepL 没有返回结果") }
		return pieces.joined(separator: "\n")
	}

	/// DeepL caps a request at 128k characters; split on paragraph boundaries well below that.
	private func chunkedText(_ text: String) -> [String] {
		let limit = 4000
		guard text.count > limit else { return [text] }
		var chunks: [String] = []
		var current = ""
		for paragraph in text.components(separatedBy: "\n\n") {
			if current.count + paragraph.count > limit, !current.isEmpty {
				chunks.append(current)
				current = ""
			}
			current += paragraph + "\n\n"
		}
		if !current.isEmpty { chunks.append(current) }
		return chunks
	}
}