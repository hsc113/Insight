// swift-tools-version: 6.0
import PackageDescription

let package = Package(
	name: "Insight",
	platforms: [.macOS("26.0")],
	targets: [
		// Everything except `@main` lives here so it can be linked by both the app and the
		// checker below. Command Line Tools ships neither XCTest nor Swift Testing, so
		// `swift test` is unavailable on a machine without full Xcode — the checker is a plain
		// executable instead.
		.target(
			name: "InsightCore",
			path: "Sources/InsightCore",
			swiftSettings: [.swiftLanguageMode(.v5)]),
		.executableTarget(
			name: "Insight",
			dependencies: ["InsightCore"],
			path: "Sources/Insight",
			swiftSettings: [.swiftLanguageMode(.v5)]),
		.executableTarget(
			name: "insight-check",
			dependencies: ["InsightCore"],
			path: "Sources/InsightCheck",
			swiftSettings: [.swiftLanguageMode(.v5)]),
	]
)