import SwiftUI

// MARK: - Add Memory View

/// Form view for creating a new memory chunk
struct AddMemoryView: View {
    let covenId: String?
    let onSave: () -> Void

    @State private var title = ""
    @State private var content = ""
    @State private var scope = "coven"
    @State private var tags: [String] = []
    @State private var tagInput = ""
    @State private var isPinned = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    let scopes: [String]

    init(covenId: String?, onSave: @escaping () -> Void) {
        self.covenId = covenId
        self.onSave = onSave
        // For personal memory, only "user" scope is available
        scopes = covenId != nil ? ["user", "coven", "agent"] : ["user"]
        _scope = State(initialValue: covenId != nil ? "coven" : "user")
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("New Memory")
                    .font(.aicovenH2)
                    .foregroundColor(.aicovenTextPrimary)

                Spacer()

                // Save button
                GradientButton("Save", icon: "checkmark", style: .primary, action: saveMemory)
                    .frame(width: 100)
                    .disabled(content.isEmpty || isLoading)
            }
            .padding(Spacing.lg)

            GradientDivider()

            // Form
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    // Title field (optional)
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Title (optional)")
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTextSecondary)

                        TextField("Enter a title...", text: $title)
                            .font(.aicovenBody)
                            .textFieldStyle(.plain)
                            .padding(Spacing.sm)
                            .background(Color.aicovenGlass)
                            .cornerRadius(BorderRadius.sm)
                    }

                    // Scope selector
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Scope")
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTextSecondary)

                        HStack(spacing: Spacing.xs) {
                            ForEach(scopes, id: \.self) { scopeOption in
                                Button {
                                    scope = scopeOption
                                } label: {
                                    Text(scopeOption.capitalized)
                                        .font(.aicovenBodySmall)
                                        .foregroundColor(scope == scopeOption ? .aicovenTeal : .aicovenTextSecondary)
                                        .padding(.horizontal, Spacing.md)
                                        .padding(.vertical, Spacing.sm)
                                        .background(
                                            RoundedRectangle(cornerRadius: BorderRadius.sm)
                                                .fill(scope == scopeOption ? Color.aicovenGlass : Color.clear)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // Content field (required)
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Content *")
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTextSecondary)

                        TextEditor(text: $content)
                            .font(.aicovenBody)
                            .frame(minHeight: 200)
                            .padding(Spacing.sm)
                            .background(Color.aicovenGlass)
                            .cornerRadius(BorderRadius.sm)
                    }

                    // Tags input
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Tags")
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTextSecondary)

                        // Tag input
                        HStack {
                            TextField("Add tag...", text: $tagInput)
                                .font(.aicovenBodySmall)
                                .textFieldStyle(.plain)
                                .onSubmit {
                                    addTag()
                                }

                            Button {
                                addTag()
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundColor(.aicovenTeal)
                            }
                            .buttonStyle(.plain)
                            .disabled(tagInput.isEmpty)
                        }
                        .padding(Spacing.sm)
                        .background(Color.aicovenGlass)
                        .cornerRadius(BorderRadius.sm)

                        // Tag chips
                        if !tags.isEmpty {
                            FlowLayout(spacing: Spacing.xs) {
                                ForEach(tags, id: \.self) { tag in
                                    HStack(spacing: Spacing.xxs) {
                                        Text("#\(tag)")
                                            .font(.aicovenCaption)
                                            .foregroundColor(.aicovenTeal)

                                        Button {
                                            removeTag(tag)
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 10))
                                                .foregroundColor(.aicovenTextTertiary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, Spacing.xs)
                                    .padding(.vertical, 2)
                                    .background(Color.aicovenGlass)
                                    .cornerRadius(BorderRadius.sm)
                                }
                            }
                        }
                    }

                    // Pin toggle
                    Toggle(isOn: $isPinned) {
                        HStack(spacing: Spacing.xs) {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.aicovenTeal)

                            Text("Pin this memory")
                                .font(.aicovenBodySmall)
                                .foregroundColor(.aicovenTextPrimary)
                        }
                    }
                    .toggleStyle(SwitchToggleStyle(tint: .aicovenTeal))

                    // Error message
                    if let error = errorMessage {
                        ErrorBannerView(message: error)
                    }
                }
                .padding(Spacing.lg)
            }
        }
    }

    // MARK: - Actions

    /// Add a tag
    private func addTag() {
        let trimmed = tagInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !tags.contains(trimmed) {
            tags.append(trimmed)
            tagInput = ""
        }
    }

    /// Remove a tag
    private func removeTag(_ tag: String) {
        tags.removeAll { $0 == tag }
    }

    /// Save the memory
    private func saveMemory() {
        guard !content.isEmpty else { return }

        isLoading = true
        errorMessage = nil

        Task {
            do {
                _ = try await MemoryService.shared.createMemory(
                    covenId: covenId,
                    scope: scope,
                    title: title.isEmpty ? nil : title,
                    content: content,
                    tags: tags.isEmpty ? nil : tags,
                    isPinned: isPinned
                )

                // Also index this memory locally with an embedding so chat
                // and agents can retrieve it via the context sandwich.
                _ = try await EmbeddingService.shared.indexMemory(
                    scope: scope,
                    text: content,
                    tags: tags,
                    pii: false,
                    createdBy: nil,
                    source: nil
                )

                // Call completion handler
                onSave()
            } catch {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }
}

/// Wrapper used on mobile to present EditMemoryView in a sheet and refresh list
struct EditMemorySheetWrapper: View {
    let memoryId: String
    let covenId: String?
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        EditMemoryView(memoryId: memoryId, covenId: covenId) {
            onSaved()
            dismiss()
        }
    }
}

