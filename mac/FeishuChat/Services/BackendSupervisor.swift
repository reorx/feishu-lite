import Foundation
import os

/// 拉起并守护后端子进程：`uv run --project <backend> feishu-lite-backend --port P`。
/// 每次启动随机选端口、随机生成 token；子进程退出后按退避重启；App 退出时结束它。
@MainActor
final class BackendSupervisor {
    enum State: Equatable {
        case stopped
        case starting
        case ready(BackendEndpoint)
        /// 起不来，退避之后会再试
        case failed(String)
        /// 依赖缺失时暂停，等待用户安装后主动重新检测。
        case dependencyMissing(String)
    }

    static let backoff: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(10), .seconds(30)]
    /// 首次启动 uv 可能要同步依赖，给足时间
    static let readyTimeout: Duration = .seconds(90)
    static let logFileLimit = 5 * 1024 * 1024

    private(set) var state: State = .stopped {
        didSet {
            if state != oldValue {
                onStateChange?(state)
            }
        }
    }
    var onStateChange: ((State) -> Void)?

    private let config: BackendConfig
    private let log = Logger(subsystem: "com.reorx.FeishuChat", category: "backend")
    private var process: Process?
    private var loop: Task<Void, Never>?

    init(config: BackendConfig) {
        self.config = config
    }

    func start() {
        guard loop == nil else { return }
        if let external = config.externalEndpoint {
            log.notice("using external backend at \(external.baseURL.absoluteString, privacy: .public)")
            state = .ready(external)
            return
        }
        guard config.executablePath != nil else {
            state = .dependencyMissing(config.usesInstalledBackend ? "feishu-lite-backend" : "uv")
            return
        }
        loop = Task { await superviseLoop() }
    }

    /// App 退出时调用：结束子进程并等它退出（最多 timeout 秒）。
    /// 即使这里没等到，后端也会靠 FEISHU_LITE_PARENT_PID 在 2 秒内发现 App 不在了自己退出。
    func stop(timeout: TimeInterval = 2) {
        loop?.cancel()
        loop = nil
        state = .stopped
        guard let process, process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    // MARK: - 守护循环

    private func superviseLoop() async {
        var attempt = 0
        while !Task.isCancelled {
            state = .starting
            do {
                let (process, endpoint, exit) = try launch()
                self.process = process
                if try await waitUntilReady(endpoint, process: process) {
                    attempt = 0
                    state = .ready(endpoint)
                } else {
                    process.terminate()
                }
                let code = await exit.value
                log.warning("backend exited with status \(code)")
                if Task.isCancelled { return }
                state = .failed("后端进程退出了（退出码 \(code)），正在重启")
            } catch is CancellationError {
                return
            } catch {
                log.error("failed to launch backend: \(error.localizedDescription, privacy: .public)")
                state = .failed("后端启动失败：\(error.localizedDescription)")
            }
            let delay = Self.backoff[min(attempt, Self.backoff.count - 1)]
            attempt += 1
            try? await Task.sleep(for: delay)
        }
    }

    private func launch() throws -> (Process, BackendEndpoint, Task<Int32, Never>) {
        guard let executablePath = config.executablePath else {
            throw SupervisorError.uvNotFound(config.uvPath)
        }
        let port = try Self.freePort()
        let token = Self.randomToken()
        let logHandle = try Self.openLogFile()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = config.usesInstalledBackend
            ? ["--port", String(port)]
            : ["run", "--project", config.backendDir, "feishu-lite-backend", "--port", String(port)]
        if !config.usesInstalledBackend {
            process.currentDirectoryURL = URL(fileURLWithPath: config.backendDir)
        }
        var environment = ProcessInfo.processInfo.environment
        environment["FEISHU_LITE_TOKEN"] = token
        environment["FEISHU_LITE_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        environment["FEISHU_LITE_HOME"] = config.homeOverride
        environment["PYTHONUNBUFFERED"] = "1"
        // 这个项目的虚拟环境和当前 shell 激活的那个无关
        environment["VIRTUAL_ENV"] = nil
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = logHandle
        process.standardError = logHandle

        let (exitCodes, continuation) = AsyncStream.makeStream(of: Int32.self)
        process.terminationHandler = { finished in
            continuation.yield(finished.terminationStatus)
            continuation.finish()
        }
        try process.run()
        try? logHandle.close()
        log.notice("backend started, pid \(process.processIdentifier), port \(port)")

        let exit = Task.detached { () -> Int32 in
            for await code in exitCodes { return code }
            return -1
        }
        let endpoint = BackendEndpoint(baseURL: URL(string: "http://127.0.0.1:\(port)")!, token: token)
        return (process, endpoint, exit)
    }

    /// 轮询 /status，返回 200 即就绪。进程提前退出或超时返回 false。
    private func waitUntilReady(_ endpoint: BackendEndpoint, process: Process) async throws -> Bool {
        let client = BackendClient(endpoint: endpoint)
        let deadline = ContinuousClock.now + Self.readyTimeout
        while process.isRunning, ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if (try? await client.status()) != nil {
                return true
            }
            try await Task.sleep(for: .milliseconds(300))
        }
        return false
    }

    // MARK: - 零件

    private enum SupervisorError: LocalizedError {
        case uvNotFound(String)
        case noFreePort

        var errorDescription: String? {
            switch self {
            case let .uvNotFound(path): "找不到 uv（\(path)），检查 Config/Backend.xcconfig 里的 FEISHU_UV_PATH"
            case .noFreePort: "分配不到本地端口"
            }
        }
    }

    static var logFileURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appending(path: "Logs/FeishuChat/backend.log")
    }

    private static func openLogFile() throws -> FileHandle {
        let url = logFileURL
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let size = (try? manager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size > logFileLimit {
            let rotated = url.appendingPathExtension("1")
            try? manager.removeItem(at: rotated)
            try? manager.moveItem(at: url, to: rotated)
        }
        // 必须用 O_APPEND：重启时旧后端还在写收尾日志，普通写句柄各记各的偏移量，会互相覆盖
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    /// 让系统在回环地址上分配一个空闲端口
    private static func freePort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw SupervisorError.noFreePort }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)

        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(descriptor, generic, length) == 0 && getsockname(descriptor, generic, &length) == 0
            }
        }
        guard bound else { throw SupervisorError.noFreePort }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }
}
