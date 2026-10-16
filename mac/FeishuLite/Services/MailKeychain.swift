import Foundation
import Security
import FeishuLiteCore

@MainActor
protocol MailCredentialStore {
    func read(accountID: String) throws -> MailSecret
    func write(_ secret: MailSecret, accountID: String, address: String) throws
    func delete(accountID: String) throws
}

enum MailKeychainError: Error, Equatable, LocalizedError {
    case notFound, denied, locked, other
    var errorDescription: String? {
        switch self {
        case .notFound: "钥匙串中没有此邮箱的密码，请重新输入专用密码。"
        case .denied: "钥匙串访问未获授权，请允许访问后重试，或重新输入专用密码。"
        case .locked: "钥匙串已锁定或暂时无法交互，请解锁后重试。"
        case .other: "无法访问钥匙串，请重试；密码不会保存为明文。"
        }
    }
    static func classify(_ status: OSStatus) -> MailKeychainError {
        switch status {
        case errSecItemNotFound: .notFound
        case errSecUserCanceled, errSecAuthFailed: .denied
        case errSecInteractionNotAllowed, errSecNotAvailable: .locked
        default: .other
        }
    }
}

/// 可注入系统调用；测试只能替换调用，不能碰真实条目或弹权限框。
struct MailSecItemOperations {
    var copy: ([String: Any]) -> (OSStatus, Data?)
    var add: ([String: Any]) -> OSStatus
    var update: ([String: Any], [String: Any]) -> OSStatus
    var delete: ([String: Any]) -> OSStatus
    static let system = MailSecItemOperations(
        copy: { query in
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result as? Data)
        },
        add: { SecItemAdd($0 as CFDictionary, nil) },
        update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) },
        delete: { SecItemDelete($0 as CFDictionary) }
    )
}

@MainActor
struct MailKeychain: MailCredentialStore {
    // 存储标识不随 App 改名；既有 ACL 可能要求授权新签名。Debug/Release 仍严格隔离。
    #if DEBUG
    static let service = "com.reorx.FeishuChat.mail.debug"
    #else
    static let service = "com.reorx.FeishuChat.mail"
    #endif
    var operations: MailSecItemOperations = .system

    private func query(_ accountID: String) -> [String: Any] {
        // 不设置 kSecUseDataProtectionKeychain / access group / synchronizable，使用 file-based keychain。
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service, kSecAttrAccount as String: accountID]
    }
    func read(accountID: String) throws -> MailSecret {
        var match = query(accountID)
        match[kSecReturnData as String] = true
        match[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = operations.copy(match)
        guard status == errSecSuccess else { throw MailKeychainError.classify(status) }
        guard let data, let value = String(data: data, encoding: .utf8), !value.isEmpty else { throw MailKeychainError.other }
        return MailSecret(value)
    }
    func write(_ secret: MailSecret, accountID: String, address: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: secret.withValue { Data($0.utf8) },
                                      kSecAttrLabel as String: "FeishuLite 邮箱", kSecAttrComment as String: address]
        let status = operations.update(query(accountID), attributes)
        if status == errSecItemNotFound {
            let added = operations.add(query(accountID).merging(attributes) { _, new in new })
            guard added == errSecSuccess else { throw MailKeychainError.classify(added) }
        } else if status != errSecSuccess {
            throw MailKeychainError.classify(status)
        }
    }
    func delete(accountID: String) throws {
        let status = operations.delete(query(accountID))
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MailKeychainError.classify(status) }
    }
}
