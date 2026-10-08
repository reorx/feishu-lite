import Foundation

/// Finder 不继承用户的 shell PATH，因此也检查 uv 和 Homebrew 的常用安装目录。
public enum BackendInstallation {
    public static func executable(
        named name: String,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> String? {
        let directories = [environment["UV_TOOL_BIN_DIR"], home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
            .compactMap { $0 } + (environment["PATH"] ?? "").components(separatedBy: ":")
        return directories.filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name).path }
            .first(where: isExecutable)
    }

    public static func installCommand(revision: String) -> String {
        // revision 由构建脚本提供（git SHA 或发布 tag），不接收用户输入。
        "uv tool install --force --python 3.12 'git+https://github.com/reorx/feishu-lite.git@\(revision)#subdirectory=backend'"
    }
}
