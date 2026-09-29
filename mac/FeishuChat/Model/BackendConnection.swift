/// 当前可用的后端客户端。后端重启后端口和 token 都会变，所以各处不直接持有 client，而是从这里取。
@MainActor
final class BackendConnection {
    var client: BackendClient?

    enum ConnectionError: Error {
        case notReady
    }

    func requireClient() throws -> BackendClient {
        guard let client else { throw ConnectionError.notReady }
        return client
    }
}
