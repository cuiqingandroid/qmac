import SwiftUI

extension View {
    /// onChange 的跨版本写法。
    /// macOS 14 的双参数版在 13 上不存在，13 的单参数版在 14 上被标记废弃，
    /// 包一层按版本分发，既能在 13 上跑，也不会留一堆废弃警告。
    @ViewBuilder
    func onValueChange<V: Equatable>(of value: V, perform: @escaping (V) -> Void) -> some View {
        if #available(macOS 14.0, *) {
            self.onChange(of: value) { _, newValue in perform(newValue) }
        } else {
            self.onChange(of: value, perform: perform)
        }
    }
}
