import SwiftUI

/// "Send to Agent", as the cloud app's sheet for one agent: the asset,
/// the agent and the thread it is sent in (one of the place's, or a new
/// one), and what the person adds. Sent, the thread is opened.
struct AssetHandoffSheet: View {
    @StateObject private var model: AssetHandoffModel
    private let onSent: (Thread) -> Void
    /// Counts the readings asked for: each is the sheet's own task, which
    /// closing the sheet calls off, so that nothing of it lands or is said
    /// for a sheet that is gone. Try Again asks for another.
    @State private var readings = 0
    @Environment(\.dismiss) private var dismiss

    init(asset: Asset, onSent: @escaping (Thread) -> Void) {
        _model = StateObject(wrappedValue: AssetHandoffModel(asset: asset))
        self.onSent = onSent
    }

    private var asset: Asset {
        model.asset
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    source
                }

                Section {
                    if model.isLoading {
                        HStack(spacing: Spacing.sm) {
                            ProgressView()
                                .controlSize(.small)
                            Text(AssetHandoffModel.loading)
                                .foregroundStyle(Color.aicovenTextSecondary)
                        }
                    } else if !model.hasRead {
                        // Not read: nothing is said of what agents or
                        // threads there are, and the reading is offered again.
                        Text(AssetHandoffModel.couldNotLoad)
                            .foregroundStyle(Color.aicovenError)
                        Button("Try Again") { readings += 1 }
                    } else {
                        Picker("Agent", selection: $model.agentID) {
                            Text("Choose an agent").tag(String?.none)
                            ForEach(model.agents) { agent in
                                Text(agent.name).tag(String?.some(agent.id))
                            }
                        }
                        Toggle("Start a new thread", isOn: $model.startsNewThread)
                        if model.startsNewThread {
                            labelled("Thread title") {
                                TextField("Thread title", text: $model.newThreadTitle, prompt: Text("Optional"))
                            }
                        } else if model.threads.isEmpty {
                            Text(AssetHandoffModel.noThreads)
                                .foregroundStyle(Color.aicovenTextSecondary)
                        } else {
                            Picker("Thread", selection: $model.threadID) {
                                Text("Choose a thread").tag(String?.none)
                                ForEach(model.threads) { thread in
                                    Text(ThreadListRules.title(of: thread)).tag(String?.some(thread.id))
                                }
                            }
                        }
                    }
                } footer: {
                    if let note = model.agentNote, model.hasRead {
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text(note)
                                .font(.aicovenBodySmall)
                                .foregroundStyle(Color.aicovenError)
                            // No model was found for it: reading again can find one.
                            if model.offersTryAgain {
                                Button("Try Again") { readings += 1 }
                                    .font(.aicovenBodySmall)
                            }
                        }
                    }
                }
                .disabled(model.isSending)

                Section {
                    labelled("Instructions") {
                        TextField("Instructions", text: $model.direction, prompt: Text("Anything the agent should know"), axis: .vertical)
                            .lineLimit(3 ... 8)
                            .disabled(model.isSending)
                    }
                } footer: {
                    Group {
                        // What could not be read is said where the agents and threads would be.
                        if let failure = model.failure, model.hasRead {
                            Text(failure)
                                .foregroundStyle(Color.aicovenError)
                        } else {
                            Text(AssetHandoffModel.footer)
                        }
                    }
                    .font(.aicovenBodySmall)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Send to Agent")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .disabled(model.isSending)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if model.isSending {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("Sending the asset")
                        } else {
                            Button("Send", action: send)
                                .keyboardShortcut(.defaultAction)
                                .disabled(!model.canSend)
                        }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 420)
        #endif
        .interactiveDismissDisabled(model.isSending)
        .task(id: readings) { await model.load(as: UserScope.currentUserID) }
    }

    /// A field with its name shown: an iOS form shows only a field's
    /// prompt, which goes once something is typed, so there the name is
    /// written over the field; the Mac's form writes it itself.
    @ViewBuilder
    private func labelled(_ name: String, @ViewBuilder field: () -> some View) -> some View {
        #if os(iOS)
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(name)
                .font(.aicovenBodySmall)
                .foregroundStyle(Color.aicovenTextSecondary)
                .accessibilityHidden(true)
            field()
        }
        #else
        field()
        #endif
    }

    /// The asset being sent, and where its review stands.
    private var source: some View {
        HStack(spacing: Spacing.sm) {
            AssetThumbnail(type: asset.type, isLocked: asset.isUnreadable, width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(asset.title)
                    .font(.aicovenBody.weight(.semibold))
                    .foregroundStyle(Color.aicovenTextPrimary)
                    .lineLimit(2)
                Text(asset.type.displayName)
                    .font(.aicovenBodySmall)
                    .foregroundStyle(Color.aicovenTextSecondary)
                if asset.status == .approved {
                    Label("Approved", systemImage: "checkmark.seal.fill")
                        .font(.aicovenBodySmall)
                        .foregroundStyle(Color.aicovenTextSecondary)
                } else {
                    Label("Proposed — not reviewed", systemImage: "exclamationmark.triangle.fill")
                        .font(.aicovenBodySmall)
                        .foregroundStyle(Color.aicovenTextSecondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Sends for the account that pressed Send, and opens the thread it
    /// was sent in.
    private func send() {
        let account = UserScope.currentUserID
        Task {
            guard let thread = await model.send(as: account) else { return }
            onSent(thread)
        }
    }
}
