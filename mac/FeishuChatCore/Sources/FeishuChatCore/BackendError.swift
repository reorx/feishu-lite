import Foundation

public enum BackendError: LocalizedError, Equatable {
    case loggedOut
    case http(status: Int, detail: String)

    public var errorDescription: String? {
        switch self {
        case .loggedOut: "登录已失效"
        case let .http(status, detail): "请求失败（\(status)）\(detail)"
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
