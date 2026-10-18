import Foundation
import FeishuLiteCore
import Observation

/// Persistent receipts contain identities only, never sender, subject, body or credentials.
struct MailNotificationReceipt: Codable {
    let id: String
    let accountID: String
    let uidvalidity: Int
    let batchID: String
    let members: [String]
    // true only after a successful add, exact center evidence, or explicit suppression.
    // false is an interrupted/uncertain intent, never evidence sufficient for ack.
    var handled: Bool
    var acknowledged: Bool
    let createdAt: TimeInterval
}

@Observable @MainActor final class MailNotificationCoordinator {
    private static let receiptsKey = "mail-notification-receipts-v1"
    static let receiptLimit = 2048
    private let mail: MailState
    private let center: any LocalNotificationCenter
    private let preferences: UserDefaults
    private var receipts: [String: MailNotificationReceipt]
    @ObservationIgnored private var work: Task<Void, Never>?
    private var activeIntentID: String?
    private var retryUncertain = false
    private var revision = 0
    private var epoch = 0
    private var dirty = false
    private var stopped = false
    private var resetAccounts: Set<String> = []
    private struct AckKey: Hashable {
        let account: String
        let validity: Int
        let batch: String
        init(_ batch: MailNotification) {
            account = batch.accountID; validity = batch.uidvalidity; self.batch = batch.id
        }
    }
    private struct AckAttempt {
        let count: Int
        let next: TimeInterval
    }
    @ObservationIgnored private var ackAttempts: [AckKey: AckAttempt] = [:]
    /// Monotonic time; replaceable by the isolated HTTP/recorder tests.
    @ObservationIgnored var ackClock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private(set) var lastFailure: String?
    var workCount: Int { work == nil ? 0 : 1 }
    var uncertainDeliveryCount: Int { receipts.values.filter { !$0.handled && $0.id != activeIntentID }.count }

    init(mail: MailState, notifications: NotificationService, preferences: UserDefaults) {
        self.mail = mail; center = notifications.localCenter; self.preferences = preferences
        let saved = preferences.data(forKey:Self.receiptsKey)
        receipts = saved.flatMap { try? JSONDecoder().decode([String:MailNotificationReceipt].self,from:$0) } ?? [:]
    }

    func request() {
        guard !stopped else { return }
        revision += 1; dirty = true
        guard work == nil else { return }
        work = Task { [weak self] in
            guard let self else { return }
            defer {
                self.work = nil
                if self.dirty, !self.stopped { self.request() }
            }
            while self.dirty, !Task.isCancelled, !self.stopped {
                self.dirty = false
                await self.process()
            }
        }
    }
    /// User explicitly accepts that a dismissed notification might appear again.
    func retryUncertainDeliveries() { retryUncertain = true; request() }
    func backendChanged() {
        epoch += 1; work?.cancel(); dirty = false
        ackAttempts.removeAll()
        // Keep the serial owner until an in-flight add completes and is cleaned up.
    }
    func stop() { stopped = true; backendChanged() }
    func waitForWork() async {
        while let work { await work.value }
    }
    func removeAccount(_ account: String) {
        epoch += 1; work?.cancel()
        let ids = receipts.values.filter { $0.accountID == account }.map(\.id)
        ids.forEach { receipts.removeValue(forKey:$0) }
        persist(); center.remove(ids)
        request() // query center too: a crash may have left a notification without a receipt
    }
    func resetAccount(_ account: String) {
        resetAccounts.insert(account)
        removeAccount(account)
    }
    func invalidate(ids: [String], account: String) {
        guard !ids.isEmpty else { return }
        let matches = receipts.values.filter { $0.accountID == account && !$0.members.filter(ids.contains).isEmpty }.map(\.id)
        center.remove(matches)
        // Retain handled receipts until ack, so a partially invalidated summary cannot be reposted.
        request()
    }

    private func persist() {
        preferences.set(try? JSONEncoder().encode(receipts),forKey:Self.receiptsKey)
        preferences.synchronize() // persist success/intent before an ack or another add
    }
    private func current(_ identity: MailReaderIdentity, epoch: Int) -> Bool {
        !stopped && !Task.isCancelled && self.epoch == epoch && mail.readerIdentity == identity
    }

