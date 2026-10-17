import Foundation
import FeishuLiteCore

struct MailReaderIdentity: Hashable {
    let epoch: Int
    let accountID: String
    let generation: Int
    let uidvalidity: Int
    var messageID: String?
}

struct MailRenderToken: Equatable {
    let identity: MailReaderIdentity
    let selection: Int
    let presentation: UUID
}

@MainActor extension MailState {
    var canRetryBody: Bool {
        guard case .failed = bodyLoadState else { return false }
        return bodyFailure?.isBodyRetryable ?? true
    }

    var displayedBodyRoute: NotificationRoute? {
        guard let token = displayedToken, token == renderToken, isCurrent(token),
              !showsConfiguration, case .loaded = bodyLoadState else { return nil }
        return selectedRoute
    }

    func invalidatePresentation() {
        renderToken = nil
        displayedToken = nil
        readTask?.cancel()
        readTask = nil
        readTaskID = UUID()
        isReading = false
        readError = nil
    }
    func invalidateReaderConnection() {
        htmlInteractions.removeAll()
        plainPositions.removeAll()
        invalidatePresentation()
        selectionRevision += 1
        if case .loading = bodyLoadState { bodyLoadState = .failed("邮箱连接已变化，请重新读取正文。") }
    }

    func stopReader() {
        readerTask?.cancel(); readerTask = nil
        readerTaskID = UUID()
        readTask?.cancel(); readTask = nil
        wantsReaderRefresh = false
        readerRevision += 1
        selectionRevision += 1
        isRefreshingReader = false
        isPaging = false
        isReading = false
    }

    func resetReader() {
        stopReader()
        items = []; folders = []; nextCursor = nil
        hasLoadedList = false
        listError = nil
        routeError = nil
        readAttempts.removeAll()
    }

