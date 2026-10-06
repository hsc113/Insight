import AppKit

/// Full-screen drag-to-select screenshot capture.
///
/// Design notes:
/// - The overlays are *transparent*: the user keeps seeing their live desktop, dimmed outside
///   the selection. Nothing is pre-captured, so there is no full-screen image cache to manage
///   and no lag between the frozen snapshot and reality.
/// - The overlays are borderless windows that accept mouse events without ever becoming the key
///   window, so taking a screenshot doesn't pull focus out of whatever you're reading. Escape is
///   caught with a *global* key monitor for the same reason.
/// - Overlays are torn down and the compositor is given a beat before capturing, otherwise the
///   capture would include the overlays themselves.
@MainActor
final class SnipController {
	static let shared = SnipController()

	private var overlays: [OverlayWindow] = []
	private var completion: ((CGImage?) -> Void)?
	private var keyMonitor: Any?
	private var startPoint: NSPoint = .zero
	private var currentPoint: NSPoint = .zero
	private var isDragging = false

	private init() {}

	func begin(completion: @escaping (CGImage?) -> Void) {
		guard overlays.isEmpty, !NSScreen.screens.isEmpty else {
			completion(nil)
			return
		}
		self.completion = completion

		for target in NSScreen.screens {
			let overlay = OverlayWindow(screen: target)
			overlay.onDragChanged = { [weak self] point, phase in
				self?.handleDrag(point: point, phase: phase)
			}
			overlay.onCancel = { [weak self] in self?.finish(result: nil) }
			overlays.append(overlay)
			overlay.orderFrontRegardless()
		}

		NSCursor.crosshair.set()
		keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
			MainActor.assumeIsolated {
				// Escape cancels, Return confirms the current rectangle.
				switch event.keyCode {
				case 53: self?.finish(result: nil)
				case 36: self?.confirmSelection()
				default: break
				}
			}
		}
	}

	// MARK: - Drag handling

	private func handleDrag(point: NSPoint, phase: SnipPhase) {
		switch phase {
		case .began:
			isDragging = true
			startPoint = point
			currentPoint = point
		case .moved:
			currentPoint = point
		case .ended:
			currentPoint = point
			guard isDragging else { return }
			isDragging = false
			let rect = Self.normalized(startPoint, currentPoint)
			// Ignore stray clicks.
			guard rect.width > 4, rect.height > 4 else {
				finish(result: nil)
				return
			}
			confirmSelection()
			return
		}

		let selection = Self.normalized(startPoint, currentPoint)
		for overlay in overlays { overlay.setSelection(selection) }
	}

	private static func normalized(_ a: NSPoint, _ b: NSPoint) -> CGRect {
		CGRect(
			x: min(a.x, b.x), y: min(a.y, b.y),
			width: abs(a.x - b.x), height: abs(a.y - b.y))
	}

	/// Tear down the overlays, then capture. The delay lets the WindowServer actually remove
	/// them from the composited frame.
	private func confirmSelection() {
		let rect = Self.normalized(startPoint, currentPoint)
		teardown()
		Task { @MainActor [weak self] in
			try? await Task.sleep(nanoseconds: 90_000_000)
			do {
				let image = try await ScreenGrabber.capture(rect: rect)
				self?.deliver(image)
			} catch {
				Log.error("capture failed: \(error.localizedDescription)")
				self?.deliver(nil)
			}
		}
	}

	private func deliver(_ image: CGImage?) {
		let completion = self.completion
		self.completion = nil
		completion?(image)
	}

	private func finish(result: CGImage?) {
		teardown()
		deliver(result)
	}

	private func teardown() {
		if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
		keyMonitor = nil
		for overlay in overlays { overlay.close() }
		overlays.removeAll()
		isDragging = false
		NSCursor.arrow.set()
	}
}

// MARK: - Overlay

private final class OverlayWindow: NSWindow {
	var onDragChanged: ((NSPoint, SnipPhase) -> Void)?
	var onCancel: (() -> Void)?

	private let screenFrame: NSRect

