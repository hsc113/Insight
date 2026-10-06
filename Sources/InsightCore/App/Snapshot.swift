import AppKit

/// `Insight --snapshot [path]`: present the demo panel, wait for the stream to finish, render the
/// panel's own view hierarchy to a PNG and exit.
///
/// Exists for the README screenshot. A screen capture needs a Screen Recording grant for whatever
/// process runs `screencapture`, but rendering the app's *own* view needs no TCC permission at
/// all — so a fresh clone can regenerate the shot without touching System Settings.
@MainActor
enum Snapshot {
	static func run() {
		let arguments = CommandLine.arguments
		let path: String = {
			guard let index = arguments.firstIndex(of: "--snapshot"),
				arguments.indices.contains(index + 1),
				!arguments[index + 1].hasPrefix("--")
			else { return "/tmp/insight-panel.png" }
			return arguments[index + 1]
		}()

		Task { @MainActor in
			try? await Task.sleep(nanoseconds: 600_000_000)
			PanelController.shared.present(text: DemoStream.sampleInput)
			DemoStream.run(PanelController.shared.model.pipeline)

			// The demo finishes streaming in a bit over three seconds; the extra tail lets the
			// layout settle (Markdown reflow, card split, elapsed badge) before the frame is
			// taken.
			try? await Task.sleep(nanoseconds: 7_000_000_000)

			guard let contentView = PanelController.shared.panel.contentView,
				let rep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds)
			else {
				FileHandle.standardError.write("snapshot: no content view to render\n".data(using: .utf8)!)
				exit(2)
			}
			contentView.cacheDisplay(in: contentView.bounds, to: rep)
			guard let data = rep.representation(using: .png, properties: [:]) else {
				FileHandle.standardError.write("snapshot: PNG encoding failed\n".data(using: .utf8)!)
				exit(2)
			}
			do {
				try data.write(to: URL(fileURLWithPath: path))
			} catch {
				FileHandle.standardError.write("snapshot: \(error)\n".data(using: .utf8)!)
				exit(2)
			}
			print("snapshot: \(path)")
			exit(0)
		}
	}
}
