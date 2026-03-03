import SwiftUI

// MARK: - MCP Server Management View

/// Main view for managing MCP servers (add/remove/test/view tools)
struct MCPServerManagementView: View {
    @EnvironmentObject var storeService: StoreService

    @State private var servers: [MCPServerAccount] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showAddSheet = false
    @State private var showSubscription = false

    let service = ConnectedAccountsService.shared

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.xl) {
                headerSection

                if isLoading {
                    ProgressView()
                        .padding(.top, Spacing.xxl)
                } else if servers.isEmpty {
                    emptyStateSection
                } else {
                    serverListSection
                }

                addServerButton
            }
            .padding(.bottom, Spacing.xxl)
        }
        .background(NebulaBackground())
        .task { await loadServers() }
        .sheet(isPresented: $showAddSheet) {
            AddMCPServerSheet(onAdded: {
                Task { await loadServers() }
            })
        }
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            if let errorMessage { Text(errorMessage) }
        }
    }

    // MARK: - Sub-views

    private var headerSection: some View {
        VStack(spacing: Spacing.sm) {
            IconBadge(icon: "server.rack", size: 60, color: .aicovenPurple)

            Text("MCP Servers")
                .font(.aicovenDisplaySmall)
                .foregroundColor(.aicovenTextPrimary)

            Text("Connect remote tool servers for extended agent capabilities")
                .font(.aicovenBody)
                .foregroundColor(.aicovenTextSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, Spacing.xl)
        .padding(.horizontal, Spacing.lg)
    }

    private var emptyStateSection: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 48))
                .foregroundColor(.aicovenTextTertiary)

            Text("No MCP Servers")
                .font(.aicovenH2)
                .foregroundColor(.aicovenTextSecondary)

            Text("Add an MCP server like Zapier to give your agents access to thousands of external tools and actions.")
                .font(.aicovenBodySmall)
                .foregroundColor(.aicovenTextTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xl)
        }
        .padding(.top, Spacing.xl)
    }

    private var serverListSection: some View {
        VStack(spacing: Spacing.md) {
            ForEach(servers) { server in
                MCPServerCard(
                    server: server,
                    onTest: { await testServer(server) },
                    onDelete: { await deleteServer(server) }
                )
            }
        }
        .padding(.horizontal, Spacing.lg)
    }

    private var addServerButton: some View {
        Button(action: {
            if storeService.hasToolsPack {
                showAddSheet = true
            } else {
                showSubscription = true
            }
        }) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "plus.circle.fill")
                Text("Add MCP Server")
            }
            .font(.aicovenH3)
            .foregroundColor(.aicovenPurple)
            .padding(Spacing.md)
            .frame(maxWidth: .infinity)
            .background(Color.aicovenPurple.opacity(0.1))
            .cornerRadius(BorderRadius.md)
        }
        .padding(.horizontal, Spacing.lg)
        .sheet(isPresented: $showSubscription) {
            FeatureUpsellView(
                feature: .shellTool, // Gated by Tools Pack
                featureDescription: "Connect remote MCP servers like Zapier or custom endpoints to give your agents powerful new capabilities."
            )
            .environmentObject(storeService)
        }
    }

    // MARK: - API calls

    private func loadServers() async {
        isLoading = true
        defer { isLoading = false }

        let loaded = await service.getAllMCPServers()
        await MainActor.run {
            servers = loaded
        }
    }

    private func testServer(_ server: MCPServerAccount) async {
        do {
            let token = try? await service.getMCPToken(forServerId: server.id)
            let client = MCPClient(server: server, token: token)
            try await client.connect()

            // Wait a moment for tools to cache
            try await Task.sleep(nanoseconds: 1_000_000_000)

            await loadServers()
        } catch {
            // Suggest switching transport if the connection failed
            let transportHint = server.transport == .sse
                ? "\n\nTip: Try removing this server and re-adding it with 'Streamable HTTP' transport."
                : server.transport == .streamableHttp
                ? "\n\nTip: Try removing this server and re-adding it with 'SSE' transport."
                : ""
            errorMessage = "Connection test failed: \(error.localizedDescription)\(transportHint)"
        }
    }

    private func deleteServer(_ server: MCPServerAccount) async {
        do {
            try await service.deleteMCPServer(id: server.id)
            await loadServers()
        } catch {
            errorMessage = "Failed to remove server: \(error.localizedDescription)"
        }
    }
}

