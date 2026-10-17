import FeishuLiteCore
import SwiftUI

/// 状态行和提示条里附带的按钮
struct InlineAction {
    var title: String
    var isEnabled = true
    var perform: () -> Void
}

/// 侧栏状态的语气，决定圆点颜色，以及侧栏收起后要不要在工具栏露出来。
enum SidebarStatusTone: Equatable {
    case healthy, neutral, warning, error

    var color: Color {
        switch self {
        case .healthy: .green
        case .neutral: .gray
        case .warning: .orange
        case .error: .red
        }
    }

    var isAbnormal: Bool { self == .warning || self == .error }
}

struct SidebarStatus {
    var tone: SidebarStatusTone
    var text: String
    /// 次要信息，比如邮箱地址和同步时间
    var detail: String?
    /// 最近一次操作失败的原因
    var error: String?
    /// 需要用户处理时的入口
    var action: InlineAction?
}

/// 两个模块共用的侧栏：顶部是模块切换，下面是模块自己的头部和列表。
struct ModuleSidebar<Switcher: View, Content: View>: View {
    let switcher: Switcher
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            switcher
            content
        }
        .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
    }
}

/// 两个模块共用的侧栏头部：第一行是标题或菜单加操作按钮，第二行是状态。
struct SidebarHeader<Title: View, Actions: View>: View {
    let status: SidebarStatus
    @ViewBuilder var title: Title
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                title
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                actions
            }
            .controlSize(.small)
            .frame(minHeight: 24)
            SidebarStatusRow(status: status)
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension SidebarHeader where Actions == EmptyView {
    init(status: SidebarStatus, @ViewBuilder title: () -> Title) {
        self.init(status: status, title: title, actions: { EmptyView() })
    }
}

/// 彩色圆点加一句话；需要用户处理时附一个按钮。宽度撑满、左对齐，内容变化时不会左右跳。
struct SidebarStatusRow: View {
    let status: SidebarStatus

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle()
                .fill(status.tone.color)
                .frame(width: 8, height: 8)
                .alignmentGuide(.firstTextBaseline) { $0.height / 2 + 3.5 }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.text)
                    .foregroundStyle(status.tone == .error ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(3)
                if let detail = status.detail {
                    Text(detail)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
                if let error = status.error {
                    Text(error)
                        .foregroundStyle(.red)
                        .lineLimit(4)
                }
            }
            .font(.caption)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("状态：" + [status.text, status.detail, status.error].compactMap { $0 }.joined(separator: "，"))
            Spacer(minLength: 0)
            if let action = status.action {
                Button(action.title, action: action.perform)
                    .controlSize(.small)
                    .disabled(!action.isEnabled)
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 侧栏顶部的模块切换。badge 叠在图标角上，不改变按钮尺寸。
struct ModuleSwitcher: View {
    let activeModule: AppModule
    let counts: UnreadCounts
    let select: (AppModule) -> Void

    var body: some View {
        HStack(spacing: 4) {
            button(.messages, title: "Messages", icon: "bubble.left.and.bubble.right", count: counts.messages,
                   shortcut: "⌘1")
            button(.email, title: "Email", icon: "envelope", count: counts.email, shortcut: "⌘2")
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private func button(_ module: AppModule, title: String, icon: String, count: Int, shortcut: String) -> some View {
        let isSelected = activeModule == module
        return Button { select(module) } label: {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .frame(width: 28, height: 20)
                    .overlay(alignment: .topLeading) {
                        // 叠在图标右上角，只压住图标的一角
                        if count > 0 {
                            UnreadBadge(count: count, muted: false)
                                .fixedSize()
                                .offset(x: 20, y: -7)
                        }
                    }
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .contentShape(.rect)
        }
        .buttonStyle(ModuleSwitchButtonStyle(isSelected: isSelected))
        .help("\(title)（\(shortcut)）")
        .accessibilityLabel(title)
        .accessibilityValue(count > 0 ? "\(count) 条未读" : "没有未读")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// 选中态用强调色底，悬停和按下各有一层浅底。
private struct ModuleSwitchButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, isSelected: isSelected)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        let isSelected: Bool
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .background(fill, in: .rect(cornerRadius: 8))
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovering)
        }

        private var fill: Color {
            if isSelected { return Color.accentColor.opacity(configuration.isPressed ? 0.24 : 0.14) }
            if configuration.isPressed { return Color.primary.opacity(0.12) }
            return isHovering ? Color.primary.opacity(0.06) : .clear
        }
    }
}

enum NoticeTone {
    case warning, error

    var color: Color {
        switch self {
        case .warning: .orange
        case .error: .red
        }
    }
}

/// 统一的提示条：浅色底、图标、文字和按钮。只占自己的高度，文字可以换行，按钮保持完整尺寸。
/// 调用方决定它放在哪里，以及和相邻内容之间要不要加 Divider。
struct NoticeBar: View {
    let tone: NoticeTone
    let systemImage: String
    let title: String
    var message: String?
    var action: InlineAction?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 15))
                .foregroundStyle(tone.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                // 标题跟随环境字体，调用方可以整体调小
                Text(title)
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            // 不用 fixedSize：分栏会用很窄的宽度询问最小高度，固定高度会把整个窗口的最小高度撑大。
            .layoutPriority(1)
            Spacer(minLength: 0)
            if let action {
                Button(action.title, action: action.perform)
                    .disabled(!action.isEnabled)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.color.opacity(0.1))
    }
}

/// 侧栏收起后，当前模块的状态异常时在工具栏露出来；点一下重新展开侧栏。
struct CollapsedSidebarStatus: ToolbarContent {
    let status: SidebarStatus
    @Binding var visibility: NavigationSplitViewVisibility

    var body: some ToolbarContent {
        if visibility == .detailOnly, status.tone.isAbnormal {
            ToolbarItem(placement: .automatic) {
                Button { visibility = .all } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(status.tone.color)
                            .frame(width: 8, height: 8)
                        Text(status.text)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .fixedSize()
                    .padding(.horizontal, 4)
                }
                .help("显示侧栏")
                .accessibilityLabel("状态：\(status.text)，显示侧栏")
            }
        }
    }
}
