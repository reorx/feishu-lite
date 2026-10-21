import Foundation
import FeishuLiteCore

/// 本地后端的地址和本次启动用的 token
struct BackendEndpoint: Equatable {
    var baseURL: URL
    var token: String
}

/// 怎么拉起后端：路径来自 Info.plist（值在 Config/Backend.xcconfig），调试开关来自环境变量
struct BackendConfig {
    var uvPath: String
    var backendDir: String
    /// 设了 FEISHU_LITE_BACKEND_URL 和 FEISHU_LITE_TOKEN 时直连已经在跑的后端，不拉子进程
    var externalEndpoint: BackendEndpoint?
    /// 透传给后端的数据目录（FEISHU_LITE_HOME），不设就用后端的默认目录
    var homeOverride: String?

    var mockDataDir: String? = nil

    var usesInstalledBackend: Bool { backendDir.isEmpty }

    var executablePath: String? {
        if usesInstalledBackend {
            return BackendInstallation.executable(named: "feishu-lite-backend")
        }
        if FileManager.default.isExecutableFile(atPath: uvPath) { return uvPath }
        return BackendInstallation.executable(named: "uv")
    }

    static var installationCommand: String {
        let revision = Bundle.main.object(forInfoDictionaryKey: "FeishuBackendRevision") as? String ?? "master"
        return BackendInstallation.installCommand(revision: revision.isEmpty ? "master" : revision)
    }

    static func load(bundle: Bundle = .main,
                     environment: [String: String] = ProcessInfo.processInfo.environment) -> BackendConfig {
        let backendDir = path(bundle.object(forInfoDictionaryKey: "FeishuBackendDir"))
        var mock: String?
        #if DEBUG
        if let raw = environment["FEISHU_LITE_MOCK_DATA"], !raw.isEmpty {
            mock = resolveMockPath(raw, backendDir: backendDir)
        }
        #endif
        return BackendConfig(
            uvPath: path(bundle.object(forInfoDictionaryKey: "FeishuUVPath")),
            backendDir: path(bundle.object(forInfoDictionaryKey: "FeishuBackendDir")),
            externalEndpoint: mock == nil ? externalEndpoint(environment) : nil,
            homeOverride: mock == nil ? environment["FEISHU_LITE_HOME"].flatMap { $0.isEmpty ? nil : $0 } : nil,
            mockDataDir: mock
        )
    }

    static func resolveMockPath(_ raw: String, backendDir: String) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        let root = URL(fileURLWithPath: backendDir).deletingLastPathComponent()
        return URL(fileURLWithPath: expanded, relativeTo: root).standardizedFileURL.path
    }

    func backendArguments(port: Int) -> [String] {
        var arguments = usesInstalledBackend ? ["--port", String(port)]
            : ["run", "--project", backendDir, "feishu-lite-backend", "--port", String(port)]
        if let mockDataDir { arguments += ["--mock-data", mockDataDir] }
        return arguments
    }

    private static func path(_ value: Any?) -> String {
        guard let raw = value as? String, !raw.isEmpty else { return "" }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    private static func externalEndpoint(_ environment: [String: String]) -> BackendEndpoint? {
        guard let raw = environment["FEISHU_LITE_BACKEND_URL"], let url = URL(string: raw),
              let token = environment["FEISHU_LITE_TOKEN"], !token.isEmpty else { return nil }
        return BackendEndpoint(baseURL: url, token: token)
    }
}