/// Wrapper used on mobile to present AddMemoryView in a sheet and refresh list
struct AddMemorySheetWrapper: View {
    let covenId: String?
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AddMemoryView(covenId: covenId) {
            onSaved()
            dismiss()
        }
    }
}

// MARK: - Edit Memory View

/// Form view for editing an existing memory chunk
struct EditMemoryView: View {
    let memoryId: String
    let covenId: String?
    let onSave: () -> Void

    @State private var memory: Memory?
    @State private var title = ""
    @State private var content = ""
    @State private var scope = "coven"
    @State private var tags: [String] = []
    @State private var tagInput = ""
    @State private var isPinned = false
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    let scopes: [String]

    init(memoryId: String, covenId: String?, onSave: @escaping () -> Void) {
        self.memoryId = memoryId
        self.covenId = covenId
        self.onSave = onSave
        // For personal memory, only "user" scope is available
        scopes = covenId != nil ? ["user", "coven", "agent"] : ["user"]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Edit Memory")
                    .font(.aicovenH2)
                    .foregroundColor(.aicovenTextPrimary)

                Spacer()

                // Save button
                GradientButton("Save", icon: "checkmark", style: .primary, action: saveMemory)
                    .frame(width: 100)
                    .disabled(content.isEmpty || isSaving)
            }
            .padding(Spacing.lg)

            GradientDivider()

            // Content
            if isLoading {
                LoadingView(message: "Loading memory...")
            } else if memory == nil {
                MemoryErrorView(message: errorMessage ?? "Failed to load memory") {
                    Task {
                        await loadMemory()
                    }
                }
            } else {
                // Form
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.lg) {
                        // Title field (optional)
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text("Title (optional)")
                                .font(.aicovenCaption)
                                .foregroundColor(.aicovenTextSecondary)

                            TextField("Enter a title...", text: $title)
                                .font(.aicovenBody)
                                .textFieldStyle(.plain)
                                .padding(Spacing.sm)
                                .background(Color.aicovenGlass)
                                .cornerRadius(BorderRadius.sm)
                        }

                        // Scope selector
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text("Scope")
                                .font(.aicovenCaption)
                                .foregroundColor(.aicovenTextSecondary)

