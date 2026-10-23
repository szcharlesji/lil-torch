import Foundation
import TorchSSH

// End-to-end check from a Mac: torchkit-probe <gateway-key> <relay-key> [host]
let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    print("usage: torchkit-probe <gateway-private-key> <relay-private-key> [gateway-host]")
    exit(2)
}
let gatewayKey = try SSHKeys.parseOpenSSHPrivateKey(String(contentsOfFile: arguments[1], encoding: .utf8))
let relayKey = try SSHKeys.parseOpenSSHPrivateKey(String(contentsOfFile: arguments[2], encoding: .utf8))
var endpoint = TorchEndpoint()
if arguments.count > 3 { endpoint.gatewayHost = arguments[3] }

let connection = TorchConnection(endpoint: endpoint, key: gatewayKey, relayKey: relayKey, pinned: PinnedHostKeys())

// `--terminal`: exercise the relay's PTY path (the one that can prompt for NYU login).
if arguments.contains("--terminal") {
    let started = Date()
    let terminal = try await connection.openTerminal(cols: 100, rows: 30)
    terminal.send("echo PTY-HOST=$(hostname) TERM=$TERM SIZE=$(stty size)\r")
    terminal.resize(cols: 120, rows: 40)
    terminal.send("sleep 1; echo RESIZED=$(stty size); exit\r")
    var transcript: [UInt8] = []
    for await event in terminal.events {
        switch event {
        case .output(let bytes): transcript += bytes
        case .closed(let error): print("closed after \(String(format: "%.1f", Date().timeIntervalSince(started)))s error=\(error ?? "none")")
        }
    }
    let text = String(decoding: transcript, as: UTF8.self)
    for line in text.split(separator: "\n") where line.contains("PTY-HOST=t") || line.contains("RESIZED=") {
        print(line.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    await connection.disconnect()
    exit(0)
}
let service = TorchService(connection: connection)

let started = Date()
let snapshot = try await service.snapshot(historyDays: 14)
print("user=\(snapshot.user) jobs=\(snapshot.jobs.count) in \(String(format: "%.2f", Date().timeIntervalSince(started)))s warnings=\(snapshot.warnings)")
for job in snapshot.jobs.prefix(10) {
    print(job.id, job.state.rawValue, job.partition, job.elapsed.map { Int($0) } ?? -1, job.gpuCount ?? 0, job.name)
    print("   out:", job.stdoutPath ?? "-")
}
let keys = await connection.observedHostKeys
print("gateway host key:", keys.gateway.flatMap(SSHKeys.fingerprint(ofPublicKeyLine:)) ?? "-")
print("relay host key:  ", keys.relay.flatMap(SSHKeys.fingerprint(ofPublicKeyLine:)) ?? "-")

if let path = snapshot.jobs.first(where: { $0.stdoutPath != nil })?.stdoutPath {
    let again = Date()
    let tail = try await service.tail(path: path, lines: 5)
    print("tail \(path) size=\(tail.size ?? -1) in \(String(format: "%.2f", Date().timeIntervalSince(again)))s")
    print(tail.text)
}

// The persistent shell should make later commands cheap and keep stderr/exit codes apart.
for _ in 0..<2 {
    let again = Date()
    let repeated = try await service.snapshot(historyDays: 7)
    print("repeat snapshot jobs=\(repeated.jobs.count) in \(String(format: "%.2f", Date().timeIntervalSince(again)))s")
}
let failing = try await connection.run("echo out; echo 'err ünïcode' >&2; exit 3")
print("failing: rc=\(failing.exitCode) out=\(failing.stdout.debugDescription) err=\(failing.stderr.debugDescription)")
let noNewline = try await connection.run("printf 'a\\nb'")
print("no trailing newline:", noNewline.stdout.debugDescription)

// Pinned keys must be accepted, and a wrong pin must be refused.
let pinned = TorchConnection(endpoint: endpoint, key: gatewayKey, relayKey: relayKey, pinned: keys)
print("pinned run:", try await pinned.run("echo ok").stdout.trimmingCharacters(in: .whitespacesAndNewlines))
let wrong = TorchConnection(endpoint: endpoint, key: gatewayKey, relayKey: relayKey,
                            pinned: PinnedHostKeys(gateway: keys.gateway, relay: SSHKeys.authorizedKeyLine(for: SSHKeys.generate(), comment: "")))
do {
    _ = try await wrong.run("echo should-not-run")
    print("ERROR: mismatched pin was accepted")
} catch {
    print("mismatched pin refused:", error.localizedDescription)
}
await connection.disconnect()
await pinned.disconnect()
