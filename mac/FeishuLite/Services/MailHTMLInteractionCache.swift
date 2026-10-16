import CryptoKit
import Foundation

/// Session bytes only, never a retained view/DOM/body. Recent eight bodies, at most 2 MiB.
struct MailHTMLInteraction {
    let identity: MailReaderIdentity
    let fingerprint: SHA256.Digest
    let documentURL: URL
    var owner: UUID
    var state: Data?

    init(token: MailRenderToken, content: String) {
        identity = token.identity
        fingerprint = SHA256.hash(data:Data(content.utf8))
        documentURL = URL(string:"feishu-mail-body://document/" + UUID().uuidString)!
        owner = token.presentation
        state = nil
    }
}

@MainActor final class MailHTMLInteractionCache {
    static let capacity = 8
    static let maximumStateBytes = 256 * 1024
    private var entries: [String: MailHTMLInteraction] = [:]
    private var recency: [String] = []
    var count: Int { entries.count }
    subscript(_ id: String) -> MailHTMLInteraction? { entries[id] }

    @discardableResult func claim(token: MailRenderToken, content: String) -> MailHTMLInteraction {
        let id = token.identity.messageID!
        let digest = SHA256.hash(data:Data(content.utf8))
        var entry = entries[id].flatMap {
            $0.identity == token.identity && $0.fingerprint == digest ? $0 : nil
        } ?? MailHTMLInteraction(token:token,content:content)
        entry.owner = token.presentation
        entries[id] = entry
        recency.removeAll { $0 == id }; recency.append(id)
        while recency.count > Self.capacity { entries.removeValue(forKey:recency.removeFirst()) }
        return entry
    }
    func save(_ state: Any?, token: MailRenderToken) {
        guard let id = token.identity.messageID, var entry = entries[id],
              entry.identity == token.identity, entry.owner == token.presentation else { return }
        // WK's public state is opaque NSData; never decode or rely on its private format.
        entry.state = (state as? Data).flatMap { $0.count <= Self.maximumStateBytes ? $0 : nil }
        entries[id] = entry
    }
    func removeAll() { entries.removeAll(); recency.removeAll() }
}
