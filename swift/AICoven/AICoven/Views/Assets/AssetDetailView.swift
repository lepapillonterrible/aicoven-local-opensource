internal import Combine
import SwiftUI

/// An asset's page, as the cloud app's: what it is, what can be done with
/// it, and its files. It is pushed on the iPhone and iPad and a sheet on
/// the Mac; the Mac also shows it beside the table, in the inspector.
struct AssetDetailView: View {
    let asset: Asset
    @ObservedObject var model: AssetLibraryModel

    /// This page's own Quick Look and exporter, taking turns with the
    /// library's and the other pages'.
    @StateObject private var files: AssetFiles

    /// Opens the thread the asset was made in.
    private let onOpenThread: ((Thread) -> Void)?
    /// The thread the asset was made in, once looked up.
    @StateObject private var originFound = AssetOriginModel()
    /// How the asset is related to others, once read.
    @StateObject private var lineage = AssetLineageModel()
    /// Whether the asset is being sent to an agent from this page.
    @State private var isSendingToAgent = false

    private var origin: Origin {
        originFound.origin
    }

    /// What is known of the thread an asset was made in.
    enum Origin: Equatable {
        case unknown
        case thread(Thread)
        /// It was made in a thread that is no longer there.
        case gone
    }

    static let threadGone = "The thread this was made in has been deleted."
    static let lineageFailed = "Couldn't load where this came from."

    init(asset: Asset, model: AssetLibraryModel, sharing turn: AssetFiles.Turn, onOpenThread: ((Thread) -> Void)? = nil) {
        self.asset = asset
        self.model = model
        self.onOpenThread = onOpenThread
        _files = StateObject(wrappedValue: AssetFiles(turn: turn))
    }

    /// Reads how the asset is related to others, as the account signed
    /// in. Not for an asset the key cannot open: its page shows no
    /// lineage, so nothing is read, shown or said of one.
    private func readLineage() async {
        guard !asset.isUnreadable else {
            lineage.forget()
            return
        }
        await lineage.read(asset.id, as: UserScope.currentUserID)
    }

    /// Looks up the thread the asset was made in, as the account signed in.
    private func findOrigin() async {
        let threadID = asset.threadID
        await originFound.find {
            await Self.origin(
                ofThread: threadID, as: UserScope.currentUserID,
                thread: { try await ThreadService.shared.getThread(threadId: $0) },
                isThread: { try await ThreadRepository.shared.isThread($0, of: $1) }
            )
        }
    }

    /// What is known of the thread an asset was made in: the thread, where
    /// it is the account's; gone only where the store says the account has
    /// no such thread; unknown where that cannot be read (the row is then
    /// left out, and nothing is said of a deletion). Nil if another
    /// account is signed in by then.
    static func origin(
        ofThread threadID: String?, as account: String,
        thread: (String) async throws -> Thread,
        isThread: (String, String) async throws -> Bool,
        signedIn: () -> String = { UserScope.currentUserID }
    ) async -> Origin? {
        guard let threadID else { return .unknown }
        let found: Origin = if let read = try? await thread(threadID), read.userId == account {
            .thread(read)
        } else if let isThere = try? await isThread(threadID, account) {
            // There, but not read: nothing is said of it.
            isThere ? .unknown : .gone
        } else {
            .unknown
        }
        return signedIn() == account ? found : nil
    }

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

            if origin == .gone {
                Section {
                    Label(Self.threadGone, systemImage: "info.circle")
                        .foregroundStyle(Color.aicovenTextSecondary)
                }
            }

