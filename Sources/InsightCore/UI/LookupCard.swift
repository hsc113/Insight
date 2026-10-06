import SwiftUI

/// A compact overlay for looking up a word selected inside the result.
///
/// Kept separate from the main panel: swapping the whole panel for a one-word lookup would
/// throw away the translation the user was in the middle of reading.
struct LookupCard: View {
	let word: String
	let pipeline: InsightPipeline
	let onClose: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack(spacing: 6) {
				Image(systemName: "magnifyingglass")
					.font(.system(size: 10, weight: .medium))
					.foregroundStyle(.tertiary)

				Text(word)
					.font(.system(size: 13, weight: .semibold))
					.lineLimit(1)

				Spacer(minLength: 8)

				if pipeline.translationPhase == .done && !pipeline.translation.isEmpty {
					Button {
						NSPasteboard.general.clearContents()
						NSPasteboard.general.setString(pipeline.translation, forType: .string)
					} label: {
						Image(systemName: "doc.on.doc")
							.font(.system(size: 10))
					}
					.buttonStyle(.plain)
					.foregroundStyle(.secondary)
					.help("复制")
				}

				Button(action: onClose) {
					Image(systemName: "xmark")
						.font(.system(size: 10))
				}
				.buttonStyle(.plain)
				.foregroundStyle(.secondary)
				.help("关闭 esc")
			}

			Divider().opacity(0.4)

			if pipeline.summary.isEmpty, pipeline.translation.isEmpty {
				HStack(spacing: 6) {
					ProgressView().controlSize(.small).scaleEffect(0.6)
					Text("查询中…")
						.font(.system(size: 11))
						.foregroundStyle(.tertiary)
				}
			} else {
				if !pipeline.summary.isEmpty {
					Text(pipeline.summary)
						.font(.system(size: 12))
						.foregroundStyle(.secondary)
						.lineSpacing(2)
				}
				Text(pipeline.translation)
					.font(.system(size: 13))
					.lineSpacing(3)
					.textSelection(.enabled)
					.frame(maxWidth: .infinity, alignment: .leading)
			}
		}
		.padding(14)
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		.background(.regularMaterial)
	}
}
