import Foundation
import Security

struct KeychainTokenStore: Sendable {
    private let service = "org.libchess.macos.provider-token"

    func contains(provider: String) throws -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: provider,
            kSecMatchLimit: kSecMatchLimitOne,
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess, errSecInteractionNotAllowed:
            return true
        case errSecItemNotFound:
            return false
        default:
            throw KeychainError(status: status)
        }
    }

    func load(provider: String) throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: provider,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError(status: status)
        }
        guard let token = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidEncoding
        }
        return token
    }

    func save(_ token: String, provider: String) throws {
        let tokenData = Data(token.utf8)
        let identity: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: provider,
        ]
        let update: [CFString: Any] = [
            kSecValueData: tokenData,
        ]

        let updateStatus = SecItemUpdate(identity as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError(status: updateStatus)
        }

        var item = identity
        item[kSecValueData] = tokenData
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError(status: addStatus)
        }
    }

    func delete(provider: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: provider,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}

private enum KeychainError: LocalizedError {
    case invalidEncoding
    case status(OSStatus)

    init(status: OSStatus) {
        self = .status(status)
    }

    var errorDescription: String? {
        switch self {
        case .invalidEncoding:
            "The saved credential is not valid UTF-8."
        case let .status(status):
            SecCopyErrorMessageString(status, nil) as String?
                ?? "Keychain returned status \(status)."
        }
    }
}
