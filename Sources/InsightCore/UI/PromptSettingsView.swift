import AppKit
import SwiftUI

/// Editing for both prompts: one editor per half, nothing to pick between.
///
/// The layout is a slot switcher over a form rather than the list-plus-editor it used to be. That
/// list existed to choose between three built-ins and the user's own copies; with one prompt per
/// slot it would have been a one-row table, which reads as a bug. What is left is the part that
/// was doing the work: the text is long — a summary prompt is ~20 lines of Chinese, a translation
/// prompt is English prose with `{{…}}` in it — so it gets the full width and its own scroll.
///
/// Edits are held in a local `@State` copy and pushed to `Settings` on every change, the same way
/// every other text field in this settings window behaves. The copy matters for one specific
/// reason: 还原 has to be able to throw the in-flight edit away, and a field bound straight
/// through to the store would have nothing to discard.
struct PromptSettings: View {
	@State private var slot: PromptSlot = .summary
	@State private var draft: PromptPreset?

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Picker("", selection: $slot) {
				ForEach(PromptSlot.allCases) { item in
					Label(item.displayName, systemImage: item.symbol).tag(item)
				}
			}
			.pickerStyle(.segmented)
			.labelsHidden()
			.frame(width: 180)
			// The draft belongs to the half that was being edited, so switching halves has to
			// reload it — otherwise the summary text would still be in the fields while the
			// switcher says 翻译, and the next keystroke would write it to the translation prompt.
			.onChange(of: slot) { _, _ in loadDraft() }

			Divider()

			if draft != nil {
				ScrollView {
					VStack(alignment: .leading, spacing: 12) {
						editorRow(
							title: "角色设定",
							subtitle: "发给模型的 system 消息。留空会回落到出厂设定。",
							text: textBinding(\.system))
						editorRow(
							title: "输出要求",
							subtitle: "发给模型的 user 消息，末尾会自动附上原文。",
							text: textBinding(\.user))
						placeholderLegend
						preview
						restoreRow
					}
					.padding(.vertical, 2)
				}
			}
		}
		.padding(.horizontal, 20)
		.padding(.bottom, 20)
		// Fills the column, like every other page — see `InterfaceSettings` for why there is no
		// 560pt cap any more. The prompt is long prose, so the extra width is welcome rather than
		// awkward, and a capped page left a band of empty window down the right-hand side.
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		.onAppear { loadDraft() }
	}

	// MARK: - Editor

	private func editorRow(
		title: String, subtitle: String, text: Binding<String>
	) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack(alignment: .firstTextBaseline, spacing: 8) {
				Text(title)
					.font(.system(size: 12, weight: .medium))
				Text(subtitle)
					.font(.system(size: 10))
					.foregroundStyle(.tertiary)
			}
			TextEditor(text: text)
				.font(.system(size: 11.5))
				.scrollContentBackground(.hidden)
				.frame(minHeight: 148)
				.padding(5)
				.background(
					RoundedRectangle(cornerRadius: 6)
						.fill(Color.primary.opacity(0.05))
				)
				.overlay(
					RoundedRectangle(cornerRadius: 6)
						.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
				)
		}
	}

	private var placeholderLegend: some View {
		VStack(alignment: .leading, spacing: 3) {
			Text("可用占位符")
				.font(.system(size: 10, weight: .medium))
				.foregroundStyle(.secondary)
			// Filtered by slot rather than listing all six: a summary author has no use for
			// `{{targetLanguage}}`, and offering it is how a placeholder ends up in a prompt where
			// it resolves to nothing.
			Text(PromptTemplate.keys(for: slot).map { PromptTemplate.token($0) }
				.joined(separator: "  "))
				.font(.system(size: 10).monospaced())
				.foregroundStyle(.tertiary)
				.textSelection(.enabled)
				.fixedSize(horizontal: false, vertical: true)
		}
	}

	private var preview: some View {
		VStack(alignment: .leading, spacing: 4) {
			Text("实际发送的内容")
				.font(.system(size: 10, weight: .medium))
				.foregroundStyle(.secondary)
			ScrollView {
				Text(previewText)
					.font(.system(size: 10.5).monospaced())
					.textSelection(.enabled)
					.frame(maxWidth: .infinity, alignment: .topLeading)
					.padding(7)
			}
			.frame(height: 130)
			.background(
				RoundedRectangle(cornerRadius: 6)
					.fill(Color.primary.opacity(0.04))
			)
			.overlay(
				RoundedRectangle(cornerRadius: 6)
					.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
			)
		}
	}

	/// One button, and it is disabled until there is something to restore.
	///
	/// There is no second button any more: with nothing to create and nothing to delete, "restore"
	/// is the only action this page has, and a disabled button that says so is a better answer to
	/// "did I change this?" than a marker somewhere else on the page.
	private var restoreRow: some View {
		HStack(spacing: 8) {
			Button {
				Settings.shared.restorePrompt(slot)
				loadDraft()
			} label: {
				Text("还原为初始提示词")
			}
			.controlSize(.small)
			.disabled(!Settings.shared.isPromptModified(slot))

			Text(
				Settings.shared.isPromptModified(slot)
					? "还原会把这一项恢复到出厂状态，改动无法撤销" : "当前就是初始提示词"
			)
			.font(.system(size: 10))
			.foregroundStyle(.tertiary)
			Spacer()
		}
	}

	// MARK: - Wiring

	/// A binding that writes through to `Settings` and keeps the local copy in step.
	///
	/// `WritableKeyPath` rather than a closure per field so adding a field to `PromptPreset`
	/// doesn't mean adding a third binding here.
	private func textBinding(_ keyPath: WritableKeyPath<PromptPreset, String>) -> Binding<String> {
		Binding(
			get: { draft?[keyPath: keyPath] ?? "" },
			set: { newValue in
				guard var current = draft else { return }
				current[keyPath: keyPath] = newValue
				draft = current
				Settings.shared.updatePrompt(current)
			})
	}

	private func loadDraft() {
		draft = Settings.shared.prompt(for: slot)
	}

	// MARK: - Preview

	/// The request the current draft would produce, with a fixed sample in place of the real
	/// source. Purely for reading: it shows the placeholders resolved and the fences in place,
	/// which is the only way to catch a `{{targetLanguage}}` pasted into a summary prompt before
	/// it silently sends an empty string to the model.
	private var previewText: String {
		guard let draft else { return "" }
		let sample = "这是用来预览提示词的示例原文。Insight 在这里填入真实选中的文字。"
		switch draft.slot {
		case .summary:
			let request = Prompts.summary(
				prompt: draft,
				context: .summary(
					input: sample,
					languageName: Languages.name(Settings.shared.summaryLanguage),
					maxChars: Settings.shared.summaryMaxChars))
			return request.system + "\n\n——— user ———\n\n" + request.user
		case .translation:
			let request = Prompts.translate(
				prompt: draft,
				context: .translate(
					input: sample,
					sourceName: "English ",
					targetName: Languages.englishName(Settings.shared.targetLanguage)))
			return request.system + "\n\n——— user ———\n\n" + request.user
		}
	}
}
