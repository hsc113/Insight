import AppKit
import ScreenCaptureKit

/// One-shot screen capture.
///
/// `CGDisplayCreateImage` is marked unavailable in the macOS 26 SDK and Apple points at
/// ScreenCaptureKit instead. `SCScreenshotManager.captureImage(in:)` is the right primitive
/// anyway: it takes a rect in screen-space points and is display-agnostic, so dragging a
/// selection across two monitors needs no per-display bookkeeping at all.
enum ScreenGrabber {
	struct Failure: LocalizedError {
		var code: Int
		var domain: String
		var underlying: String

		var errorDescription: String? {
			"截屏失败 SCStreamError \(domain) \(code)\(underlying.isEmpty ? "" : " — \(underlying)")"
		}
	}

	/// - Parameter rect: The selection in AppKit global coordinates — the space `NSScreen.frame`
	///   and `NSEvent` both use.
	/// - Throws: `Failure` carrying the real `SCStreamError`, because "截图失败" on its own tells
	///   the user nothing about what to do about it.
	static func capture(rect: CGRect) async throws -> CGImage {
		try await withCheckedThrowingContinuation { continuation in
			SCScreenshotManager.captureImage(in: displaySpaceRect(fromAppKitRect: rect)) { image, error in
				if let image {
					continuation.resume(returning: image)
					return
				}
				let scError = error as NSError?
				continuation.resume(
					throwing: Failure(
						code: scError?.code ?? 0,
						domain: scError?.domain ?? "未知",
						underlying: scError?.localizedDescription ?? ""))
			}
		}
	}

	/// AppKit's global space and CoreGraphics' global space disagree about one thing only: which
	/// direction is up.
	///
	/// AppKit puts the origin at the **bottom-left** of the primary display with y growing
	/// upward; CoreGraphics puts it at the **top-left** with y growing downward. `SnipController`
	/// measures the drag in AppKit space, and `SCScreenshotManager.captureImage(in:)` documents
	/// its rect as being "in points on the screen space" — i.e. CoreGraphics space. Handing it the
	/// AppKit rect unchanged therefore captured a vertically mirrored region, and OCR faithfully
	/// read whichever text happened to sit that far down the screen rather than the text the
	/// user framed.
	///
	/// Only the y axis needs flipping; x is shared. For a display *above* the primary one the
	/// formula yields a negative y, which is exactly right — CoreGraphics' origin is the
	/// primary display's top-left, so anything above it is negative.
	static func displaySpaceRect(fromAppKitRect rect: CGRect) -> CGRect {
		CGRect(
			x: rect.minX,
			y: primaryDisplayHeight - rect.maxY,
			width: rect.width,
			height: rect.height)
	}

	/// `NSScreen.screens[0]` is the primary display — the one holding the menu bar — and its frame
	/// origin is `(0, 0)` by definition, so its height is the reference the CG space is measured
	/// from. Falling back to the rect itself keeps this total on a machine with no displays
	/// reported, rather than trapping on a force unwrap in a code path that only ever runs to
	/// show a pasteboard preview.
	static var primaryDisplayHeight: CGFloat {
		NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0
	}
}