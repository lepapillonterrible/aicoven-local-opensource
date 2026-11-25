@testable import AICoven
import XCTest

/// What a skill added from a file is called, as the cloud app names one.
final class SkillTitleTests: XCTestCase {
    /// The cloud app's cases: the folder a `SKILL.md` is in, and its text.
    private let skills: [String: String] = [
        "code-simplification": "---\nname: Readable skill name\n---\n# Body",
        "comment-example": "---\n# Example: {key: value}\n# Example: [value]\nname: Readable skill name\n---\n# Body",
        "single-quoted": "---\nname: 'Readable skill name'\n---\n# Body",
        "double-quoted": "---\r\nname: \"Readable skill name\"\r\n---\r\n# Body",
        "closed-flow-before": "---\ntags: [writing]\nname: Readable skill name\n---\n# Body",
        "single-quoted-comment": "---\nname: 'Readable skill name' # 'example'\n---\n# Body",
        "quoted-bracket-before": "---\ntags: [\"[\"]\nname: Readable skill name\n---\n# Body",
        "comment-bracket-before": "---\ntags: [writing] # {example\nname: Readable skill name\n---\n# Body",
        "apostrophe-flow-before": "---\ntags: [don't, x]\nname: Readable skill name\n---\n# Body",
        "double-quoted-comment": "---\nname: \"Readable skill name\" # \"example\"\n---\n# Body",
        "nested-flow-comment": "---\nmetadata: { # }\nname: Nested name\n}\n---\n# Body",
        "absent": "---\ndescription: Instructions\n---\n# Body",
        "blank": "---\nname:  \n---\n# Body",
        "blank-comment": "---\nname: # No name\n---\n# Body",
        "empty-quoted": "---\nname: ''\n---\n# Body",
        "null": "---\nname: null\n---\n# Body",
        "boolean": "---\nname: true\n---\n# Body",
        "number": "---\nname: 123\n---\n# Body",
        "list": "---\nname: [not, a, string]\n---\n# Body",
        "mapping": "---\nname: {nested: value}\n---\n# Body",
        "nested": "---\nmetadata:\n  name: Nested name\n---\n# Body",
        "nested-flow": "---\nmetadata: {\nname: Nested name\n}\n---\n# Body",
        "body-only": "---\ndescription: Instructions\n---\nname: Body name",
        "unclosed": "---\nname: Unclosed name\n# Body",
        "not-leading": "# Body\n---\nname: Body name\n---",
    ]

    func testASkillFileIsCalledByTheNameInItsFrontmatter() throws {
        for folder in [
            "code-simplification", "single-quoted", "double-quoted", "comment-example", "closed-flow-before",
            "single-quoted-comment", "double-quoted-comment", "quoted-bracket-before", "comment-bracket-before", "apostrophe-flow-before",
        ] {
            XCTAssertEqual(try SkillTitle.of(text: XCTUnwrap(skills[folder]), fileName: "SKILL.md", folder: folder), "Readable skill name", folder)
        }
    }

    func testASkillFileWithNoNameThatIsAStringAtItsTop_isCalledByItsFolder() throws {
        for folder in [
            "absent", "blank", "blank-comment", "empty-quoted", "null", "boolean", "number", "list", "mapping",
            "nested", "nested-flow", "nested-flow-comment", "body-only", "unclosed", "not-leading",
        ] {
            XCTAssertEqual(try SkillTitle.of(text: XCTUnwrap(skills[folder]), fileName: "SKILL.md", folder: folder), folder, folder)
        }
        // With no folder to go by, by its own name.
        XCTAssertEqual(SkillTitle.of(text: "# Body", fileName: "SKILL.md", folder: ""), "SKILL")
    }

    func testAnyOtherFileIsCalledByItsOwnName_whateverItsFrontmatterSays() {
        XCTAssertEqual(SkillTitle.of(text: "---\nname: Not the title\n---\n# Body", fileName: "Writing.md", folder: "ordinary"), "Writing")
        XCTAssertEqual(SkillTitle.of(text: "Be brief.", fileName: "house style.txt", folder: ""), "house style")
        XCTAssertEqual(SkillTitle.of(text: "Be brief.", fileName: "notes", folder: ""), "notes")
    }

    func testATitleIsKeptAsOneShortLine() {
        XCTAssertEqual(SkillTitle.kept("  House \n style\t guide  "), "House style guide")
        XCTAssertEqual(SkillTitle.kept(String(repeating: "a", count: 300)).count, SkillTitle.longest)
        XCTAssertEqual(SkillTitle.kept(" \n "), "Untitled")
        XCTAssertEqual(SkillTitle.of(text: "---\nname: \"Two\\nlines\"\n---", fileName: "SKILL.md", folder: "f"), "Two lines")
    }
}
