#if os(macOS)
import AppKit
import SwiftUI

nonisolated enum GrowingTextEditorLayout {
    /// The lowest the editor gets: one 16 pt line of body text between the
    /// vertical insets, as high as the composer's controls, so that line
    /// shares their centre and, as the text grows, its last line stays level
    /// with them. A taller line makes the editor higher than this.
    static let minHeight: CGFloat = 30
    static let verticalInset: CGFloat = 7
    static let maxHeight: CGFloat = 140

    static func clampedHeight(
        usedGlyphHeight: CGFloat,
        verticalInset: CGFloat,
        minHeight: CGFloat = Self.minHeight,
        maxHeight: CGFloat = Self.maxHeight
    ) -> CGFloat {
        let contentHeight = ceil(usedGlyphHeight) + (verticalInset * 2)
        return max(minHeight, min(maxHeight, contentHeight))
    }

    /// `lineHeight` is one line of the editor's font. Empty text is that
    /// high, and text is never lower, so the editor keeps its height on the
    /// first character where a line is taller than 16 pt (a larger system
    /// text size, or a preferred language with tall letters, such as Thai)
    /// and when the character comes from a fallback font with a lower line.
    /// Text whose line is taller than `lineHeight` still makes it grow.
    static func measuredHeight(
        text: String,
        usedGlyphHeight: CGFloat,
        lineHeight: CGFloat,
        verticalInset: CGFloat,
        minHeight: CGFloat = Self.minHeight,
        maxHeight: CGFloat = Self.maxHeight
    ) -> CGFloat {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return clampedHeight(usedGlyphHeight: lineHeight, verticalInset: verticalInset, minHeight: minHeight, maxHeight: maxHeight)
        }
        return clampedHeight(
            usedGlyphHeight: max(usedGlyphHeight, lineHeight),
            verticalInset: verticalInset,
            minHeight: minHeight,
            maxHeight: maxHeight
        )
    }

    /// The selection after the text is replaced from outside the field: kept
    /// where it was, except that a caret at the end stays at the end, so
    /// typing on after completed text (a picked @mention) goes after it.
    static func selection(afterReplacing old: String, selected: NSRange, with new: String) -> NSRange {
        let kept = safeTextRange(selected, in: old)
        if kept.length == 0, kept.location == (old as NSString).length {
            return NSRange(location: (new as NSString).length, length: 0)
        }
        return safeTextRange(kept, in: new)
    }

    /// `range` held within `text`.
    static func safeTextRange(_ range: NSRange, in text: String) -> NSRange {
        let length = (text as NSString).length
        guard range.location != NSNotFound else {
            return NSRange(location: length, length: 0)
        }
        let location = max(0, min(range.location, length))
        return NSRange(location: location, length: max(0, min(range.length, length - location)))
    }
}

