import SwiftUI
import UniformTypeIdentifiers

/// Learning & skills, as the cloud app's pane: Add a Skill, and the skills
/// with their switches. A skill is a file of instructions the person adds;
/// agents follow the skills that are on.
struct LearningSettingsView: View {
    @StateObject private var model = SkillsModel()
    @State private var isChoosingFile = false
    @State private var deleting: Skill?
    @State private var isOnScreen = false

    var body: some View {
        SettingsForm {
            Section {
                Menu {
                    Button("From a File…", systemImage: "doc") { isChoosingFile = true }
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
                        Text("Couldn't load your skills. Open this page again to retry.")
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
            guard let file = try? result.get().first else { return }
            Task { await model.add(from: file, as: account) }
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
        .task { await model.load() }
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
        .onChange(of: model.failure) { _, failure in
            // Said to VoiceOver too, while the pane is on screen.
            if isOnScreen, let failure { AccessibilityNotification.Announcement(failure).post() }
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
                .disabled(model.changing.contains(skill.id))
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
