import Citadel
import Foundation
import NIOCore
import NIOSSH

/// An interactive terminal on Torch through the relay.
///
/// With a PTY the relay runs `ssh -tt torch` instead of checking for Orin's
/// master first, so when the master is gone this prompts for NYU authentication
/// and the login becomes the new shared master (`ControlMaster auto`,
/// `ControlPersist yes`). Exiting the shell leaves that master running.
public final class TerminalSession: @unchecked Sendable {
    public enum Event: Sendable {
        case output([UInt8])
        case closed(String?)
    }

    private enum Input: Sendable {
        case bytes([UInt8])
        case resize(cols: Int, rows: Int)
    }

    /// Terminal output, then one `.closed` with an error message if the session failed.
    public let events: AsyncStream<Event>
    private let input: AsyncStream<Input>.Continuation
    private let task: Task<Void, Never>

    init(client: SSHClient, cols: Int, rows: Int) {
        let (events, eventSink) = AsyncStream.makeStream(of: Event.self)
        let (inputs, input) = AsyncStream.makeStream(of: Input.self)
        self.events = events
        self.input = input

        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )

        task = Task {
            var failure: String?
            do {
                try await client.withPTY(request) { inbound, outbound in
                    let writer = Unchecked(outbound)
                    let pump = Task {
                        for await item in inputs {
                            switch item {
                            case .bytes(let bytes):
                                try? await writer.value.write(ByteBuffer(bytes: bytes))
                            case .resize(let cols, let rows):
                                try? await writer.value.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
                            }
                        }
                    }
                    defer { pump.cancel() }
                    do {
                        for try await chunk in inbound {
                            switch chunk {
                            case .stdout(let buffer), .stderr(let buffer):
                                eventSink.yield(.output(Array(buffer.readableBytesView)))
                            }
                        }
                    } catch is SSHClient.CommandFailed {
                        // A non-zero exit from the remote shell is still a normal close.
                    }
                }
            } catch is CancellationError {
            } catch ChannelError.alreadyClosed {
                // Citadel closes the channel after the remote shell already did.
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            }
            input.finish()
            eventSink.yield(.closed(failure))
            eventSink.finish()
        }
    }

    public func send(_ bytes: [UInt8]) {
        input.yield(.bytes(bytes))
    }

    public func send(_ text: String) {
        send(Array(text.utf8))
    }

    public func resize(cols: Int, rows: Int) {
        input.yield(.resize(cols: cols, rows: rows))
    }

    public func close() {
        input.finish()
        task.cancel()
    }
}

extension TorchConnection {
    /// Opens a login shell on Torch over a PTY; see `TerminalSession`.
    public func openTerminal(cols: Int, rows: Int) async throws -> TerminalSession {
        TerminalSession(client: try await connectedRelay(), cols: cols, rows: rows)
    }
}

/// Citadel's stdin writer isn't marked Sendable, but it only wraps a NIO channel.
private struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
