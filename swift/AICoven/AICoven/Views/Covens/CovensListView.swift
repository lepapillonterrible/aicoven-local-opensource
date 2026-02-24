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
            ZStack {
                NebulaBackground()

                ScrollView {
                    VStack(spacing: Spacing.lg) {
                        // Header
                        VStack(spacing: Spacing.sm) {
                            IconBadge(icon: "sparkles", size: 80, color: .aicovenPurple)

                            Text("Create a Coven")
                                .font(.aicovenDisplaySmall)
                                .foregroundColor(.aicovenTextPrimary)

                            Text("Collaborate with multiple AI roles in a shared workspace")
                                .font(.aicovenBody)
                                .foregroundColor(.aicovenTextSecondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 400)
                        }
                        .padding(.top, Spacing.xl)

                        // Form
                        VStack(spacing: Spacing.md) {
                            // Name field
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                Text("Coven Name")
                                    .font(.aicovenBodyMedium)
                                    .foregroundColor(.aicovenTextPrimary)

                                TextField("", text: $name, prompt: Text("My Project").foregroundColor(.aicovenTextTertiary))
                                    .font(.aicovenBody)
                                    .foregroundColor(.aicovenTextPrimary)
                                    .padding(Spacing.sm)
                                    .background(Color.aicovenGlass)
                                    .cornerRadius(BorderRadius.md)
                            }

                            // Description field
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                Text("Description (Optional)")
                                    .font(.aicovenBodyMedium)
                                    .foregroundColor(.aicovenTextPrimary)

                                TextField("", text: $description, prompt: Text("What's this coven for?").foregroundColor(.aicovenTextTertiary), axis: .vertical)
                                    .font(.aicovenBody)
                                    .foregroundColor(.aicovenTextPrimary)
                                    .padding(Spacing.sm)
                                    .background(Color.aicovenGlass)
                                    .cornerRadius(BorderRadius.md)
                                    .lineLimit(3 ... 6)
                            }
                        }
                        .padding(.horizontal, Spacing.xl)
                        .glassMorphism()
                        .padding(.horizontal, Spacing.lg)

                        // Error message
                        if let errorMessage {
                            Text(errorMessage)
                                .font(.aicovenBodySmall)
                                .foregroundColor(.aicovenError)
                                .padding(.horizontal, Spacing.lg)
                        }

                        // Actions
                        HStack(spacing: Spacing.md) {
                            // Cancel button
                            Button("Cancel") {
                                dismiss()
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, Spacing.lg)
                            .padding(.vertical, Spacing.sm)
                            .background(Color.aicovenGlass)
                            .foregroundColor(.aicovenTeal)
                            .cornerRadius(BorderRadius.md)

                            Button(action: {
                                Task {
                                    await createCoven()
                                }
                            }) {
                                HStack(spacing: Spacing.xs) {
                                    if isCreating {
                                        ProgressView()
                                            .controlSize(.small)
                                            .tint(.white)
                                    }
                                    Text(isCreating ? "Creating..." : "Create Coven")
                                        .font(.aicovenBodyMedium)
                                }
                                .padding(.horizontal, Spacing.lg)
                                .padding(.vertical, Spacing.sm)
                                .frame(minWidth: 150)
                                .background(
                                    Group {
                                        if name.isEmpty {
                                            Color.aicovenGlass
                                        } else {
                                            LinearGradient(
                                                colors: [Color.aicovenTeal, Color.aicovenPurple],
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            )
                                        }
                                    }
                                )
                                .foregroundColor(.white)
                                .cornerRadius(BorderRadius.md)
                            }
                            .buttonStyle(.plain)
                            .disabled(name.isEmpty || isCreating)
                        }
                        .padding(.horizontal, Spacing.lg)
                    }
                    .padding(.bottom, Spacing.xl)
                }
            }
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
