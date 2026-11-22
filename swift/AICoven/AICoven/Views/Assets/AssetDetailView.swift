import SwiftUI

/// An asset's page, as the cloud app's: what it is, what can be done with
/// it, and its files. Full size it is pushed on the iPhone and iPad and a
/// sheet on the Mac; the Mac also shows it beside the table, in the
/// inspector.
struct AssetDetailView: View {
    enum Style {
        case full
        case inspector
    }

    let asset: Asset
    @ObservedObject var model: AssetLibraryModel
    var style: Style = .full

    /// This page's own Quick Look and exporter.
    @StateObject private var files = AssetFiles()

    static let proposedNote = "Proposed for review."
    static let noFiles = "No files."

    private var isChanging: Bool {
        model.changing.contains(asset.id)
    }

    /// What went wrong with the last thing asked of this asset.
    private var failure: String? {
        model.actionFailure.flatMap { $0.assetID == asset.id ? $0.words : nil }
    }

    var body: some View {
        SettingsForm {
            Section {
                header
                #if os(macOS)
                actionRow
                #endif
            } footer: {
                #if os(macOS)
                notes
                #endif
            }

            #if os(iOS)
            let actions = AssetLibraryRules.reviewActions(asset) + AssetLibraryRules.otherActions(asset)
            if !actions.isEmpty {
                Section {
                    ForEach(actions) { action in
                        Button {
                            perform(action)
                        } label: {
                            Label(action.title, systemImage: action.iconSystemName)
                        }
                        .disabled(isBusy(with: action))
                    }
                } footer: {
                    notes
                }
            }
            #endif

            if asset.isUnreadable {
                Section {
                    Label(AssetLibraryRules.unreadable, systemImage: "lock")
                        .foregroundStyle(Color.aicovenTextSecondary)
                }
            }

            Section {
                LabeledContent("Made by", value: AssetLibraryRules.madeBy(asset))
                LabeledContent("Updated", value: AssetLibraryRules.fullTime(asset.updatedAt))
            }

            if !asset.isUnreadable {
                Section("Files") {
                    if asset.files.isEmpty {
                        Text(Self.noFiles)
                            .foregroundStyle(Color.aicovenTextSecondary)
                    }
                    ForEach(asset.files) { file in
                        fileRow(file)
                    }
                    if let said = files.said {
                        Text(said)
                            .font(.aicovenBodySmall)
                            .foregroundStyle(Color.aicovenError)
                    }
                }

                if !asset.details.isEmpty {
                    Section("Content") {
                        Text(asset.details)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .presenting(files)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            AssetThumbnail(type: asset.type, isLocked: asset.isUnreadable, width: 96, height: 72)
            if !asset.isUnreadable {
                Text(asset.title)
                    .font(.aicovenH3)
                    .foregroundStyle(Color.aicovenTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            Text("\(asset.type.displayName) · \(AssetLibraryRules.statusLabel(asset))")
                .font(.aicovenBodySmall)
                .foregroundStyle(Color.aicovenTextSecondary)
        }
        .padding(.vertical, Spacing.xxs)
    }

    /// What is said under the actions: where a proposed asset stands, and
    /// what went wrong with the last thing asked (the library, which is
    /// there behind every page, says it to VoiceOver).
    private var notes: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            if asset.status == .proposed {
                Text(Self.proposedNote)
            }
            if let failure {
                Text(failure)
                    .foregroundStyle(Color.aicovenError)
            }
        }
        .font(.aicovenBodySmall)
    }

    #if os(macOS)
    /// The review's answers as buttons, and the rest in a menu.
    @ViewBuilder
    private var actionRow: some View {
        let review = AssetLibraryRules.reviewActions(asset)
        let others = AssetLibraryRules.otherActions(asset)
        if !review.isEmpty || !others.isEmpty {
            HStack(spacing: Spacing.xs) {
                ForEach(review) { action in
                    Button(action.title) { perform(action) }
                        .disabled(isBusy(with: action))
                }
                if !others.isEmpty {
                    Menu {
                        ForEach(others) { action in
                            Button {
                                perform(action)
                            } label: {
                                Label(action.title, systemImage: action.iconSystemName)
                            }
                            .disabled(isBusy(with: action))
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .labelStyle(.iconOnly)
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                if isChanging {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Updating the asset")
                }
            }
        }
    }
    #endif

    private func fileRow(_ file: AssetFile) -> some View {
        Button {
            Task { await files.look(at: file) }
        } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: file.mimeType.hasPrefix("image/") ? "photo" : "doc")
                    .foregroundStyle(Color.aicovenTextSecondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: Spacing.xxxs) {
                    Text(file.name)
                        .foregroundStyle(Color.aicovenTextPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(AssetLibraryRules.size(file.sizeBytes))
                        .font(.aicovenCaption)
                        .foregroundStyle(Color.aicovenTextSecondary)
                }
                Spacer(minLength: Spacing.xs)
                if files.preview.isOpening || files.preparing == file.id {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(files.preview.isOpening)
        .accessibilityHint("Opens it in Quick Look")
        .contextMenu {
            Button {
                Task { await files.download(file) }
            } label: {
                Label(AssetAction.download.title, systemImage: AssetAction.download.iconSystemName)
            }
        }
    }

    /// Whether an action cannot be asked for just now: a change of status
    /// while one is on its way, a download while one is being read.
    private func isBusy(with action: AssetAction) -> Bool {
        action == .download ? files.preparing != nil : isChanging
    }

    /// Does an action for the account that pressed it. Download… saves the
    /// asset's first file; each file's own menu saves that one.
    private func perform(_ action: AssetAction) {
        if action == .download {
            guard let file = asset.files.first else { return }
            Task { await files.download(file) }
            return
        }
        let account = UserScope.currentUserID
        Task { await model.perform(action, on: asset, as: account) }
    }
}
