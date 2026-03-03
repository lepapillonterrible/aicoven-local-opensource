import SwiftUI

struct MCPServerManagementView: View {
    @State private var servers: [MCPServerAccount] = []
    @State private var showingAddSheet = false
    @State private var selectedServer: MCPServerAccount?

    // Form state
    @State private var newName = ""
    @State private var newUrl = ""
    @State private var authType = "none"
    @State private var bearerToken = ""

    // Status state
    @State private var isSaving = false
    @State private var errorMessage: String?

    let service = ConnectedAccountsService.shared

    var body: some View {
        Form {
            Section(header: Text("Model Context Protocol Servers"), footer: Text("Connect to external tools and services using the MCP protocol.")) {
                if servers.isEmpty {
                    Text("No MCP servers connected.")
                        .foregroundColor(.secondary)
                } else {
                    List {
                        ForEach(servers) { server in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(server.name)
                                        .font(.headline)
                                    Text(server.serverUrl)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                // Status indicator
                                Circle()
                                    .fill(statusColor(for: server.status))
                                    .frame(width: 10, height: 10)

                                Text(server.status.rawValue)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .contentShape(Rectangle())
                            .contextMenu {
                                Button("Delete", role: .destructive) {
                                    deleteServer(server)
                                }
                            }
                        }
                        .onDelete(perform: deleteServersAt)
                    }
                }

                Button(action: { showingAddSheet = true }) {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                        Text("Add MCP Server")
                    }
                }
            }
        }
        .navigationTitle("MCP Servers")
        .interactiveDismissDisabled(false)
        .onAppear {
            loadServers()
        }
        #if os(macOS)
        .formStyle(.grouped)
        .frame(minWidth: 450, minHeight: 350)
        #endif
        .sheet(isPresented: $showingAddSheet) {
            NavigationView {
                Form {
                    Section("Server Details") {
                        TextField("Name", text: $newName)
                        TextField("URL (SSE/HTTP)", text: $newUrl)
                            .disableAutocorrection(true)
                        #if os(iOS)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                        #endif
                    }

                    Section("Authentication") {
                        Picker("Type", selection: $authType) {
                            Text("None").tag("none")
                            Text("Bearer Token").tag("bearer")
                            // Basic auth could be added later
                        }

                        if authType == "bearer" {
                            SecureField("API Key / Token", text: $bearerToken)
                        }
                    }

                    if let error = errorMessage {
                        Section {
                            Text(error)
                                .foregroundColor(.red)
                                .font(.footnote)
                        }
                    }
                }
                .navigationTitle("Add Server")
                #if os(macOS)
                    .formStyle(.grouped)
                #else
                    .navigationBarTitleDisplayMode(.inline)
                #endif
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") {
                                showingAddSheet = false
                                resetForm()
                            }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") {
                                saveServer()
                            }
                            .disabled(newName.isEmpty || newUrl.isEmpty || isSaving)
                        }
                    }
            }
            #if os(macOS)
            .frame(width: 450, height: 350)
            #endif
        }
    }

    private func statusColor(for status: ConnectionStatus) -> Color {
        switch status {
        case .connected: .green
        case .disconnected: .red
        case .pending: .orange
        case .error: .red
        case .revoked: .gray
        }
    }

    private func loadServers() {
        Task {
            let loaded = await service.getAllMCPServers()
            await MainActor.run {
                servers = loaded
            }
        }
    }

    private func saveServer() {
        guard let url = URL(string: newUrl) else {
            errorMessage = "Invalid URL"
            return
        }

        isSaving = true
        errorMessage = nil

        Task {
            // First logic check to see if we can connect or fetch tools?
            // For now, let's just save the configuration. The MCPClient will connect when needed.
            var newAccount: MCPServerAccount?
            do {
                newAccount = try await service.createMCPServer(
                    name: newName,
                    serverUrl: url.absoluteString,
                    transport: .sse, // Default for HTTP
                    authType: MCPAuthType(rawValue: authType) ?? .none,
                    token: authType == "bearer" && !bearerToken.isEmpty ? bearerToken : nil
                )

                await MainActor.run {
                    isSaving = false
                    showingAddSheet = false
                    resetForm()
                    loadServers()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSaving = false
                }
                return
            }

            // Background task: trigger a test connection to cache tools immediately
            if let newAccount {
                Task.detached {
                    let client = MCPClient(server: newAccount, token: newAccount.authType == .bearer ? bearerToken : (newAccount.authType == .apiKey ? bearerToken : nil))
                    do {
                        // connect() will fetch and store tools in the account
                        try await client.connect()
                    } catch {
                        print("Initial MCP connection failed: \(error)")
                    }
                }
            }
        }
    }

    private func deleteServer(_ server: MCPServerAccount) {
        Task {
            // Remove server config and token
            try? await service.deleteMCPServer(id: server.id)
            loadServers()
        }
    }

    private func deleteServersAt(_ indexSet: IndexSet) {
        let serversToDelete = indexSet.map { servers[$0] }
        for server in serversToDelete {
            deleteServer(server)
        }
    }

    private func resetForm() {
        newName = ""
        newUrl = ""
        authType = "none"
        bearerToken = ""
        errorMessage = nil
    }
}
