import AppKit
import SwiftUI

/// Four numbers and a per-day bar chart.
///
/// The four the user asked for are the tiles — 大模型调用, 翻译接口调用, 输入字数, 输出字数 — and the
/// breakdown under them (总结/译文字数, 失败次数) is there because "输出字数" alone can't explain a
/// bill. Failures are shown as a rate next to the call count for the same reason: a summary that
/// fails four times in five is five calls and one summary, and a bare count hides that.
///
/// **Plain `Rectangle`s, not Charts.** Four series and one axis do not need a charting framework,
/// and `import Charts` would pull in a dependency for something a `GeometryReader` draws in twenty
/// lines — while making the axis hard to customise for the one thing this page needs from it,
/// which is a two-character label per bar.
struct UsageSettings: View {
	@State private var range: UsageRange = .today
	@State private var confirmClear = false

	private var ledger: UsageLedger { UsageLedger.shared }

	private var totals: UsageTotals { ledger.totals(range) }

	var body: some View {
		let totals = totals

		VStack(alignment: .leading, spacing: 12) {
			rangePicker
			Divider()
			HStack(alignment: .top, spacing: 14) {
				tiles(totals)
					.frame(width: 260)
				chart
			}
		}
		.padding(.horizontal, 20)
		.padding(.bottom, 20)
		.frame(maxWidth: .infinity, alignment: .leading)
		.onAppear { ledger.load() }
	}

	private var rangePicker: some View {
		HStack(spacing: 8) {
			Text("统计区间")
				.font(.system(size: 12))
			Picker("", selection: $range) {
				ForEach(UsageRange.allCases) { item in
					Text(item.displayName).tag(item)
				}
			}
			.labelsHidden()
			.frame(width: 120)
			Spacer()
			Button(role: .destructive) {
				confirmClear = true
			} label: {
				Text("清空统计")
			}
			.controlSize(.small)
			.disabled(ledger.days.isEmpty)
			.confirmationDialog(
				"清空全部用量统计？此操作不可撤销。",
				isPresented: $confirmClear, titleVisibility: .visible
			) {
				Button("清空", role: .destructive) { ledger.clear() }
				Button("取消", role: .cancel) {}
			}
		}
	}

	// MARK: - Tiles

	private func tiles(_ totals: UsageTotals) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			UsageTile(
				title: "大模型调用", value: totals.llmCalls, unit: "次",
				icon: "sparkles", tint: .purple,
				footnote: totals.failures > 0 ? "失败 \(totals.failures) 次" : nil)
			UsageTile(
				title: "翻译接口调用", value: totals.mtCalls, unit: "次",
				icon: "character.book.closed", tint: .teal,
				footnote: totals.mtCalls == 0 && totals.llmCalls > 0
					? "翻译走的是大模型，不另计" : nil)
			UsageTile(
				title: "输入字数", value: totals.inputChars, unit: "字",
				icon: "text.cursor", tint: .blue, footnote: nil)
			UsageTile(
				title: "输出字数", value: totals.outputChars, unit: "字",
				icon: "text.append", tint: .green,
				footnote: "总结 \(totals.summaryChars) · 翻译 \(totals.translationChars)")

			if totals.totalCalls > 0 {
				Text(
					"平均每次调用输出 \(Int((Double(totals.outputChars) / Double(totals.totalCalls)).rounded())) 字"
				)
				.font(.system(size: 10))
				.foregroundStyle(.tertiary)
				.padding(.top, 2)
			}
			Spacer()
		}
	}

	// MARK: - Chart

	private var chart: some View {
		let all = ledger.days(in: range)
		let shown = Array(all.suffix(Self.maxBars))

		return VStack(alignment: .leading, spacing: 6) {
			HStack {
				Text("每天的调用次数")
					.font(.system(size: 12, weight: .medium))
				Spacer()
				Text("\(shown.count) 天")
					.font(.system(size: 10).monospacedDigit())
					.foregroundStyle(.tertiary)
			}

			if shown.isEmpty {
				Text(range == .all ? "还没有任何用量记录" : "这个区间内没有记录")
					.font(.system(size: 11))
					.foregroundStyle(.secondary)
					.frame(maxWidth: .infinity, maxHeight: 120)
			} else {
				GeometryReader { proxy in
					let peak = max(1, shown.map(\.totalCalls).max() ?? 1)
					let slot = proxy.size.width / CGFloat(shown.count)
					let barWidth = max(2, min(14, slot - 3))
					HStack(alignment: .bottom, spacing: (slot - barWidth).rounded()) {
						ForEach(shown) { day in
							VStack(spacing: 3) {
								Rectangle()
									.fill(Color.accentColor.opacity(0.75))
									.frame(
										width: barWidth,
										// A 2pt floor so a day with one call is still visible —
										// a zero-height bar reads as "no data", not "one call".
										height: max(
											2, proxy.size.height * CGFloat(day.totalCalls) / CGFloat(peak)))
								Text(Self.shortDay(day.day))
									.font(.system(size: 8).monospacedDigit())
									.foregroundStyle(.tertiary)
							}
							.help("\(day.day)\n调用 \(day.totalCalls) 次\n输入 \(day.inputChars) 字\n输出 \(day.outputChars) 字")
						}
					}
					.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
				}
				.frame(height: 150)

				if all.count > Self.maxBars {
					// 400 retained buckets is a lot to draw on 500pt. Saying so beats silently
					// showing the most recent 30 and letting "近 30 天" look like the whole range.
					Text("仅显示最近 \(Self.maxBars) 天，共 \(all.count) 天有记录")
						.font(.system(size: 10))
						.foregroundStyle(.tertiary)
				}
			}
			Spacer()
		}
		.frame(maxWidth: .infinity, alignment: .topLeading)
		.padding(10)
		.background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
	}

	static let maxBars = 30

	static func shortDay(_ day: String) -> String {
		// "2026-10-05" → "10-05". Fixed-width by construction, so the two components are always
		// the last five characters.
		day.count >= 10 ? String(day.suffix(5)) : day
	}
}

private struct UsageTile: View {
	let title: String
	let value: Int
	let unit: String
	let icon: String
	let tint: Color
	var footnote: String?

	var body: some View {
		VStack(alignment: .leading, spacing: 2) {
			HStack(spacing: 5) {
				Image(systemName: icon)
					.font(.system(size: 10))
					.foregroundStyle(tint)
				Text(title)
					.font(.system(size: 11))
					.foregroundStyle(.secondary)
				Spacer()
			}
			HStack(alignment: .firstTextBaseline, spacing: 3) {
				Text(value.formatted(.number.grouping(.automatic)))
					.font(.system(size: 20, weight: .medium, design: .rounded))
					.monospacedDigit()
				Text(unit)
					.font(.system(size: 10))
					.foregroundStyle(.tertiary)
				Spacer()
			}
			if let footnote {
				Text(footnote)
					.font(.system(size: 9))
					.foregroundStyle(.tertiary)
					.lineLimit(1)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(.horizontal, 10)
		.padding(.vertical, 7)
		.background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
	}
}