    /// One coalesced job, including events received during a slow page.
    func requestReaderRefresh() {
        guard readerIdentity != nil else { return }
        wantsReaderRefresh = true
        readerRevision += 1 // immediately invalidates pagination already in flight
        guard readerTask == nil else { return }
        let epoch = readerIdentity!.epoch
        let job = UUID()
        readerTaskID = job
        readerTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.readerTaskID == job { self.readerTask = nil; self.isRefreshingReader = false } }
            while self.wantsReaderRefresh, !Task.isCancelled, self.readerIdentity?.epoch == epoch {
                self.wantsReaderRefresh = false
                await self.performReaderRefresh()
            }
        }
    }
    func waitForReaderWork() async { await readerTask?.value }

    func refreshReader() async {
        requestReaderRefresh()
        await readerTask?.value
    }

    private func performReaderRefresh() async {
        guard let identity = readerIdentity, let client = readerClient else { return }
        let revision = readerRevision
        isRefreshingReader = true
        let job = readerTaskID
        defer { if job == readerTaskID { isRefreshingReader = false } }
        do {
            let newFolders = try await client.mailFolders()
            guard identity == readerIdentity, revision == readerRevision, !Task.isCancelled else { return }
            // Rebuild the loaded prefix so missed deletes/reconnects cannot retain stale rows.
            let oldestLoadedUID = items.last?.key.uid
            var rows: [MailSummary] = []
            var cursor: String?
            var usedCursors: Set<String> = []
            repeat {
                let page = try await client.mailMessages(cursor: cursor)
                guard identity == readerIdentity, revision == readerRevision, !Task.isCancelled else { return }
                guard page.items.allSatisfy({ matches($0, identity) }) else { throw MailAPIError(status:410,code:"stale_request") }
                rows = merged(rows, page.items)
                cursor = page.nextCursor
                if let cursor, !usedCursors.insert(cursor).inserted { throw MailAPIError(status:502,code:"malformed_response") }
            } while cursor != nil && oldestLoadedUID != nil && (rows.last?.key.uid ?? Int.max) > oldestLoadedUID!
            folders = newFolders
            items = rows
            nextCursor = cursor
            hasLoadedList = true
            listError = nil
            // A route may deliberately point outside the loaded prefix.
            if let id = selectedMessageID, let row = rows.first(where: { $0.id == id }) { selectedSummary = row }
        } catch {
            guard identity == readerIdentity, revision == readerRevision, !Task.isCancelled else { return }
            listError = readerError(error, body: false)
            if (error as? MailAPIError)?.status == 410 {
                nextCursor = nil
                // No auto retry loop: the next explicit refresh/state event will recover.
                await refreshStatus()
            }
        }
    }

    func loadNextPage() async {
        guard !isPaging, !isRefreshingReader, let cursor = nextCursor,
              let identity = readerIdentity, let client = readerClient else { return }
        isPaging = true
        let revision = readerRevision
        defer { if identity == readerIdentity { isPaging = false } }
        do {
            let page = try await client.mailMessages(cursor:cursor)
            guard identity == readerIdentity, revision == readerRevision, cursor == nextCursor, !Task.isCancelled else { return }
            guard page.items.allSatisfy({ matches($0, identity) }), page.nextCursor != cursor else { throw MailAPIError(status:410,code:"stale_cursor") }
            items = merged(items, page.items)
            nextCursor = page.nextCursor
            listError = nil
        } catch {
            guard identity == readerIdentity, revision == readerRevision, !Task.isCancelled else { return }
            listError = readerError(error, body:false)
            if (error as? MailAPIError)?.status == 410 {
                nextCursor = nil
                await refreshStatus()
                await refreshReader()
            }
        }
    }

    private func matches(_ row: MailSummary, _ identity: MailReaderIdentity) -> Bool {
        row.key.accountID == identity.accountID && row.key.folderID == "INBOX" && row.key.uidvalidity == identity.uidvalidity
    }
    private func merged(_ old: [MailSummary], _ new: [MailSummary]) -> [MailSummary] {
        var rows = Dictionary(old.map { ($0.id,$0) }, uniquingKeysWith: { _, last in last })
        for row in new { rows[row.id] = row }
        return rows.values.sorted { $0.key.uid > $1.key.uid }
    }

    func selectMessage(_ id: String?) async {
        selectionRevision += 1
        let revision = selectionRevision
        invalidatePresentation()
        selectedMessageID = id
        selectedSummary = nil
        bodyLoadState = id == nil ? .idle : .loading
        routeError = nil
        guard let id, let identity = readerIdentity, let client = readerClient else { return }
        do {
            let row: MailSummary
            if let cached = items.first(where: { $0.id == id }) { row = cached }
            else { row = try await client.mailSummary(id:id) }
            guard identity == readerIdentity, revision == selectionRevision, selectedMessageID == id, !Task.isCancelled else { return }
            guard row.id == id, matches(row, identity) else { throw MailAPIError(status:410,code:"stale_message") }
            selectedSummary = row
            let body = try await client.mailBody(id:id)
            guard identity == readerIdentity, revision == selectionRevision, selectedMessageID == id, !Task.isCancelled else { return }
            bodyLoadState = .loaded(body)
        } catch {
            guard identity == readerIdentity, revision == selectionRevision, selectedMessageID == id, !Task.isCancelled else { return }
            if let api = error as? MailAPIError, api.status == 404 || api.status == 410 {
                selectedMessageID = nil
                selectedSummary = nil
                bodyLoadState = .idle
                routeError = "这封邮件已不存在或已失效，已返回收件箱。"
                await refreshStatus()
                requestReaderRefresh()
            } else {
                bodyLoadState = .failed(readerError(error, body:true))
                bodyFailure = error as? MailAPIError
            }
        }
    }

    func openRoute(_ route: NotificationRoute) async {
        guard case let .email(account, folder, id) = route, account == status?.mailAccountID,
              folder == "INBOX" else {
            await selectMessage(nil)
            routeError = "通知的邮箱目标已失效，已返回当前收件箱。"
            return
        }
        showsConfiguration = false
        selectedFolderID = "INBOX"
        await selectMessage(id)
        if id == nil { requestReaderRefresh() }
    }

    func beginBodyPresentation() -> MailRenderToken? {
        guard case .loaded = bodyLoadState, var identity = readerIdentity, let id = selectedMessageID,
              selectedSummary?.id == id, !showsConfiguration else { return nil }
        identity.messageID = id
        let token = MailRenderToken(identity:identity, selection:selectionRevision, presentation:UUID())
        renderToken = token
        displayedToken = nil
        if selectedSummary?.unread == true, readAttempts.contains(identity) {
            readError = "上次已读结果尚未确认，可重试。"
        }
        return token
    }
    private func isCurrent(_ token: MailRenderToken) -> Bool {
        var identity = readerIdentity
        identity?.messageID = selectedMessageID
        return identity == token.identity && token.selection == selectionRevision && token == renderToken
    }
    func bodyDidDisplay(_ token: MailRenderToken) {
        guard isCurrent(token), !showsConfiguration, case .loaded = bodyLoadState else { return }
        displayedToken = token
        reevaluateViewing()
    }
    func bodyDidDisappear(_ token: MailRenderToken) {
        if token == renderToken { invalidatePresentation() }
    }
    func bodyRenderFailed(_ token: MailRenderToken) {
        guard isCurrent(token) else { return }
        invalidatePresentation()
        bodyLoadState = .failed("正文未能安全显示，请重试。")
    }

    func reevaluateViewing() {
        guard !isReading, status?.state == .online, let route = displayedBodyRoute,
              viewingContext?().shouldMarkMailRead(route:route,bodyLoaded:true) == true,
              let token = displayedToken, selectedSummary?.unread == true,
              !readAttempts.contains(token.identity) else { return }
        readAttempts.insert(token.identity)
        isReading = true
        let job = UUID()
        readTaskID = job
        readTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.readTaskID == job { self.isReading = false; self.readTask = nil } }
            await self.submitRead(token)
        }
    }
    private func submitRead(_ token: MailRenderToken) async {
        guard isCurrent(token), displayedToken == token, let client = readerClient,
              let id = token.identity.messageID,
              let route = displayedBodyRoute,
              viewingContext?().shouldMarkMailRead(route:route,bodyLoaded:true) == true else {
            readAttempts.remove(token.identity)
            return
        }
        do {
            let result = try await client.readMail(id:id)
            guard isCurrent(token), !Task.isCancelled else { return }
            applyReadIDs(result.readIDs)
            readError = nil
            await refreshStatus() // count always comes from the whole inbox snapshot
        } catch {
            guard isCurrent(token), !Task.isCancelled else { return }
            readError = readerError(error,body:false)
            let api = error as? MailAPIError
            if api?.needsStatusRefresh == true || api?.status == 404 || api?.status == 410 {
                await refreshStatus()
                guard isCurrent(token), !Task.isCancelled else { return }
                // STORE may have happened before timeout; verify the exact row once.
                await verifyReadTarget(id, token:token)
            }
        }
    }
    private func verifyReadTarget(_ id: String, token: MailRenderToken) async {
        guard let client = readerClient else { return }
        do {
            let row = try await client.mailSummary(id:id)
            guard isCurrent(token), row.id == id, matches(row,token.identity), !Task.isCancelled else { return }
            selectedSummary = row
            if !row.unread { applyReadIDs([id]); readError = nil }
        } catch {
            guard isCurrent(token), !Task.isCancelled else { return }
            if let api = error as? MailAPIError, api.status == 404 || api.status == 410 {
                await selectMessage(nil)
                routeError = "这封邮件已不存在或已失效，已返回收件箱。"
                requestReaderRefresh()
            }
        }
    }
    func retryRead() async {
        guard let token = displayedToken else { return }
        readAttempts.remove(token.identity)
        readError = nil
        reevaluateViewing()
        await readTask?.value
    }
    func applyReadIDs(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        if let account = status?.mailAccountID { onReadIDs?(ids, account) }
        removePendingMembers(ids)
        for i in items.indices where ids.contains(items[i].id) { items[i].unread = false }
        if let id = selectedSummary?.id, ids.contains(id) { selectedSummary?.unread = false }
    }
    private func readerError(_ error: Error, body: Bool) -> String {
        if let api = error as? MailAPIError {
            if body, api.code == "offline" { return "当前离线，这封邮件尚未缓存正文。连接后可重试。" }
            if api.code == "not_synced" { return "正在首次同步收件箱，请稍后刷新。" }
            return api.localizedDescription
        }
        return "邮件加载未完成，请重试。"
    }
}
