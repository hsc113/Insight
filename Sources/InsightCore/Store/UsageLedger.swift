import Foundation

/// One calendar day's counters.
///
/// **Why this is a per-day bucket rather than a scan of the history.** The history list is
/// deliberately short — 50 rows by default, 1000 at most — because its job is "find that
/// translation from ten minutes ago". Deriving "近 30 天的用量" from it would silently under-report
/// by whatever fell off the end, and it would under-report *differently every day*, which is worse
/// than being wrong: the number moves because the data was trimmed, not because usage changed.
/// Buckets are independent of the retention limit, so the two features can't distort each other.
struct UsageDay: Codable, Identifiable, Equatable, Sendable {
	/// The day key is the identity: there is one bucket per day, by construction.
	var id: String { day }

	/// `yyyy-MM-dd` in the user's calendar.
	var day: String
	/// Requests sent to the LLM provider — the summary chain, plus the translation chain when the
	/// engine *is* the model.
	var llmCalls = 0
	/// Requests sent to 百度 / 腾讯 / DeepL. Apple 系统翻译 is local and free, so it counts as none.
	var mtCalls = 0
	/// The text the user handed us, i.e. the selection or the OCR result.
	var inputChars = 0
	var summaryChars = 0
	var translationChars = 0
	/// Chains that gave up. Shown as a rate next to the call count — a summary that fails four
	/// times out of five is five calls and one summary.
	var failures = 0

	var outputChars: Int { summaryChars + translationChars }
	var totalCalls: Int { llmCalls + mtCalls }

	/// How many buckets to keep. A year is far more than any of the displayed ranges needs, and the
	/// file stays a couple of kilobytes, so there is no reason to let it grow unbounded.
	static let retainedBuckets = 400

	// MARK: - Day keys

	/// `yyyy-MM-dd` in the user's calendar, and *their* calendar — a day boundary is a local
	/// concept, so UTC would file the morning under the wrong bucket.
	static func key(_ date: Date = Date()) -> String {
		let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
		return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
	}

	/// Arithmetic on `yyyy-MM-dd` rather than through `DateFormatter`, which is both slower and
	/// locale-sensitive. A formatter that silently starts emitting `"2026/10/05"` would break
	/// every stored key at once, and the breakage would look like "my history vanished".
	static func shift(_ day: String, by delta: Int) -> String? {
		let parts = day.split(separator: "-").compactMap { Int($0) }
		guard parts.count == 3 else { return nil }
		var components = DateComponents()
		components.year = parts[0]
		components.month = parts[1]
		components.day = parts[2]
		guard let base = Calendar.current.date(from: components),
			let shifted = Calendar.current.date(byAdding: .day, value: delta, to: base)
		else { return nil }
		return key(shifted)
	}

	static func isValidKey(_ day: String) -> Bool { shift(day, by: 0) != nil }
}

/// Which bill a request goes to.
enum UsageKind: Sendable {
	case llm
	case mt
}

/// Which slice of the ledger a total covers.
enum UsageRange: String, CaseIterable, Identifiable, Sendable {
	case today
	case yesterday
	case last7
	case last30
	case all

	var id: String { rawValue }

	var displayName: String {
		switch self {
		case .today: return "今天"
		case .yesterday: return "昨天"
		case .last7: return "近 7 天"
		case .last30: return "近 30 天"
		case .all: return "全部"
		}
	}

	/// - Parameter day: The bucket's key, compared against `today` in the user's calendar.
	func contains(_ day: String, today: String) -> Bool {
		switch self {
		case .today:
			return day == today
		case .yesterday:
			return day == UsageDay.shift(today, by: -1)
		case .last7:
			// Seven days *including* today, so the window ends at today and reaches back six.
			guard let earliest = UsageDay.shift(today, by: -6) else { return false }
			return day >= earliest && day <= today
		case .last30:
			guard let earliest = UsageDay.shift(today, by: -29) else { return false }
			return day >= earliest && day <= today
		case .all:
			return true
		}
	}
}

/// Summed counters. One struct rather than four separate numbers so a row of the stats table can't
/// show yesterday's calls next to today's characters.
struct UsageTotals: Equatable, Sendable {
	var llmCalls = 0
	var mtCalls = 0
	var inputChars = 0
	var summaryChars = 0
	var translationChars = 0
	var failures = 0

