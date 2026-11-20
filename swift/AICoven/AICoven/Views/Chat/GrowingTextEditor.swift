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
    /// Files, and pictures as PNG bytes, pasted or dropped into the field,
    /// to be attached. Nil pastes and drops as text.
    var onAttach: ((_ files: [URL], _ pictures: [Data]) -> Void)?
    /// Space held in the empty field: talking starts, is sent when Space
    /// is let go, or called off with Esc. Without the first, Space types
    /// a space as ever; the other two are kept for as long as there is a
    /// mic, so that a hold under way can always be ended.
    var onVoiceHoldStart: (() -> Void)?
    var onVoiceHoldStop: (() -> Void)?
    var onVoiceHoldCancel: (() -> Void)?
    /// Esc, while there is something for it to call off.
    var onEscape: (() -> Void)?

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
        textView.onAttach = isDisabled ? nil : onAttach
        textView.onVoiceHoldStart = onVoiceHoldStart
        textView.onVoiceHoldStop = onVoiceHoldStop
        textView.onVoiceHoldCancel = onVoiceHoldCancel
        textView.onEscape = onEscape

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
        textView.onAttach = isDisabled ? nil : onAttach
        textView.onVoiceHoldStart = onVoiceHoldStart
        textView.onVoiceHoldStop = onVoiceHoldStop
        textView.onVoiceHoldCancel = onVoiceHoldCancel
        textView.onEscape = onEscape

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
        var onVoiceHoldStart: (() -> Void)?
        var onVoiceHoldStop: (() -> Void)?
        var onVoiceHoldCancel: (() -> Void)?
        var onEscape: (() -> Void)?
        /// Space is down in the empty field and has not been held long
        /// enough yet to mean talking.
        private var voiceHoldTask: Task<Void, Never>?
        /// Space was held long enough: talking started with it.
        private var isSpaceHoldRecording = false
        private static let spaceKeyCode: UInt16 = 49

        private var holdsToTalk: Bool {
            onVoiceHoldStart != nil && onVoiceHoldStop != nil && onVoiceHoldCancel != nil
        }

        /// What can be dropped on the field depends on whether this is
        /// set, and a text view lists that only when told to: it is told
        /// whenever this is set where it was not, or the other way round.
        /// Listing only adds, so what was listed is dropped first.
        var onAttach: ((_ files: [URL], _ pictures: [Data]) -> Void)? {
            didSet {
                guard (oldValue == nil) != (onAttach == nil) else { return }
                unregisterDraggedTypes()
                updateDragTypeRegistration()
            }
        }

        // MARK: Paste and drop

        override func paste(_ sender: Any?) {
            if attach(from: .general) { return }
            super.paste(sender)
        }

        /// Paste is on only for what the field can read; files and picture
        /// bytes are added so that ⌘V reaches `paste` when the clipboard
        /// holds only those. After the text kinds, so text still wins
        /// over a picture's bytes where both are there (files are
        /// attached whatever text comes with them).
        override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
            onAttach == nil ? super.readablePasteboardTypes : super.readablePasteboardTypes + Self.attachableTypes
        }

        /// Files and picture bytes can be dropped while the composer can
        /// attach them.
        override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
            onAttach == nil ? super.acceptableDragTypes : super.acceptableDragTypes + Self.attachableTypes
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            if attach(from: sender.draggingPasteboard) { return true }
            return super.performDragOperation(sender)
        }

        private func attach(from pasteboard: NSPasteboard) -> Bool {
            guard let onAttach, let found = Self.attachables(on: pasteboard) else { return false }
            onAttach(found.files, found.pictures)
            return true
        }

        static let attachableTypes: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff]

        /// What on the pasteboard is attached and not typed: its files
        /// (not folders); else, where it holds no text, its picture, as
        /// PNG bytes (a TIFF, which can hold the picture at several sizes,
        /// as a PNG of the first). Copied cells or slides carry a picture of
        /// themselves beside their text, and that text is what is meant.
        /// Nil where there is nothing of the kind: it is then pasted or
        /// dropped as text.
        static func attachables(on pasteboard: NSPasteboard) -> (files: [URL], pictures: [Data])? {
            let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            let files = urls.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
            if !files.isEmpty { return (files, []) }
            guard pasteboard.string(forType: .string) == nil else { return nil }
            if let png = pasteboard.data(forType: .png) { return ([], [png]) }
            guard let tiff = pasteboard.data(forType: .tiff), let png = png(from: tiff) else { return nil }
            return ([], [png])
        }

        static func png(from picture: Data) -> Data? {
            NSBitmapImageRep(data: picture)?.representation(using: .png, properties: [:])
        }

        override func becomeFirstResponder() -> Bool {
            let became = super.becomeFirstResponder()
            if became { onFocusChange?(true) }
            return became
        }

        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned {
                onFocusChange?(false)
                callOffSpaceHold()
            }
            return resigned
        }

        override func keyDown(with event: NSEvent) {
            // Return, or Enter on the keypad. While an input method is
            // composing (Japanese, Chinese), Return is its own: it confirms
            // what is being composed, and sends nothing.
            // Talking by a held Space: what else is pressed meanwhile is
            // not typed into the field behind it.
            if isSpaceHoldRecording { return }
            // Another key before Space had been held long enough: Space
            // was typing after all.
            if voiceHoldTask != nil, event.keyCode != Self.spaceKeyCode {
                voiceHoldTask?.cancel()
                voiceHoldTask = nil
                insertText(" ", replacementRange: selectedRange())
            }
            let isEnter = (event.keyCode == 36 || event.keyCode == 76) && !hasMarkedText()
            // Space alone in the empty field, not while an input method
            // composes: held, it talks; let go at once, it types a space.
            let modifiers = event.modifierFlags.intersection([.command, .control, .option])
            let isSpace = event.keyCode == Self.spaceKeyCode && modifiers.isEmpty && !hasMarkedText()
            if isSpace, holdsToTalk, string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // The key repeats while it is held: the first press counts.
                if !event.isARepeat, voiceHoldTask == nil, !isSpaceHoldRecording { waitForSpaceToBeHeld() }
            } else if isEnter, event.modifierFlags.contains(.shift) {
                insertNewline(nil)
            } else if isEnter, let onSend {
                onSend()
            } else {
                super.keyDown(with: event)
            }
        }

        private func waitForSpaceToBeHeld() {
            voiceHoldTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: VoiceHoldToTalkPolicy.spaceHoldDelay)
                guard let self, !Task.isCancelled else { return }
                voiceHoldTask = nil
                isSpaceHoldRecording = true
                onVoiceHoldStart?()
            }
        }

        override func keyUp(with event: NSEvent) {
            guard event.keyCode == Self.spaceKeyCode, voiceHoldTask != nil || isSpaceHoldRecording else {
                super.keyUp(with: event)
                return
            }
            let wasWaiting = voiceHoldTask != nil
            voiceHoldTask?.cancel()
            voiceHoldTask = nil
            if isSpaceHoldRecording {
                isSpaceHoldRecording = false
                onVoiceHoldStop?()
            } else if wasWaiting {
                // Let go before it meant talking: the space it was.
                insertText(" ", replacementRange: selectedRange())
            }
        }

        /// Esc: calls off talking by Space, or whatever else there is.
        override func cancelOperation(_ sender: Any?) {
            if voiceHoldTask != nil || isSpaceHoldRecording {
                voiceHoldTask?.cancel()
                voiceHoldTask = nil
                if isSpaceHoldRecording {
                    isSpaceHoldRecording = false
                    onVoiceHoldCancel?()
                }
                return
            }
            if let onEscape {
                onEscape()
                return
            }
            super.cancelOperation(sender)
        }

        /// The field stopped being where keys go while Space was down:
        /// its release will not come here, so talking by it is called off.
        private func callOffSpaceHold() {
            voiceHoldTask?.cancel()
            voiceHoldTask = nil
            if isSpaceHoldRecording {
                isSpaceHoldRecording = false
                onVoiceHoldCancel?()
            }
        }
    }
}
#endif
