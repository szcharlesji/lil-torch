import Citadel
import Foundation
import NIOCore

/// One long-lived `bash` on Torch, fed commands over stdin.
///
/// Every exec through the Orin relay pays several seconds of session setup on
/// Torch, so we pay it once and frame each command's output with a random marker:
///
///     ( command ) </dev/null 2>"$err"; rc=$?
///     printf '\n@@LT-END <token> <rc> <base64 stderr>\n'
final class PersistentShell: @unchecked Sendable {
    private struct Request: Sendable {
        let command: String
        let reply: CheckedContinuation<CommandResult, Error>
    }

    private let requests: AsyncStream<Request>.Continuation
    private let task: Task<Void, Never>
    private let state = State()

    var isAlive: Bool { state.isAlive }

    init(client: SSHClient) {
        let (stream, continuation) = AsyncStream<Request>.makeStream()
        requests = continuation
        task = Task { [state] in
            await Self.serve(client: client, requests: stream, continuation: continuation, state: state)
        }
    }

    func run(_ command: String) async throws -> CommandResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { reply in
                if case .terminated = requests.yield(Request(command: command, reply: reply)) {
                    reply.resume(throwing: ShellClosed(stderr: ""))
                }
            }
        } onCancel: {
            // The shell may be mid-command; its framing can't be trusted any more.
            close()
        }
    }

    func close() {
        state.isAlive = false
        requests.finish()
        task.cancel()
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var _isAlive = true
        var isAlive: Bool {
            get { lock.withLock { _isAlive } }
            set { lock.withLock { _isAlive = newValue } }
        }
    }

    private static let setup = """
    __lt_err=$(mktemp); trap 'rm -f "$__lt_err"' EXIT; export TZ=UTC\n
    """

    private static func serve(
        client: SSHClient,
        requests: AsyncStream<Request>,
        continuation: AsyncStream<Request>.Continuation,
        state: State
    ) async {
        var pending = requests.makeAsyncIterator()
        var current: Request?
        var stderr = Data()
        var failure: Error = ShellClosed(stderr: "")

        do {
            try await client.withExec("exec bash --noprofile --norc") { inbound, outbound in
                var output = inbound.makeAsyncIterator()
                var buffer = Data()
                try await outbound.write(ByteBuffer(string: setup))

                while let request = await pending.next() {
                    current = request
                    let token = UUID().uuidString
                    try await outbound.write(ByteBuffer(string: """
                    ( \(request.command)
                    ) </dev/null 2>"$__lt_err"; __lt_rc=$?
                    printf '\\n@@LT-END %s %d %s\\n' \(token) "$__lt_rc" "$(base64 -w0 < "$__lt_err")"\n
                    """))

                    let marker = Data("\n@@LT-END \(token) ".utf8)
                    while true {
                        if let start = buffer.range(of: marker),
                           let end = buffer[start.upperBound...].firstIndex(of: UInt8(ascii: "\n")) {
                            let trailer = String(decoding: buffer[start.upperBound..<end], as: UTF8.self)
                                .split(separator: " ", omittingEmptySubsequences: false)
                            let result = CommandResult(
                                stdout: String(decoding: buffer[..<start.lowerBound], as: UTF8.self),
                                stderr: trailer.count > 1
                                    ? String(decoding: Data(base64Encoded: String(trailer[1])) ?? Data(), as: UTF8.self)
                                    : "",
                                exitCode: trailer.first.flatMap { Int($0) } ?? -1
                            )
                            buffer = Data(buffer[buffer.index(after: end)...])
                            current = nil
                            request.reply.resume(returning: result)
                            break
                        }
                        guard let chunk = try await output.next() else {
                            throw ShellClosed(stderr: String(decoding: stderr, as: UTF8.self))
                        }
                        switch chunk {
                        case .stdout(let bytes): buffer.append(contentsOf: bytes.readableBytesView)
                        case .stderr(let bytes): stderr.append(contentsOf: bytes.readableBytesView)
                        }
                    }
                }
            }
        } catch {
            failure = error
        }

        let message = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if message.contains("master is disconnected") {
            failure = TorchError.masterDisconnected(message)
        } else if !(failure is ShellClosed) {
            failure = ShellClosed(stderr: message.isEmpty ? String(describing: failure) : message)
        }
        state.isAlive = false
        current?.reply.resume(throwing: failure)
        continuation.finish()
        while let request = await pending.next() {
            request.reply.resume(throwing: failure)
        }
    }
}

struct ShellClosed: Error, LocalizedError {
    var stderr: String
    var errorDescription: String? {
        stderr.isEmpty ? "The Torch shell closed." : "The Torch shell closed: \(stderr)"
    }
}