	var outputChars: Int { summaryChars + translationChars }
	var totalCalls: Int { llmCalls + mtCalls }

	static func sum(_ days: [UsageDay]) -> UsageTotals {
		var totals = UsageTotals()
		for day in days {
			totals.llmCalls += day.llmCalls
			totals.mtCalls += day.mtCalls
			totals.inputChars += day.inputChars
			totals.summaryChars += day.summaryChars
			totals.translationChars += day.translationChars
			totals.failures += day.failures
		}
		return totals
	}
}

/// Request counts, character counts, and their per-day buckets.
@MainActor
@Observable
final class UsageLedger {
	static let shared = UsageLedger()

	/// Ascending by day. `nil` until `load()` runs, which the app does at launch.
	private(set) var days: [UsageDay] = []

	/// Bumped on every mutation so the settings page redraws.
	private var saveTask: Task<Void, Never>?

	private init() {}

	nonisolated static var fileURL: URL {
		let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
		return base.appendingPathComponent("Insight/usage.json")
	}

	// MARK: - Recording

	/// One request going out.
	///
	/// Counted **when the request is issued, not when it completes**. A chain that is cancelled
	/// mid-stream or fails at the far end still consumed a request, and a usage screen that
	/// quietly omits those is not measuring spend — it is measuring success.
	func noteRequest(_ kind: UsageKind) {
		mutate { day in
			switch kind {
			case .llm: day.llmCalls += 1
			case .mt: day.mtCalls += 1
			}
		}
	}

	func noteInput(_ characters: Int) {
		guard characters > 0 else { return }
		mutate { $0.inputChars += characters }
	}

	func noteOutput(summary: Int, translation: Int) {
		guard summary > 0 || translation > 0 else { return }
		mutate {
			$0.summaryChars += summary
			$0.translationChars += translation
		}
	}

	func noteFailure() {
		mutate { $0.failures += 1 }
	}

	private func mutate(_ body: (inout UsageDay) -> Void) {
		let key = UsageDay.key()
		if let index = days.firstIndex(where: { $0.day == key }) {
			body(&days[index])
		} else {
			var day = UsageDay(day: key)
			body(&day)
			// Keep ascending so `last(...)` and the bar chart don't have to sort.
			days.append(day)
			days.sort { $0.day < $1.day }
		}
		days = Self.pruned(days)
		scheduleSave()
	}

	/// Drops the oldest buckets past the retention limit.
	nonisolated static func pruned(
		_ days: [UsageDay], keeping limit: Int = UsageDay.retainedBuckets
	) -> [UsageDay] {
		days.count <= limit ? days : Array(days.suffix(limit))
	}

	// MARK: - Reading

	func totals(_ range: UsageRange, today: String = UsageDay.key()) -> UsageTotals {
		UsageTotals.sum(days.filter { range.contains($0.day, today: today) })
	}

	/// The buckets inside a range, oldest first — what the bar chart draws.
	func days(in range: UsageRange, today: String = UsageDay.key()) -> [UsageDay] {
		days.filter { range.contains($0.day, today: today) }
	}

	func clear() {
		days = []
		saveNow()
	}

	// MARK: - Persistence

	func load() {
		guard Settings.persistenceEnabled else { return }
		guard let data = try? Data(contentsOf: Self.fileURL),
			let decoded = try? JSONDecoder().decode([UsageDay].self, from: data)
		else { return }
		// Re-sorted and re-pruned on the way in: the file is hand-editable and an out-of-order or
		// over-long list would make every range total quietly wrong.
		days = Self.pruned(decoded.sorted { $0.day < $1.day })
	}

	private func scheduleSave() {
		guard Settings.persistenceEnabled else { return }
		saveTask?.cancel()
		saveTask = Task { [weak self] in
			try? await Task.sleep(nanoseconds: 500_000_000)
			guard !Task.isCancelled else { return }
			self?.saveNow()
		}
	}

	func saveNow() {
		saveTask?.cancel()
		saveTask = nil
		guard Settings.persistenceEnabled else { return }
		guard let data = try? JSONEncoder().encode(days) else { return }
		try? FileManager.default.createDirectory(
			at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
		try? data.write(to: Self.fileURL, options: Data.WritingOptions.atomic)
	}
}