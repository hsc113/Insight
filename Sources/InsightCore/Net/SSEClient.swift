import CryptoKit
import Foundation

/// Minimal Server-Sent Events reader for OpenAI-compatible `stream: true` responses.
///
/// Two non-obvious details:
/// - `URLSession.bytes(for:)` yields one byte at a time, and paying the async-iterator cost per
///   byte is measurably slow across a long completion, so bytes accumulate into a buffer that is
///   scanned only once it holds a useful chunk.
/// - The buffer is scanned with plain integer indices rather than `Data` slices. After a partial
///   flush the slice's start index shifts, and relying on that costs an out-of-bounds trap.
enum SSEClient {
	private static let flushThreshold = 4096
	/// A server that never sends a newline must not be able to grow this without bound.
	private static let maxLineBytes = 1 << 20

	static func stream(
		request: URLRequest,
		onPayload: @Sendable @escaping (String) -> Void
	) async throws {
		let (bytes, response) = try await HTTP.session.bytes(for: request)

		if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
			var collected = Data()
			collected.reserveCapacity(4096)
			for try await byte in bytes {
				collected.append(byte)
				if collected.count > 64 * 1024 { break }
			}
			throw NetError.http(status: http.statusCode, body: HTTP.decodeErrorBody(collected))
		}

		// A plain byte array rather than `Data`. `Data` keeps a non-zero `startIndex` after
		// `removeFirst`, and its `subscript(Int)` traps for indices below that origin — which
		// is exactly what a scan starting at 0 does on the second flush.
		var buffer: [UInt8] = []
		buffer.reserveCapacity(1 << 16)

		for try await byte in bytes {
			try Task.checkCancellation()
			buffer.append(byte)
			if buffer.count >= flushThreshold {
				if drain(&buffer, onPayload: onPayload) { return }
			}
		}
		_ = drain(&buffer, onPayload: onPayload)
	}

	/// Consumes every complete line in `buffer`, leaving any trailing partial line behind.
	/// - Returns: `true` once the server signals `[DONE]`.
	@discardableResult
	private static func drain(
		_ buffer: inout [UInt8], onPayload: @Sendable @escaping (String) -> Void
	) -> Bool {
		let count = buffer.count
		guard count > 0 else { return false }

		var start = 0
		var index = 0
		var sawDone = false

		while index < count {
			guard buffer[index] == 0x0A else {
				index += 1
				continue
			}
			var end = index
			if end > start, buffer[end - 1] == 0x0D { end -= 1 }
			index += 1

			if end > start {
				let line = String(decoding: buffer[start..<end], as: UTF8.self)
				if line.hasPrefix("data:") {
					var payload = line.dropFirst(5)
					if payload.first == " " { payload = payload.dropFirst() }
					if payload == "[DONE]" {
						sawDone = true
					} else if !payload.isEmpty {
						onPayload(String(payload))
					}
				}
			}
			start = index
			if sawDone { break }
		}

		// Nothing has been terminated: guard against an unterminated line growing forever.
		if start == 0, count > maxLineBytes {
			buffer.removeAll(keepingCapacity: true)
			return false
		}
		if start > 0 { buffer.removeFirst(start) }
		return sawDone
	}
}