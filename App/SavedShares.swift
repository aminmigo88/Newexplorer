import Foundation
import Security

struct SavedShare: Codable, Hashable, Identifiable {
    let host: String
    let share: String
    let user: String
    var id: String { user + "@" + host + "/" + share }
    var title: String { share + " on " + host }
}

// Windows shares the person chose to remember. The list is kept in the app's settings;
// each password is kept in the iPhone's Keychain, for this device only.
@MainActor
final class SavedShares: ObservableObject {
    static let shared = SavedShares()
    nonisolated static let storeKey = "savedShares.v1"
    @Published private(set) var all: [SavedShare] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
           let list = try? JSONDecoder().decode([SavedShare].self, from: data) {
            all = list
        }
    }

    // The share is listed even if the Keychain refuses the password; it then asks for it when opened.
    @discardableResult
    func remember(_ share: SavedShare, password: String) -> Bool {
        let stored = Keychain.set(password, account: share.id)
        all.removeAll { $0.id == share.id }
        all.append(share)
        all.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        persist()
        return stored
    }
    func password(for share: SavedShare) -> String? { Keychain.get(account: share.id) }
    func forget(_ share: SavedShare) {
        Keychain.remove(account: share.id)
        all.removeAll { $0.id == share.id }
        persist()
    }
    func match(_ server: Share) -> SavedShare? {
        all.first {
            $0.host.caseInsensitiveCompare(server.host) == .orderedSame
                && $0.share.caseInsensitiveCompare(server.name) == .orderedSame && $0.user == server.user
        }
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: Self.storeKey) }
    }
}

enum Keychain {
    static let service = "Newexplorer.WindowsShare"
    private static func item(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    static func set(_ password: String, account: String) -> Bool {
        SecItemDelete(item(account) as CFDictionary)
        var added = item(account)
        added[kSecValueData as String] = Data(password.utf8)
        added[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(added as CFDictionary, nil) == errSecSuccess
    }
    static func get(account: String) -> String? {
        var query = item(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func remove(account: String) {
        SecItemDelete(item(account) as CFDictionary)
    }
}
