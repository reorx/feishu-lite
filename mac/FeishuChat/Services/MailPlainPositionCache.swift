import CryptoKit
import Foundation

struct MailPlainPosition: Equatable {
    let character: Int
    let lineOffset: CGFloat
}

struct MailPlainSession {
    let identity: MailReaderIdentity
    let fingerprint: SHA256.Digest
    var owner: UUID
    var position: MailPlainPosition?
}

/// At most eight locations and digests; no views, body text or location history.
@MainActor final class MailPlainPositionCache {
    static let capacity = 8
    private var entries: [String: MailPlainSession] = [:]
    private var recency: [String] = []
    var count: Int { entries.count }
    subscript(_ id: String) -> MailPlainSession? { entries[id] }

    func claim(token: MailRenderToken, content: String) -> MailPlainPosition? {
        guard let id = token.identity.messageID else { return nil }
        let fingerprint = SHA256.hash(data:Data(content.utf8))
        var entry = entries[id].flatMap {
            $0.identity == token.identity && $0.fingerprint == fingerprint ? $0 : nil
        } ?? MailPlainSession(identity:token.identity,fingerprint:fingerprint,owner:token.presentation)
        entry.owner = token.presentation
        entries[id] = entry
        recency.removeAll { $0 == id }; recency.append(id)
        while recency.count > Self.capacity { entries.removeValue(forKey:recency.removeFirst()) }
        return entry.position
    }
    func save(_ position: MailPlainPosition, token: MailRenderToken) {
        guard let id = token.identity.messageID, var entry = entries[id],
              entry.identity == token.identity, entry.owner == token.presentation else { return }
        entry.position = position
        entries[id] = entry
    }
    func removeAll() { entries.removeAll(); recency.removeAll() }
}
