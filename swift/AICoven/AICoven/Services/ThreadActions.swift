internal import Combine
import SwiftUI

/// What a list of threads lets the person do with one: rename it, archive
/// it or bring it back, delete it (after asking), and copy it as Markdown.
/// One list has one; its rows and its sheet and alerts go through it, so
/// every list offers the same, in the same words.
@MainActor
final class ThreadActions: ObservableObject {
    /// What could not be done, for an alert.
    struct Failure: Identifiable, Equatable {
        let id = UUID()
        let title: String
        static let message = "Try again."

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.title == rhs.title
        }
    }

    /// What the actions do to the store. Tests give their own.
    struct Dependencies {
        var rename: (_ threadID: String, _ title: String) async throws -> Void
        var setArchived: (_ threadID: String, _ archived: Bool) async throws -> Void
        var delete: (_ threadID: String) async throws -> Void
        /// Stops the turn running in a thread, if one is.
        var stopTurn: @MainActor (_ threadID: String) -> Void
        var currentAccount: @MainActor () -> String
        var export: ThreadMarkdownExportDependencies

        static let live = Dependencies(
            rename: { _ = try await ThreadService.shared.updateThread(threadId: $0, title: $1) },
            setArchived: {
                _ = try await ThreadService.shared.updateThread(threadId: $0, isArchived: $1)
                // Which covens hold an unread reply follows what is put away.
                ThreadActivities.shared.reload()
            },
            delete: {
                try await ThreadService.shared.deleteThread(threadId: $0)
                ThreadActivities.shared.reload()
            },
            stopTurn: { TurnEngine.shared.stop(threadID: $0) },
            currentAccount: { UserScope.currentUserID },
            export: .live
        )
    }

    /// The thread being renamed (its sheet is up), or asked about before
    /// it is deleted.
    @Published var renaming: Thread?
    @Published var deleting: Thread?
    @Published var failure: Failure?
    @Published var notice: ThreadMarkdownExportNotice?
    /// The thread being copied, while it is read.
    @Published private(set) var exportingThreadID: String?

    /// Told when a thread was changed or deleted, so the list shows it.
    var onChanged: (() -> Void)?
    /// Told when a thread is gone or put away: what shows it closes.
    var onLeft: ((Thread) -> Void)?

    private let dependencies: Dependencies
    private var export: Task<Void, Never>?
    private var exportGeneration = 0

    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    /// Renames a thread. Like the other actions, it gives back the work it
    /// started, or nothing if there was nothing to do.
    @discardableResult
    func rename(_ thread: Thread, to typed: String) -> Task<Void, Never>? {
        guard let name = ThreadListRules.name(from: typed), name != thread.title else { return nil }
        return run("Couldn't rename the thread") { [dependencies] in
            try await dependencies.rename(thread.id, name)
        }
    }

    /// Archives a thread, or brings it back. Archiving stops the turn
    /// running in it (what waited for that turn goes back to its
    /// composer).
    @discardableResult
    func setArchived(_ thread: Thread, _ archived: Bool) -> Task<Void, Never>? {
        if archived { dependencies.stopTurn(thread.id) }
        return run(archived ? "Couldn't archive the thread" : "Couldn't unarchive the thread", leaving: archived ? thread : nil) { [dependencies] in
            try await dependencies.setArchived(thread.id, archived)
        }
    }

    /// Deletes a thread: called once the person has said so.
    @discardableResult
    func delete(_ thread: Thread) -> Task<Void, Never>? {
        // A copy of it under way is called off: it is no longer there to copy.
        if exportingThreadID == thread.id { cancelExport() }
        dependencies.stopTurn(thread.id)
        return run("Couldn't delete the thread", leaving: thread) { [dependencies] in
            try await dependencies.delete(thread.id)
        }
    }

    /// Whether a thread can be copied now: not while one is being read.
    var canCopy: Bool {
        exportingThreadID == nil
    }

    /// Copies a thread to the clipboard as Markdown, and says how it went.
    @discardableResult
    func copy(_ thread: Thread) -> Task<Void, Never>? {
        guard canCopy else { return nil }
        let account = dependencies.currentAccount()
        exportGeneration &+= 1
        let request = exportGeneration
        exportingThreadID = thread.id
        notice = nil
        let copying = Task { [weak self, dependencies] in
            var said: ThreadMarkdownExportNotice?
            do {
                let markdown = try await ThreadMarkdownExport.makeDocument(thread: thread, dependencies: dependencies.export)
                try Task.checkCancellation()
                // Only as the account that asked, and only the latest asked for.
                guard let self, request == exportGeneration, dependencies.currentAccount() == account else {
                    self?.finishExport(request, saying: nil)
                    return
                }
                guard dependencies.export.writeClipboard(markdown) else { throw ThreadMarkdownExportError.clipboardWriteFailed }
                said = ThreadMarkdownExportNotice(kind: .success, message: ThreadMarkdownExport.copied)
            } catch is CancellationError {
                said = nil
            } catch {
                if !(error is ThreadMarkdownExportError) { AppErrorReporter.log(error: error, context: "ThreadActions.copy") }
                guard dependencies.currentAccount() == account else {
                    self?.finishExport(request, saying: nil)
                    return
                }
                let message = switch error as? ThreadMarkdownExportError {
                case .empty: ThreadMarkdownExport.nothingToCopy
                case .clipboardWriteFailed: ThreadMarkdownExport.clipboardFailed
                case .threadGone, nil: ThreadMarkdownExport.failed
                }
                said = ThreadMarkdownExportNotice(kind: .failure, message: message)
            }
            self?.finishExport(request, saying: said)
        }
        export = copying
        return copying
    }

    /// The list went to another place or another account: a copy under
    /// way is called off with what it would have said, and a rename sheet
    /// or a delete question still open is closed.
    func invalidate() {
        cancelExport()
        renaming = nil
        deleting = nil
    }

    private func cancelExport() {
        exportGeneration &+= 1
        export?.cancel()
        export = nil
        exportingThreadID = nil
        notice = nil
    }

    private func finishExport(_ request: Int, saying notice: ThreadMarkdownExportNotice?) {
        guard request == exportGeneration else { return }
        exportingThreadID = nil
        export = nil
        self.notice = notice
    }

    /// Runs a change for the account that asked; says so if it failed.
    private func run(
        _ failureTitle: String, leaving left: Thread? = nil, _ change: @escaping () async throws -> Void
    ) -> Task<Void, Never> {
        let account = dependencies.currentAccount()
        return Task { [weak self, dependencies] in
            // Another account signed in before this began: it is not made.
            guard dependencies.currentAccount() == account else { return }
            do {
                try await change()
                guard let self, dependencies.currentAccount() == account else { return }
                if let left { onLeft?(left) }
                onChanged?()
            } catch {
                AppErrorReporter.log(error: error, context: "ThreadActions: \(failureTitle)")
                guard let self, dependencies.currentAccount() == account else { return }
                failure = Failure(title: failureTitle)
                // The list shows what is stored, whatever was tried.
                onChanged?()
            }
        }
    }
}

