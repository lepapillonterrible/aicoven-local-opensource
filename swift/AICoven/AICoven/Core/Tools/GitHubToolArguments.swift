import Foundation

/// How a GitHub tool's arguments are read. The cloud app names a
/// repository in one argument, `repo: "owner/name"`; this app's tools took
/// `owner` and `repo` apart. Both are read.
nonisolated enum GitHubToolArguments {
    /// A repository on GitHub.
    struct Repository: Equatable {
        let owner: String
        let name: String

        var fullName: String {
            "\(owner)/\(name)"
        }
    }

    /// What a tool is told when its call names no repository that reads
    /// as one.
    static let repositoryMissing = #"Missing or unreadable 'repo'. Give the repository as "owner/name"."#

    /// The repository a call names: `repo` as "owner/name", or `owner`
    /// and `repo` apart. Nil if neither reads as a repository. Both are
    /// read as they were written: nothing is trimmed or mended.
    static func repository(in args: [String: AnyJSONValue]) -> Repository? {
        guard let repo = args["repo"]?.value as? String else { return nil }
        // An `owner` left out, or given as null (as models write what they
        // leave out), is none. One given as anything else must be text.
        let apart: String?
        switch args["owner"]?.value {
        case nil, is NSNull:
            apart = nil
        case let given as String:
            apart = given
        default:
            return nil
        }
        let parts = repo.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let owner: String
        let name: String
        switch parts.count {
        case 2:
            // "owner/name" says it all; an `owner` beside it must be a
            // name too, and the same one (GitHub does not tell names
            // apart by case).
            if let apart, !isName(apart) || apart.lowercased() != parts[0].lowercased() { return nil }
            (owner, name) = (parts[0], parts[1])
        case 1:
            guard let apart else { return nil }
            (owner, name) = (apart, parts[0])
        default:
            return nil
        }
        guard isName(owner), isName(name) else { return nil }
        return Repository(owner: owner, name: name)
    }

    /// Whether this reads as the name of an owner or a repository: the
    /// letters GitHub gives them, and not a step in a path.
    static func isName(_ name: String) -> Bool {
        guard (1 ... 100).contains(name.utf8.count), name != ".", name != ".." else { return false }
        return name.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "a") ... UInt8(ascii: "z"), UInt8(ascii: "A") ... UInt8(ascii: "Z"), UInt8(ascii: "0") ... UInt8(ascii: "9"):
                true
            case UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."):
                true
            default:
                false
            }
        }
    }

    /// The pull request a call names (`pull_number`, or `number`), as a
    /// number or as digits.
    static func pullNumber(in args: [String: AnyJSONValue]) -> Int? {
        guard let number = whole("pull_number", in: args) ?? whole("number", in: args), number > 0 else { return nil }
        return number
    }

    /// The page asked for: 1 unless a later one is named.
    static func page(in args: [String: AnyJSONValue]) -> Int {
        max(1, whole("page", in: args) ?? 1)
    }

    /// How many results a page holds: what is asked for, between 1 and
    /// 100 (GitHub's most), or `standard` when nothing is.
    static func perPage(in args: [String: AnyJSONValue], standard: Int) -> Int {
        min(100, max(1, whole("per_page", in: args) ?? standard))
    }

    /// A whole number, given as a number or as digits.
    static func whole(_ key: String, in args: [String: AnyJSONValue]) -> Int? {
        switch args[key]?.value {
        case let number as Int:
            number
        case let number as Double:
            Int(exactly: number)
        case let digits as String:
            Int(digits.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            nil
        }
    }

    /// The names two tools had before they took the cloud app's. A call
    /// by an old name is a call of the tool as it is named now.
    static let renamed: [String: String] = [
        "github.getPR": "github.getPullRequest",
        "github.listPRFiles": "github.listPullRequestFiles",
    ]

    /// The name a tool is offered and allowed under.
    static func offeredName(of tool: String) -> String {
        renamed[tool] ?? tool
    }
}