// MARK: - MCP Server Card

/// Card displaying a single MCP server with status, tools, and actions
struct MCPServerCard: View {
    let server: MCPServerAccount
    let onTest: () async -> Void
    let onDelete: () async -> Void

    @State private var isTesting = false
    @State private var showTools = false
    @State private var showDeleteConfirm = false

    /// Status indicator color
    private var statusColor: Color {
        switch server.status {
        case .connected: .green
        case .error: .red
        case .pending: .orange
        case .disconnected: .red
        case .revoked: .gray
        }
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                // Header row: name + status
                HStack(spacing: Spacing.md) {
                    ZStack {
                        Circle()
                            .fill(Color.aicovenPurple.opacity(0.2))
                            .frame(width: 48, height: 48)

                        Image(systemName: "server.rack")
                            .font(.system(size: 22))
                            .foregroundColor(.aicovenPurple)
                    }

                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(server.name)
                            .font(.aicovenH3)
                            .foregroundColor(.aicovenTextPrimary)

                        Text(server.serverUrl)
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTextTertiary)
                            .lineLimit(1)
                    }

                    Spacer()

                    // Status badge
                    HStack(spacing: 4) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                        Text(server.status.rawValue.capitalized)
                            .font(.caption2)
                            .fontWeight(.bold)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(statusColor.opacity(0.15))
                    .clipShape(Capsule())
                }

                // Tool count
                if let tools = server.cachedTools, !tools.isEmpty {
                    Button(action: { showTools.toggle() }) {
                        HStack(spacing: Spacing.xs) {
                            Image(systemName: "wrench.and.screwdriver")
                                .font(.caption)
                            Text("\(tools.count) tool\(tools.count == 1 ? "" : "s") available")
                                .font(.aicovenCaption)
                            Image(systemName: showTools ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                        }
                        .foregroundColor(.aicovenTeal)
                    }

                    // Expandable tools list
                    if showTools {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            ForEach(tools, id: \.name) { tool in
                                HStack(spacing: Spacing.xs) {
                                    Image(systemName: "gearshape")
                                        .font(.caption2)
                                        .foregroundColor(.aicovenTextTertiary)
                                    Text(tool.name)
                                        .font(.aicovenCaption)
                                        .foregroundColor(.aicovenTextSecondary)
                                }
                            }
                        }
                        .padding(.leading, Spacing.md)
                    }
                }

                // Action buttons
                HStack(spacing: Spacing.md) {
                    // Test connection
                    Button(action: {
                        isTesting = true
                        Task {
                            await onTest()
                            isTesting = false
                        }
                    }) {
                        HStack(spacing: 4) {
                            if isTesting {
                                ProgressView()
                                    .scaleEffect(0.7)
                            } else {
                                Image(systemName: "bolt.fill")
                            }
                            Text(isTesting ? "Testing..." : "Test")
                        }
                        .font(.aicovenCaption)
                        .foregroundColor(.aicovenTeal)
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, Spacing.xs)
                        .background(Color.aicovenTeal.opacity(0.1))
                        .cornerRadius(BorderRadius.sm)
                    }
                    .disabled(isTesting)

                    Spacer()

                    // Delete
                    Button(action: { showDeleteConfirm = true }) {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                            Text("Remove")
                        }
                        .font(.aicovenCaption)
                        .foregroundColor(.red.opacity(0.8))
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, Spacing.xs)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(BorderRadius.sm)
                    }
                    .confirmationDialog("Remove MCP Server?", isPresented: $showDeleteConfirm) {
                        Button("Remove \(server.name)", role: .destructive) {
                            Task { await onDelete() }
                        }
                    } message: {
                        Text("This will remove the MCP server and its tools from all agents.")
                    }
                }
            }
        }
    }
}