                            HStack(spacing: Spacing.xs) {
                                ForEach(scopes, id: \.self) { scopeOption in
                                    Button {
                                        scope = scopeOption
                                    } label: {
                                        Text(scopeOption.capitalized)
                                            .font(.aicovenBodySmall)
                                            .foregroundColor(scope == scopeOption ? .aicovenTeal : .aicovenTextSecondary)
                                            .padding(.horizontal, Spacing.md)
                                            .padding(.vertical, Spacing.sm)
                                            .background(
                                                RoundedRectangle(cornerRadius: BorderRadius.sm)
                                                    .fill(scope == scopeOption ? Color.aicovenGlass : Color.clear)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        // Content field (required)
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text("Content *")
                                .font(.aicovenCaption)
                                .foregroundColor(.aicovenTextSecondary)

                            TextEditor(text: $content)
                                .font(.aicovenBody)
                                .frame(minHeight: 200)
                                .padding(Spacing.sm)
                                .background(Color.aicovenGlass)
                                .cornerRadius(BorderRadius.sm)
                        }

                        // Tags input
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text("Tags")
                                .font(.aicovenCaption)
                                .foregroundColor(.aicovenTextSecondary)

                            // Tag input
                            HStack {
                                TextField("Add tag...", text: $tagInput)
                                    .font(.aicovenBodySmall)
                                    .textFieldStyle(.plain)
                                    .onSubmit {
                                        addTag()
                                    }

                                Button {
                                    addTag()
                                } label: {
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundColor(.aicovenTeal)
                                }
                                .buttonStyle(.plain)
                                .disabled(tagInput.isEmpty)
                            }
                            .padding(Spacing.sm)
                            .background(Color.aicovenGlass)
                            .cornerRadius(BorderRadius.sm)

                            // Tag chips
                            if !tags.isEmpty {
                                FlowLayout(spacing: Spacing.xs) {
                                    ForEach(tags, id: \.self) { tag in
                                        HStack(spacing: Spacing.xxs) {
                                            Text("#\(tag)")
                                                .font(.aicovenCaption)
                                                .foregroundColor(.aicovenTeal)

                                            Button {
                                                removeTag(tag)
                                            } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .font(.system(size: 10))
                                                    .foregroundColor(.aicovenTextTertiary)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        .padding(.horizontal, Spacing.xs)
                                        .padding(.vertical, 2)
                                        .background(Color.aicovenGlass)
                                        .cornerRadius(BorderRadius.sm)
                                    }
                                }
                            }
                        }

                        // Pin toggle
                        Toggle(isOn: $isPinned) {
                            HStack(spacing: Spacing.xs) {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(.aicovenTeal)

                                Text("Pin this memory")
                                    .font(.aicovenBodySmall)
                                    .foregroundColor(.aicovenTextPrimary)
                            }
                        }
                        .toggleStyle(SwitchToggleStyle(tint: .aicovenTeal))

                        // Error message
                        if let error = errorMessage {
                            HStack(spacing: Spacing.xs) {
                                Image(systemName: "exclamationmark.triangle")
                                Text(error)
                            }
                            .font(.aicovenCaption)
                            .foregroundColor(.red)
                            .padding(Spacing.sm)
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(BorderRadius.sm)
                        }
                    }
                    .padding(Spacing.lg)
                }
            }
        }
        .task {
            await loadMemory()
        }
    }

    // MARK: - Actions

    /// Load memory from API
    private func loadMemory() async {
        isLoading = true
        errorMessage = nil

        do {
            let loadedMemory = try await MemoryService.shared.getMemory(memoryId: memoryId)
            memory = loadedMemory

            // Populate form fields
            title = loadedMemory.title ?? ""
            content = loadedMemory.content
            scope = loadedMemory.scope.rawValue
            tags = loadedMemory.tags ?? []
            isPinned = loadedMemory.isPinned
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    /// Add a tag
    private func addTag() {
        let trimmed = tagInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !tags.contains(trimmed) {
            tags.append(trimmed)
            tagInput = ""
        }
    }

    /// Remove a tag
    private func removeTag(_ tag: String) {
        tags.removeAll { $0 == tag }
    }

    /// Save the memory
    private func saveMemory() {
        guard !content.isEmpty else { return }

        isSaving = true
        errorMessage = nil

        Task {
            do {
                _ = try await MemoryService.shared.updateMemory(
                    memoryId: memoryId,
                    title: title.isEmpty ? nil : title,
                    content: content,
                    tags: tags.isEmpty ? nil : tags,
                    scope: scope,
                    isPinned: isPinned
                )

                // Call completion handler
                onSave()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}

// MARK: - Supporting Views

/// Error state view for memory views
struct MemoryErrorView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: Spacing.lg) {
            IconBadge(icon: "exclamationmark.triangle", size: 60, color: .red)

            Text("Error")
                .font(.aicovenH2)
                .foregroundColor(.aicovenTextPrimary)

            Text(message)
                .font(.aicovenBodySmall)
                .foregroundColor(.aicovenTextSecondary)
                .multilineTextAlignment(.center)

            GradientButton("Retry", icon: "arrow.clockwise", style: .secondary, action: onRetry)
                .frame(width: 120)
        }
        .padding(Spacing.xl)
    }
}
