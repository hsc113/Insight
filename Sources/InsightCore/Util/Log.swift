import Foundation
import os

enum Log {
	private static let subsystem = "com.hsc113.Insight"

	private static let network = Logger(subsystem: subsystem, category: "net")
	private static let pipeline = Logger(subsystem: subsystem, category: "pipeline")
	private static let capture = Logger(subsystem: subsystem, category: "capture")
	private static let ocr = Logger(subsystem: subsystem, category: "ocr")
	private static let ui = Logger(subsystem: subsystem, category: "ui")

	static func net(_ message: String) { network.debug("\(message, privacy: .public)") }
	static func pipeline(_ message: String) { pipeline.debug("\(message, privacy: .public)") }
	static func capture(_ message: String) { capture.debug("\(message, privacy: .public)") }
	static func ocr(_ message: String) { ocr.debug("\(message, privacy: .public)") }
	static func ui(_ message: String) { ui.debug("\(message, privacy: .public)") }

	static func error(_ message: String) {
		Logger(subsystem: subsystem, category: "error").error("\(message, privacy: .public)")
	}
}