    /// Top-level boundary catches temporary system/HTTP failures once; next state/recovery retries.
    private func process() async {
        guard mail.capability == .supported, mail.isBackendReady, let status = mail.status,
              let client = mail.readerClient else { return }
        let epoch = epoch
        let identity = mail.readerIdentity
        let version = revision
        do {
            if let identity {
                let mailRevision = mail.notificationRevision
                let authoritative = try await client.mailStatus()
                guard current(identity,epoch:epoch), version == revision else { dirty = true; return }
                // A late SSE arrival/snapshot must not resurrect a durably acked (possibly pruned) batch.
                if authoritative != mail.status || authoritative.pending != mail.pending {
                    mail.applyNotificationAck(authoritative,expected:identity,revision:mailRevision)
                    return
                }
            }
            let existing = await center.notifications()
            guard epoch == self.epoch, !Task.isCancelled, version == revision else { dirty = true; return }
            let resetIDs = existing.filter {
                if case let .email(account, _, _) = NotificationRoute(userInfo:$0.userInfo) { return resetAccounts.contains(account) }
                return false
            }.map(\.id)
            center.remove(resetIDs)
            resetAccounts.removeAll()
            recoverReceipts(existing.filter { !resetIDs.contains($0.id) })
            // Every authoritative status can repair missed read/delete/reset/account events after restart.
            try await clean(existing:existing, status:status, client:client, epoch:epoch, version:version)
            guard let identity, current(identity,epoch:epoch), version == revision else { return }
            let pendingKeys = Set(mail.pending.map(AckKey.init))
            ackAttempts = ackAttempts.filter { pendingKeys.contains($0.key) }
            if retryUncertain {
                // Query/recover above first: a proven center entry does not need another add.
                for id in receipts.keys where receipts[id]?.handled == false { receipts.removeValue(forKey:id) }
                retryUncertain = false; persist()
            }
            let permission = await center.authorization()
            guard current(identity,epoch:epoch), version == revision else { return }
            if permission == .undecided { return } // authorization activation will schedule another pass
            for batch in mail.pending {
                guard current(identity,epoch:epoch),
                      MailNotificationPolicy.eligible(batch,accountID:identity.accountID,uidvalidity:identity.uidvalidity) else { return }
                try await deliver(batch, permission:permission, identity:identity, epoch:epoch)
                guard current(identity,epoch:epoch), let active = mail.pending.first(where:{ $0.id == batch.id }) else { continue }
                let targets = notificationTargets(active)
                guard !targets.isEmpty, targets.allSatisfy({ receipts[$0.id]?.handled == true }) else { continue }
                let key = AckKey(active)
                if let attempt = ackAttempts[key], ackClock() < attempt.next { continue }
                let count = min((ackAttempts[key]?.count ?? 0) + 1, 7)
                // Both an HTTP failure and a successful-but-unchanged pending snapshot need backoff.
                // Retry only on a later sync/recovery trigger, never by spinning or scheduling a task per batch.
                ackAttempts[key] = AckAttempt(count:count, next:ackClock() + min(60, pow(2, Double(count - 1))))
                let revision = mail.notificationRevision
                let new = try await client.ackMail(active)
                guard current(identity,epoch:epoch) else { return }
                if !new.pending.contains(where: { $0.id == batch.id }) {
                    ackAttempts.removeValue(forKey:key)
                    for id in receipts.keys where receipts[id]?.accountID == active.accountID &&
                        receipts[id]?.uidvalidity == active.uidvalidity && receipts[id]?.batchID == batch.id {
                        receipts[id]?.acknowledged = true
                    }
                }
                persist()
                // A concurrent SSE snapshot is newer than an ack response; never overwrite it.
                mail.applyNotificationAck(new, expected:identity, revision:revision)
            }
            prune()
            lastFailure = ackAttempts.isEmpty ? nil : "邮件提醒暂未完成，将在下次同步时重试。"
        } catch {
            // Only a known failed add is retryable automatically. Unrelated uncertain intents survive.
            if let id = activeIntentID, receipts[id]?.handled == false { receipts.removeValue(forKey:id) }
            activeIntentID = nil
            persist()
            guard epoch == self.epoch, !Task.isCancelled else { return }
            lastFailure = "邮件提醒暂未完成，将在下次同步时重试。"
            // No immediate retry on a failed add/ack. Even if ack itself emitted a status, stop this burst.
            dirty = false
        }
    }

    private func recoverReceipts(_ existing: [LocalNotification]) {
        for entry in existing {
            guard case let .email(account, folder, message) = NotificationRoute(userInfo:entry.userInfo),
                  let validity = entry.userInfo["mail_uidvalidity"].flatMap(Int.init),
                  let batch = entry.userInfo["mail_batch"], let encoded = entry.userInfo["mail_members"]?.data(using:.utf8),
                  let members = try? JSONDecoder().decode([String].self,from:encoded) else { continue }
            let route = NotificationRoute.email(accountID:account,folderID:folder,messageID:message)
            guard entry.id == route.notificationIdentifier(itemID:message ?? batch) else { continue }
            if let record = receipts[entry.id] {
                guard record.accountID == account, record.uidvalidity == validity,
                      record.batchID == batch, record.members == members else { continue }
                receipts[entry.id]?.handled = true
                continue
            }
            receipts[entry.id] = MailNotificationReceipt(id:entry.id,accountID:account,uidvalidity:validity,batchID:batch,
                                                       members:members,handled:true,acknowledged:false,createdAt:Date().timeIntervalSince1970)
        }
        // An absent entry proves neither failure nor success (it may have been dismissed).
        // Keep the uncertain intent and backend pending until center evidence or explicit retry.
        persist()
    }

