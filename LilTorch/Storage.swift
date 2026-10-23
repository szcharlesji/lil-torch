import Foundation
import Security
import TorchKit

/// A paired lil-torch agent. Its token lives in the Keychain.
struct AgentRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var url: URL
}

struct AppSettings: Codable, Equatable {
    var agents: [AgentRecord] = []
    var notifications = NotificationPrefs()
    var refreshInterval: TimeInterval = 30
    /// Last event seen per agent, so each notifies once.
    var lastEventSeq: [UUID: Int] = [:]
    /// APNs token for this install, once iOS hands it over.
    var deviceToken: String?

    private static let defaultsKey = "settings.v2"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return settings
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }
}

/// Agent tokens, readable after first unlock so background refresh works while locked.
enum TokenStore {
    private static let service = "liltorch.agent-token"

    static func load(_ id: UUID) -> String? {
        var query = baseQuery(id)
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String, for id: UUID) {
        delete(id)
        var item = baseQuery(id)
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete(_ id: UUID) {
        SecItemDelete(baseQuery(id) as CFDictionary)
    }

    private static func baseQuery(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }
}

/// What each agent last reported, kept on disk so the app opens with data.
struct AgentState: Codable {
    var info: AgentInfo?
    var jobs: JobSnapshot?
    var gpus: GPUSnapshot?
    var error: String?
    var loginNeeded = false
    var pushRegistered = false
}

enum StateCache {
    private static var url: URL {
        URL.applicationSupportDirectory.appending(path: "agents.json")
    }

    static func load() -> [UUID: AgentState] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? decoder.decode([UUID: AgentState].self, from: data)) ?? [:]
    }

    static func save(_ states: [UUID: AgentState]) {
        try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(states).write(to: url, options: .atomic)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
