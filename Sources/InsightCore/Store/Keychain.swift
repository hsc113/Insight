import Foundation
import Security

/// Secrets live in the keychain, never in the JSON config file.
/// Writing all sixteen providers' API keys to `config.json` in the clear is an alternative;
/// there is no reason to take it.
///
/// All reads and writes go through `Secrets.shared`, which keeps the keychain in memory. Going
/// to `SecItemCopyMatching` directly cost over a second of main-thread blocking on the hotkey
/// path; see `Secrets` for the measurement.
///
enum Keychain {
	private static let service = "Insight"

	static func apiKey(forProvider id: String) -> String {
		Secrets.shared.value(Secrets.Key.llmAPIKey(providerID: id))
	}

	static func setAPIKey(_ value: String, forProvider id: String) {
		Secrets.shared.set(value, for: Secrets.Key.llmAPIKey(providerID: id))
	}

	static func baiduSecretKey() -> String { Secrets.shared.value(Secrets.Key.baiduSecretKey) }
	static func setBaiduSecretKey(_ value: String) { Secrets.shared.set(value, for: Secrets.Key.baiduSecretKey) }

	static func tencentSecretKey() -> String { Secrets.shared.value(Secrets.Key.tencentSecretKey) }
	static func setTencentSecretKey(_ value: String) {
		Secrets.shared.set(value, for: Secrets.Key.tencentSecretKey)
	}

	static func deepLKey() -> String { Secrets.shared.value(Secrets.Key.deepLKey) }
	static func setDeepLKey(_ value: String) { Secrets.shared.set(value, for: Secrets.Key.deepLKey) }
}