    private func clean(existing: [LocalNotification], status: MailStatus, client: BackendClient,
                       epoch: Int, version: Int) async throws {
        var removals = existing.filter { entry in
            guard case let .email(account, _, _) = NotificationRoute(userInfo:entry.userInfo) else { return false }
            return account != status.mailAccountID || (status.uidvalidity != nil && entry.userInfo["mail_uidvalidity"] != String(status.uidvalidity!))
        }.map(\.id)
        let pendingIDs = Set(mail.pending.map(\.id))
        var invalidMembers: Set<String> = []
        let activeIDs = Set(existing.map(\.id))
        for record in Array(receipts.values) {
            if record.accountID != status.mailAccountID || (status.uidvalidity != nil && record.uidvalidity != status.uidvalidity) {
                removals.append(record.id); receipts.removeValue(forKey:record.id)
                continue
            }
            if !pendingIDs.contains(record.batchID) {
                if !record.handled { receipts.removeValue(forKey:record.id); continue }
                receipts[record.id]?.acknowledged = true
            }
            guard activeIDs.contains(record.id), status.uidvalidity != nil else { continue }
            for id in record.members {
                if invalidMembers.contains(id) { removals.append(record.id); break }
                if let row = try await client.mailSummaryIfPresent(id:id) {
                    guard epoch == self.epoch, version == revision, !Task.isCancelled else { return }
                    if !row.unread || row.key.accountID != status.mailAccountID || row.key.uidvalidity != status.uidvalidity {
                        invalidMembers.insert(id); removals.append(record.id); break
                    }
                } else {
                    guard epoch == self.epoch, version == revision, !Task.isCancelled else { return }
                    invalidMembers.insert(id); removals.append(record.id); break
                }
            }
        }
        guard epoch == self.epoch, version == revision, !Task.isCancelled else { return }
        center.remove(Array(Set(removals))); persist()
    }

    private func notificationTargets(_ batch: MailNotification) -> [LocalNotification] {
        let route = NotificationRoute.email(accountID:batch.accountID,folderID:batch.folderID,messageID:nil)
        let rows: [(String, NotificationRoute, String, String, [String])]
        if batch.mode == .summary {
            rows = [(batch.id,route,"新邮件","收件箱有 \(batch.items.count) 封新邮件",batch.items.map(\.id))]
        } else {
            rows = batch.items.map { ($0.id, MailNotificationPolicy.route(for:$0),
                                     $0.displaySender.isEmpty ? "新邮件" : $0.displaySender, $0.displaySubject, [$0.id]) }
        }
        return rows.map { item, route, title, body, members in
            var info = route.userInfo
            info["mail_batch"] = batch.id; info["mail_uidvalidity"] = String(batch.uidvalidity)
            info["mail_members"] = String(data:try! JSONEncoder().encode(members),encoding:.utf8)!
            return LocalNotification(id:route.notificationIdentifier(itemID:item),title:title,body:body,
                                     threadID:route.threadIdentifier,userInfo:info)
        }
    }

    private func deliver(_ batch: MailNotification, permission: NotificationPermission,
                         identity: MailReaderIdentity, epoch: Int) async throws {
        for target in notificationTargets(batch) {
            guard current(identity,epoch:epoch), let active = mail.pending.first(where:{ $0.id == batch.id }) else { return }
            if receipts[target.id] != nil { continue } // uncertain intents await explicit recovery, never ack
            let members = batch.mode == .summary ? active.items : active.items.filter { MailNotificationPolicy.route(for:$0) == NotificationRoute(userInfo:target.userInfo) }
            guard !members.isEmpty else { continue }
            let suppress = permission == .disabled || members.allSatisfy {
                MailNotificationPolicy.shouldSuppress($0,context:mail.viewingContext?() ?? ViewingContext(activeModule:.messages,isAppActive:false,isWindowVisible:false,selectedChatID:nil))
            }
            prune()
            guard receipts.count < Self.receiptLimit else { throw MailAPIError(status:503,code:"queue_full") }
            receipts[target.id] = MailNotificationReceipt(id:target.id,accountID:batch.accountID,uidvalidity:batch.uidvalidity,
                                                         batchID:batch.id,members:members.map(\.id),handled:suppress,
                                                         acknowledged:false,createdAt:Date().timeIntervalSince1970)
            persist()
            if !suppress {
                activeIntentID = target.id
                try await center.add(target)
                activeIntentID = nil
                guard current(identity,epoch:epoch) else {
                    if mail.status?.mailAccountID == batch.accountID, mail.status?.uidvalidity == batch.uidvalidity,
                       receipts[target.id] != nil {
                        receipts[target.id]?.handled = true; persist()
                    } else { center.remove([target.id]) }
                    return
                }
                // A read/delete can arrive while add is suspended. Remove its late completion.
                let remaining = mail.pending.first(where:{ $0.id == batch.id })?.items.map(\.id) ?? []
                if !members.allSatisfy({ remaining.contains($0.id) }) { center.remove([target.id]) }
                receipts[target.id]?.handled = true; persist()
            }
        }
    }
    private func prune() {
        let pending = Set(mail.pending.map(\.id))
        let removable = receipts.values.filter { $0.acknowledged && !pending.contains($0.batchID) }.sorted { $0.createdAt < $1.createdAt }
        let count = max(0,receipts.count - Self.receiptLimit + 1)
        let ids = removable.prefix(count).map(\.id)
        center.remove(ids); ids.forEach { receipts.removeValue(forKey:$0) }; persist()
    }
}