	init(screen: NSScreen) {
		screenFrame = screen.frame
		super.init(
			contentRect: screen.frame,
			styleMask: .borderless,
			backing: .buffered,
			defer: true)

		isOpaque = false
		backgroundColor = .clear
		hasShadow = false
		ignoresMouseEvents = false
		acceptsMouseMovedEvents = true
		// Above everything, including full-screen apps and the Dock.
		level = .screenSaver
		collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
		isReleasedWhenClosed = false

		let view = OverlayView(screenFrame: screen.frame)
		view.autoresizingMask = [.width, .height]
		view.onDrag = { [weak self] point, phase in
			self?.onDragChanged?(point, phase)
		}
		view.onCancel = { [weak self] in self?.onCancel?() }
		contentView = view
	}

	func setSelection(_ selection: CGRect) {
		(contentView as? OverlayView)?.setSelection(selection)
	}
}

private enum SnipPhase { case began, moved, ended }

private final class OverlayView: NSView {
	private let screenFrame: NSRect
	private var selection: CGRect = .zero

	var onDrag: ((NSPoint, SnipPhase) -> Void)?
	var onCancel: (() -> Void)?

	init(screenFrame: NSRect) {
		self.screenFrame = screenFrame
		super.init(frame: NSRect(origin: .zero, size: screenFrame.size))
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError("unused") }

	func setSelection(_ rect: CGRect) {
		selection = rect
		needsDisplay = true
	}

	// MARK: Input

	override func mouseDown(with event: NSEvent) { onDrag?(globalPoint(event), .began) }
	override func mouseDragged(with event: NSEvent) { onDrag?(globalPoint(event), .moved) }
	override func mouseUp(with event: NSEvent) { onDrag?(globalPoint(event), .ended) }
	override func rightMouseDown(with event: NSEvent) { onCancel?() }

	private func globalPoint(_ event: NSEvent) -> NSPoint {
		let inWindow = event.locationInWindow
		return NSPoint(x: screenFrame.minX + inWindow.x, y: screenFrame.minY + inWindow.y)
	}

	// MARK: Drawing

	override func draw(_ dirtyRect: NSRect) {
		guard !selection.isEmpty else {
			NSColor.black.withAlphaComponent(0.3).setFill()
			bounds.fill()
			return
		}

		let local = CGRect(
			x: selection.minX - screenFrame.minX,
			y: selection.minY - screenFrame.minY,
			width: selection.width, height: selection.height)

		// Dim everything outside the selection as four bands rather than an even-odd fill,
		// because the selection routinely extends past this screen's bounds.
		let dim = NSColor.black.withAlphaComponent(0.32)
		dim.setFill()
		for region in [
			CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width,
				height: max(0, local.minY - bounds.minY)),
			CGRect(x: bounds.minX, y: local.maxY, width: bounds.width,
				height: max(0, bounds.maxY - local.maxY)),
			CGRect(x: bounds.minX, y: local.minY, width: max(0, local.minX - bounds.minX),
				height: local.height),
			CGRect(x: local.maxX, y: local.minY, width: max(0, bounds.maxX - local.maxX),
				height: local.height),
		] where !region.isEmpty {
			region.fill()
		}

		let border = NSBezierPath(rect: local)
		border.lineWidth = 1.5
		NSColor.white.setStroke()
		border.stroke()

		if selection.width >= 40, selection.height >= 24 {
			let text = NSAttributedString(
				string: "\(Int(selection.width)) × \(Int(selection.height))",
				attributes: [
					.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
					.foregroundColor: NSColor.white,
				])
			let size = text.size()
			let chip = NSRect(
				x: local.minX, y: local.minY - 19, width: size.width + 12, height: 16)
			NSColor.black.withAlphaComponent(0.75).setFill()
			NSBezierPath(roundedRect: chip, xRadius: 3, yRadius: 3).fill()
			text.draw(at: NSPoint(x: chip.minX + 6, y: chip.minY + 2.5))
		}
	}

	override func resetCursorRects() {
		addCursorRect(bounds, cursor: .crosshair)
	}
}