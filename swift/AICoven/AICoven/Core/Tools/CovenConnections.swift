import Foundation

/// Which of the person's connections a coven's agents may use, and whether
/// to read only or to make changes too. A connection that is not named
/// here is not used in the coven at all.
nonisolated struct CovenConnections: Codable, Hashable {
    /// What agents can do with a connection that is on.
    enum Access: String, Codable, CaseIterable {
        /// Look, and change nothing.
        case readOnly = "read_only"
        /// Look and make changes (each change still asks first).
        case readWrite = "read_write"
    }

    /// The connected apps that are on, by app (`github`, `google_drive`).
    var apps: [String: Access] = [:]
    /// The MCP servers that are on, by the server's id.
    var mcpServers: [String: Access] = [:]

    enum CodingKeys: String, CodingKey {
        case apps
        case mcpServers = "mcp_servers"
    }

    init(apps: [String: Access] = [:], mcpServers: [String: Access] = [:]) {
        self.apps = apps
        self.mcpServers = mcpServers
    }

    /// What was stored, leaving out any entry that does not read as an
    /// access: an entry this app does not understand is not a grant.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func read(_ key: CodingKeys) -> [String: Access] {
            let stored = (try? container.decodeIfPresent([String: String].self, forKey: key)) ?? [:]
            return stored.compactMapValues(Access.init(rawValue:))
        }
        apps = read(.apps)
        mcpServers = read(.mcpServers)
    }
}

nonisolated extension CovenConnections {
    /// What a coven that has made no choice is living by: everything
    /// connected, to read and make changes. Its first change in the
    /// Connections screen starts from this, so that changing one thing
    /// does not turn the others off.
    static func everything(apps: [String], mcpServers: [String]) -> CovenConnections {
        CovenConnections(
            apps: Dictionary(apps.map { ($0, Access.readWrite) }, uniquingKeysWith: { first, _ in first }),
            mcpServers: Dictionary(mcpServers.map { ($0, Access.readWrite) }, uniquingKeysWith: { first, _ in first })
        )
    }

    /// This choice with an app turned on or off. One turned on starts on
    /// read only; one already on keeps what it has.
    func turning(app: String, on: Bool) -> CovenConnections {
        var changed = self
        changed.apps[app] = on ? (apps[app] ?? .readOnly) : nil
        return changed
    }

    /// This choice with what agents can do with an app that is on. Nothing
    /// changes for one that is off.
    func setting(app: String, to access: Access) -> CovenConnections {
        guard apps[app] != nil else { return self }
        var changed = self
        changed.apps[app] = access
        return changed
    }

    /// As `turning(app:on:)`, for an MCP server.
    func turning(mcpServer id: String, on: Bool) -> CovenConnections {
        var changed = self
        changed.mcpServers[id] = on ? (mcpServers[id] ?? .readOnly) : nil
        return changed
    }

    /// As `setting(app:to:)`, for an MCP server.
    func setting(mcpServer id: String, to access: Access) -> CovenConnections {
        guard mcpServers[id] != nil else { return self }
        var changed = self
        changed.mcpServers[id] = access
        return changed
    }
}

nonisolated extension CovenConnections.Access {
    /// As the Connections screen names it.
    var label: String {
        switch self {
        case .readOnly: "Read"
        case .readWrite: "Read and make changes"
        }
    }
}

