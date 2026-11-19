import SwiftUI

/// macOS 13 replacement for `onChange(of:initial:_:)` (macOS 14+).
private struct ChangeModifier<V: Equatable>: ViewModifier {
    let value: V
    let action: (V, V) -> Void
    @State private var previous: V

    init(value: V, action: @escaping (V, V) -> Void) {
        self.value = value
        self.action = action
        _previous = State(initialValue: value)
    }

    func body(content: Content) -> some View {
        content.onChange(of: value) { new in
            let old = previous
            previous = new
            action(old, new)
        }
    }
}

extension View {
    func onChangeCompat<V: Equatable>(of value: V, _ action: @escaping (V, V) -> Void) -> some View {
        modifier(ChangeModifier(value: value, action: action))
    }

    func onChangeCompat<V: Equatable>(of value: V, initial: Bool, _ action: @escaping (V, V) -> Void) -> some View {
        modifier(ChangeModifier(value: value, action: action))
            .onAppear { if initial { action(value, value) } }
    }

    func onChangeCompat<V: Equatable>(of value: V, _ action: @escaping () -> Void) -> some View {
        onChange(of: value) { _ in action() }
    }
}
