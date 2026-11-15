import Foundation
import Observation
import Security

@Observable
final class AppSettings {
    var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: "serverURL") }
    }

    var token: String {
        didSet { Keychain.set(token, for: "apiToken") }
    }

    init() {
        serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? ""
        token = Keychain.get("apiToken") ?? ""
        #if DEBUG
        // Dev setup: `-serverURL <url> -apiToken <value>` launch arguments are saved like a normal edit.
        let args = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        if let t = args["apiToken"] as? String {
            token = t
            Keychain.set(t, for: "apiToken")
        }
        if let u = args["serverURL"] as? String {
            serverURL = u
            UserDefaults.standard.set(u, forKey: "serverURL")
        }
        #endif
    }

    var isConfigured: Bool { baseURL != nil && !token.isEmpty }

    var baseURL: URL? {
        var s = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.hasPrefix("http://") && !s.hasPrefix("https://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s)
    }

    var api: APIClient? {
        guard let baseURL, !token.isEmpty else { return nil }
        return APIClient(baseURL: baseURL, token: token)
    }
}

enum Keychain {
    private static let service = "musicapp"

    static func set(_ value: String, for key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
