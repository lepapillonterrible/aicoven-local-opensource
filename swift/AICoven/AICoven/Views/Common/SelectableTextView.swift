import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A selectable text view that renders Markdown using UIKit/AppKit text views.
/// Handles dynamic sizing to prevent content overflow/overlap in SwiftUI layouts.
struct SelectableTextView: View {
    let text: String
    let fontSize: CGFloat

    @State private var dynamicHeight: CGFloat = .zero

    init(_ text: String, fontSize: CGFloat = 15) {
        self.text = text
        self.fontSize = fontSize
    }

    var body: some View {
        PlatformTextView(text: text, fontSize: fontSize, dynamicHeight: $dynamicHeight)
            .frame(height: dynamicHeight)
    }
}

// MARK: - iOS Implementation

#if os(iOS)
private struct PlatformTextView: UIViewRepresentable {
    let text: String
    let fontSize: CGFloat
    @Binding var dynamicHeight: CGFloat

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isScrollEnabled = false // Critical for auto-sizing
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.linkTextAttributes = [
            .foregroundColor: UIColor(Color.aicovenTeal)
        ]

        // Use default compression resistance to allow growing
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        // Only update text if changed to avoid loops
        if uiView.text != text {
            // Convert Markdown to NSAttributedString
            do {
                // Use default options to support blocks, lists, etc.
                var attributed = try AttributedString(markdown: text)
                attributed.foregroundColor = .white
                attributed.font = .systemFont(ofSize: fontSize)
                uiView.attributedText = NSAttributedString(attributed)
                uiView.textColor = .white
            } catch {
                uiView.text = text
                uiView.textColor = .white
                uiView.font = .systemFont(ofSize: fontSize)
            }
        }

        // Recalculate height
        DispatchQueue.main.async {
            recalculateHeight(view: uiView, result: $dynamicHeight)
        }
    }

    private func recalculateHeight(view: UIView, result: Binding<CGFloat>) {
        let newSize = view.sizeThatFits(CGSize(width: view.frame.width, height: CGFloat.greatestFiniteMagnitude))
        if result.wrappedValue != newSize.height {
            result.wrappedValue = newSize.height
        }
    }
}
#endif

// MARK: - macOS Implementation (Simplified Placeholder)

#if os(macOS)
private struct PlatformTextView: NSViewRepresentable {
    let text: String
    let fontSize: CGFloat
    @Binding var dynamicHeight: CGFloat

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        return textView
    }

    func updateNSView(_ nsView: NSTextView, context: Context) {
        nsView.textStorage?.setAttributedString(NSAttributedString(string: text))
        nsView.textColor = .white
        nsView.font = .systemFont(ofSize: fontSize)

        // Simple sizing for macOS
        DispatchQueue.main.async {
            if let layoutManager = nsView.layoutManager, let container = nsView.textContainer {
                layoutManager.ensureLayout(for: container)
                let size = layoutManager.usedRect(for: container).size
                if dynamicHeight != size.height {
                    dynamicHeight = size.height
                }
            }
        }
    }
}
#endif
