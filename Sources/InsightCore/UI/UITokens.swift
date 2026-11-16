import SwiftUI

/// Design tokens for the panel — the SwiftUI counterpart of the `shadcn-neutral` style from the
/// web-ui skill (黑白灰、细边框、中等圆角), and the one place a spacing, radius or type size is
/// decided. Views use these names instead of bare numbers, the same way the web pages use
/// semantic CSS variables: change one value here and every surface follows.
///
/// Colours are **never literals**. Everything is derived from `Color.primary` / `.secondary` at a
/// fixed opacity, which is what keeps light and dark mode correct without a second palette — the
/// same reason `shadcn-neutral` defines its border as `oklch(1 0 0 / .1)` in dark rather than a
/// separate grey. The one chromatic token is `destructive`, because an error has to be findable.
enum UI {
	/// 4pt grid, doubled up for the larger steps. Odd values are not allowed on purpose.
	enum Space {
		static let x1: CGFloat = 4
		static let x2: CGFloat = 8
		static let x3: CGFloat = 12
		static let x4: CGFloat = 16
	}

	/// `sm` for buttons and chips, `md` for inputs, `lg` for cards — one step apart, so nested
	/// shapes (a button inside a card) never share a radius and read as concentric.
	enum Radius {
		static let sm: CGFloat = 6
		static let md: CGFloat = 8
		static let lg: CGFloat = 12
	}

	/// Four sizes. The panel is 480pt wide; anything finer than this is noise.
	enum Size {
		static let micro: CGFloat = 10
		static let caption: CGFloat = 11
		static let label: CGFloat = 12
		static let body: CGFloat = 13
	}

	/// `--border`: a hairline that is visible but never competes with the text.
	static let border = Color.primary.opacity(0.10)
	/// `--card`: a barely-there lift over the backdrop, for the cards and the input strip.
	static let surface = Color.primary.opacity(0.035)
	/// `--accent`: the hover fill of an icon button.
	static let hover = Color.primary.opacity(0.07)
	/// `--destructive`: failures only. Warnings and hints stay neutral.
	static let destructive = Color(nsColor: .systemRed)
}
