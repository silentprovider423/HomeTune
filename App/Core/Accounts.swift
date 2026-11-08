import Foundation
import Security

/// Passwörter liegen nur im Schlüsselbund (je Konto-ID).
enum Keychain {
    private static let service = "org.homeroll.hometune.password"

    static func set(_ value: String, for account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func delete(_ account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}

/// Mehrere Konten/Server, umschaltbar (wie FotosLokal).
@MainActor @Observable
final class AccountStore {
    private(set) var accounts: [ServerAccount] = []
    private(set) var currentID: String?
    private let defaults = UserDefaults.standard

    init() {
        if let d = defaults.data(forKey: "accounts"), let a = try? JSONDecoder().decode([ServerAccount].self, from: d) {
            accounts = a
        }
        currentID = defaults.string(forKey: "currentAccount") ?? accounts.first?.id
    }

    var current: ServerAccount? { accounts.first { $0.id == currentID } ?? accounts.first }

    func client(for account: ServerAccount) -> SubsonicClient? {
        guard let pw = Keychain.get(account.id) else { return nil }
        return SubsonicClient(account: account, password: pw)
    }

    func add(_ account: ServerAccount, password: String) {
        Keychain.set(password, for: account.id)
        accounts.removeAll { $0.server == account.server && $0.username == account.username }
        accounts.append(account)
        select(account.id)
        save()
    }

    func select(_ id: String) {
        currentID = id
        defaults.set(id, forKey: "currentAccount")
    }

    func remove(_ id: String) {
        Keychain.delete(id)
        accounts.removeAll { $0.id == id }
        if currentID == id { currentID = accounts.first?.id; defaults.set(currentID, forKey: "currentAccount") }
        save()
    }

    private func save() {
        if let d = try? JSONEncoder().encode(accounts) { defaults.set(d, forKey: "accounts") }
    }

    /// Normalisiert eine eingegebene Serveradresse („musik.local:4533“ → „http://musik.local:4533“).
    nonisolated static func normalize(_ text: String) -> URL? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix("/") { t.removeLast() }
        guard !t.isEmpty else { return nil }
        if !t.lowercased().hasPrefix("http://") && !t.lowercased().hasPrefix("https://") { t = "http://" + t }
        guard let u = URL(string: t), u.host() != nil else { return nil }
        return u
    }
}
