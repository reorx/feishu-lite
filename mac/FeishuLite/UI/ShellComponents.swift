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

/// 两个模块共用的侧栏容器；模块切换由内容的头部承载。
struct ModuleSidebar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
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

/// 标题菜单与工具栏共用模块选择和未读快照。
struct ModuleSwitcher: View {
    let activeModule: AppModule
    let counts: UnreadCounts
    let select: (AppModule) -> Void

    private func title(_ module: AppModule) -> String { module == .messages ? "Messages" : "Email" }
    private func count(_ module: AppModule) -> Int { module == .messages ? counts.messages : counts.email }
    private func icon(_ module: AppModule) -> String {
        module == .messages ? "bubble.left.and.bubble.right" : "envelope"
    }

    var body: some View {
        Menu {
            Picker("模块", selection: Binding(get: { activeModule }, set: select)) {
                ForEach([AppModule.messages, .email], id: \.self) { module in
                    Label(menuTitle(module), systemImage: icon(module)).tag(module)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 3) {
                Text(title(activeModule))
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
        .help("切换模块（Messages ⌘1，Email ⌘2）")
        .accessibilityLabel("切换模块，当前为 \(title(activeModule))")
        .accessibilityValue("\(count(activeModule)) 条未读")
    }

    func toolbarButton(_ module: AppModule) -> some View {
        Button { select(module) } label: {
            Image(systemName: icon(module))
                .font(.system(size: 15))
                .frame(width: 28, height: 24)
                .foregroundStyle(activeModule == module ? Color.accentColor : Color.secondary)
                .background(activeModule == module ? Color.accentColor.opacity(0.12) : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
                .overlay(alignment: .topTrailing) {
                    if count(module) > 0 {
                        UnreadBadge(count: count(module), muted: false)
                            .scaleEffect(0.8, anchor: .topTrailing)
                            .offset(x: 5, y: -5)
                            .allowsHitTesting(false)
                    }
                }
        }
        .buttonStyle(.plain)
        .help("\(title(module))（\(module == .messages ? "⌘1" : "⌘2")）")
        .accessibilityLabel("切换到 \(title(module))")
        .accessibilityValue("\(count(module)) 条未读")
        .accessibilityAddTraits(activeModule == module ? [.isSelected] : [])
    }

    private func menuTitle(_ module: AppModule) -> String {
        let unread = count(module)
        return title(module) + (unread > 0 ? "（\(unread > 99 ? "99+" : String(unread)) 条未读）" : "")
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
    /// 可选的关闭按钮，放在最右边
    var dismiss: (() -> Void)?

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
            if let dismiss {
                Button("关闭提示", systemImage: "xmark", action: dismiss)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("关闭")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.color.opacity(0.1))
    }
}

/// 列表里的小空态：居中、次要色，可以带一个小图标、一句说明和一个按钮。
/// 详情区这类主要区域的空态用 ContentUnavailableView。
struct ListEmptyState: View {
    let systemImage: String
    let title: String
    var message: String?
    var action: InlineAction?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if let action {
                Button(action.title, action: action.perform)
                    .controlSize(.small)
                    .disabled(!action.isEnabled)
                    .padding(.top, 2)
            }
        }
        .multilineTextAlignment(.center)
        .padding(20)
        .frame(maxWidth: .infinity)
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
