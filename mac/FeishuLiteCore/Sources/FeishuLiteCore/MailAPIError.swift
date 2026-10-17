import Foundation

/// 安全 mail 错误；未知 code/原始响应/系统异常永远不进入描述。
public struct MailAPIError: LocalizedError, Equatable, Sendable {
    public let status: Int
    public let code: String
    public var isLocalTokenFailure: Bool { status == 401 }
    public var needsStatusRefresh: Bool { status == 504 || code == "transport_failed" }
    /// 只判断重试同一封正文是否有意义；通信失败和未知错误保留重试入口。
    public var isBodyRetryable: Bool { !Self.permanentBodyCodes.contains(code) }
    public init(status: Int, code: String) {
        self.status = status
        self.code = Self.knownCodes.contains(code) ? code : "unknown"
    }
    public var errorDescription: String? {
        if isLocalTokenFailure { return "本机后端访问凭证失效，请重新连接后端。" }
        switch code {
        case "credential_missing": return "请重新输入邮箱专用密码。"
        case "authentication_failed": return "邮箱专用密码已失效，请更新密码；聊天登录不受影响。"
        case "mailbox_readonly": return "邮箱只读，无法同步已读状态。"
        case "unconfigured": return "请先配置邮箱。"
        case "offline", "disconnected", "not_synced", "service_stopped", "executor_stopped", "transport_failed":
            return "邮箱暂时无法连接，缓存和未读数已保留，请稍后重试。"
        case "stale_message", "stale_cursor", "stale_request", "account_mismatch": return "邮箱状态已变化，请刷新后重试。"
        case "message_missing", "folder_missing", "inbox_missing": return "目标已不存在，请刷新邮箱。"
        case "connection_test_busy", "queue_full": return "邮箱正在处理其他请求，请稍后重试。"
        case "command_timeout", "idle_done_timeout", "request_timeout": return "请求超时，正在重新确认邮箱状态，请稍后重试。"
        case "invalid_request": return "请检查邮箱地址和专用密码。"
        case "tls_failed": return "无法建立安全的邮箱连接，请检查网络后重试。"
        case "malformed_mime": return "这封邮件的格式已损坏，无法解析正文。请使用飞书邮箱查看。"
        case "malformed_encoding": return "这封邮件的正文编码已损坏，无法解码。请使用飞书邮箱查看。"
        case "unsupported_charset": return "暂不支持这封邮件使用的字符集。请使用飞书邮箱查看。"
        case "unsupported_transfer_encoding": return "暂不支持这封邮件使用的传输编码。请使用飞书邮箱查看。"
        case "unsupported_body": return "这封邮件没有受支持的可读正文。请使用飞书邮箱查看。"
        case "mime_too_deep": return "这封邮件的嵌套层级过多，无法安全解析。请使用飞书邮箱查看。"
        case "too_many_parts": return "这封邮件的组成部分过多，无法安全解析。请使用飞书邮箱查看。"
        case "body_too_large": return "这封邮件的正文过大，超出安全读取上限。请使用飞书邮箱查看。"
        case "headers_too_large": return "这封邮件的头部过大，超出安全读取上限。请使用飞书邮箱查看。"
        case "response_too_large": return "这封邮件的数据过大，超出安全读取上限。请使用飞书邮箱查看。"
        default: return "邮箱请求未完成，请稍后重试。"
        }
    }
    public static func responseError(status: Int, body: Data) -> MailAPIError? {
        guard !(200..<300).contains(status) else { return nil }
        let fields = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let code = fields?["domain"] as? String == "mail" ? fields?["code"] as? String : nil
        return MailAPIError(status: status, code: code ?? "unknown")
    }
    private static let permanentBodyCodes: Set<String> = [
        "malformed_mime", "malformed_encoding", "unsupported_charset", "unsupported_transfer_encoding",
        "unsupported_body", "mime_too_deep", "too_many_parts", "body_too_large", "headers_too_large", "response_too_large"
    ]
    private static let knownCodes: Set<String> = [
        "unconfigured", "account_mismatch", "invalid_id", "unsupported_folder", "invalid_page_size",
        "credential_missing", "authentication_failed", "mailbox_readonly", "message_missing", "folder_missing", "inbox_missing",
        "stale_message", "stale_cursor", "stale_request", "body_too_large", "response_too_large", "headers_too_large",
        "mime_too_deep", "too_many_parts", "invalid_request", "malformed_mime", "malformed_encoding", "unsupported_charset",
        "unsupported_transfer_encoding", "unsupported_body", "malformed_response", "seen_not_persisted", "command_rejected",
        "disconnected", "imap_failed", "tls_failed", "offline", "not_synced", "service_stopped", "executor_stopped",
        "stop_timeout", "queue_full", "connection_test_busy", "command_timeout", "idle_done_timeout", "request_timeout",
        "internal_error", "transport_failed"
    ]
}
