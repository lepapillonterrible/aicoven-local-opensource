import Foundation

/// The names tools had before they took the cloud app's. A call by an old
/// name is a call of the tool as it is named now: allowed, refused and
/// run as that one.
nonisolated enum ToolNames {
    static let renamed: [String: String] = [
        "github.getPR": "github.getPullRequest",
        "github.listPRFiles": "github.listPullRequestFiles",
        "google_sheets.writeValues": "google_sheets.updateValues",
    ]

    /// The name a tool is offered and allowed under.
    static func offeredName(of tool: String) -> String {
        renamed[tool] ?? tool
    }
}
