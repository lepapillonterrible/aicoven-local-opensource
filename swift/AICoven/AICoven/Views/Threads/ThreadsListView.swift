import SwiftUI

/// List of threads with filtering and search.
///
/// In the local-first client this is used for personal threads only
/// (no covens). The `covenId` parameter from the legacy cloud app has
/// been removed so we do not depend on any coven/role services.
struct ThreadsListView: View {
    var isPersonal: Bool = true
    @Binding var selectedThread: Thread?
    @Binding var refreshTrigger: Bool
    
    @State private var threads: [Thread] = []
    @State private var searchText = ""
    @State private var showNewThreadSheet = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    
    init(isPersonal: Bool = true, selectedThread: Binding<Thread?> = .constant(nil), refreshTrigger: Binding<Bool> = .constant(false)) {
        self.isPersonal = isPersonal
        self._selectedThread = selectedThread
        self._refreshTrigger = refreshTrigger
    }
    
    var filteredThreads: [Thread] {
        if searchText.isEmpty {
            return threads
        }
        return threads.filter { $0.title?.localizedCaseInsensitiveContains(searchText) ?? false }
    }
    
    var body: some View {
        List(selection: $selectedThread) {
            ForEach(filteredThreads) { thread in
                ThreadRow(thread: thread, isPersonal: isPersonal)
                    .tag(thread)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedThread = thread
                    }
            }
        }
        .navigationTitle(isPersonal ? "Personal Threads" : "Threads")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { showNewThreadSheet = true }) {
                    Label("New Thread", systemImage: "plus")
                }
            }
        }
        .overlay {
            if isLoading && threads.isEmpty {
                ProgressView()
            } else if !isLoading && filteredThreads.isEmpty {
                ContentUnavailableView(
                    "No Threads",
                    systemImage: "message",
                    description: Text(searchText.isEmpty ? "Start a new conversation" : "No threads match your search")
                )
            }
        }
        .sheet(isPresented: $showNewThreadSheet) {
            NewThreadView { _ in
                // Trigger refresh when new thread is created
                refreshTrigger.toggle()
            }
        }
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            if let errorMessage {
                Text(errorMessage)
            }
        }
        .task {
            await loadThreads()
        }
        .onChange(of: refreshTrigger) { _, _ in
            Task {
                await loadThreads()
            }
        }
    }
    
    /// Load threads from the local ThreadService (personal workspace only).
    private func loadThreads() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        
        do {
            AppErrorReporter.log(message: "Loading personal threads", context: "ThreadsListView.loadThreads")
            threads = try await ThreadService.shared.loadThreads(covenId: nil)
            AppErrorReporter.log(message: "Loaded \(threads.count) personal threads", context: "ThreadsListView.loadThreads")
        } catch {
            AppErrorReporter.log(error: error, context: "ThreadsListView.loadThreads")
            errorMessage = "Failed to load threads: \(error.localizedDescription)"
        }
    }
}

/// Thread row view
struct ThreadRow: View {
    let thread: Thread
    let isPersonal: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            // Role icon
            ZStack {
                Circle()
                    .fill(Color(hex: "#30FFC4").opacity(0.2))
                    .frame(width: 32, height: 32)
                
                Image(systemName: "bubble.left")
                    .font(.system(size: 14))
                    .foregroundColor(Color(hex: "#30FFC4"))
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(thread.title ?? "Untitled Thread")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                
                HStack(spacing: 4) {
                    if let agentName = thread.agentName {
                        Text("• \(agentName)")
                            .fontWeight(.medium)
                    } else if isPersonal {
                        Text("• Strix")
                            .fontWeight(.medium)
                    }
                    
                    // Only show model if thread has one stored (from previous conversations)
                    if let model = thread.agentModel {
                        Text("•")
                        Text(model)
                    }
                    
                    if let updatedAt = thread.updatedAt {
                        Text(updatedAt, style: .relative)
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
            }
            
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

/// New thread creation sheet.
///
/// Pass a `covenId` when creating a thread inside a coven workspace.
/// When `nil`, the thread will be a personal (home) thread.
struct NewThreadView: View {
    @Environment(\.dismiss) private var dismiss
    /// Optional coven context; `nil` = personal thread.
    var covenId: String? = nil
    /// Callback invoked with the newly created thread so callers can
    /// immediately navigate into it.
    let onThreadCreated: (Thread) -> Void
    
    @State private var title = ""
    @State private var selectedRoleId: String?
    @State private var roles: [Role] = []
    @State private var isLoadingRoles = false
    @State private var isCreating = false
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationStack {
            ZStack {
                NebulaBackground()

                Form {
                    Section("Thread Details") {
                        TextField("Title", text: $title)
                    }
                    .disabled(isCreating)
                    
                    // Only show role picker when creating a coven thread
                    if covenId != nil {
                        Section("Primary Role") {
                            if isLoadingRoles {
                                ProgressView()
                            } else if roles.isEmpty {
                                Text("No roles configured for this coven yet.")
                                    .foregroundColor(.secondary)
                            } else {
                                Picker("Role", selection: $selectedRoleId) {
                                    ForEach(roles) { role in
                                        Text("\(role.emoji ?? "🤖") \(role.name)")
                                            .tag(Optional(role.id))
                                    }
                                }
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("New Thread")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            await createThread()
                        }
                    }
                    // For coven threads, require a primary role when roles
                    // are available so each thread has a clear agent.
                    .disabled(
                        isCreating ||
                        (covenId != nil && !roles.isEmpty && selectedRoleId == nil)
                    )
                }
            }
            .alert("Error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                if let errorMessage {
                    Text(errorMessage)
                }
            }
        }
        .task {
            await loadRolesIfNeeded()
        }
    }
    
    /// Load coven roles when covenId is set
    private func loadRolesIfNeeded() async {
        guard let covenId, roles.isEmpty else { return }
        isLoadingRoles = true
        defer { isLoadingRoles = false }
        do {
            roles = try await RoleService.shared.loadRoles(covenId: covenId)
            // Preselect first role if available
            if let first = roles.first, selectedRoleId == nil {
                selectedRoleId = first.id
            }
        } catch {
            AppErrorReporter.log(error: error, context: "NewThreadView.loadRolesIfNeeded")
        }
    }
    
    private func createThread() async {
        isCreating = true
        errorMessage = nil
        defer { isCreating = false }
        
        do {
            AppErrorReporter.log(message: "Creating thread '\(title)' covenId=\(covenId ?? "nil") roleId=\(selectedRoleId ?? "none")", context: "NewThreadView.createThread")
            let thread = try await ThreadService.shared.createThread(
                title: title.isEmpty ? nil : title,
                covenId: covenId,
                agentId: covenId == nil ? nil : selectedRoleId
            )
            AppErrorReporter.log(message: "Thread created successfully (id: \(thread.id))", context: "NewThreadView.createThread")
            onThreadCreated(thread)
            dismiss()
        } catch {
            AppErrorReporter.log(error: error, context: "NewThreadView.createThread")
            errorMessage = "Failed to create thread: \(error.localizedDescription)"
        }
    }
}

#Preview {
    NavigationStack {
        ThreadsListView(isPersonal: true)
    }
}
