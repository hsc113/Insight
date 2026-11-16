import SwiftUI

/// Design tokens for the panel — the SwiftUI counterpart of the web-ui skill's `tr-airy` style
/// (大留白、无边框、大圆角、柔和), and the one place a spacing, radius or type size is decided.
/// Views use these names instead of bare numbers, the same way the web pages use semantic CSS
/// variables: change one value here and every surface follows.
///
/// Colours are **never literals**. Everything is derived from `Color.primary` / system colours at a
/// fixed opacity, which keeps light and dark mode correct without a second palette. The one
/// chromatic token is `destructive`, because an error has to be findable.
enum UI {
	/// 4pt grid. Odd values are not allowed on purpose.
	enum Space {
		static let x1: CGFloat = 4
		static let x2: CGFloat = 8
		static let x3: CGFloat = 12
		static let x4: CGFloat = 16
		/// Panel margin: cards, input strip and top bar all start here.
		static let gutter: CGFloat = x4
		/// Padding inside a card.
		static let card: CGFloat = x4
	}

	/// `sm` for buttons and chips, `md` for inputs, `lg` for cards — strictly growing, so nested
	/// shapes (a button inside a card) never share a radius and read as concentric.
	enum Radius {
		static let sm: CGFloat = 10
		static let md: CGFloat = 14
		static let lg: CGFloat = 20
	}

	/// Four sizes. The panel is 480pt wide; anything finer than this is noise.
	enum Size {
		static let micro: CGFloat = 10
		static let caption: CGFloat = 11
		static let label: CGFloat = 12
		static let body: CGFloat = 13
	}

	/// All text goes through here so the typeface can change in one place.
	static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
		.system(size: size, weight: weight)
	}

	/// Extra leading for reading text.
	static let lineSpacing: CGFloat = 5

	/// `--card`: no borders in this style — blocks are told apart by a soft fill alone.
	static let surface = Color.primary.opacity(0.06)
	/// `--border` is absent on purpose; the card overlay uses a clear stroke of zero width.
	static let border = Color.clear
	static let borderWidth: CGFloat = 0
	/// `--accent`: the hover fill of an icon button.
	static let hover = Color.primary.opacity(0.07)
	/// `--destructive`: failures only. Warnings and hints stay neutral.
	static let destructive = Color(nsColor: .systemRed)
}
