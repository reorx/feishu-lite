import Testing
@testable import FeishuChatCore

struct BackendInstallationTests {
    @Test func finderLaunchFindsUVToolWithoutShellPath() {
        let path = BackendInstallation.executable(named: "feishu-lite-backend", home: "/Users/alice", environment: [:]) {
            $0 == "/Users/alice/.local/bin/feishu-lite-backend"
        }
        #expect(path == "/Users/alice/.local/bin/feishu-lite-backend")
    }

    @Test func missingOrNonExecutableToolNeedsInstallation() {
        #expect(BackendInstallation.executable(named: "feishu-lite-backend", home: "/Users/alice", environment: [:], isExecutable: { _ in false }) == nil)
    }

    @Test func customUVBinDirectoryAndHomebrewAreSupported() {
        for location in ["/custom/bin", "/opt/homebrew/bin", "/usr/local/bin"] {
            let path = BackendInstallation.executable(named: "feishu-lite-backend", home: "/Users/alice", environment: ["UV_TOOL_BIN_DIR": "/custom/bin"]) {
                $0 == location + "/feishu-lite-backend"
            }
            #expect(path == location + "/feishu-lite-backend")
        }
    }

    @Test func retryDetectsNewlyInstalledTool() {
        var installed = false
        let check = { (_: String) in installed }
        #expect(BackendInstallation.executable(named: "feishu-lite-backend", home: "/Users/alice", environment: [:], isExecutable: check) == nil)
        installed = true
        #expect(BackendInstallation.executable(named: "feishu-lite-backend", home: "/Users/alice", environment: [:], isExecutable: check) != nil)
    }

    @Test func installationUsesMatchingSourceRevision() {
        let command = BackendInstallation.installCommand(revision: "v0.1.0")
        #expect(command.contains("@v0.1.0#subdirectory=backend"))
        #expect(command.contains("--python 3.12"))
        #expect(command.contains("--force"))
    }
}
