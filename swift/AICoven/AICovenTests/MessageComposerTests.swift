@testable import AICoven
import XCTest

/// What the composer decides from its state: which button its slot is,
/// whether Send sends, what it says of a turn in the way, and its @mentions.
final class MessageComposerTests: XCTestCase {
    func testTheSlot_isStopOnlyWhileATurnRunsWithAnEmptyField() {
        XCTAssertEqual(ComposerRules.slot(text: "", isAgentRunning: true, canStop: true), .stop)
        XCTAssertEqual(ComposerRules.slot(text: " \n", isAgentRunning: true, canStop: true), .stop, "White space is an empty field")
        XCTAssertEqual(ComposerRules.slot(text: "Next", isAgentRunning: true, canStop: true), .send, "Once there is text the slot is Send")
        XCTAssertEqual(ComposerRules.slot(text: "", isAgentRunning: false, canStop: true), .send)
        XCTAssertEqual(ComposerRules.slot(text: "", isAgentRunning: true, canStop: false), .send, "A composer with no turn to stop has no Stop")
    }

    func testSend_needsTextAndNothingInItsWay() {
        XCTAssertTrue(ComposerRules.canSend(text: "Hello", isDisabled: false, isBusy: false))
        XCTAssertFalse(ComposerRules.canSend(text: "", isDisabled: false, isBusy: false))
        XCTAssertFalse(ComposerRules.canSend(text: "  \n ", isDisabled: false, isBusy: false))
        XCTAssertFalse(ComposerRules.canSend(text: "Hello", isDisabled: true, isBusy: false))
        XCTAssertFalse(ComposerRules.canSend(text: "Hello", isDisabled: false, isBusy: true), "Not while a file is being attached or a send is under way")
    }

    func testWhileATurnRuns_theComposerSaysTheMessageWillWaitForIt() {
        XCTAssertEqual(ComposerRules.waitNote(isAgentRunning: true, runningName: "Strix"), "Sends when Strix finishes")
        XCTAssertNil(ComposerRules.waitNote(isAgentRunning: false, runningName: "Strix"))
        XCTAssertEqual(WaitingMessageBubble.note(isNext: true, agentName: "Strix"), "Waiting. Sends when Strix finishes.")
        XCTAssertEqual(WaitingMessageBubble.note(isNext: false, agentName: "Strix"), "Waiting. Sends after the one above.")
    }

    func testWhatIsHandedBackToTheComposer_goesBeforeWhatIsInItABlankLineApart() {
        let file = FileAttachmentDetail(id: "a", name: "a.txt", mimeType: nil, sizeBytes: nil, width: nil, height: nil, url: nil)
        let other = FileAttachmentDetail(id: "b", name: "b.txt", mimeType: nil, sizeBytes: nil, width: nil, height: nil, url: nil)
        let handedBack = ComposerDraft(text: "Waited", attachments: [file])

        XCTAssertEqual(
            handedBack.followed(by: ComposerDraft(text: "Typed since", attachments: [other])),
            ComposerDraft(text: "Waited\n\nTyped since", attachments: [file, other])
        )
        XCTAssertEqual(handedBack.followed(by: ComposerDraft(text: "  ")).text, "Waited", "An empty field adds nothing")
        XCTAssertEqual(ComposerDraft(text: "\n").followed(by: ComposerDraft(text: "Typed")).text, "Typed")
        XCTAssertTrue(ComposerDraft().isEmpty)
        XCTAssertTrue(ComposerDraft(text: " \n").isEmpty)
        XCTAssertFalse(ComposerDraft(attachments: [file]).isEmpty)
    }

