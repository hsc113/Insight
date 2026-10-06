import Foundation

/// Persistence for API keys and other secrets.
///
/// **This started out backed by the macOS keychain and that was a mistake.** Every keychain call
/// from this app — even a plain read — blocked forever inside
/// `SecurityServer::encrypt` waiting on a `mach_msg` reply from securityd. Because Insight is a
/// `LSUIElement` agent that never becomes the foreground app, the authorisation prompt securityd
/// wanted to show could not be presented, and the call never returned. Reproduced with an
/// ad-hoc-signed bundle, with and without hardened runtime, with and without `LSUIElement`, and
/// after deleting every stored item; the same code in a plain CLI bundle completes in 20ms.
///
/// The alternatives are to keep them in `UserDefaults` or to ask for a password. For a
/// single-user local tool the reliability of a plain file wins over an encryption layer that can
/// hang the app. The file is created with `0600` in Application Support and never leaves the
/// machine, and switching to Developer ID signing is the way to move this back behind the
/// keychain if that ever matters.
///
/// Reads are memory-only and synchronous: the file is a couple of kilobytes, so there is no
/// preload task, no background queue and no window in which the key is unavailable.
final class Secrets: @unchecked Sendable {
	static let shared = Secrets()

	/// When false, nothing reaches the file. Defaults to true; only the offline checker turns it
	/// off.
	///
	/// **This exists because its absence leaked six thousand entries into a real secrets file.**
	/// `Settings` has had the same flag from the start; `Secrets` never did, and the checker's
	/// `StreamingChecks.makeProvider()` builds a fresh `LLMProviderConfig.makeCustom()` — a random
	/// id — and assigns it an API key on every run. With no guard, each of those writes landed in
	/// `~/Library/Application Support/Insight/secrets.json`: `llm.custom-XXXX.apiKey = "sk-test"`,
	/// one or more per provider per run. Nothing broke visibly — the file just grew to 239 KB and
	/// the settings UI would eventually have been listing thousands of dead providers — which is
	/// exactly why it went unnoticed until the file was read by hand.
	///
	/// Note that **`load()` is deliberately not guarded.** Writing is what a test must never do;
	/// reading the user's own file is harmless and `SelfTest` needs it, because verifying the real
	/// on-disk round trip and the `0600` mode is the entire point of that test.
	static var persistenceEnabled = true

	private var store: [String: String] = [:]
	private let lock = NSLock()

	private init() {
		load()
	}

	// MARK: - Location

	private static var directory: URL {
		FileManager.default
			.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("Insight", isDirectory: true)
	}

	private static var fileURL: URL { directory.appendingPathComponent("secrets.json") }

	private static func ensureDirectory() {
		try? FileManager.default.createDirectory(
			at: directory, withIntermediateDirectories: true,
			attributes: [.posixPermissions: 0o700])
	}

	// MARK: - Load / Save

	private func load() {
		// A missing file is a real state — fresh install, a CI runner, or the user deleted the
		// file — and it means "no secrets": the cache must be dropped, not kept. Keeping it made
		// `reloadFromDisk()` a silent no-op on machines without the file, which the offline
		// checker only caught on CI, because a development machine always has the file.
		//
		// A file that exists but fails to read or decode is the opposite call: keep the in-memory
		// values rather than wipe secrets over a transient I/O error or corrupt JSON.
		guard FileManager.default.fileExists(atPath: Self.fileURL.path) else {
			lock.withLock { store = [:] }
			return
		}
		guard let data = try? Data(contentsOf: Self.fileURL),
			let parsed = try? JSONDecoder().decode([String: String].self, from: data)
		else { return }
		lock.withLock { store = parsed }
		Log.ui("loaded \(parsed.count) secrets")
	}

	private func persist() {
		guard Self.persistenceEnabled else { return }
		let snapshot = lock.withLock { store }
		Self.ensureDirectory()
		guard let data = try? JSONEncoder().encode(snapshot) else { return }
		try? data.write(to: Self.fileURL, options: Data.WritingOptions.atomic)
		// Re-assert the mode: `Data.write` replaces the file, so an inherited umask could
		// otherwise leave it group- or world-readable.
		try? FileManager.default.setAttributes(
			[.posixPermissions: 0o600], ofItemAtPath: Self.fileURL.path)
	}

	// MARK: - Access

	func value(_ key: String) -> String {
		lock.withLock { store[key] ?? "" }
	}

	func isEmpty(_ key: String) -> Bool { value(key).isEmpty }

	func set(_ value: String, for key: String) {
		lock.withLock { store[key] = value }
		persist()
	}

	func delete(_ key: String) {
		lock.withLock { store[key] = "" }
		persist()
	}

	/// Exposed for the self test so it can assert on the real file, not a mock.
	var fileURLForTesting: URL { Self.fileURL }

	/// Re-reads the backing file, discarding anything cached. Used by the self test to simulate a
	/// relaunch, and available if the file is ever edited underneath the app.
	func reloadFromDisk() {
		load()
	}

	/// Drops the named keys from the store and from the file. `delete(_:)` blanks a value, which
	/// leaves an empty entry behind forever; this actually removes it.
	func forget(_ keys: Set<String>) {
		lock.withLock {
			for key in keys { store.removeValue(forKey: key) }
		}
		persist()
	}
}

// MARK: - Named keys

extension Secrets {
	enum Key {
		static func llmAPIKey(providerID: String) -> String { "llm.\(providerID).apiKey" }
		static let baiduSecretKey = "mt.baidu.secretKey"
		static let tencentSecretKey = "mt.tencent.secretKey"
		static let deepLKey = "mt.deepl.key"
		static let proxyPassword = "net.proxy.password"
	}
}
