import Foundation
import FeishuChatCore

extension BackendClient {
    /// 后端等待 30 秒 + DNS 清理约 1.5 秒，预留调度余量。
    static let mailRequestTimeout: TimeInterval = 35

    func mailStatus() async throws -> MailStatus { try await mailRequest("GET", ["mail", "status"]) }
    func testMailAccount(address: String, password: MailSecret) async throws -> MailConnectionTest {
        try await mailRequest("POST", ["mail", "account", "test"], body: BackendJSON.encoder.encode(MailAccountBody(address: address, password: password)))
    }
    func configureMailAccount(address: String, password: MailSecret) async throws -> MailAccountChange {
        try await mailRequest("PUT", ["mail", "account"], body: BackendJSON.encoder.encode(MailAccountBody(address: address, password: password)))
    }
    func injectMailCredential(accountID: String, password: MailSecret) async throws -> MailStatus {
        try await mailRequest("PUT", ["mail", "account", "credential"], body: BackendJSON.encoder.encode(MailCredentialBody(mailAccountID: accountID, password: password)))
    }
    func removeMailAccount() async throws -> MailAccountChange { try await mailRequest("DELETE", ["mail", "account"]) }
    func mailFolders() async throws -> [MailFolder] { try await mailRequest("GET", ["mail", "folders"]) }
    func mailMessages(folder: String = "INBOX", cursor: String? = nil) async throws -> MailPage {
        var query = [URLQueryItem(name: "folder", value: folder)]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await mailRequest("GET", ["mail", "messages"], query: query)
    }
    func mailBody(id: String) async throws -> MailBody { try await mailRequest("GET", ["mail", "messages", id]) }
    func mailSummary(id: String) async throws -> MailSummary { try await mailRequest("GET", ["mail", "messages", id, "summary"]) }
    func readMail(id: String) async throws -> MailReadResult { try await mailRequest("POST", ["mail", "messages", id, "read"]) }
    func syncMail(reconnect: Bool = false, wait: Bool = false) async throws -> MailStatus {
        try await mailRequest("POST", ["mail", "sync"], query: [URLQueryItem(name: "reconnect", value: String(reconnect)), URLQueryItem(name: "wait", value: String(wait))])
    }
    func ackMail(_ batch: MailNotification) async throws -> MailStatus {
        try await mailRequest("POST", ["mail", "notifications", "ack"], body: BackendJSON.encoder.encode(MailAckBody(mailAccountID: batch.accountID, uidvalidity: batch.uidvalidity, batchID: batch.id)))
    }
}

private struct MailAccountBody: Encodable {
    var address: String
    var password: MailSecret
}
private struct MailCredentialBody: Encodable {
    var mailAccountID: String
    var password: MailSecret
    enum CodingKeys: String, CodingKey { case mailAccountID = "mail_account_id", password }
}
private struct MailAckBody: Encodable {
    var mailAccountID: String
    var uidvalidity: Int
    var batchID: String
    enum CodingKeys: String, CodingKey { case mailAccountID = "mail_account_id", uidvalidity, batchID = "batch_id" }
}