    func testMentionSuggestions_showWhileTheTextEndsInAnUnfinishedMention() {
        XCTAssertEqual(ComposerRules.mentionQuery(in: "Ask @"), "")
        XCTAssertEqual(ComposerRules.mentionQuery(in: "Ask @sco"), "sco")
        XCTAssertEqual(ComposerRules.mentionQuery(in: "a@b.c then @Sc"), "Sc", "The last @ is the one being typed")
        XCTAssertNil(ComposerRules.mentionQuery(in: "Ask @Scout to"), "A space ends the mention")
        XCTAssertNil(ComposerRules.mentionQuery(in: "No mention"))
        XCTAssertNil(ComposerRules.mentionQuery(in: ""))

        let roles = (1 ... 8).map { MentionableRole(id: "\($0)", name: $0 == 3 ? "Scout" : "Agent \($0)", emoji: nil) }
        XCTAssertEqual(ComposerRules.suggestions(for: "", among: roles).map(\.id), ["1", "2", "3", "4", "5", "6"], "The first six with nothing typed")
        XCTAssertEqual(ComposerRules.suggestions(for: "SCO", among: roles).map(\.name), ["Scout"])
        XCTAssertEqual(ComposerRules.suggestions(for: "agent", among: roles).count, 6)
        XCTAssertEqual(ComposerRules.suggestions(for: "nobody", among: roles), [])

        XCTAssertEqual(ComposerRules.inserting(mention: "Scout", into: "Ask @sc"), "Ask @Scout ")
        XCTAssertEqual(ComposerRules.inserting(mention: "Scout", into: "No mention"), "No mention")
    }

    #if os(macOS)
    func testTheMacField_isAsHighAsItsTextBetweenOneLineAndItsLimit() {
        // One 16 pt line between the 7 pt insets is the controls' 30 pt.
        XCTAssertEqual(GrowingTextEditorLayout.clampedHeight(usedGlyphHeight: 16, verticalInset: 7), 30)
        XCTAssertEqual(GrowingTextEditorLayout.clampedHeight(usedGlyphHeight: 4, verticalInset: 7), 30, "Never lower than one line's controls")
        XCTAssertEqual(GrowingTextEditorLayout.clampedHeight(usedGlyphHeight: 48.2, verticalInset: 7), 63)
        XCTAssertEqual(GrowingTextEditorLayout.clampedHeight(usedGlyphHeight: 900, verticalInset: 7), 140, "Past its limit it scrolls")

        // Empty text is one line of the editor's font high, whatever was laid out.
        XCTAssertEqual(GrowingTextEditorLayout.measuredHeight(text: " \n", usedGlyphHeight: 60, lineHeight: 20, verticalInset: 7), 34)
        // Text is never lower than that line: a first character from a
        // fallback font with a lower line does not shrink the field.
        XCTAssertEqual(GrowingTextEditorLayout.measuredHeight(text: "a", usedGlyphHeight: 14, lineHeight: 20, verticalInset: 7), 34)
        XCTAssertEqual(GrowingTextEditorLayout.measuredHeight(text: "a\nb", usedGlyphHeight: 40, lineHeight: 20, verticalInset: 7), 54)
    }

    func testTextReplacedFromOutsideTheMacField_keepsTheCaretWhereTypingGoesOn() {
        // A caret at the end stays at the end: a picked @mention is typed after.
        XCTAssertEqual(
            GrowingTextEditorLayout.selection(afterReplacing: "Ask @sc", selected: NSRange(location: 7, length: 0), with: "Ask @Scout "),
            NSRange(location: 11, length: 0)
        )
        // Elsewhere it stays where it was, within the new text.
        XCTAssertEqual(
            GrowingTextEditorLayout.selection(afterReplacing: "Hello there", selected: NSRange(location: 2, length: 3), with: "Hello"),
            NSRange(location: 2, length: 3)
        )
        XCTAssertEqual(
            GrowingTextEditorLayout.selection(afterReplacing: "Hello there", selected: NSRange(location: 6, length: 4), with: "Hi"),
            NSRange(location: 2, length: 0)
        )
        XCTAssertEqual(GrowingTextEditorLayout.safeTextRange(NSRange(location: NSNotFound, length: 0), in: "abc"), NSRange(location: 3, length: 0))
        XCTAssertEqual(GrowingTextEditorLayout.safeTextRange(NSRange(location: 1, length: 9), in: "abc"), NSRange(location: 1, length: 2))
        // Counted as the text view counts: in UTF-16 units.
        XCTAssertEqual(
            GrowingTextEditorLayout.selection(afterReplacing: "👋", selected: NSRange(location: 2, length: 0), with: "👋👋"),
            NSRange(location: 4, length: 0)
        )
    }
    #endif
}