/// What a coven's choice of connections allows of a tool. The rules are
/// the cloud app's: a connection that is not on is not used; one on to
/// read gives only what changes nothing (for a connected app, every tool
/// but its fixed list of writing ones; for an MCP server, only the tools
/// the server marks as read-only); one on to read and make changes gives
/// all of it. Tools that belong to no connection are not its business.
nonisolated enum CovenConnectionRules {
    /// The connected app a tool belongs to, or nil for a tool of none.
    static func app(of tool: String) -> String? {
        let name = tool.lowercased()
        if name.hasPrefix("github.") { return "github" }
        // One Google connection carries Drive, Docs, Sheets and Slides.
        if ["google_drive.", "google_docs.", "google_sheets.", "google_slides."].contains(where: name.hasPrefix) { return "google_drive" }
        if name.hasPrefix("figma.") { return "figma" }
        if name.hasPrefix("linear.") { return "linear" }
        return nil
    }

    /// The connected-app tools that change something, as the cloud app
    /// lists them, in exactly the spellings the executor takes (camel case
    /// or with underscores).
    static let writeTools: Set<String> = [
        "github.writeFile", "github.write_file",
        "github.createBranch", "github.create_branch",
        "github.createPR", "github.create_pr",
        "google_drive.uploadFile", "google_drive.upload_file",
        "google_sheets.updateValues", "google_sheets.writeValues", "google_sheets.write_values",
        "google_sheets.batchUpdate", "google_docs.update", "google_slides.update",
        "figma.addComment",
    ]

    static func isWriteTool(_ tool: String) -> Bool {
        writeTools.contains(tool)
    }

    /// What the coven's choice says of using a tool.
    enum Decision: Equatable {
        case allowed
        /// The tool's connection is not on in the coven.
        case notOn
        /// It is on to read, and the tool changes something (or, for an
        /// MCP tool, is not marked as only reading).
        case readOnly
    }

    /// For a connected app's tool. `connections` nil means the thread is
    /// in no coven (a personal thread), or in one that has made no choice
    /// yet: everything connected is used, as before there was a choice.
    static func decision(forAppTool tool: String, in connections: CovenConnections?) -> Decision {
        guard let connections, let app = app(of: tool) else { return .allowed }
        guard let access = connections.apps[app] else { return .notOn }
        return access == .readOnly && isWriteTool(tool) ? .readOnly : .allowed
    }

    /// For a tool of an MCP server. Only a tool the server marks as
    /// read-only is one that only reads; one it does not mark, or does not
    /// list, counts as one that changes things.
    static func decision(forToolMarkedReadOnly isMarkedReadOnly: Bool, ofMCPServer serverID: String, in connections: CovenConnections?) -> Decision {
        guard let connections else { return .allowed }
        guard let access = connections.mcpServers[serverID] else { return .notOn }
        return access == .readOnly && !isMarkedReadOnly ? .readOnly : .allowed
    }

    /// The native tools and MCP servers a turn is offered, of those
    /// connected, under the coven's choice: app tools the choice does not
    /// allow are left out; servers that are not on are left out; a server
    /// on to read keeps only its tools marked read-only (and is left out
    /// if it marks none).
    static func offered(tools: Set<String>, servers: [MCPServerAccount], in connections: CovenConnections?) -> (tools: Set<String>, servers: [MCPServerAccount]) {
        guard let connections else { return (tools, servers) }
        let kept = tools.filter { decision(forAppTool: $0, in: connections) == .allowed }
        let on: [MCPServerAccount] = servers.compactMap { server in
            guard let access = connections.mcpServers[server.id] else { return nil }
            guard access == .readOnly else { return server }
            var reading = server
            reading.cachedTools = server.cachedTools?.filter(\.readOnlyHint)
            return reading.cachedTools?.isEmpty == false ? reading : nil
        }
        return (kept, on)
    }

    /// What the model is told when the coven's choice refuses a tool.
    /// `isOfAnMCPServer` says which kind of connection it is: a connected
    /// app's tool is refused for changing something, an MCP server's for
    /// not being marked as read-only by its server.
    static func refusal(_ decision: Decision, tool: String, connection: String, isOfAnMCPServer: Bool = false) -> (message: String, code: String)? {
        switch decision {
        case .allowed:
            return nil
        case .notOn:
            return ("\(connection) is not turned on in this coven, so '\(tool)' cannot be used here. The person can turn it on in this coven's Connections.", "connection_not_on")
        case .readOnly:
            let why = isOfAnMCPServer ? "is not marked as read-only by the server" : "changes something"
            return ("\(connection) is on to read only in this coven, and '\(tool)' \(why). The person can allow changes in this coven's Connections.", "connection_read_only")
        }
    }
}
