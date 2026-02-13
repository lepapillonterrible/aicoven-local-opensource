import Foundation

/// Agent tool definition matching the core package
struct AgentTool: Identifiable, Hashable {
    let id: String
    let label: String
    let family: String
}

/// Catalog of all available agent tools (from @aicoven/core/agent-tools.ts)
/// These tools can be selected when creating or editing agent roles
let AVAILABLE_AGENT_TOOLS: [AgentTool] = [
    // GitHub tools
    AgentTool(id: "github.readFile", label: "GitHub · Read file", family: "github"),
    AgentTool(id: "github.listFiles", label: "GitHub · List files", family: "github"),
    AgentTool(id: "github.proposeFileChanges", label: "GitHub · Propose file changes (no direct write)", family: "github"),
    AgentTool(id: "github.writeFile", label: "GitHub · Write file (commit)", family: "github"),
    AgentTool(id: "github.createBranch", label: "GitHub · Create branch", family: "github"),
    AgentTool(id: "github.createPR", label: "GitHub · Open pull request", family: "github"),

    // Google Drive tools
    AgentTool(id: "google_drive.listFiles", label: "Google Drive · List files", family: "google_drive"),
    AgentTool(id: "google_drive.uploadFile", label: "Google Drive · Upload file", family: "google_drive"),

    // Google Docs tools
    AgentTool(id: "google_docs.read", label: "Google Docs · Read document", family: "google_docs"),
    AgentTool(id: "google_docs.update", label: "Google Docs · Update document", family: "google_docs"),

    // Google Sheets tools
    AgentTool(id: "google_sheets.read", label: "Google Sheets · Read spreadsheet", family: "google_sheets"),
    AgentTool(id: "google_sheets.readValues", label: "Google Sheets · Read values", family: "google_sheets"),
    AgentTool(id: "google_sheets.updateValues", label: "Google Sheets · Update values", family: "google_sheets"),
    AgentTool(id: "google_sheets.batchUpdate", label: "Google Sheets · Batch update", family: "google_sheets"),

    // Google Slides tools
    AgentTool(id: "google_slides.read", label: "Google Slides · Read presentation", family: "google_slides"),
    AgentTool(id: "google_slides.update", label: "Google Slides · Update presentation", family: "google_slides"),

    // Generation tools
    AgentTool(id: "image.generate", label: "Image · Generate", family: "image"),
    AgentTool(id: "video.generate", label: "Video · Generate", family: "video"),
    AgentTool(id: "file.generate", label: "File · Generate", family: "file"),

    // Web tools
    AgentTool(id: "web.search", label: "Web · Search", family: "web"),
    AgentTool(id: "web.browse", label: "Web · Browse", family: "web"),
]

/// Group tools by family for organized display
func groupToolsByFamily() -> [(family: String, tools: [AgentTool])] {
    let grouped = Dictionary(grouping: AVAILABLE_AGENT_TOOLS, by: { $0.family })
    return grouped.sorted { $0.key < $1.key }.map { (family: $0.key, tools: $0.value) }
}

/// Default tools for new roles (matching React Native defaults)
let DEFAULT_ALLOWED_TOOLS: [String] = [
    "image.generate",
    "video.generate",
    "file.generate",
    "web.search",
    "web.browse"
]
