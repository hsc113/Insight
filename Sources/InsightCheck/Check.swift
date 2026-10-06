import Foundation

/// A tiny assertion harness.
///
/// Command Line Tools ships neither XCTest nor Swift Testing, so `swift test` cannot run on a
/// machine without full Xcode. This is deliberately small: named checks, an explicit pass/fail
/// line each, and a non-zero exit code when anything fails, which is all a CI step needs.
enum Check {
	static var passed = 0
	static var failed = 0
	static var currentGroup = ""

	static func group(_ name: String) {
		currentGroup = name
		print("\n▸ \(name)")
	}

	static func that(_ condition: Bool, _ description: String, file: String = #fileID, line: Int = #line) {
		if condition {
			passed += 1
			print("  ✓ \(description)")
		} else {
			failed += 1
			print("  ✗ \(description)   (\(URL(fileURLWithPath: file).lastPathComponent):\(line))")
		}
	}

	static func equal<T: Equatable>(
		_ actual: T, _ expected: T, _ description: String,
		file: String = #fileID, line: Int = #line
	) {
		if actual == expected {
			passed += 1
			print("  ✓ \(description)")
		} else {
			failed += 1
			print(
				"  ✗ \(description) — expected \(expected), got \(actual)   "
					+ "(\(URL(fileURLWithPath: file).lastPathComponent):\(line))")
		}
	}

	static func summarize() -> Int32 {
		print("\n\(failed == 0 ? "全部通过" : "有失败")：\(passed) 通过，\(failed) 失败")
		return failed == 0 ? 0 : 1
	}
}