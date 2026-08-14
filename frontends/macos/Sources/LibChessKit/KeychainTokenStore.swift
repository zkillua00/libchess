import Foundation
import LocalAuthentication
import Security

struct KeychainTokenStore: Sendable {
    private let service = "org.libchess.macos.provider-token"

    func contains(provider: String) throws -> Bool {
        for implementation in KeychainImplementation.allCases {
            let result = copyCredential(provider: provider, from: implementation)
            switch result.status {
            case errSecSuccess:
                return true
            case errSecItemNotFound, errSecInteractionNotAllowed:
                continue
            case errSecMissingEntitlement where implementation == .dataProtection:
                continue
            default:
                throw KeychainError(status: result.status)
            }
        }
        return false
    }

    func load(provider: String) throws -> String? {
        var interactionWasRequired = false

        for implementation in KeychainImplementation.allCases {
            let result = copyCredential(provider: provider, from: implementation)
            switch result.status {
            case errSecSuccess:
                guard let data = result.data,
                      let token = String(data: data, encoding: .utf8)
                else {
                    throw KeychainError.invalidEncoding
                }
                if implementation == .fileBased {
                    migrateToDataProtectionKeychain(token, provider: provider)
                }
                return token
            case errSecItemNotFound:
                continue
            case errSecInteractionNotAllowed:
                interactionWasRequired = true
            case errSecMissingEntitlement where implementation == .dataProtection:
                continue
            default:
                throw KeychainError(status: result.status)
            }
        }

        if interactionWasRequired {
            throw KeychainError.interactionRequired
        }
        return nil
    }

    func save(_ token: String, provider: String) throws {
        let tokenData = Data(token.utf8)
        let dataProtectionStatus = writeCredential(
            tokenData,
            provider: provider,
            to: .dataProtection
        )
        if dataProtectionStatus == errSecSuccess {
            deleteCredential(provider: provider, from: .fileBased)
            return
        }
        guard dataProtectionStatus == errSecMissingEntitlement else {
            throw KeychainError(status: dataProtectionStatus)
        }

        let fileBasedStatus = writeCredential(tokenData, provider: provider, to: .fileBased)
        guard fileBasedStatus == errSecSuccess else {
            if fileBasedStatus == errSecInteractionNotAllowed {
                throw KeychainError.interactionRequired
            }
            throw KeychainError(status: fileBasedStatus)
        }
    }

    func delete(provider: String) throws {
        var firstError: OSStatus?
        for implementation in KeychainImplementation.allCases {
            let status = deleteCredential(provider: provider, from: implementation)
            switch status {
            case errSecSuccess, errSecItemNotFound:
                continue
            case errSecMissingEntitlement where implementation == .dataProtection:
                continue
            default:
                firstError = firstError ?? status
            }
        }

        if firstError == errSecInteractionNotAllowed {
            throw KeychainError.interactionRequired
        }
        if let firstError {
            throw KeychainError(status: firstError)
        }
    }

    private func copyCredential(
        provider: String,
        from implementation: KeychainImplementation
    ) -> (status: OSStatus, data: Data?) {
        var query = identity(provider: provider, implementation: implementation)
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecReturnData] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    private func writeCredential(
        _ tokenData: Data,
        provider: String,
        to implementation: KeychainImplementation
    ) -> OSStatus {
        let identity = identity(provider: provider, implementation: implementation)
        var update: [CFString: Any] = [kSecValueData: tokenData]
        if implementation == .dataProtection {
            update[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }

        let updateStatus = SecItemUpdate(identity as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess {
            return updateStatus
        }
        guard updateStatus == errSecItemNotFound else {
            return updateStatus
        }

        var item = identity
        item[kSecValueData] = tokenData
        if implementation == .dataProtection {
            item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        return SecItemAdd(item as CFDictionary, nil)
    }

    @discardableResult
    private func deleteCredential(
        provider: String,
        from implementation: KeychainImplementation
    ) -> OSStatus {
        let query = identity(provider: provider, implementation: implementation)
        return SecItemDelete(query as CFDictionary)
    }

    private func identity(
        provider: String,
        implementation: KeychainImplementation
    ) -> [CFString: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true

        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: provider,
            kSecUseAuthenticationContext: context,
        ]
        if implementation == .dataProtection {
            query[kSecUseDataProtectionKeychain] = true
        }
        return query
    }

    private func migrateToDataProtectionKeychain(_ token: String, provider: String) {
        let status = writeCredential(
            Data(token.utf8),
            provider: provider,
            to: .dataProtection
        )
        if status == errSecSuccess {
            deleteCredential(provider: provider, from: .fileBased)
        }
    }
}

private enum KeychainImplementation: CaseIterable, Equatable {
    case dataProtection
    case fileBased
}

private enum KeychainError: LocalizedError {
    case invalidEncoding
    case interactionRequired
    case status(OSStatus)

    init(status: OSStatus) {
        self = .status(status)
    }

    var errorDescription: String? {
        switch self {
        case .invalidEncoding:
            "The saved credential is not valid UTF-8."
        case .interactionRequired:
            "The saved credential requires interaction, so LibChess did not request a Keychain password. Sign in again once to replace it."
        case let .status(status):
            SecCopyErrorMessageString(status, nil) as String?
                ?? "Keychain returned status \(status)."
        }
    }
}
