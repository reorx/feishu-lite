import Foundation
import Security
import FeishuChatCore
import Testing
@testable import FeishuChatState

@Suite
@MainActor
struct MailKeychainTests {
    @Test func fileBasedQueriesOnlyMatchExactAccountAndWriteDoesNotDeleteFirst() throws {
        let id = UUID().uuidString
        var queries: [[String: Any]] = []
        var attributes: [[String: Any]] = []
        let operations = MailSecItemOperations(copy: { query in
            queries.append(query)
            return (errSecSuccess, Data("synthetic".utf8))
        }, add: { query in
            queries.append(query)
            attributes.append(query)
            return errSecSuccess
        }, update: { query, changes in
            queries.append(query); attributes.append(changes)
            return errSecItemNotFound
        }, delete: { query in queries.append(query); return errSecItemNotFound })
        let store = MailKeychain(operations: operations)
        let secret = try store.read(accountID: id)
        try store.write(secret, accountID: id, address: "synthetic@example.invalid")
        try store.delete(accountID: id)
        #expect(queries.count == 4)
        #expect(queries.allSatisfy { $0[kSecAttrAccount as String] as? String == id })
        #expect(queries.allSatisfy { $0[kSecAttrService as String] as? String == MailKeychain.service })
        #expect(queries.allSatisfy { $0[kSecUseDataProtectionKeychain as String] == nil })
        #expect(queries.allSatisfy { $0[kSecAttrAccessGroup as String] == nil })
        #expect(attributes.allSatisfy { $0[kSecAttrComment as String] as? String == "synthetic@example.invalid" })
    }

    @Test(arguments: [errSecItemNotFound, errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed, errSecNotAvailable, errSecParam])
    func systemErrorsHaveSpecificSafeResults(_ code: OSStatus) {
        let store = MailKeychain(operations: MailSecItemOperations(copy: { _ in (code, nil) }, add: { _ in code }, update: { _, _ in code }, delete: { _ in code }))
        #expect(throws: MailKeychainError.classify(code)) { try store.read(accountID: UUID().uuidString) }
    }

    @Test func failedUpdateDoesNotAddOrDeleteAndDataCannotLeakInError() {
        let store = MailKeychain(operations: MailSecItemOperations(copy: { _ in (errSecSuccess, Data([0xff])) }, add: { _ in Issue.record("不得尝试 add"); return errSecSuccess }, update: { _, _ in errSecAuthFailed }, delete: { _ in Issue.record("不得先删除密码"); return errSecSuccess }))
        #expect(throws: MailKeychainError.denied) { try store.write(MailSecret("synthetic"), accountID: UUID().uuidString, address: "synthetic@example.invalid") }
        #expect(throws: MailKeychainError.other) { try store.read(accountID: UUID().uuidString) }
    }
}