// MARK: - Add MCP Server Sheet

/// Sheet for adding a new MCP server
struct AddMCPServerSheet: View {
    @Environment(\.dismiss) var dismiss

    let onAdded: () -> Void

    @State private var name = ""
    @State private var serverUrl = ""
    @State private var transport = "sse"
    @State private var authType = "none"
    @State private var authToken = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    let service = ConnectedAccountsService.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.lg) {
                    // Info banner
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.aicovenTeal)
                        Text("Enter the details for your remote MCP server (e.g. Zapier, custom server).")
                            .font(.aicovenBodySmall)
                            .foregroundColor(.aicovenTextSecondary)
                    }
                    .padding(Spacing.md)
                    .background(Color.aicovenGlass)
                    .cornerRadius(BorderRadius.md)

                    // Name field
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Server Name")
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTextSecondary)
                        TextField("e.g. Zapier", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }

                    // URL field
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Server URL")
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTextSecondary)
                        TextField("https://actions.zapier.com/mcp/...", text: $serverUrl)
                            .textFieldStyle(.roundedBorder)
                            .disableAutocorrection(true)
                        #if os(iOS)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                        #endif
                    }

                    // Transport picker
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Transport")
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTextSecondary)
                        Picker("Transport", selection: $transport) {
                            Text("SSE").tag("sse")
                            Text("Streamable HTTP").tag("streamable_http")
                        }
                        .pickerStyle(.segmented)
                    }

                    // Auth type picker
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Authentication")
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTextSecondary)
                        Picker("Auth", selection: $authType) {
                            Text("None").tag("none")
                            Text("Bearer Token").tag("bearer")
                            Text("API Key").tag("api_key")
                        }
                        .pickerStyle(.segmented)
                    }

                    // Auth token field (shown when auth is required)
                    if authType != "none" {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text(authType == "bearer" ? "Bearer Token" : "API Key")
                                .font(.aicovenCaption)
                                .foregroundColor(.aicovenTextSecondary)
                            SecureField("Enter token...", text: $authToken)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                }
                .padding(Spacing.lg)
            }
            .background(NebulaBackground())
            .navigationTitle("Add MCP Server")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(action: { Task { await submit() } }) {
                            if isSubmitting {
                                ProgressView()
                            } else {
                                Text("Add")
                                    .fontWeight(.bold)
                            }
                        }
                        .disabled(!isFormValid || isSubmitting)
                    }
                }
                // Show errors as an alert so they're always visible
                .alert("Error", isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )) {
                    Button("OK", role: .cancel) {}
                } message: {
                    if let errorMessage { Text(errorMessage) }
                }
        }
    }

    /// Form validation
    private var isFormValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
            !serverUrl.trimmingCharacters(in: .whitespaces).isEmpty &&
            (authType == "none" || !authToken.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// Submit the new MCP server locally
    private func submit() async {
        guard let url = URL(string: serverUrl.trimmingCharacters(in: .whitespaces)) else {
            errorMessage = "Invalid URL"
            return
        }

        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        let mcpTransport: MCPTransportType = transport == "sse" ? .sse : .streamableHttp
        let mcpAuthType = MCPAuthType(rawValue: authType) ?? .none
        let tokenToSave = authType != "none" ? authToken.trimmingCharacters(in: .whitespaces) : nil

        do {
            let newAccount = try await service.createMCPServer(
                name: name.trimmingCharacters(in: .whitespaces),
                serverUrl: url.absoluteString,
                transport: mcpTransport,
                authType: mcpAuthType,
                token: tokenToSave
            )

            // Trigger background connect
            Task.detached {
                let client = MCPClient(server: newAccount, token: tokenToSave)
                do {
                    try await client.connect()
                } catch {
                    print("Initial MCP connection failed: \(error)")
                }
            }

            await MainActor.run {
                onAdded()
                dismiss()
            }

        } catch {
            errorMessage = "Failed to add server: \(error.localizedDescription)"
        }
    }
}
