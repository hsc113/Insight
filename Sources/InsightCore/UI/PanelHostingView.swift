import AppKit
import SwiftUI

/// Geometry of the panel's top bar, shared between AppKit and SwiftUI.
///
/// A separate non-generic type because `PanelHostingView` is generic and Swift does not allow
/// static stored properties on a generic type — and because these two numbers are a contract
/// between the hit test in `PanelHostingView.mouseDown` and the row drawn in `ResultView.topBar`.
enum PanelChrome {
	/// Height of the drag strip, matching `ResultView.topBar`'s `.frame(height:)`.
	///
	/// Written in both places it would be a silent bug: a top bar that grew by a point would leave
	/// the last point of it un-draggable, and the only symptom would be that the window is slightly
	/// harder to grab than it looks.
	static let dragStripHeight: CGFloat = 30

	/// Width reserved for the three trailing buttons.
	///
	/// 3 × 22pt buttons + 2 × 4pt gaps + the 14pt gutter, plus 8pt of slack so the last button's
	/// hover background is never swallowed by the drag strip. A single click landing in the gap
	/// between the last draggable pixel and the first button would otherwise drag the window *and*
	/// register as a button press.
	private static let buttonSide: CGFloat = 22
	private static let buttonGap: CGFloat = 4
	private static let gutter: CGFloat = 14
	private static let slack: CGFloat = 8

	static let actionClusterWidth: CGFloat =
		3 * buttonSide + 2 * buttonGap + gutter + slack

	/// AppKit's own "start moving this window" entry point, by its Objective-C selector.
	///
	/// `performWindowDragWithEvent:` is declared in `NSWindow.h` and is what
	/// `isMovableByWindowBackground` calls, but it is **not surfaced to Swift on this SDK** — the
	/// import has no `performWindowDrag(with:)`, so there is no `#selector` to write either, which is
	/// also why the compiler's "use #selector" suggestion is not actionable here.
	/// `NSSelectorFromString` rather than `Selector(...)` for the same reason: the latter compiles to
	/// the same thing and draws that warning on every build.
	///
	/// It lives here rather than on `PanelHostingView` because Swift forbids static stored properties
	/// on a generic type. `responds(to:)` is checked at the call site; see `mouseDown`.
	static let windowDragSelector = NSSelectorFromString("performWindowDragWithEvent:")
}

/// The panel's content view, with the window drag handled by AppKit.
///
/// # Why this exists instead of a SwiftUI `DragGesture`
///
/// The gesture used to live in `ResultView` and call `panel.setFrameOrigin` from `.onChanged`. It
/// tracked the pointer at **half speed** and jumped, and both symptoms come from one thing:
/// `DragGesture.Value.translation` is recomputed on every event by converting the current mouse
/// position into **the view's own coordinate space** — and this view is the panel's content view,
/// which the handler had just moved. Solving that feedback loop for a steady drag gives
/// `origin = origin₀ + T/2`, where `T` is how far the pointer actually moved: the window lags at
/// half speed *permanently*, and every per-event rounding and coalescing shows up as a stutter.
///
/// `performWindowDrag(with:)` hands the whole thing to AppKit's own tracking loop: the window
/// follows the pointer exactly, no SwiftUI gesture recogniser is re-entered mid-drag, and we never
/// call `setFrameOrigin` ourselves.
///
/// It also retires the note in `PanelController.init` about `isMovableByWindowBackground` having to
/// be off. That was forced by a collision between AppKit's background-drag and SwiftUI's gesture
/// recogniser over the split handle; with the drag no longer going through SwiftUI there is nothing
/// left to collide.
///
/// Hit testing lives here rather than in a background `NSView` under the SwiftUI content because an
/// `NSHostingView` does not fall through to sibling views for clicks its own content did not take —
/// such a view would simply never be clicked.
final class PanelHostingView<Content: View>: NSHostingView<Content> {
	/// AppKit's own "start moving this window" entry point, reached through its Objective-C selector.
	///
	/// `responds(to:)` is the guard rather than an assumption: `PanelChrome.windowDragSelector` is
	/// present on every macOS this app supports (10.11+), and if a future SDK ever drops it the drag
	/// falls back to `dragWindowManually` instead of silently becoming a dead strip.
	override func mouseDown(with event: NSEvent) {
		guard Self.isInDragStrip(event.locationInWindow, bounds: bounds), let window else {
			// The text editor's clicks land here too — it is the biggest interactive area.
			super.mouseDown(with: event)
			return
		}
		// Non-blocking when AppKit's path is taken: the Window Server owns the drag from here, which
		// is what makes the window follow the pointer exactly and keeps space switching working.
		guard window.responds(to: PanelChrome.windowDragSelector) else {
			dragWindowManually(window, mouseDown: event)
			return
		}
		_ = window.perform(PanelChrome.windowDragSelector, with: event)
	}

	/// Fallback drag, used only if AppKit's entry point is unavailable.
	///
	/// The essential detail is that the delta is measured in **global screen coordinates**, not in
	/// the view's: this view *is* the window's content view and moves with it, so a
	/// view-relative delta feeds back into itself and the window tracks at half speed. Every frame
	/// also sets an absolute origin derived from the mouse-down, so a dropped event cannot
	/// accumulate into drift.
	private func dragWindowManually(_ window: NSWindow, mouseDown: NSEvent) {
		let origin = window.frame.origin
		let start = window.convertPoint(toScreen: mouseDown.locationInWindow)
		while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]),
			next.type == .leftMouseDragged
		{
			// `mouseLocation` is the position *now*, which is what a tracking loop wants;
			// `next.locationInWindow` would be measured against a view that just moved.
			let now = NSEvent.mouseLocation
			window.setFrameOrigin(
				NSPoint(x: origin.x + now.x - start.x, y: origin.y + now.y - start.y))
		}
		// The loop exits having consumed the mouse-up, so the click never reaches whatever is
		// underneath.
	}

	/// Whether a point in the hosting view's coordinate space belongs to the drag strip.
	///
	/// Pure and static so the checker can assert both edges — a strip anchored to the bottom of the
	/// window, or one that swallowed the buttons, is invisible in the code and obvious only when you
	/// try to use it.
	static func isInDragStrip(_ point: NSPoint, bounds: NSRect) -> Bool {
		let stripHeight = PanelChrome.dragStripHeight
		// AppKit's origin is bottom-left, so the top of the window is the *high* y and the buttons
		// are on the right.
		guard point.y >= bounds.height - stripHeight else { return false }
		return point.x < bounds.width - PanelChrome.actionClusterWidth
	}
}