/// The Mac's message field: an AppKit text view in a scroll view, as high
/// as its text up to a limit and scrolling past it. Return sends and
/// Shift+Return starts a new line; a SwiftUI field cannot put a newline at
/// the caret on Shift+Return before macOS 15.
struct GrowingTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat

    var isDisabled: Bool
    var autoFocus: Bool = false
    var onSend: () -> Void
    /// The field became, or stopped being, where typing goes.
    var onFocusChange: ((Bool) -> Void)?

    /// The editor's font, and the height of the empty editor: one line of
    /// it between the insets.
    static var font: NSFont {
        NSFont.preferredFont(forTextStyle: .body)
    }

    static let emptyHeight = GrowingTextEditorLayout.clampedHeight(
        usedGlyphHeight: NSLayoutManager().defaultLineHeight(for: font),
        verticalInset: GrowingTextEditorLayout.verticalInset
    )

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        let textView = ChatTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.font = Self.font
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = NSColor.labelColor
        textView.insertionPointColor = NSColor.controlAccentColor
        textView.textContainerInset = NSSize(width: 4, height: GrowingTextEditorLayout.verticalInset)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: GrowingTextEditorLayout.minHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.string = text
        textView.setAccessibilityLabel("Message")
        textView.setAccessibilityIdentifier("composer")
        textView.onSend = sendKeepingFocus(in: textView)
        textView.onFocusChange = onFocusChange

        scrollView.documentView = textView
        context.coordinator.updateHeight(in: scrollView)
        context.coordinator.focusIfNeeded(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ChatTextView else { return }

        if textView.string != text {
            let selection = GrowingTextEditorLayout.selection(afterReplacing: textView.string, selected: textView.selectedRange(), with: text)
            textView.string = text
            textView.setSelectedRange(selection)
        }

        textView.isEditable = !isDisabled
        textView.isSelectable = !isDisabled
        // Left unset, accessibility reads this text view as not enabled
        // even while it takes typing.
        textView.setAccessibilityEnabled(!isDisabled)
        // Return must call this render's send: it reads the current state.
        textView.onSend = sendKeepingFocus(in: textView)
        textView.onFocusChange = onFocusChange

        context.coordinator.parent = self
        context.coordinator.updateHeight(in: scrollView, publishHeightSynchronously: false)
        context.coordinator.focusIfNeeded(textView)
    }

    /// Sends, and keeps the caret in the field for the next message.
    private func sendKeepingFocus(in textView: ChatTextView) -> () -> Void {
        { [weak textView] in
            onSend()
            textView?.window?.makeFirstResponder(textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GrowingTextEditor
        private var didAutoFocus = false

        init(_ parent: GrowingTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? ChatTextView,
                  let scrollView = textView.enclosingScrollView else { return }
            parent.text = textView.string
            updateHeight(in: scrollView)
            scrollSelectionToVisible(in: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? ChatTextView else { return }
            scrollSelectionToVisible(in: textView)
        }

        private func scrollSelectionToVisible(in textView: NSTextView) {
            textView.scrollRangeToVisible(GrowingTextEditorLayout.safeTextRange(textView.selectedRange(), in: textView.string))
        }

        func updateHeight(in scrollView: NSScrollView, publishHeightSynchronously: Bool = true) {
            guard let textView = scrollView.documentView as? ChatTextView,
                  let textContainer = textView.textContainer,
                  let layoutManager = textView.layoutManager else { return }

            let availableWidth = max(0, scrollView.contentSize.width)
            if availableWidth > 0 {
                textView.frame.size.width = availableWidth
                textContainer.containerSize = NSSize(width: availableWidth, height: CGFloat.greatestFiniteMagnitude)
            }

            layoutManager.ensureLayout(for: textContainer)
            let usedHeight = layoutManager.usedRect(for: textContainer).height
            let measuredHeight = GrowingTextEditorLayout.measuredHeight(
                text: textView.string,
                usedGlyphHeight: usedHeight,
                // The editor's own font: `textView.font` becomes the
                // fallback font of the first character once there is text.
                lineHeight: layoutManager.defaultLineHeight(for: GrowingTextEditor.font),
                verticalInset: textView.textContainerInset.height
            )
            let contentHeight = ceil(usedHeight) + (textView.textContainerInset.height * 2)
            let rawContentHeight = textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? measuredHeight : contentHeight

            if abs(parent.height - measuredHeight) > 0.5 {
                if publishHeightSynchronously {
                    parent.height = measuredHeight
                } else {
                    // Not while SwiftUI is updating the view.
                    DispatchQueue.main.async { [weak self] in
                        guard let self, abs(parent.height - measuredHeight) > 0.5 else { return }
                        parent.height = measuredHeight
                    }
                }
            }

            scrollView.hasVerticalScroller = rawContentHeight > GrowingTextEditorLayout.maxHeight + 0.5
            textView.frame.size.height = max(measuredHeight, rawContentHeight)
        }

        func focusIfNeeded(_ textView: NSTextView) {
            guard parent.autoFocus, !parent.isDisabled, !didAutoFocus else { return }
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView, parent.autoFocus, !parent.isDisabled,
                      let window = textView.window else { return }
                window.makeFirstResponder(textView)
                didAutoFocus = true
            }
        }
    }

    final class ChatTextView: NSTextView {
        var onSend: (() -> Void)?
        var onFocusChange: ((Bool) -> Void)?

        override func becomeFirstResponder() -> Bool {
            let became = super.becomeFirstResponder()
            if became { onFocusChange?(true) }
            return became
        }

        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned { onFocusChange?(false) }
            return resigned
        }

        override func keyDown(with event: NSEvent) {
            // Return, or Enter on the keypad. While an input method is
            // composing (Japanese, Chinese), Return is its own: it confirms
            // what is being composed, and sends nothing.
            let isEnter = (event.keyCode == 36 || event.keyCode == 76) && !hasMarkedText()
            if isEnter, event.modifierFlags.contains(.shift) {
                insertNewline(nil)
            } else if isEnter, let onSend {
                onSend()
            } else {
                super.keyDown(with: event)
            }
        }
    }
}
#endif
