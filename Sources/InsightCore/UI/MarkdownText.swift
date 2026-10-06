import SwiftUI

/// Renders the small, fixed subset of Markdown that the summary prompt asks for.
///
/// # Why not just `AttributedString(markdown:)`
///
/// That initializer does the *inline* half perfectly — `**bold**`, `*italic*`, `` `code` ``,
/// `[links](…)` — and there is no reason to hand-roll any of it. What it cannot do is **blocks**:
/// it leaves `- item` as a literal dash followed by a run of text, which in a narrow panel reads
/// as a wrapped paragraph rather than a list, and gives wrapped lines no hanging indent.
///
/// So the split is: this file decides what each *line* is (gist, bullet, plain paragraph) and lays
/// the lines out; the system decides how each line's *inline* markup is styled.
///
/// # Only a few block types
///
/// The prompt asks for a gist line and `- ` bullets, and nothing else. A parser that also
/// understood headings, tables, block quotes and nested lists would be a liability: every extra
/// rule is another way for an unexpected token to silently become structure, and the summary panel
/// has no use for any of it. Anything unrecognised degrades to a plain paragraph.
///
/// # Streaming
///
/// Text arrives a few tokens at a time, so the opening `**` of a bold run reaches the view long
/// before its partner. Styling that half-written line makes the emphasis blink on and off with
/// every token. So while the summary is still streaming, the **last** block is drawn as plain
/// text; it only gets styled once the pipeline says it is finished. By then every marker is
/// balanced and `AttributedString` never has to guess.
///
/// Whether the last block is styled is decided by the caller passing the real pipeline phase
/// rather than by sniffing for a trailing newline — a completed summary usually *doesn't* end in
/// one, so that heuristic would leave the final line permanently unstyled.
struct MarkdownText: View {
	let text: String
	/// The summary phase. Only `.streaming` withholds styling from the last block.
	let phase: InsightPipeline.Phase

	/// Bullet indentation, in points. Also the width the bullet glyph is pinned to.
	private static let bulletInset: CGFloat = 15

	var body: some View {
		// A `VStack` of rows rather than one concatenated `Text`: each block needs its own weight
		// and hanging indent, which a single `Text` can't express.
		VStack(alignment: .leading, spacing: 0) {
			ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
				row(for: block)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.textSelection(.enabled)
	}

	// MARK: - Blocks

	enum Block: Equatable {
		/// The one-line gist, rendered slightly heavier so the panel keeps a visual entry point now
		/// that a list follows it.
		case gist(String)
		case bullet(String)
		case paragraph(String)
		/// A block whose inline markup is not yet trustworthy because it is still being written.
		case pending(String)

		var text: String {
			switch self {
			case .gist(let value), .bullet(let value), .paragraph(let value),
				.pending(let value):
				return value
			}
		}
	}

	private static let bulletPrefix = "- "

	/// Classifies each line. Exposed to the checker, which asserts on this directly rather than on
	/// pixels.
	static func blocks(from raw: String) -> [Block] {
		var result: [Block] = []
		for line in raw.components(separatedBy: .newlines) {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			guard !trimmed.isEmpty else { continue }
			// A bullet that lost its content mid-stream — or was emitted empty — is dropped rather
			// than rendered as a paragraph containing a stray dash.
			if trimmed == bulletPrefix.trimmingCharacters(in: .whitespaces) { continue }
			if trimmed.hasPrefix(bulletPrefix) {
				let body = String(trimmed.dropFirst(bulletPrefix.count))
					.trimmingCharacters(in: .whitespaces)
				if !body.isEmpty { result.append(.bullet(body)) }
			} else {
				// The first non-bullet line is the gist by definition; anything later that isn't a
				// bullet is a stray paragraph, and rendering it as a paragraph is the safe reading.
				result.append(result.isEmpty ? .gist(trimmed) : .paragraph(trimmed))
			}
		}
		return result
	}

	/// The blocks to draw.
	private var blocks: [Block] {
		let parsed = Self.blocks(from: text)
		guard phase == .streaming, let last = parsed.last else { return parsed }
		// A bullet keeps its marker even while pending — dropping it would make the list visibly
		// grow a bullet per line as the text streams in. Only the inline styling is withheld.
		return Array(parsed.dropLast()) + [.pending(last.text)]
	}

	// MARK: - Rows

	@ViewBuilder
	private func row(for block: Block) -> some View {
		switch block {
		case .gist(let value):
			styled(value, fallbackSize: 13.5)
				.font(.system(size: 13.5, weight: .medium))
				.fixedSize(horizontal: false, vertical: true)
				.padding(.bottom, 7)
		case .bullet(let value):
			HStack(alignment: .firstTextBaseline, spacing: 6) {
				Text("•")
					.font(.system(size: 13))
					.foregroundStyle(.secondary)
					.frame(width: Self.bulletInset - 6, alignment: .leading)
				styled(value, fallbackSize: 13)
					.font(.system(size: 13))
					.fixedSize(horizontal: false, vertical: true)
					.frame(maxWidth: .infinity, alignment: .leading)
			}
			.padding(.bottom, 4)
		case .paragraph(let value):
			styled(value, fallbackSize: 13)
				.font(.system(size: 13))
				.fixedSize(horizontal: false, vertical: true)
				.padding(.bottom, 5)
		case .pending(let value):
			Text(value)
				.font(.system(size: 13))
				.fixedSize(horizontal: false, vertical: true)
				.padding(.bottom, 4)
		}
	}

	/// `AttributedString` markdown parsing, with a plain-text fallback.
	///
	/// The fallback is not defensive padding. A *finished* block always has balanced markers, but a
	/// model can still emit an unbalanced one — a stray `**` inside text it was quoting, say — and
	/// `AttributedString(markdown:)` throws on input it cannot parse. Losing the bold is fine;
	/// losing the whole summary is not.
	@ViewBuilder
	private func styled(_ value: String, fallbackSize: CGFloat) -> some View {
		if let attributed = try? AttributedString(markdown: value) {
			Text(attributed)
		} else {
			Text(value)
				.font(.system(size: fallbackSize))
		}
	}
}
