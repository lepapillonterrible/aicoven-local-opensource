import SwiftUI

/// List of user's covens with search and quick create
struct CovensListView: View {
    @Binding var selectedCoven: Coven?
    @Binding var showNewCovenSheet: Bool
    @Binding var refreshTrigger: Bool

    private let analytics = AnalyticsService.shared

    @State private var covens: [Coven] = []
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var filteredCovens: [Coven] {
        if searchText.isEmpty {
            return covens
        }
        return covens.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List(selection: $selectedCoven) {
            ForEach(filteredCovens) { coven in
                CovenRow(coven: coven)
                    .tag(coven)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedCoven = coven
                        analytics.trackCovenView(covenId: coven.id)
                    }
            }
        }
        .navigationTitle("Covens")
        .searchable(text: $searchText, prompt: "Search covens")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { showNewCovenSheet = true }) {
                    Label("New Coven", systemImage: "plus")
                }
            }
        }
        .overlay {
            if isLoading, covens.isEmpty {
                ProgressView()
            } else if !isLoading, filteredCovens.isEmpty {
                ContentUnavailableView(
                    "No Covens",
                    systemImage: "sparkles",
                    description: Text(searchText.isEmpty ? "Create your first coven to start collaborating" : "No covens match your search")
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
        .task {
            await loadCovens()
            await MainActor.run {
                analytics.trackScreenView(screenName: "CovensListView", screenClass: "CovensListView")
            }
        }
        .onChange(of: refreshTrigger) { _, _ in
            Task {
                await loadCovens()
            }
        }
    }

    /// Load covens from local database
    private func loadCovens() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            print("🏰 CovensListView: Loading covens from local database")
            covens = try await CovenService.shared.loadCovens()
            print("✅ CovensListView: Loaded \(covens.count) covens")
        } catch {
            print("❌ CovensListView: Failed to load covens - \(error.localizedDescription)")
            errorMessage = "Failed to load covens: \(error.localizedDescription)"
        }
    }
}

/// Row view for a coven
struct CovenRow: View {
    let coven: Coven

    var body: some View {
        HStack(spacing: 12) {
            // Coven icon/avatar
            ZStack {
                Circle()
                    .fill(Color(hex: "#8B5CF6").opacity(0.2))
                    .frame(width: 40, height: 40)

                Image(systemName: "sparkles")
                    .foregroundColor(Color(hex: "#8B5CF6"))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(coven.name)
                    .font(.headline)

                if let description = coven.description {
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

/// New coven creation sheet
struct NewCovenView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    let onCovenCreated: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Coven Name", text: $name)
                    TextField("Description (optional)", text: $description, axis: .vertical)
                        .lineLimit(3 ... 6)
                }
            }
            .disabled(isCreating)
            .navigationTitle("New Coven")
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
                                await createCoven()
                            }
                        }
                        .disabled(name.isEmpty || isCreating)
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
    }

    private func createCoven() async {
        isCreating = true
        errorMessage = nil
        defer { isCreating = false }

        do {
            print("🏰 NewCovenView: Creating coven '\(name)'")
            _ = try await CovenService.shared.createCoven(
                name: name,
                description: description.isEmpty ? nil : description
            )
            print("✅ NewCovenView: Coven created successfully")
            onCovenCreated()
            dismiss()
        } catch {
            print("❌ NewCovenView: Failed to create coven - \(error.localizedDescription)")
            errorMessage = "Failed to create coven: \(error.localizedDescription)"
        }
    }
}

#Preview {
    NavigationStack {
        CovensListView(
            selectedCoven: .constant(nil),
            showNewCovenSheet: .constant(false),
            refreshTrigger: .constant(false)
        )
    }
}
