import CryptoKit
import Foundation

enum NetError: LocalizedError {
	case badURL(String)
	case notConfigured(String)
	case http(status: Int, body: String)
	case decoding(String)
	case cancelled

	var errorDescription: String? {
		switch self {
		case .badURL(let value): return "接口地址无效：\(value)"
		case .notConfigured(let value): return value
		case .http(let status, let body):
			// Prefer the provider's own message. `/models` can return 200 with a bad key on some
			// gateways, and a bare status code tells the user nothing about what to fix.
			let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
			if trimmed.isEmpty { return "请求失败（HTTP \(status)）" }
			return trimmed.count > 400 ? String(trimmed.prefix(400)) + "…" : trimmed
		case .decoding(let value): return "返回格式无法解析：\(value)"
		case .cancelled: return "已取消"
		}
	}
}

enum HTTP {
	private static let lock = NSLock()
	private static var cachedSession: URLSession?
	private static var cachedProxyKey: Int = -1

	/// Rebuilt when the proxy settings change.
	///
	/// Proxy support is a top-requested feature in every comparable app's issue tracker, and for
	/// anyone behind a firewall it is the
	/// difference between the app working and not working. The session is cached rather than
	/// rebuilt per request so connection reuse still works.
	static var session: URLSession {
		// Snapshot first: the session cache is deliberately non-isolated so it can be read from
		// any thread, but the settings behind it are main-actor state.
		let settings = ProxySettingsCache.snapshot
		let key = settings.fingerprint
		return lock.withLock {
			if let cachedSession, cachedProxyKey == key { return cachedSession }
			let config = URLSessionConfiguration.ephemeral
			config.waitsForConnectivity = false
			config.timeoutIntervalForRequest = 90
			config.timeoutIntervalForResource = 600
			config.httpMaximumConnectionsPerHost = 4
			config.requestCachePolicy = .reloadIgnoringLocalCacheData
			config.urlCache = nil
			settings.apply(to: config)
			let session = URLSession(configuration: config)
			cachedSession = session
			cachedProxyKey = key
			Log.net("session built, proxy=\(settings.isEnabled)")
			return session
		}
	}


	static func jsonRequest(
		url: URL,
		method: String = "POST",
		headers: [String: String] = [:],
		body: [String: Any]
	) throws -> URLRequest {
		guard !url.absoluteString.isEmpty, url.scheme != nil else {
			throw NetError.badURL(url.absoluteString)
		}
		var request = URLRequest(url: url)
		request.httpMethod = method
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.setValue("application/json", forHTTPHeaderField: "Accept")
		for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
		request.httpBody = try JSONSerialization.data(withJSONObject: body)
		return request
	}

	/// Performs a request and returns the raw body, including error bodies so the caller can
	/// surface a useful message.
	static func data(for request: URLRequest) async throws -> Data {
		let (data, response) = try await session.data(for: request)
		if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
			throw NetError.http(status: http.statusCode, body: decodeErrorBody(data))
		}
		return data
	}

	static func decodeErrorBody(_ data: Data) -> String {
		if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
			if let error = object["error"] as? [String: Any],
				let message = error["message"] as? String
			{
				return message
			}
			if let message = object["message"] as? String { return message }
			if let responseError = object["ResponseError"] as? [String: Any],
				let message = responseError["Message"] as? String
			{
				return message
			}
		}
		return String(data: data, encoding: .utf8) ?? ""
	}
}

// MARK: - Crypto helpers (Baidu MD5, Tencent TC3)

enum Crypto {
	static func md5Hex(_ string: String) -> String {
		Insecure.MD5.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
	}

	static func sha256Hex(_ data: Data) -> String {
		SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
	}

	static func hmac(key: Data, message: String) -> Data {
		let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key))
		return Data(mac)
	}
}
/// Mirrors the main-actor settings into a lock-protected value.
///
/// `URLSession` is created and read from background tasks, so it cannot reach into
/// main-actor state. Settings pushes a snapshot here whenever it commits, which keeps the hot
/// request path free of any actor hop.
enum ProxySettingsCache {
	private static let lock = NSLock()
	private static var current = ProxySettings(
		isEnabled: false, host: "", port: 0,
		requiresAuth: false, username: "", password: "")

	static var snapshot: ProxySettings { lock.withLock { current } }

	/// Takes values rather than reading `Settings.shared`.
	///
	/// This gets called from the end of `Settings.init()`, and reaching back into
	/// `Settings.shared` from there re-enters `dispatch_once` on the very singleton being
	/// initialised — which traps. Passing the values keeps it free of any actor hop or self
	/// reference.
	static func update(_ value: ProxySettings) {
		lock.withLock { current = value }
	}
}

/// An immutable copy of the proxy settings.
struct ProxySettings: Sendable {
	var isEnabled: Bool
	var host: String
	var port: Int
	var requiresAuth: Bool
	var username: String
	var password: String

	var fingerprint: Int {
		var hasher = Hasher()
		hasher.combine(isEnabled)
		hasher.combine(host)
		hasher.combine(port)
		hasher.combine(requiresAuth)
		hasher.combine(username)
		hasher.combine(password)
		return hasher.finalize()
	}

	func apply(to config: URLSessionConfiguration) {
		guard isEnabled, !host.isEmpty else { return }
		var dictionary: [String: Any] = [
			kCFNetworkProxiesHTTPEnable as String: true,
			kCFNetworkProxiesHTTPProxy as String: host,
			kCFNetworkProxiesHTTPPort as String: port,
			// HTTPS traffic goes through the same proxy. Every vendor Insight talks to is https,
			// so enabling only the HTTP key would silently do nothing.
			kCFNetworkProxiesHTTPSEnable as String: true,
			kCFNetworkProxiesHTTPSProxy as String: host,
			kCFNetworkProxiesHTTPSPort as String: port,
		]
		if requiresAuth, !username.isEmpty {
			dictionary[kCFProxyUsernameKey as String] = username
			dictionary[kCFProxyPasswordKey as String] = password
		}
		config.connectionProxyDictionary = dictionary
	}
}
