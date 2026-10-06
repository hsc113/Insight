import Foundation
import Network

/// Minimal chunked HTTP/1.1 server for tests.
///
/// A real socket rather than a `URLProtocol` stub on purpose: the thing most likely to be wrong
/// in `SSEClient` is how it reassembles bytes that arrive in arbitrary 1-byte-to-4KB chunks with
/// `\r\n` line endings, and only a real transport reproduces that.
final class TestHTTPServer {
	struct Response {
		var status = 200
		var contentType = "text/plain"
		var body: Data = Data()
		/// When set, the body is written in these slices with a pause between them.
		var chunks: [Data] = []
	}

	private let listener: NWListener
	private(set) var port: UInt16 = 0
	private var routes: [(String, Response)] = []

	init() throws {
		let parameters = NWParameters.tcp
		parameters.allowLocalEndpointReuse = true
		listener = try NWListener(using: parameters, on: .any)
	}

	func start() async throws {
		let ready = expectation(description: "listener ready")
		listener.stateUpdateHandler = { state in
			if case .ready = state { ready.fulfill() }
		}
		listener.newConnectionHandler = { [weak self] connection in
			self?.serve(connection)
		}
		listener.start(queue: .global(qos: .userInitiated))
		await fulfillment(of: [ready], timeout: 5)

		port = listener.port?.rawValue ?? 0
	}

	func stub(path: String, response: Response) {
		routes.append((path, response))
	}

	func stubSSE(path: String, payloads: [String], chunkDelay: Duration = .milliseconds(12)) {
		var body = Data()
		for payload in payloads { body.append(Data("data: \(payload)\n\n".utf8)) }
		body.append(Data("data: [DONE]\n\n".utf8))
		stub(path: path, response: Response(contentType: "text/event-stream", chunks: [body]))
	}

	func baseURL(_ path: String) -> String { "http://127.0.0.1:\(port)\(path)" }

	private func serve(_ connection: NWConnection) {
		connection.start(queue: .global(qos: .userInitiated))
		readRequest(on: connection, buffer: Data(), attemptsLeft: 32) { request in
			guard let request else {
				connection.cancel()
				return
			}
			let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
			let response = self.routes.first { $0.0 == path }?.1
				?? Response(status: 404, body: Data("not found".utf8))
			self.write(response, on: connection)
		}
	}

	/// Reads until the headers are complete **and** the declared body has arrived.
	///
	/// Answering as soon as `\r\n\r\n` shows up is the second of the two ways this server used to
	/// lose a connection under concurrency: the client is still writing its POST body, gets a
	/// response followed by a close, and fails its own write with `EPIPE`. The prompts Insight sends
	/// are a few kilobytes, which is exactly the size range where this shows up — and it surfaced as
	/// a flaky *pipeline* assertion, never as a server one.
	///
	/// These responses are written with `Content-Length`, so the declared length is authoritative.
	/// A request without one (every GET here) is answered immediately.
	private func readRequest(
		on connection: NWConnection, buffer: Data, attemptsLeft: Int,
		then body: @escaping (String?) -> Void
	) {
		connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
			data, _, isComplete, error in
			guard error == nil else {
				connection.cancel()
				return
			}
			var accumulated = buffer
			if let data { accumulated.append(data) }

			guard let headerEnd = accumulated.range(of: Data("\r\n\r\n".utf8)) else {
				guard !isComplete, attemptsLeft > 0 else {
					connection.cancel()
					return
				}
				self.readRequest(
					on: connection, buffer: accumulated, attemptsLeft: attemptsLeft - 1, then: body)
				return
			}

			let header = String(decoding: accumulated[..<headerEnd.lowerBound], as: UTF8.self)
			if let expected = Self.contentLength(in: header) {
				let received = accumulated.distance(
					from: headerEnd.upperBound, to: accumulated.endIndex)
				if received < expected, !isComplete, attemptsLeft > 0 {
					self.readRequest(
						on: connection, buffer: accumulated, attemptsLeft: attemptsLeft - 1,
						then: body)
					return
				}
			}
			body(header)
		}
	}

	/// The declared body length, or `nil` when there isn't one.
	///
	/// Static and pure so the checker can assert it against hand-written headers, rather than
	/// inferring its behaviour from whether a request happened to work.
	static func contentLength(in header: String) -> Int? {
		for line in header.split(separator: "\r\n") {
			let parts = line.split(
				separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
			guard parts.count == 2 else { continue }
			let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
			guard name == "content-length" else { continue }
			return Int(parts[1].trimmingCharacters(in: .whitespaces))
		}
		return nil
	}

	private func write(_ response: Response, on connection: NWConnection) {
		let pieces = response.chunks.isEmpty ? [response.body] : response.chunks
		let total = pieces.reduce(0) { $0 + $1.count }
		let header = [
			"HTTP/1.1 \(response.status) OK",
			"Content-Type: \(response.contentType)",
			"Content-Length: \(total)",
			"Connection: close",
			"", "",
		].joined(separator: "\r\n")
		connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] _ in
			guard let self else { return }
			// Dribble a few bytes at a time. The client's buffer only flushes every 4096 bytes, so
			// deliberately awkward write sizes are the whole point of using a real socket.
			self.send(Array(pieces), on: connection)
		})
	}

	/// Dribbles the body out three bytes at a time, then closes.
	private func send(_ pieces: [Data], on connection: NWConnection) {
		// Empty slices are dropped here, explicitly. This used to fall out of the guard by accident:
		// after the last three bytes, `Data(head.dropFirst(size))` is an *empty* `Data`, which became
		// `pieces.first`, failed `!head.isEmpty`, and reached `connection.cancel()`.
		let pending = pieces.filter { !$0.isEmpty }
		guard let head = pending.first else {
			// `cancel()` is all Network.framework offers, and it is **abortive** — it sends RST rather
			// than FIN whenever the socket still has unread received data. That was the flake: the
			// response was responding after only the headers, so the rest of a multi-kilobyte POST
			// body was sitting unread in the receive buffer, and tearing down with data pending turned
			// the client's orderly end-of-stream into `NSURLErrorNetworkConnectionLost (-1005)`.
			//
			// `readRequest` now drains to `Content-Length` first, so by this point there is nothing
			// left to reset over and `cancel()` degrades into a plain FIN. Two independent fixes: the
			// drain (the real cause) and the explicit empty-slice filter (which had been reaching the
			// same branch by accident rather than by design).
			connection.cancel()
			return
		}
		let size = min(3, head.count)
		connection.send(content: head.prefix(size), completion: .contentProcessed { [weak self] _ in
			self?.send([Data(head.dropFirst(size))] + pending.dropFirst(), on: connection)
		})
	}

	func stop() {
		listener.cancel()
	}
}

// MARK: - Minimal async helpers (no XCTest dependency)

func expectation(description: String) -> Expectation {
	Expectation(description: description)
}

final class Expectation {
	private var isFulfilled = false
	private let lock = NSLock()
	let description: String

	init(description: String) { self.description = description }

	func fulfill() {
		lock.withLock { isFulfilled = true }
	}

	var fulfilled: Bool { lock.withLock { isFulfilled } }
}

func fulfillment(of expectations: [Expectation], timeout: TimeInterval) async {
	let deadline = Date().addingTimeInterval(timeout)
	while Date() < deadline {
		if expectations.allSatisfy(\.fulfilled) { return }
		try? await Task.sleep(nanoseconds: 10_000_000)
	}
}