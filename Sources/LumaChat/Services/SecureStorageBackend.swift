import Foundation

/// Platform seam for credentials. Higher-level stores provide a service and
/// account; only the selected host adapter can touch OS credential APIs.
protocol SecureStorageBackend: Sendable {
    func save(_ data: Data, service: String, account: String) throws
    func load(service: String, account: String) throws -> Data?
    func delete(service: String, account: String) throws
}

enum SecureStorageBackendError: LocalizedError, Sendable {
    case unavailable
    case status(Int32, String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Secure credential storage is unavailable on this platform."
        case .status(let status, let detail):
            "Secure credential storage failed (\(status)): \(detail)"
        }
    }
}

#if canImport(Security)
import Security

struct SystemSecureStorageBackend: SecureStorageBackend {
    func save(_ data: Data, service: String, account: String) throws {
        let query = baseQuery(service: service, account: account)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw error(addStatus) }
        default:
            throw error(updateStatus)
        }
    }

    func load(service: String, account: String) throws -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw SecureStorageBackendError.status(-1, "invalid data") }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw error(status)
        }
    }

    func delete(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw error(status) }
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func error(_ status: OSStatus) -> SecureStorageBackendError {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "unknown OSStatus"
        return .status(status, detail)
    }
}
#else
struct SystemSecureStorageBackend: SecureStorageBackend {
    func save(_: Data, service _: String, account _: String) throws {
        throw SecureStorageBackendError.unavailable
    }

    func load(service _: String, account _: String) throws -> Data? {
        throw SecureStorageBackendError.unavailable
    }

    func delete(service _: String, account _: String) throws {
        throw SecureStorageBackendError.unavailable
    }
}
#endif
