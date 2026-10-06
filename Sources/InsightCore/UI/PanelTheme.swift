import SwiftUI

/// How the panel is surfaced.
///
/// Apple's guidance is explicit: Liquid Glass belongs to the *functional* layer — controls,
/// navigation, floating shells — and must not be used in the content layer, because it makes
/// "what can be interacted with" ambiguous. A translation panel is exactly the case where that
/// matters: the text refreshes constantly, and the only thing the user needs to find is the
/// buttons. So glass goes on the shell and the buttons; the summary and translation cards keep
/// standard materials in every theme.
enum PanelTheme: String, CaseIterable, Identifiable, Sendable {
	case glass
	case frosted
	case solid

	var id: String { rawValue }

	var displayName: String {
		switch self {
		case .glass: return "毛玻璃"
		case .frosted: return "磨砂"
		case .solid: return "纯色"
		}
	}

	/// Content-layer backdrop. Never glass — see `shellSurface`.
	@ViewBuilder
	var contentBackdrop: some View {
		switch self {
		case .glass:
			// Ultra-thin, so whatever is behind the panel still tints through slightly while the
			// card material on top keeps the text readable.
			Rectangle().fill(.ultraThinMaterial)
		case .frosted:
			Rectangle().fill(.regularMaterial)
		case .solid:
			// `Color(nsColor:)` adapts to light and dark on its own. Hardcoding white or black
			// here would break the light mode.
			Rectangle().fill(Color(nsColor: .windowBackgroundColor))
		}
	}

	/// Material for the cards, which are content layer.
	var cardMaterial: Material {
		switch self {
		case .glass, .frosted: return .thin
		case .solid: return .thick
		}
	}
}

// MARK: - Liquid Glass bridge

/// Deliberately does **not** mention `Glass` in any signature.
///
/// `Glass` is annotated `@available(macOS 26.0)`, so a function whose parameter type is `Glass`
/// drags the whole caller's availability with it and fails to compile for an earlier target.
/// `if #available` inside the body is not enough — the type has to be kept out of the signature.
/// Mirroring it in an app-owned enum keeps the shim compiling everywhere.
enum GlassFlavour: Sendable {
	case regular
	case accent(Color)

	@available(macOS 26.0, *)
	var api: Glass {
		switch self {
		case .regular: .regular
		case .accent(let color): .regular.tint(color).interactive()
		}
	}
}

extension View {
	/// The window shell.
	///
	/// Deliberately **not** Liquid Glass. Two reasons, one from Apple and one measured here:
	/// their guidance is to use glass sparingly and never in the content layer, and a whole
	/// 480×470 panel *is* the content. Applying `glassEffect` to it also lets
	/// `DefaultGlassEffectShape` turn the window into a lens-shaped magnifier, which looks wrong
	/// on a rectangular popup and distorts the text underneath.
	@ViewBuilder
	func shellSurface(_ theme: PanelTheme, cornerRadius: CGFloat) -> some View {
		switch theme {
		case .glass, .frosted:
			background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
		case .solid:
			background(Color(nsColor: .windowBackgroundColor),
				in: RoundedRectangle(cornerRadius: cornerRadius))
		}
	}

}

/// Groups nearby glass shapes so the system renders them together — cheaper, and adjacent
/// shapes blend into one continuous form.
struct GlassEffectHost<Content: View>: View {
	let theme: PanelTheme
	let spacing: CGFloat
	@ViewBuilder let content: () -> Content

	init(theme: PanelTheme, spacing: CGFloat = 8, @ViewBuilder content: @escaping () -> Content) {
		self.theme = theme
		self.spacing = spacing
		self.content = content
	}

	var body: some View {
		if theme == .glass {
			if #available(macOS 26.0, *) {
				GlassEffectContainer(spacing: spacing) { content() }
			} else {
				content()
			}
		} else {
			content()
		}
	}
}


extension View {
	/// Liquid Glass for a small control's label, leaving the button's own layout alone.
	@ViewBuilder
	func glassLabel(_ theme: PanelTheme, cornerRadius: CGFloat = 6) -> some View {
		if theme == .glass {
			if #available(macOS 26.0, *) {
				glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
			} else {
				self
			}
		} else {
			self
		}
	}
}
