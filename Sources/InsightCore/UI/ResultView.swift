import AppKit
import SwiftUI
import Translation

/// The result panel.
///
/// Layout follows the conventions of floating utility panels: **there is no
/// title bar at all**. Content starts flush with the top edge, sections are separated by
/// whitespace and inset hairlines instead of full-bleed dividers, and every piece of metadata
/// is tertiary text that never competes with the two things the user actually came to read.
///
/// The one structural constraint is unchanged: the input is a single collapsed strip, so the
/// summary and the translation own all the remaining height.
struct ResultView: View {
	let model: PanelModel
	let panel: NSPanel

	@State private var appleConfig: TranslationSession.Configuration?

	/// 14pt side margin. Everything aligns to it, which is what makes the panel read as one
	/// object rather than a stack of rows.
	private let gutter: CGFloat = 14

	var body: some View {
		let theme = Settings.shared.panelTheme

		VStack(spacing: 0) {
			topBar(theme: theme)
			InputStrip(model: model, gutter: gutter)
				.padding(.horizontal, gutter)
				.padding(.bottom, 10)
			statusLine

			if let permission = model.permission {
				PermissionCard(permission: permission)
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else {
				cards(theme: theme)
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background(theme.contentBackdrop)
		.shellSurface(theme, cornerRadius: 0)
		// Without this the root view starts below the title bar even though
		// `titlebarAppearsTransparent` is set, leaving a dead band at the top of the window.
		.ignoresSafeArea()
		// Held in @State so the modifier gets a stable value; recomputing it in `body` would
		// restart the translation task on every unrelated state change.
		.translationTask(appleConfig) { session in
			await runAppleTranslation(session)
		}
		.onChange(of: model.pipeline.appleRequest?.id) { _, newValue in
			appleConfig = newValue.map { _ in
				let request = model.pipeline.appleRequest
				return TranslationSession.Configuration(
					source: request?.source.flatMap { Locale.Language(identifier: $0) },
					target: Locale.Language(identifier: request?.target ?? "zh-Hans"))
			}
		}
	}

	private func runAppleTranslation(_ session: TranslationSession) async {
		guard let request = model.pipeline.appleRequest else { return }
		do {
			try await session.prepareTranslation()
			let response = try await session.translate(request.text)
			model.pipeline.completeApple(id: request.id, result: .success(response.targetText))
		} catch {
			model.pipeline.completeApple(id: request.id, result: .failure(error))
		}
	}

	// MARK: - Status line

	/// The one row above the cards that reports "Insight is still working".
	///
	/// It replaces nothing and sits above the previous result rather than over it, because the whole
	/// point of showing the window before the text is known is that the last answer stays readable
	/// while the next one is being read. A ⌥S that takes Vision a second would otherwise either show
	/// an empty panel or nothing at all.
	@ViewBuilder
	private var statusLine: some View {
		if let label = model.captureLabel {
			statusNotice(text: label, icon: "arrow.triangle.2.circlepath", tint: .secondary, busy: true)
		} else if let notice = model.transientHint {
			statusNotice(text: notice, icon: "exclamationmark.triangle.fill", tint: .orange, busy: false)
		}
	}

	private func statusNotice(
		text: String, icon: String, tint: Color, busy: Bool
	) -> some View {
		HStack(spacing: 5) {
			Image(systemName: icon)
				.font(.system(size: 9.5))
			Text(text)
				.font(.system(size: 10.5))
			Spacer()
		}
		.foregroundStyle(tint)
		.padding(.horizontal, gutter)
		.padding(.bottom, 7)
		.transition(.opacity)
	}

	// MARK: - Top bar

	/// 30pt, flat, no background. The standard window buttons are hidden, so this row is the only
	/// chrome.
	///
	/// The row is also the window's drag handle, but **not through SwiftUI**: `PanelHostingView`
	/// claims the mouse-down inside this strip and calls `performWindowDrag(with:)`. The gesture that
	/// used to live here called `panel.setFrameOrigin` from `.onChanged`, and since
	/// `DragGesture.translation` is computed in the coordinate space of the view being moved — which
	/// *is* the panel's content view — the window tracked the pointer at half speed and jumped. That
	/// is why this row carries no gesture at all, and why the strip's height is a shared constant
	/// rather than a literal `30` written here as well.
	private func topBar(theme: PanelTheme) -> some View {
		HStack(spacing: 6) {
			HStack(spacing: 6) {
				Image(systemName: "text.alignleft")
					.font(.system(size: 10, weight: .semibold))
					.foregroundStyle(.quaternary)

				Text("Insight")
					.font(.system(size: 11, weight: .medium))
					.foregroundStyle(.tertiary)

				Spacer(minLength: 8)
			}
			.help("拖动可移动窗口")

			if !model.permissionTitlebarHidden {
				// Grouped so the three shapes render as one blended form rather than three
				// independent ones.
				actionButtons(theme: theme)
			}
		}
		.padding(.horizontal, gutter)
		.frame(height: PanelChrome.dragStripHeight)
	}

	/// Plain `HStack`, not a `GlassEffectContainer`.
	///
	/// The container was supposed to blend the three shapes into one form, but inside an
	/// `HStack` it mislaid them — the close button ended up rendered over the input strip.
	/// Each button already carries its own `glassEffect`, so the container was buying nothing
	/// worth that.
	private func actionButtons(theme: PanelTheme) -> some View {
		HStack(spacing: 4) {
			BarButton(
				system: "arrow.clockwise",
				help: "分析  ⌘R",
				disabled: self.model.input.isEmpty,
				theme: theme,
				action: { self.model.retry() })

			BarButton(
				system: self.model.isPinned ? "pin.fill" : "pin",
				help: self.model.isPinned ? "取消置顶  ⌘P" : "窗口置顶  ⌘P",
				active: self.model.isPinned,
				theme: theme,
				action: { PanelController.shared.togglePin() })

			BarButton(
				system: "xmark",
				help: "关闭  esc",
				theme: theme,
				action: { PanelController.shared.hide() })
		}
	}

	// MARK: - Result sections

	/// The two cards, split by a draggable hairline.
	///
	/// A plain `VStack` would hand both cards `maxHeight: .infinity`, so each gets exactly half
	/// the panel at every window height — and resizing the window moves both boundaries together.
	/// That is wrong for a panel whose two halves are not equally important: a long selection
	/// needs a tall translation, a transcript needs a tall summary, and a user who has just read
	/// the summary and is now checking it against the translation wants most of the window on the
	/// translation. So the split is a stored fraction and the divider is its handle.
	///
	/// When one of the two is switched off in 功能设置, its card keeps its header and loses its
	/// body — the geometry is `cardLayout`, a pure function, so "the other card gets the space" is
	/// assertable without a window on screen.
	private func cards(theme: PanelTheme) -> some View {
		let settings = Settings.shared
		let layout = Self.cardLayout(
			summaryEnabled: settings.summaryEnabled,
			translationEnabled: settings.translationEnabled,
			split: settings.cardSplit)

		return GeometryReader { proxy in
			VStack(spacing: 0) {
				summarySection(theme: theme)
					// The translation card is left to soak up the remainder rather than given its
					// own computed height — two independent multiplications of the same fraction
					// would drift by a fraction of a point on every resize. It has no remainder to
					// soak up while the divider is out, which is why the divider is not there: with
					// one card switched off, the card that is on gets the whole area by being the
					// only thing in it, rather than by arithmetic that happens to add up.
					.frame(height: layout.summaryHeight(in: proxy.size.height))

				if layout.isSplittable {
					CardSplitHandle(
						totalHeight: proxy.size.height,
						fraction: splitFraction,
						onChange: { setSplitFraction($0) },
						onReset: { setSplitFraction(0.5) })
						.frame(height: CardSplitHandle.grabHeight)
						// Inset to the gutters, like every other rule in this panel.
						.padding(.horizontal, gutter)
				}

				translationSection(theme: theme)
					.frame(maxHeight: .infinity)
			}
			.frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
		}
	}

	/// The height of the summary card, and whether the divider still means anything, for a given
	/// pair of switches.
	struct CardLayout: Equatable {
		/// Fixed height of a switched-off card: its header plus one line saying so.
		static let compactHeight: CGFloat = 48

		/// `nil` means "share the card area by `split`", a number means "exactly this tall", and
		/// `.infinity` means "the whole card area" — the third case being 仅总结, where a fraction of
		/// the panel is not a preference about a single card. Exactly one of the two cards ever
		/// takes what is left: the summary is laid out first and the translation soaks up the rest.
		var summaryFixedHeight: CGFloat?
		var isSplittable: Bool
		/// The split in force. Threaded in through `cardLayout` rather than read from `Settings`
		/// here, so the whole of this value is a function of its arguments.
		var split: CGFloat

		func summaryHeight(in total: CGFloat) -> CGFloat {
			// `.infinity` and the compact strip are the same line of code on purpose: both mean
			// "this card is not divided with anything", and `min` is what turns one into the whole
			// window and the other into 48pt.
			if let summaryFixedHeight { return min(summaryFixedHeight, total) }
			// Half the handle's height belongs to the gap above the line, so the summary gets
			// exactly `fraction` of the card area rather than a half-point more.
			//
			// The floor is `CardSplitHandle.minimumFraction(for:)` rather than a bare pixel
			// minimum, so the height here and the fraction the drag handler clamps to are the same
			// constraint expressed twice — they can't drift and let the divider outrun the pointer.
			let fraction = max(
				split, CardSplitHandle.minimumFraction(for: total))
			return max(
				CardSplitHandle.minimumCardHeight,
				total * fraction - CardSplitHandle.grabHeight / 2)
		}
	}

	/// What the panel shows, given the two switches and the stored split.
	///
	/// Three outcomes, and the mapping is worth stating because it is the feature: both on → the
	/// stored split, as it has always been; summary off → the summary card is a header strip and
	/// the translation takes the panel; translation off → the summary takes the panel and *its*
	/// stored split is deliberately ignored, because a fraction of the panel chosen when there
	/// were two cards is not a preference about one.
	static func cardLayout(
		summaryEnabled: Bool, translationEnabled: Bool, split: Double
	) -> CardLayout {
		let fraction = CGFloat(Settings.clampCardSplit(split))
		switch (summaryEnabled, translationEnabled) {
		case (true, true):
			return CardLayout(summaryFixedHeight: nil, isSplittable: true, split: fraction)
		case (false, true):
			return CardLayout(
				summaryFixedHeight: CardLayout.compactHeight, isSplittable: false, split: fraction)
		case (true, false):
			// The whole card area, and `split` is not consulted at all — not merely ignored through
			// a fraction of 1, which would still divide by the panel height and still let
			// `minimumFraction(for:)` push the card down to 70pt in a short window. The card that
			// owns the panel owns all of it, at every window size.
			return CardLayout(summaryFixedHeight: .infinity, isSplittable: false, split: fraction)
		case (false, false):
			// Unreachable through the UI — no `FeatureMode` expresses it and `decodeConfig` settles
			// it — but stated rather than trapped: two header strips is a legible panel, and a
			// `fatalError` here would turn a hand-edited config.json into a crash on the hotkey path.
			return CardLayout(
				summaryFixedHeight: CardLayout.compactHeight, isSplittable: false, split: fraction)
		}
	}

	private var splitFraction: CGFloat { CGFloat(Settings.shared.cardSplit) }

	private func setSplitFraction(_ value: CGFloat) {
		let clamped = Settings.clampCardSplit(Double(value))
		guard Settings.shared.cardSplit != clamped else { return }
		Settings.shared.cardSplit = clamped
		Settings.shared.commit()
	}

	private func summarySection(theme: PanelTheme) -> some View {
		ResultCard(
			kind: .summary,
			text: model.pipeline.summary,
			reasoning: model.pipeline.summaryReasoning,
			phase: model.pipeline.summaryPhase,
			firstTokenMs: model.pipeline.summaryFirstTokenMs,
			gutter: gutter,
			theme: theme,
			headerAccessory: { EmptyView() },
			// Switched off is not the same as collapsed by hand: the card is *only* a header, so
			// it must not offer a chevron that would appear to open it.
			compact: !Settings.shared.summaryEnabled,
			collapsed: Binding(
				get: { Settings.shared.summaryCollapsed },
				set: { Settings.shared.summaryCollapsed = $0; Settings.shared.commit() }),
			onRetry: { model.retry() },
			writeBack: nil)
	}

	private func translationSection(theme: PanelTheme) -> some View {
		ResultCard(
			kind: .translation,
			text: model.pipeline.translation,
			reasoning: model.pipeline.translationReasoning,
			phase: model.pipeline.translationPhase,
			firstTokenMs: model.pipeline.translationFirstTokenMs,
			gutter: gutter,
			theme: theme,
			headerAccessory: { LanguagePairPicker(model: model) },
			compact: !Settings.shared.translationEnabled,
			collapsed: Binding(
				get: { Settings.shared.translationCollapsed },
				set: { Settings.shared.translationCollapsed = $0; Settings.shared.commit() }),
			onRetry: { model.retry() },
			writeBack: { PanelController.shared.replaceSelectionWithTranslation() })
	}
}

// MARK: - Language pair

/// Source → target, as two menus in the card header.
///
/// This is where the language actually gets picked, over and over, so it has to be reachable from
/// the answer rather than from a settings window. Each menu is a `Menu` rather than a `Picker`
/// because a `Picker` renders as a popup button with a chevron and a fixed-width label column,
/// which does not fit a header that already has a title, a spinner, a copy button and a status
/// dot in it.
private struct LanguagePairPicker: View {
	@Bindable var model: PanelModel

	private let settings = Settings.shared

	var body: some View {
		HStack(spacing: 3) {
			menu(
				systemImage: "textformat",
				help: "源语言",
				selection: settings.sourceLanguage,
				onPick: { model.setSourceLanguage($0) })

			Image(systemName: "arrow.right")
				.font(.system(size: 8, weight: .semibold))
				.foregroundStyle(.quaternary)

			// Shows the setting, not the pipeline's resolved value: 自动识别 is a legal choice here
			// and has to be tickable, so it can't be swapped for the detected source the way the
			// card's old "源 → 目标" caption used to.
			menu(
				systemImage: "character.book.closed",
				help: "目标语言",
				selection: settings.targetLanguage,
				onPick: { model.setTargetLanguage($0) })
		}
		.fixedSize()
	}

	private func menu(
		systemImage: String,
		help: String,
		selection: String,
		onPick: @escaping (String) -> Void
	) -> some View {
		Menu {
			ForEach(Languages.quickLanguages(including: selection)) { language in
				Button {
					onPick(language.id)
				} label: {
					if language.id == selection {
						Label(language.name, systemImage: "checkmark")
					} else {
						Text(language.name)
					}
				}
			}
		} label: {
			Label(Languages.name(selection), systemImage: systemImage)
				.font(.system(size: 10))
				.labelStyle(.titleAndIcon)
		}
		.menuStyle(.borderlessButton)
		.controlSize(.small)
		.fixedSize()
		.help(help)
	}
}

// MARK: - Card split handle

/// The hairline between the two cards, and the drag handle that sets how they divide the panel.
///
/// At rest it is exactly the inset hairline it replaced — a full-bleed divider reads as a table
/// row, and this panel is not a table. The grip only appears on hover, so the resting state stays
/// quiet, and double-clicking puts the two cards back to an even split.
///
/// **Only rendered when both cards are on.** With one switched off there is no boundary to move —
/// the card that is on owns the whole area — and a rule between a full card and a one-line strip
/// would be a rule between nothing. `ResultView.cards` leaves it out rather than disabling it, so
/// the "you cannot drag this" state needs no code here at all.
///
/// Not `private`: `split(startFraction:translation:totalHeight:)` is the whole of this view's
/// behaviour and the checker asserts it directly.
struct CardSplitHandle: View {
	/// Height of the whole card area, needed to turn a drag in points into a change in fraction.
	let totalHeight: CGFloat
	let fraction: CGFloat
	let onChange: (CGFloat) -> Void
	let onReset: () -> Void

	@State private var hovering = false
	/// The split at the moment the drag began. Without it, `value.translation` is cumulative and
	/// re-applying it to an already-updated `fraction` compounds the gesture.
	@State private var startFraction: CGFloat?

	/// Tall enough to grab comfortably, short enough not to steal space from the cards.
	static let grabHeight: CGFloat = 14

	/// Fraction after a drag of `translation` points, given the split at the moment the drag began.
	///
	/// Split out as a pure function because it is the whole of the handle's behaviour and a real
	/// drag is not reproducible in a check: the panel is a `.nonactivatingPanel` in an app that is
	/// usually *not* frontmost, so an injected mouse-up can be dropped and the gesture stays live.
	///
	/// - Parameters:
	///   - translation: `DragGesture.Value.translation.height`, positive for downward movement.
	///   - startFraction: The split when the drag began, not the current one — `translation` is
	///     cumulative, so applying it to an already-updated fraction compounds every frame.
	///   - totalHeight: Height of the two cards together, so a drag in points becomes a fraction.
	static func split(
		startFraction: CGFloat, translation: CGFloat, totalHeight: CGFloat
	) -> CGFloat {
		guard totalHeight > 0 else { return startFraction }
		// Dragging the divider *down* moves it down, which grows the summary above it and shrinks
		// the translation below. `translation.height` is positive downward, so the fraction is
		// **added**. This was a subtraction, which ran the divider the opposite way to the
		// pointer — and the checker asserted the formula rather than the behaviour, so it happily
		// agreed with itself and shipped the bug.
		let moved = startFraction + translation / totalHeight
		return min(max(moved, Self.minimumFraction(for: totalHeight)), Self.maximumFraction)
	}

	/// The smallest share the summary may take, derived from a minimum readable height.
	///
	/// Deriving it — rather than clamping the rendered height separately — is what keeps the stored
	/// fraction and the drawn divider in agreement. Clamping the height on its own let the divider
	/// stop while the fraction kept changing underneath it, so in a short window the handle
	/// desynced from the pointer and then snapped on the next drag.
	static func minimumFraction(for totalHeight: CGFloat) -> CGFloat {
		guard totalHeight > 0 else { return CGFloat(Settings.cardSplitRange.lowerBound) }
		// The same half-grab-height allowance `summaryHeight` gives the summary, so the boundary
		// lands exactly on the minimum rather than half a handle off it.
		return (Self.minimumCardHeight + CardSplitHandle.grabHeight / 2) / totalHeight
	}

	/// The largest share, so the translation card below never gets squeezed out either.
	static let maximumFraction: CGFloat = CGFloat(Settings.cardSplitRange.upperBound)
	static let minimumCardHeight: CGFloat = 70

	var body: some View {
		ZStack {
			Rectangle()
				.fill(Color.primary.opacity(hovering ? 0.22 : 0.08))
				.frame(height: 1)

			Capsule()
				.fill(Color.primary.opacity(hovering ? 0.3 : 0))
				.frame(width: 26, height: 3)
		}
		.frame(height: Self.grabHeight)
		.contentShape(Rectangle())
		.onHover { inside in
			hovering = inside
			// `resizeUpDown` is what a user expects from a horizontal splitter; leaving the arrow
			// cursor there makes the handle look decorative.
			if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
		}
		.gesture(
			DragGesture(minimumDistance: 1)
				.onChanged { value in
					if startFraction == nil { startFraction = fraction }
					guard let base = startFraction else { return }
					onChange(
						CardSplitHandle.split(
							startFraction: base,
							translation: value.translation.height,
							totalHeight: totalHeight))
				}
				.onEnded { _ in startFraction = nil }
		)
		// Simultaneous rather than `onTapGesture`, which the drag gesture would swallow.
		.simultaneousGesture(TapGesture(count: 2).onEnded { onReset() })
		.help("拖动调整两个卡片的高度，双击恢复等分")
	}
}

// MARK: - Top bar button

/// A bare icon button. No fill until hovered — three filled rounded rectangles in a row is the
/// single loudest thing in the old header.
private struct BarButton: View {
	let system: String
	let help: String
	var disabled = false
	var active = false
	var theme: PanelTheme = .frosted
	let action: () -> Void

	@State private var hovering = false

	var body: some View {
		Button(action: action) {
			Image(systemName: system)
				.font(.system(size: 11, weight: .medium))
				.foregroundStyle(active ? Color.accentColor : (hovering ? Color.primary : Color.secondary))
				.frame(width: 22, height: 22)
				.background(
					RoundedRectangle(cornerRadius: 5)
						.fill(hovering && !disabled ? Color.primary.opacity(0.07) : Color.clear)
				)
				// Glass on the label rather than `.buttonStyle(.glass)`: the button style adds
				// its own padding, which reflows the top bar. This keeps the layout untouched.
				.glassLabel(theme)
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.disabled(disabled)
		.help(help)
		.onHover { hovering = $0 }
	}
}

// MARK: - Input strip

/// Collapsed by default: one line showing the first and last few characters of the selection.
/// The user cares about the summary and the translation, not about re-reading what they just
/// selected — but they still need to be able to confirm it and to fix it.
private struct InputStrip: View {
	@Bindable var model: PanelModel
	let gutter: CGFloat

	/// Follows `model.inputExpanded` so the caret lands in the text the moment the strip opens.
	///
	/// Without it, expanding the input was a two-click affair — click the strip, then click again
	/// inside the editor — and, worse, Return did nothing: `PanelController.handleReturn` refuses to
	/// analyse unless the first responder is a text input (otherwise Return with focus parked on the
	/// 收起 button would analyse instead of collapsing). So the auto-focus is what makes "回车分析"
	/// true the moment the editor is on screen, which is what the hint text promises.
	@FocusState private var draftFocused: Bool

	var body: some View {
		Group {
			if model.inputExpanded { editor } else { collapsed }
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(
			RoundedRectangle(cornerRadius: 7)
				.fill(Color.primary.opacity(0.045))
		)
		.overlay(
			RoundedRectangle(cornerRadius: 7)
				.strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
		)
		// Both directions, so collapsing hands focus back and Esc / ⌘R behave normally again.
		.onChange(of: model.inputExpanded) { _, expanded in
			draftFocused = expanded
		}
		.onAppear { draftFocused = model.inputExpanded }
	}

	private var collapsed: some View {
		Button {
			model.expandInput()
		} label: {
			HStack(spacing: 7) {
				// No leading glyph. There was a `text.alignleft` here, and the top bar already
				// carries the same shape next to the word "Insight" — two identical marks 20pt
				// apart, one of which said nothing the row's own text did not.
				Text(model.input.isEmpty ? (model.hint ?? "无输入") : model.collapsedPreview)
					.font(.system(size: 11.5))
					.foregroundStyle(model.input.isEmpty ? .tertiary : .secondary)
					.lineLimit(1)

				Spacer(minLength: 4)

				if !model.input.isEmpty {
					Text("\(model.input.count)")
						.font(.system(size: 10).monospacedDigit())
						.foregroundStyle(.quaternary)
				}

				Image(systemName: "chevron.down")
					.font(.system(size: 8, weight: .semibold))
					.foregroundStyle(.quaternary)
			}
			.padding(.horizontal, 9)
			.padding(.vertical, 6)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.help("点击展开并编辑")
	}

	private var editor: some View {
		VStack(alignment: .leading, spacing: 7) {
			TextEditor(text: $model.draft)
				.font(.system(size: 12))
				.scrollContentBackground(.hidden)
				.focused($draftFocused)
				// Asked for twice on purpose: once when the strip expands, and once here, when the
				// editor actually exists.
				//
				// A `@FocusState` write is a request against a view that may not be in the
				// hierarchy yet — expanding the strip sets the flag during the same update that
				// creates this `TextEditor`, and the request can be dropped. It then never
				// retries, because nothing changes afterwards: the strip stays open and the flag
				// stays true, so `onChange` never fires again. The visible result is a Return that
				// does nothing, which is the bug the auto-focus was added to fix.
				.onAppear { draftFocused = true }
				.frame(minHeight: 52)
				.padding(4)
				.background(
					RoundedRectangle(cornerRadius: 5)
						.fill(Color.primary.opacity(0.05))
				)

			HStack(spacing: 8) {
				// Both bindings spelled out, because after the change Return is no longer a newline
				// and there is nothing else on screen that says so.
				Text("↩ 分析 · ⇧↩ 换行")
					.font(.system(size: 10))
					.foregroundStyle(.tertiary)
				Spacer()
				Button("收起") { model.collapseInput() }
					.buttonStyle(.plain)
					.font(.system(size: 11))
					.foregroundStyle(.secondary)
				Button("分析") { model.applyDraft() }
					.buttonStyle(.borderedProminent)
					.controlSize(.small)
					.disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
					.help("也可以按回车")
			}
		}
		.padding(8)
	}
}

// MARK: - Card

private enum CardKind {
	case summary
	case translation

	var title: String {
		switch self {
		case .summary: return "总结"
		case .translation: return "翻译"
		}
	}

	var icon: String {
		switch self {
		case .summary: return "sparkles"
		case .translation: return "character.book.closed"
		}
	}

	var accent: Color {
		switch self {
		case .summary: return .purple
		case .translation: return .teal
		}
	}
}

private struct ResultCard<Accessory: View>: View {
	let kind: CardKind
	let text: String
	let reasoning: String
	let phase: InsightPipeline.Phase
	let firstTokenMs: Int?
	let gutter: CGFloat
	let theme: PanelTheme
	/// Rendered between the title and the first-token timing. The translation card puts the
	/// language pair there; the summary card has nothing to put there and passes `EmptyView`.
	@ViewBuilder let headerAccessory: Accessory
	/// Switched off in 功能设置. The card is then a fixed-height strip — header plus one line
	/// saying so — and nothing else: no chevron, no reasoning row, no copy button, no empty box
	/// where the answer would have been.
	///
	/// Distinct from `collapsed`, which is the user folding a card away by hand while both
	/// features are on. Collapsed keeps its chevron and its height; this one has neither, because
	/// there is no state behind it to open.
	///
	/// One flag rather than a second `enabled` beside it: "the feature is on" and "this is not a
	/// strip" are the same fact, and two flags that must always disagree is how a header ends up
	/// saying 未启用 on a card drawn at full height.
	var compact = false
	@Binding var collapsed: Bool
	let onRetry: () -> Void
	/// Writes this card's text back over the source selection. `nil` on the summary card, where it
	/// would have no meaning.
	let writeBack: (() -> Void)?

	@State private var showReasoning = false
	@State private var didCopy = false

	private var enabled: Bool { !compact }

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			header
			if compact {
				content
			} else if !collapsed {
				VStack(alignment: .leading, spacing: 0) {
					if !reasoning.isEmpty { reasoningRow }
					content
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.padding(.horizontal, gutter)
		.padding(.top, 4)
		.padding(.bottom, 10)
		// The card reads as a soft surface in every theme; only the functional layer gets glass.
		.background(
			RoundedRectangle(cornerRadius: 9)
				.fill(theme.cardMaterial)
				.opacity(theme == .solid ? 0 : 1)
		)
	}

	private var header: some View {
		HStack(spacing: 6) {
			// Held open rather than removed, so the icon and the title do not shift sideways when
			// the card is switched off — a header that jumps 11pt as it collapses reads as a
			// different row, not as the same row, smaller.
			if compact {
				Color.clear.frame(width: 11, height: 11)
			} else {
				Button {
					withAnimation(.snappy(duration: 0.16)) { collapsed.toggle() }
				} label: {
					Image(systemName: collapsed ? "chevron.right" : "chevron.down")
						.font(.system(size: 7, weight: .bold))
						.foregroundStyle(.quaternary)
						.frame(width: 11, height: 11)
						.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
			}

			Image(systemName: kind.icon)
				.font(.system(size: 10, weight: .medium))
				.foregroundStyle(enabled ? kind.accent : Color.secondary)

			Text(kind.title)
				.font(.system(size: 12, weight: .semibold))

			// The language pickers change a request this card no longer makes, so they go with it.
			if !compact { headerAccessory }

			if !enabled {
				Text("未启用")
					.font(.system(size: 10))
					.foregroundStyle(.quaternary)
			}

			Spacer(minLength: 6)

			if let firstTokenMs, !compact {
				Text("\(firstTokenMs) ms")
					.font(.system(size: 10).monospacedDigit())
					.foregroundStyle(.quaternary)
			}

			// Left, not cleared: a model that is mid-stream when the card is switched off keeps
			// running — the request is already paid for — and switching the card back on before it
			// lands shows the answer rather than an empty box. The height is what is reclaimed,
			// which is the whole point of the setting.
			if !text.isEmpty, !compact {
				BarButton(
					system: didCopy ? "checkmark" : "doc.on.doc",
					help: "复制\(kind.title)",
					theme: theme,
					action: copy)
			}

			// Only on the translation card, and only once there is something to write back.
			//
			// It was on neither card before: the write-back code existed and had no caller, so the
			// button was the missing half. A closure rather than a `PanelController` reference, so the
			// card does not have to know what it is writing back into.
			if let writeBack, !text.isEmpty, !compact {
				BarButton(
					system: "arrow.turn.down.left",
					help: "把译文写回原文  ⌘⇧C",
					theme: theme,
					action: writeBack)
			}

			if !compact { statusIndicator }
		}
		.padding(.vertical, 3)
	}

	private func copy() {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(text, forType: .string)
		didCopy = true
		Task {
			try? await Task.sleep(nanoseconds: 1_200_000_000)
			didCopy = false
		}
	}

	@ViewBuilder
	private var statusIndicator: some View {
		switch phase {
		case .idle:
			EmptyView()
		case .waiting:
			ProgressView().controlSize(.small).scaleEffect(0.55).frame(width: 13, height: 13)
		case .streaming:
			Circle()
				.fill(kind.accent)
				.frame(width: 5, height: 5)
				.shadow(color: kind.accent.opacity(0.5), radius: 3)
		case .done:
			Image(systemName: "checkmark")
				.font(.system(size: 9, weight: .bold))
				.foregroundStyle(.quaternary)
		case .failed:
			Button(action: onRetry) {
				Image(systemName: "exclamationmark.triangle.fill")
					.font(.system(size: 10))
					.foregroundStyle(.orange)
					.frame(width: 16, height: 16)
					.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.help("重试")
		}
	}

	private var reasoningRow: some View {
		VStack(alignment: .leading, spacing: 0) {
			Button {
				withAnimation(.snappy(duration: 0.16)) { showReasoning.toggle() }
			} label: {
				HStack(spacing: 4) {
					Image(systemName: showReasoning ? "chevron.down" : "chevron.right")
						.font(.system(size: 6, weight: .bold))
					Text("思考过程")
						.font(.system(size: 10.5))
					Text("\(reasoning.count) 字")
						.font(.system(size: 9.5).monospacedDigit())
					Spacer()
				}
				.foregroundStyle(.tertiary)
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)

			if showReasoning {
				ScrollView {
					Text(reasoning)
						.font(.system(size: 11))
						.foregroundStyle(.secondary)
						.lineSpacing(2)
						.textSelection(.enabled)
						.frame(maxWidth: .infinity, alignment: .leading)
				}
				.frame(maxHeight: 120)
				.padding(.top, 5)
			}
		}
		.padding(.top, 2)
		.padding(.bottom, 6)
	}

	@ViewBuilder
	private var content: some View {
		// Checked before the phase, not inside it: a switched-off card has no phase worth
		// rendering, and the one thing it must never do is print "等待输入" for a request that is
		// not coming. One line, one place to change it.
		if compact {
			Text(disabledHint)
				.font(.system(size: 11))
				.foregroundStyle(.tertiary)
				.lineLimit(1)
				.padding(.top, 3)
				.frame(maxWidth: .infinity, alignment: .leading)
		} else {
			phaseContent
		}
	}

	/// Where the setting that would bring this card back lives. The card is not broken and the
	/// empty half of the panel is not a mystery — saying which switch to flip is the whole reason
	/// the strip is on screen instead of being removed.
	private var disabledHint: String {
		kind == .summary ? "总结已关闭 · 在「通用设置 › 功能」中开启" : "翻译已关闭 · 在「通用设置 › 功能」中开启"
	}

	@ViewBuilder
	private var phaseContent: some View {
		switch phase {
		case .failed(let message):
			Text(message)
				.font(.system(size: 11.5))
				.foregroundStyle(.orange)
				.textSelection(.enabled)
				.fixedSize(horizontal: false, vertical: true)
				.padding(.top, 4)
				.frame(maxWidth: .infinity, alignment: .leading)

		case .idle:
			// Only reachable with the card switched on: a switched-off card renders `disabledHint`
			// instead and never gets here. So `.idle` on a live card means exactly one thing — the
			// feature is on and nothing has been asked of it yet.
			Text("等待输入")
				.font(.system(size: 11.5))
				.foregroundStyle(.quaternary)
				.padding(.top, 4)
				.frame(maxWidth: .infinity, alignment: .leading)

		default:
			ScrollView {
				// The summary is the only card that renders Markdown. The prompt asks for a gist
				// line and `- ` bullets, and `MarkdownText` covers exactly that — the translation
				// stays plain text so a stray `**` in the source can't restyle someone's document.
				if kind == .summary {
					MarkdownText(text: text.isEmpty ? " " : text, phase: phase)
						.padding(.top, 4)
				} else {
					Text(text.isEmpty ? " " : text)
						.font(.system(size: 13))
						.lineSpacing(3.5)
						.textSelection(.enabled)
						.frame(maxWidth: .infinity, alignment: .leading)
						.padding(.top, 4)
				}
			}
			.scrollContentBackground(.hidden)
		}
	}
}

// MARK: - Shared

private struct PermissionCard: View {
	let permission: Permissions.Permission

	var body: some View {
		VStack(spacing: 14) {
			Image(systemName: permission == .accessibility ? "lock.shield" : "video.badge.waveform")
				.font(.system(size: 28, weight: .light))
				.foregroundStyle(.orange)

			Text(permission.title)
				.font(.system(size: 14, weight: .semibold))

			Text(permission.detail)
				.font(.system(size: 11.5))
				.multilineTextAlignment(.center)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
				.frame(maxWidth: 300)

			Button("打开系统设置") { permission.openSettings() }
				.buttonStyle(.borderedProminent)
				.controlSize(.regular)
		}
		.padding(28)
	}
}

extension PanelModel {
	var permissionTitlebarHidden: Bool { permission != nil }
}

private struct WindowBackground: View {
	var body: some View {
		Rectangle().fill(.regularMaterial)
	}
}