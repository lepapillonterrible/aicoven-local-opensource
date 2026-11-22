import SwiftUI
import UniformTypeIdentifiers

/// Learning & skills, as the cloud app's pane: Add a Skill, and the skills
/// with their switches. A skill is a file of instructions the person adds;
/// agents follow the skills that are on.
struct LearningSettingsView: View {
    @StateObject private var model = SkillsModel()
    @State private var isChoosingFile = false
    @State private var isAddingFromGitHub = false
    @State private var deleting: Skill?
    @State private var isOnScreen = false

    var body: some View {
        SettingsForm {
            Section {
                Menu {
                    Button("From a File…", systemImage: "doc") { isChoosingFile = true }
                    Button("From GitHub…", systemImage: "folder") { isAddingFromGitHub = true }
                } label: {
                    Label("Add a Skill…", systemImage: "plus.circle.fill")
                }
                .menuIndicator(.hidden)
            } footer: {
                Group {
                    if let failure = model.failure {
                        Text(failure)
                            .foregroundStyle(Color.aicovenError)
                    } else if model.loadFailed {
                        Text(SkillsModel.couldNotLoad)
                            .foregroundStyle(Color.aicovenError)
                    }
                }
                .font(.aicovenBodySmall)
            }

            if !model.skills.isEmpty {
                Section {
                    ForEach(model.skills) { skill in
                        row(skill)
                    }
                } footer: {
                    Group {
                        #if os(macOS)
                        Text("Agents follow the skills that are on. Control-click a skill to delete it.")
                        #else
                        Text("Agents follow the skills that are on. Swipe a skill to delete it.")
                        #endif
                    }
                    .font(.aicovenBodySmall)
                }
            }
        }
        .fileImporter(isPresented: $isChoosingFile, allowedContentTypes: [.plainText], allowsMultipleSelection: false) { result in
            // For the account that chose the file: read here, not when the
            // file has been read.
            let account = UserScope.currentUserID
            switch result {
            case let .success(files):
                guard let file = files.first else { return }
                Task { await model.add(from: file, as: account) }
            case let .failure(error):
                // Closing the picker is no failure; anything else is said.
                if (error as? CocoaError)?.code != .userCancelled { model.fileNotHandedOver(to: account) }
            }
        }
        .confirmationDialog(
            "Delete \(deleting.map(title) ?? "this skill")?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible,
            presenting: deleting
        ) { skill in
            Button("Delete", role: .destructive) {
                let account = UserScope.currentUserID
                Task { await model.delete(skill, as: account) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Agents stop following it.")
        }
        .sheet(isPresented: $isAddingFromGitHub) {
            AddSkillsFromGitHubSheet(model: model)
        }
        .task { await model.load() }
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
        .onChange(of: model.announcement) { _, said in
            // Said to VoiceOver too, while the pane is on screen: each
            // failure once, also one in the same words as the last.
            if isOnScreen, let said { AccessibilityNotification.Announcement(said.words).post() }
        }
    }

    /// What a skill is called where it is named: one the key cannot open
    /// has no title to show.
    private func title(_ skill: Skill) -> String {
        skill.isUnreadable ? "this skill" : skill.title
    }

    private func row(_ skill: Skill) -> some View {
        Group {
            if skill.isUnreadable {
                // It is followed by no agent and cannot be turned on: only deleted.
                Text(SkillsModel.unreadable)
                    .foregroundStyle(Color.aicovenTextSecondary)
            } else {
                Toggle(skill.title, isOn: Binding(
                    get: { skill.isOn },
                    set: { isOn in
                        let account = UserScope.currentUserID
                        Task { await model.setOn(isOn, skill, as: account) }
                    }
                ))
                .disabled(model.isBusy(skill))
            }
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", role: .destructive) { deleting = skill }
        }
        .contextMenu {
            Button("Delete…", role: .destructive) { deleting = skill }
        }
        .accessibilityAction(named: "Delete") { deleting = skill }
    }
}

/// Add skills from a repository on GitHub, as the cloud app's sheet: one
/// field, and Add. Here the skills are added off.
private struct AddSkillsFromGitHubSheet: View {
    @ObservedObject var model: SkillsModel

    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var outcome: SkillsModel.FromGitHub?
    /// The adding that is under way. Closing the sheet calls it off: what
    /// was added by then stays, and no more is.
    @State private var adding: Task<Void, Never>?

    /// Whether something was added: the sheet is then closed with Done.
    private var addedSome: Bool {
        if case let .added(added, _) = outcome { return added > 0 }
        return false
    }

    var body: some View {
        NavigationStack {
            SettingsForm {
                Section {
                    TextField("Repository", text: $address, prompt: Text("https://github.com/…"))
                    #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                    #endif
                        .autocorrectionDisabled()
                        .disabled(adding != nil)
                        .onSubmit(add)
                } footer: {
                    Group {
                        if let said = outcome.flatMap(SkillsModel.words(for:)) {
                            Text(said)
                                .foregroundStyle(addedSome ? Color.aicovenTextSecondary : Color.aicovenError)
                        } else {
                            Text(SkillsModel.fromGitHubHint)
                        }
                    }
                    .font(.aicovenBodySmall)
                }
            }
            .navigationTitle("Add from GitHub")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(addedSome ? "Done" : "Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if adding != nil {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("Adding the skills")
                        } else {
                            Button("Add", action: add)
                                .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 240)
        #endif
        .onDisappear { adding?.cancel() }
    }

    /// Starts the adding, once: pressing again while one is under way
    /// starts no other. For the account that pressed.
    private func add() {
        guard adding == nil, !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        outcome = nil
        let account = UserScope.currentUserID
        adding = Task {
            let result = await model.addFromGitHub(address, as: account)
            adding = nil
            guard !Task.isCancelled else { return }
            outcome = result
            if let said = SkillsModel.words(for: result) {
                AccessibilityNotification.Announcement(said).post()
            } else {
                dismiss()
            }
        }
    }
}
