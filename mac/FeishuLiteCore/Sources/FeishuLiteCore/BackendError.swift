import Foundation

public enum BackendError: LocalizedError, Equatable {
    case loggedOut
    case http(status: Int, detail: String)

    public enum Action: CaseIterable, Sendable {
        case send, loadMessages, loadOlderMessages, getQRCode, loadImage

        fileprivate var failure: String {
            switch self {
            case .send: "发送失败"
            case .loadMessages: "加载消息失败"
            case .loadOlderMessages: "加载更早的消息失败"
            case .getQRCode: "获取二维码失败"
            case .loadImage: "图片加载失败"
            }
        }
    }

    public var errorDescription: String? {
        switch self {
        case .loggedOut: "登录已失效"
        case let .http(status, _): Self.reason(for: status)
        }
    }

    public func userMessage(for action: Action) -> String {
        if self == .loggedOut { return "登录已失效" }
        if case .http(status: 404, detail: _) = self {
            switch action {
            case .loadImage: return "图片已撤回或不可用"
            case .send, .loadMessages, .loadOlderMessages:
                return "\(action.failure)：会话已不存在或无法访问。"
            case .getQRCode: break
            }
        }
        return "\(action.failure)：\(errorDescription!)"
    }

    /// 未知系统错误也只给固定文案，不把 URL、解码内容或后端响应带进界面。
    public static func userMessage(for error: any Error, action: Action) -> String {
        if let error = error as? BackendError { return error.userMessage(for: action) }
        if let error = error as? URLError {
            let reason = error.code == .timedOut ? "请求超时，请稍后重试。" : "无法连接本机后端，请稍后重试。"
            return "\(action.failure)：\(reason)"
        }
        return "\(action.failure)：请求未完成，请稍后重试。"
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 401: "本机后端访问凭证失效，请重新连接后端。"
        case 403: "没有访问权限，请确认当前账号是否可用。"
        case 404: "请求的内容已不存在或无法访问。"
        case 408, 504: "请求超时，请稍后重试。"
        case 429: "操作过于频繁，请稍后重试。"
        case 500...599: "飞书服务暂时不可用，请稍后重试。"
        default: "请求未完成，请稍后重试。"
        }
    }

    public static func responseError(status: Int, body: Data) -> BackendError? {
        guard !(200..<300).contains(status) else { return nil }
        let detail = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        if status == 409, detail?["detail"] as? String == "logged_out" {
            return .loggedOut
        }
        return .http(status: status, detail: String(decoding: body.prefix(200), as: UTF8.self))
    }
}
