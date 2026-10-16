import Foundation
import Security
import FeishuLiteCore
import Testing
@testable import FeishuLiteState

/// 按真实查询的 service/account 寻址；两配置测试均使用生产默认 MailKeychain。
@MainActor
final class RecordingMailSecItems {
    #if DEBUG
    static let currentService = "com.reorx.FeishuChat.mail.debug"
    static let peerService = "com.reorx.FeishuChat.mail"
    #else
    static let currentService = "com.reorx.FeishuChat.mail"
    static let peerService = "com.reorx.FeishuChat.mail.debug"
    #endif

    private struct Key: Hashable {
        let service: String
        let account: String
    }
    private var items: [Key: Data] = [:]
    var queries: [(operation: String, query: [String: Any])] = []
    var deleteStatus: OSStatus = errSecSuccess

    func seed(service: String, accountID: String, value: String) {
        items[Key(service: service, account: accountID)] = Data(value.utf8)
    }
    func value(service: String, accountID: String) -> String? {
        items[Key(service: service, account: accountID)].flatMap { String(data: $0, encoding: .utf8) }
    }
    private func key(_ query: [String: Any]) -> Key? {
        guard let service = query[kSecAttrService as String] as? String,
              let account = query[kSecAttrAccount as String] as? String else { return nil }
        return Key(service: service, account: account)
    }
    var operations: MailSecItemOperations {
        MailSecItemOperations(copy: { query in
            self.queries.append(("copy", query))
            guard let key = self.key(query) else { return (errSecParam, nil) }
            guard let data = self.items[key] else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, data)
        }, add: { query in
            self.queries.append(("add", query))
            guard let key = self.key(query), let data = query[kSecValueData as String] as? Data else { return errSecParam }
            guard self.items[key] == nil else { return errSecDuplicateItem }
            self.items[key] = data
            return errSecSuccess
        }, update: { query, attributes in
            self.queries.append(("update", query))
            guard let key = self.key(query), let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
            guard self.items[key] != nil else { return errSecItemNotFound }
            self.items[key] = data
            return errSecSuccess
        }, delete: { query in
            self.queries.append(("delete", query))
            guard let key = self.key(query) else { return errSecParam }
            guard self.deleteStatus == errSecSuccess else { return self.deleteStatus }
            return self.items.removeValue(forKey: key) == nil ? errSecItemNotFound : errSecSuccess
        })
    }
}

@Suite
@MainActor
struct MailKeychainTests {
    @Test func configurationQueriesKeepSameUUIDAndCanariesIndependent() throws {
        let id = UUID().uuidString
        let canary = UUID().uuidString
        let items = RecordingMailSecItems()
        for service in [RecordingMailSecItems.currentService, RecordingMailSecItems.peerService] {
            items.seed(service: service, accountID: id, value: service)
            items.seed(service: service, accountID: canary, value: "canary")
        }
        let store = MailKeychain(operations: items.operations)
        #expect(try store.read(accountID: id).withValue { $0 } == RecordingMailSecItems.currentService)
        try store.write(MailSecret("updated-current"), accountID: id, address: "synthetic@example.invalid")
        #expect(try store.read(accountID: id).withValue { $0 } == "updated-current")
        #expect(items.value(service: RecordingMailSecItems.peerService, accountID: id) == RecordingMailSecItems.peerService)
        try store.delete(accountID: id)
        #expect(throws: MailKeychainError.notFound) { try store.read(accountID: id) }
        #expect(items.value(service: RecordingMailSecItems.peerService, accountID: id) == RecordingMailSecItems.peerService)
        #expect(items.value(service: RecordingMailSecItems.currentService, accountID: canary) == "canary")
        #expect(items.value(service: RecordingMailSecItems.peerService, accountID: canary) == "canary")
        #expect(items.queries.map(\.operation) == ["copy", "update", "copy", "delete", "copy"])
        #expect(items.queries.allSatisfy { $0.query[kSecAttrService as String] as? String == RecordingMailSecItems.currentService })
        #expect(items.queries.allSatisfy { $0.query[kSecAttrAccount as String] as? String == id })
    }

    @Test func missingCurrentCredentialNeverFallsBackAndAddOnlyCreatesCurrentItem() throws {
        let id = UUID().uuidString
        let items = RecordingMailSecItems()
        items.seed(service: RecordingMailSecItems.peerService, accountID: id, value: "peer-only")
        let store = MailKeychain(operations: items.operations)
        #expect(throws: MailKeychainError.notFound) { try store.read(accountID: id) }
        try store.delete(accountID: id) // 本配置缺失时幂等，不删除对方。
        #expect(items.value(service: RecordingMailSecItems.peerService, accountID: id) == "peer-only")
        try store.write(MailSecret("new-current"), accountID: id, address: "synthetic@example.invalid")
        #expect(try store.read(accountID: id).withValue { $0 } == "new-current")
        #expect(items.value(service: RecordingMailSecItems.currentService, accountID: id) == "new-current")
        #expect(items.value(service: RecordingMailSecItems.peerService, accountID: id) == "peer-only")
        #expect(items.queries.map(\.operation) == ["copy", "delete", "update", "add", "copy"])
        #expect(items.queries.allSatisfy { $0.query[kSecAttrService as String] as? String == RecordingMailSecItems.currentService })
        #expect(items.queries.allSatisfy { $0.query[kSecAttrAccount as String] as? String == id })
    }

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
