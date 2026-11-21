import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The status dot a Settings row uses for the thing it lists. VoiceOver
/// reads `label`.
struct StatusDot: View {
    let color: Color
    let label: String

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityElement()
            .accessibilityLabel(label)
            .help(label)
    }
}

/// A text field that shows its label. iOS forms show only a field's
/// prompt, so there the label sits beside the field; macOS forms show it
/// already.
struct FormTextField: View {
    let label: String
    @Binding var text: String
    let prompt: String

    var body: some View {
        #if os(iOS)
        LabeledContent(label) {
            TextField(label, text: $text, prompt: Text(prompt))
                .multilineTextAlignment(.trailing)
        }
        #else
        TextField(label, text: $text, prompt: Text(prompt))
        #endif
    }
}

/// A field for an address: no autocorrection, and on iOS the URL keyboard
/// with no capitals.
struct FormAddressField: View {
    let label: String
    @Binding var text: String
    let prompt: String

    var body: some View {
        FormTextField(label: label, text: $text, prompt: prompt)
            .autocorrectionDisabled()
        #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
        #endif
    }
}

/// A secret's field. On iOS it shows its label beside it and a paste button
/// inside the row, and is marked as a code, not a password, so Password
/// AutoFill doesn't offer to save the key.
struct SecureFieldWithPaste: View {
    let label: String
    let prompt: String
    @Binding var text: String

    var body: some View {
        #if os(iOS)
        HStack {
            Text(label)
            SecureField(label, text: $text, prompt: Text(prompt))
                .multilineTextAlignment(.trailing)
                .textContentType(.oneTimeCode)
            Button {
                if let clipboardText = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !clipboardText.isEmpty {
                    text = clipboardText
                }
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Paste \(label)")
        }
        #else
        SecureField(label, text: $text, prompt: Text(prompt))
        #endif
    }
}
