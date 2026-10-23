import Citadel
import Crypto
import Foundation
import NIOCore
import NIOSSH

/// Where the two SSH hops go. Defaults match the Orin relay setup.
public struct TorchEndpoint: Codable, Hashable, Sendable {
    /// Orin's Tailscale name or 100.x address.
    public var gatewayHost: String = "orin-nano"
    public var gatewayPort: Int = 22
    public var gatewayUser: String = "charles"
    /// The relay listens on Orin's loopback and is reached through the gateway.
    public var relayHost: String = "127.0.0.1"
    public var relayPort: Int = 22422
    public var relayUser: String = "charles"

    public init() {}
}

/// Host keys trusted for each hop, as `ssh-ed25519 AAAA…` lines. `nil` means trust on first use.
public struct PinnedHostKeys: Codable, Hashable, Sendable {
    public var gateway: String?
    public var relay: String?

    public init(gateway: String? = nil, relay: String? = nil) {
        self.gateway = gateway
        self.relay = relay
    }
}

public enum Hop: String, Sendable {
    case gateway = "Orin"
    case relay = "Torch relay"
}

public struct CommandResult: Sendable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int
}

public enum TorchError: LocalizedError, Sendable {
    case connectFailed(Hop, String)
    case hostKeyMismatch(Hop, expected: String, seen: String)
    case masterDisconnected(String)
    case commandFailed(exitCode: Int, stderr: String)
    case timedOut
    case invalidJobID(String)

    public var errorDescription: String? {
        switch self {
        case .connectFailed(let hop, let detail):
            "Could not connect to \(hop.rawValue): \(detail)"
        case .hostKeyMismatch(let hop, let expected, let seen):
            "\(hop.rawValue) presented a different host key (\(seen)) than the pinned one (\(expected)). Verify it before resetting the pin."
        case .masterDisconnected(let message):
            message
        case .commandFailed(let code, let stderr):
            stderr.isEmpty ? "Command exited with status \(code)." : stderr
        case .timedOut:
            "Torch did not answer in time."
        case .invalidJobID(let id):
            "\(id) is not a job ID."
        }
    }
}

/// An SSH session to Torch: gateway (Orin) → direct-tcpip → relay → Torch.
///
/// The relay forces every exec through Orin's authenticated Torch master, so a
/// command here runs on Torch as the account the master logged in as.
public actor TorchConnection {
    public let endpoint: TorchEndpoint
    private let key: Curve25519.Signing.PrivateKey
    private let relayKey: Curve25519.Signing.PrivateKey
    private let gatewayTrust: HostKeyTrust
    private let relayTrust: HostKeyTrust

    private var gateway: SSHClient?
    private var relay: SSHClient?
    private var shell: PersistentShell?

    /// - Parameters:
    ///   - key: Client key for the gateway hop.
    ///   - relayKey: Client key for the relay hop; defaults to `key`.
    public init(
        endpoint: TorchEndpoint,
        key: Curve25519.Signing.PrivateKey,
        relayKey: Curve25519.Signing.PrivateKey? = nil,
        pinned: PinnedHostKeys
    ) {
        self.endpoint = endpoint
        self.key = key
        self.relayKey = relayKey ?? key
        self.gatewayTrust = HostKeyTrust(hop: .gateway, expected: pinned.gateway)
        self.relayTrust = HostKeyTrust(hop: .relay, expected: pinned.relay)
    }

    /// Host keys seen on this connection, so callers can persist first-use pins.
    public var observedHostKeys: PinnedHostKeys {
        PinnedHostKeys(gateway: gatewayTrust.seen, relay: relayTrust.seen)
    }

    public func run(_ command: String, timeout: Duration = .seconds(45)) async throws -> CommandResult {
        do {
            return try await attempt(command, timeout: timeout)
        } catch let error as TorchError {
            throw error
        } catch {
            // A dropped socket (app backgrounded, Wi-Fi change) surfaces here; reconnect once.
            await disconnect()
            return try await attempt(command, timeout: timeout)
        }
    }

    public func disconnect() async {
        shell?.close()
        shell = nil
        try? await relay?.close()
        try? await gateway?.close()
        relay = nil
        gateway = nil
    }

    private func attempt(_ command: String, timeout: Duration) async throws -> CommandResult {
        let shell = try await connectedShell()
        do {
            return try await withTimeout(timeout) { try await shell.run(command) }
        } catch TorchError.timedOut {
            await disconnect()
            throw TorchError.timedOut
        }
    }

    private func connectedShell() async throws -> PersistentShell {
        if let shell, shell.isAlive, relay?.isConnected == true { return shell }
        let shell = PersistentShell(client: try await connectedRelay())
        self.shell = shell
        return shell
    }

    func connectedRelay() async throws -> SSHClient {
        if let relay, relay.isConnected { return relay }
        await disconnect()

        let gatewayKey = key
        let gatewaySettings = SSHClientSettings(
            host: endpoint.gatewayHost,
            port: endpoint.gatewayPort,
            authenticationMethod: { [user = endpoint.gatewayUser] in .ed25519(username: user, privateKey: gatewayKey) },
            hostKeyValidator: .custom(gatewayTrust)
        )
        let gateway: SSHClient
        do {
            gateway = try await SSHClient.connect(to: gatewaySettings)
        } catch {
            throw gatewayTrust.mismatch ?? TorchError.connectFailed(.gateway, Self.describe(error))
        }
        self.gateway = gateway

        let relayKey = relayKey
        let relaySettings = SSHClientSettings(
            host: endpoint.relayHost,
            port: endpoint.relayPort,
            authenticationMethod: { [user = endpoint.relayUser] in .ed25519(username: user, privateKey: relayKey) },
            hostKeyValidator: .custom(relayTrust)
        )
        do {
            let relay = try await gateway.jump(to: relaySettings)
            self.relay = relay
            return relay
        } catch {
            throw relayTrust.mismatch ?? TorchError.connectFailed(.relay, Self.describe(error))
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case is AuthenticationFailed, SSHClientError.allAuthenticationOptionsFailed:
            "the server rejected this device's key. Enroll its public key first."
        case let error as LocalizedError where error.errorDescription != nil:
            error.errorDescription!
        default:
            String(describing: error)
        }
    }
}

private func withTimeout<T: Sendable>(
    _ timeout: Duration,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw TorchError.timedOut
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

/// Pins a hop's host key, or records it on first use.
final class HostKeyTrust: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let hop: Hop
    private let expected: String?
    private let lock = NSLock()
    private var _seen: String?
    private var _mismatch: TorchError?

    init(hop: Hop, expected: String?) {
        self.hop = hop
        self.expected = expected.map(SSHKeys.normalized)
    }

    var seen: String? { lock.withLock { _seen } }
    var mismatch: TorchError? { lock.withLock { _mismatch } }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let line = String(openSSHPublicKey: hostKey)
        lock.withLock { _seen = line }
        guard let expected, expected != SSHKeys.normalized(line) else {
            validationCompletePromise.succeed(())
            return
        }
        let error = TorchError.hostKeyMismatch(
            hop,
            expected: SSHKeys.fingerprint(ofPublicKeyLine: expected) ?? expected,
            seen: SSHKeys.fingerprint(ofPublicKeyLine: line) ?? line
        )
        lock.withLock { _mismatch = error }
        validationCompletePromise.fail(error)
    }
}

// Citadel's client funnels all I/O through its NIO channel's event loop; the
// connection actor is the only caller, so handing it to Citadel's async APIs is safe.
extension SSHClient: @retroactive @unchecked Sendable {}
