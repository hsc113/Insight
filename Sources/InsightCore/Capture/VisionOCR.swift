@preconcurrency import Vision
import AppKit

/// Offline OCR via the Vision framework.
///
/// The recognition request is what costs time, and the very first one in a fresh process pays
/// for compiling the model — a 60–120s cold start. `warmUp` absorbs that on
/// a background queue shortly after launch.
enum VisionOCR {
	private static let lock = NSLock()
	private static var warmed = false

	static var isWarmedUp: Bool { lock.withLock { warmed } }

	static func warmUp() {
		// Off the critical path and at the lowest useful priority: this is speculative work
		// that must never show up as a hitch when the user presses ⌥S.
		DispatchQueue.global(qos: .utility).async {
			let request = VNRecognizeTextRequest()
			request.recognitionLevel = .fast
			request.usesLanguageCorrection = false
			request.automaticallyDetectsLanguage = false
			request.recognitionLanguages = ["en-US"]

			let size = CGSize(width: 48, height: 48)
			let image = NSImage(size: size)
			image.lockFocus()
			NSColor.white.setFill()
			NSRect(origin: .zero, size: size).fill()
			image.unlockFocus()

			guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
				return
			}
			try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
			lock.withLock { warmed = true }
			Log.ocr("warmed up")
		}
	}

	static func recognize(_ image: CGImage) async throws -> String {
		let request = VNRecognizeTextRequest()
		request.recognitionLevel = .accurate
		request.usesLanguageCorrection = true
		// Let Vision pick the recognition language per image. Screenshot translation means the
		// source can be anything, and the fixed `recognitionLanguages` list has to be filtered
		// against whatever this OS build supports or Vision throws.
		request.automaticallyDetectsLanguage = true

		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			DispatchQueue.global(qos: .userInitiated).async {
				do {
					try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
					continuation.resume()
				} catch {
					continuation.resume(throwing: error)
				}
			}
		}

		guard let observations = request.results, !observations.isEmpty else {
			throw NetError.notConfigured("没有识别到文字")
		}
		let text = assemble(observations)
		guard !text.isEmpty else { throw NetError.notConfigured("没有识别到文字") }
		return text
	}

	// MARK: - Layout

	private struct Line {
		var text: String
		var box: CGRect  // Vision-normalised, origin bottom-left
	}

	/// Vision returns observations in detection order, which follows neither reading order nor
	/// paragraph structure. Sorting by vertical position and rejoining wrapped lines is enough
	/// to turn a screenshot of prose back into readable paragraphs.
	private static func assemble(_ observations: [VNRecognizedTextObservation]) -> String {
		let lines: [Line] = observations.compactMap { observation in
			guard let candidate = observation.topCandidates(1).first else { return nil }
			return Line(text: candidate.string, box: observation.boundingBox)
		}
		guard !lines.isEmpty else { return "" }

		let sorted = lines.sorted { a, b in
			if abs(a.box.maxY - b.box.maxY) > 0.004 { return a.box.maxY > b.box.maxY }
			return a.box.minX < b.box.minX
		}

		// Median line height drives the "same paragraph?" test; the mean gets pulled around by
		// headings and single-line captions.
		let heights = sorted.map(\.box.height).sorted()
		let medianHeight = heights[heights.count / 2]

		var paragraphs: [String] = []
		var current: [String] = []

		for (index, line) in sorted.enumerated() {
			guard index > 0 else {
				current.append(line.text)
				continue
			}
			let gap = sorted[index - 1].box.minY - line.box.maxY
			if gap < medianHeight * 0.55 {
				current[current.count - 1] = join(current[current.count - 1], line.text)
			} else {
				paragraphs.append(current.joined(separator: "\n"))
				current = [line.text]
			}
		}
		if !current.isEmpty { paragraphs.append(current.joined(separator: "\n")) }

		return paragraphs
			.joined(separator: "\n\n")
			.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// Latin text needs a space when a line wraps mid-sentence; CJK does not.
	private static func join(_ lhs: String, _ rhs: String) -> String {
		guard let a = lhs.last, let b = rhs.first else { return lhs + rhs }
		let needsSpace = a.isASCII && a.isLetter && b.isASCII && b.isLetter
		return needsSpace ? lhs + " " + rhs : lhs + rhs
	}
}