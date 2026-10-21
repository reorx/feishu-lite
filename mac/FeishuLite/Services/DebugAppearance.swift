import AppKit

/// Instance-only override for Debug screenshots; nil leaves appearance to macOS.
@MainActor
enum DebugAppearance {
    static func name(environment: [String: String]) -> NSAppearance.Name? {
        #if DEBUG
        switch environment["FEISHU_LITE_APPEARANCE"] {
        case "light": return .aqua
        case "dark": return .darkAqua
        default: return nil
        }
        #else
        return nil
        #endif
    }

    static func apply(environment: [String: String] = ProcessInfo.processInfo.environment,
                      setAppearance: (NSAppearance?) -> Void = { NSApp.appearance = $0 }) {
        #if DEBUG
        setAppearance(name(environment: environment).flatMap { NSAppearance(named: $0) })
        #endif
    }
}
