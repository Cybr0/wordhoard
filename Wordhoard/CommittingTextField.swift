import SwiftUI

/// A text field that keeps the text being typed in local state and hands it back once, when the edit
/// ends: on return (single-line fields), on focus loss, and when the field disappears while still
/// focused (Back with the keyboard up). Never on a keystroke, so the card model saves once per edit.
///
/// While not focused the field shows `value`, the stored text, so a rejected or normalized commit
/// (a blank headword, `"big , large"` stored as `"big, large"`) shows the stored form without the
/// parent having to reset anything. The draft is taken from `value` when the field gains focus.
struct CommittingTextField: View {
    private let prompt: Text
    private let value: String
    private let axis: Axis
    private let onCommit: (String) -> Void

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    /// - Parameters:
    ///   - prompt: Placeholder when the text is empty; also the field's accessibility label.
    ///   - value: The stored text, shown whenever the field is not being edited.
    ///   - axis: `.vertical` for fields that may wrap; return then inserts a newline and only focus
    ///     loss commits.
    ///   - onCommit: Receives the draft once per finished edit, unchanged or not.
    init(_ prompt: Text, value: String, axis: Axis = .horizontal, onCommit: @escaping (String) -> Void) {
        self.prompt = prompt
        self.value = value
        self.axis = axis
        self.onCommit = onCommit
    }

    var body: some View {
        TextField(text: text, prompt: prompt, axis: axis) {
            prompt
        }
        .focused($isFocused)
        .onSubmit(commit)
        .onChange(of: isFocused) { _, isFocused in
            if isFocused {
                draft = value
            } else {
                commit()
            }
        }
        .onDisappear {
            if isFocused {
                commit()
            }
        }
    }

    private var text: Binding<String> {
        Binding(
            get: { isFocused ? draft : value },
            set: { draft = $0 }
        )
    }

    private func commit() {
        onCommit(draft)
    }
}
