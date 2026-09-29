import FeishuChatCore
import Foundation
import os

/// 扫码登录流程：向后端要二维码内容，轮询扫码状态，二维码过期自动换新
@MainActor
@Observable
final class LoginModel {
    enum Phase: Equatable {
        case idle
        case loading
        case waiting(qrContent: String)
        case scanned(qrContent: String)
        /// 扫码成功，等后端连上飞书
        case succeeded
        case failed(String)
    }

    static let pollInterval: Duration = .milliseconds(1500)

    private(set) var phase: Phase = .idle

    @ObservationIgnored private let connection: BackendConnection
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.reorx.FeishuChat", category: "login")

    init(connection: BackendConnection) {
        self.connection = connection
    }

    /// 进入未登录状态时调用；流程已经在跑就什么都不做
    func begin() {
        guard task == nil else { return }
        task = Task {
            await run()
            task = nil
        }
    }

    func end() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    func retry() {
        end()
        begin()
    }

    private func run() async {
        do {
            while true {
                phase = .loading
                let client = try connection.requireClient()
                let content = try await client.startQRLogin()
                phase = .waiting(qrContent: content)
                switch try await waitForScan(client, qrContent: content) {
                case .success:
                    phase = .succeeded
                    return
                case .expired:
                    continue
                default:
                    phase = .failed("扫码登录没有成功，请重试")
                    return
                }
            }
        } catch is CancellationError {
            return
        } catch {
            log.error("QR login failed: \(error.localizedDescription, privacy: .public)")
            if !Task.isCancelled {
                phase = .failed("获取二维码失败：\(error.localizedDescription)")
            }
        }
    }

    private func waitForScan(_ client: BackendClient, qrContent: String) async throws -> QRLoginStatus {
        while true {
            try await Task.sleep(for: Self.pollInterval)
            let status = try await client.qrLoginStatus()
            switch status {
            case .waiting, .idle:
                continue
            case .scanned:
                phase = .scanned(qrContent: qrContent)
            case .success, .expired, .failed:
                return status
            }
        }
    }
}