extension View {
    /// Hosts what a list's thread actions show: the rename sheet, the
    /// question before a delete, and what could not be done or was copied.
    func threadActionsHost(_ actions: ThreadActions) -> some View {
        modifier(ThreadActionsHost(actions: actions))
    }

    /// A thread row's actions: its context menu, and on a touch list its
    /// swipe (Archive, or Unarchive).
    func threadRowActions(_ thread: Thread, _ actions: ThreadActions) -> some View {
        modifier(ThreadRowActions(thread: thread, actions: actions))
    }
}

private struct ThreadActionsHost: ViewModifier {
    @ObservedObject var actions: ThreadActions

    func body(content: Content) -> some View {
        content
            .sheet(item: $actions.renaming) { thread in
                RenameThreadSheet(thread: thread) { actions.rename(thread, to: $0) }
            }
            .alert(
                actions.deleting.map(ThreadListRules.deleteQuestion(for:)) ?? "",
                isPresented: Binding(get: { actions.deleting != nil }, set: { if !$0 { actions.deleting = nil } }),
                presenting: actions.deleting
            ) { thread in
                Button("Delete", role: .destructive) { actions.delete(thread) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text(ThreadListRules.deleteConsequence)
            }
            .alert(
                actions.failure?.title ?? "",
                isPresented: Binding(get: { actions.failure != nil }, set: { if !$0 { actions.failure = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(ThreadActions.Failure.message)
            }
            .alert(
                actions.notice?.title ?? "",
                isPresented: Binding(get: { actions.notice != nil }, set: { if !$0 { actions.notice = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(actions.notice?.message ?? "")
            }
    }
}

private struct ThreadRowActions: ViewModifier {
    let thread: Thread
    @ObservedObject var actions: ThreadActions

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button {
                    actions.copy(thread)
                } label: {
                    Label("Copy Thread as Markdown", systemImage: "doc.on.doc")
                }
                .disabled(!actions.canCopy)
                if thread.isArchived {
                    Button {
                        actions.setArchived(thread, false)
                    } label: {
                        Label("Unarchive", systemImage: "tray.and.arrow.up")
                    }
                } else {
                    Button {
                        actions.renaming = thread
                    } label: {
                        Label("Rename…", systemImage: "pencil")
                    }
                    Button {
                        actions.setArchived(thread, true)
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                    Button(role: .destructive) {
                        actions.deleting = thread
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button {
                    actions.setArchived(thread, !thread.isArchived)
                } label: {
                    Label(thread.isArchived ? "Unarchive" : "Archive", systemImage: thread.isArchived ? "tray.and.arrow.up" : "archivebox")
                }
                .tint(Color.aicovenSwipeNeutral)
            }
    }
}
