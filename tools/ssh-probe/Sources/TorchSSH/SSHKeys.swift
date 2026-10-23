import Citadel
import Crypto
import Foundation
import NIOSSH

/// Helpers for the Ed25519 client key the app authenticates with.
public enum SSHKeys {
    public static func generate() -> Curve25519.Signing.PrivateKey {
        Curve25519.Signing.PrivateKey()
    }

    /// Parses an unencrypted OpenSSH private key (`-----BEGIN OPENSSH PRIVATE KEY-----`).
    public static func parseOpenSSHPrivateKey(_ text: String) throws -> Curve25519.Signing.PrivateKey {
        try Curve25519.Signing.PrivateKey(sshEd25519: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `ssh-ed25519 AAAA… comment`, ready for an authorized_keys file.
    public static func authorizedKeyLine(for key: Curve25519.Signing.PrivateKey, comment: String) -> String {
        let publicKey = NIOSSHPrivateKey(ed25519Key: key).publicKey
        return "\(String(openSSHPublicKey: publicKey)) \(comment)"
    }

    /// OpenSSH-style `SHA256:…` fingerprint of a public key line.
    public static func fingerprint(ofPublicKeyLine line: String) -> String? {
        let fields = line.split(separator: " ")
        guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])) else { return nil }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    /// Drops the comment so two lines for the same key compare equal.
    static func normalized(_ line: String) -> String {
        line.split(separator: " ").prefix(2).joined(separator: " ")
    }
}
