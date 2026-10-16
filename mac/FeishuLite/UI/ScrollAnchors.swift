import SwiftUI

/// macOS 14 的 List 没有可绑定的滚动位置；按实际 viewport 记录首个可见行。
struct VisibleScrollRows: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }

    static func first(in frames: [String: CGRect], height: CGFloat) -> String? {
        frames.filter { $0.value.maxY > 0 && $0.value.minY < height }
            .min { $0.value.minY < $1.value.minY }?.key
    }
}

extension View {
    func trackScrollRow(_ id: String, space: String) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: VisibleScrollRows.self,
                                       value: [id: geometry.frame(in: .named(space))])
            }
        }
    }
}