            Section {
                LabeledContent("Made by", value: AssetLibraryRules.madeBy(asset, agents: model.agents))
                if case let .thread(thread) = origin {
                    LabeledContent("Thread") {
                        if let onOpenThread {
                            Button(ThreadListRules.title(of: thread)) { onOpenThread(thread) }
                                .buttonStyle(.borderless)
                        } else {
                            Text(ThreadListRules.title(of: thread))
                        }
                    }
                }
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

                // Shown only where there is something to say, as in the cloud app.
                if lineage.failed || !lineage.relations.isEmpty {
                    Section("Lineage") {
                        if lineage.failed {
                            Text(Self.lineageFailed)
                                .foregroundStyle(Color.aicovenError)
                        }
                        ForEach(lineage.relations) { relation in
                            Text(relation.line)
                        }
                    }
                }
            }
        }
        .presenting(files)
        .sheet(isPresented: $isSendingToAgent) {
            AssetHandoffSheet(asset: asset) { thread in
                isSendingToAgent = false
                onOpenThread?(thread)
            }
        }
        // Read for the asset as it is listed: again when the key that
        // could not open it can, and forgotten when it no longer can.
        .task(id: "\(asset.id)|\(asset.isUnreadable)") { await readLineage() }
        // A hand-off made while the page is open (by an agent's turn, or
        // from another page) is read for.
        .onReceive(NotificationCenter.default.publisher(for: Asset.didChange).receive(on: RunLoop.main)) { _ in
            Task { await readLineage() }
        }
        .task(id: asset.threadID) { await findOrigin() }
        // Its thread deleted while the page is open: the way to it goes.
        .onReceive(NotificationCenter.default.publisher(for: .didDeleteThread).receive(on: RunLoop.main)) { _ in
            Task { await findOrigin() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            AssetThumbnail(asset: asset, width: 96, height: 72)
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
        switch action {
        case .download: files.preparing != nil
        case .sendToAgent, .copyReference: false
        default: isChanging
        }
    }

    /// Does an action for the account that pressed it. Download… saves the
    /// asset's first file; each file's own menu saves that one.
    private func perform(_ action: AssetAction) {
        if action == .download {
            guard let file = asset.files.first else { return }
            Task { await files.download(file) }
            return
        }
        if action == .sendToAgent {
            isSendingToAgent = true
            return
        }
        if action == .copyReference {
            _ = ThreadMarkdownExport.writeClipboard(AssetLibraryRules.reference(to: asset))
            return
        }
        let account = UserScope.currentUserID
        Task { await model.perform(action, on: asset, as: account) }
    }
}

/// The thread an asset was made in, as the asset's page shows it. It is
/// looked up when the page comes and again when a thread is deleted, and
/// two lookups can be under way at once: only the latest one's answer is
/// shown, so that an earlier one landing late does not bring back the way
/// to a thread that has since been deleted.
@MainActor
final class AssetOriginModel: ObservableObject {
    @Published private(set) var origin = AssetDetailView.Origin.unknown
    private var lookups = 0

    /// Looks the origin up with `lookUp` (nil for an answer that is not
    /// to be shown) and shows what it finds, unless a later lookup was
    /// asked for meanwhile.
    func find(_ lookUp: () async -> AssetDetailView.Origin?) async {
        lookups += 1
        let lookup = lookups
        let found = await lookUp()
        guard lookup == lookups, let found else { return }
        origin = found
    }
}

/// How an asset is related to others, as its page shows it. Of two
/// readings under way only the later one's answer is shown, and nothing
/// read for an account that is no longer signed in. A reading that was
/// called off says nothing; one that failed says so in place of what an
/// earlier one read, which may no longer be so.
@MainActor
final class AssetLineageModel: ObservableObject {
    @Published private(set) var relations: [AssetRelation] = []
    @Published private(set) var failed = false
    private var readings = 0

    /// Holds nothing any more, and takes nothing from a reading under
    /// way: for an asset the key can no longer open.
    func forget() {
        readings += 1
        (relations, failed) = ([], false)
    }

    func read(
        _ assetID: String, as account: String, signedIn: () -> String = { UserScope.currentUserID },
        say: (String) -> Void = { AccessibilityNotification.Announcement($0).post() },
        relations read: (_ assetID: String, _ account: String) async throws -> [AssetRelation] = {
            try await AssetRepository.shared.relations(ofAsset: $0, as: $1)
        }
    ) async {
        readings += 1
        let reading = readings
        do {
            let found = try await read(assetID, account)
            guard reading == readings, signedIn() == account else { return }
            (relations, failed) = (found, false)
        } catch is CancellationError {
            return
        } catch {
            guard reading == readings, signedIn() == account else { return }
            // The kind of failure only.
            AppErrorReporter.log(message: "An asset's relations could not be read (\(type(of: error)))", context: "AssetLineageModel")
            // Said to VoiceOver when it newly shows, not at each reading that fails again.
            if !failed { say(AssetDetailView.lineageFailed) }
            (relations, failed) = ([], true)
        }
    }
}
