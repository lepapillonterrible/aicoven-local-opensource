internal import Combine
import Foundation
import SwiftUI

/// What the person can do with an asset, in the cloud app's words.
nonisolated enum AssetAction: String, Identifiable {
    case propose
    case approve
    case sendBack
    case unarchive
    case sendToAgent
    case copyReference
    case download
    case archive

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .propose: "Propose for Review"
        case .approve: "Approve"
        case .sendBack: "Send Back"
        case .unarchive: "Unarchive"
        case .sendToAgent: "Send to Agent…"
        case .copyReference: "Copy Reference"
        case .download: "Download…"
        case .archive: "Archive"
        }
    }

    var iconSystemName: String {
        switch self {
        case .propose: "paperplane"
        case .approve: "checkmark.seal"
        case .sendBack: "arrow.uturn.backward"
        case .unarchive: "tray.and.arrow.up"
        case .sendToAgent: "arrowshape.turn.up.right"
        case .copyReference: "link"
        case .download: "arrow.down.circle"
        case .archive: "archivebox"
        }
    }

    /// The status it moves an asset to; nil for one that changes none.
    var status: AssetStatus? {
        switch self {
        case .propose: .proposed
        case .approve: .approved
        case .sendBack, .unarchive: .draft
        case .archive: .archived
        case .download, .sendToAgent, .copyReference: nil
        }
    }
}

/// How the Mac's library lays its assets out, as the cloud Mac's: its
/// table, or a grid of cards.
nonisolated enum AssetLibraryLayout: String, CaseIterable, Identifiable {
    case list
    case grid

    var id: String {
        rawValue
    }

    var title: String {
        self == .list ? "List" : "Grid"
    }
}

/// What the Assets place decides, apart from how it is drawn: which assets
/// are shown and in which part, what a row says, and what can be done with
/// an asset.
nonisolated enum AssetLibraryRules {
    /// The answers an asset's review takes, by where it stands, as the
    /// cloud app offers them: a draft with a file is proposed; what is
    /// proposed is approved or sent back; what is archived is taken out
    /// again. An asset the key cannot open is not reviewed: it cannot be
    /// looked at now.
    static func reviewActions(_ asset: Asset) -> [AssetAction] {
        switch asset.status {
        case .archived: [.unarchive]
        case _ where asset.isUnreadable: []
        case .draft: asset.files.isEmpty ? [] : [.propose]
        case .proposed: [.approve, .sendBack]
        case .approved: []
        }
    }

    /// What else can be done with an asset: it is sent to an agent (one
    /// that is proposed or approved, as the cloud app has it), its file
    /// saved somewhere (one that can be opened and has a file), and the
    /// asset put out of the way.
    static func otherActions(_ asset: Asset) -> [AssetAction] {
        (canBeSentToAnAgent(asset) ? [.sendToAgent] : []) + (asset.isUnreadable ? [] : [.copyReference])
            + (asset.isUnreadable || asset.files.isEmpty ? [] : [.download]) + (asset.status == .archived ? [] : [.archive])
    }

    /// What Copy Reference puts on the pasteboard, as the cloud app's
    /// library does: the asset's address and its title. Pasted into a
    /// thread, it tells an agent which asset is meant: the id is what
    /// `asset.get` takes. (The address itself opens nothing here.)
    static func reference(to asset: Asset) -> String {
        "aicoven-local://assets/\(asset.id) " + AttachmentContext.plainName(asset.title)
    }

    /// Copies an asset's reference, and tells VoiceOver whether it was
    /// copied: nothing on screen changes for a copy.
    @MainActor
    static func copyReference(to asset: Asset) {
        let copied = ThreadMarkdownExport.writeClipboard(reference(to: asset))
        AccessibilityNotification.Announcement(copied ? "Reference copied" : "Couldn't copy the reference").post()
    }

    /// Where the Mac's library keeps its layout, for each window.
    static let layoutKey = "assets.layout"

    /// The narrowest a card of the Mac's grid is, and the widest.
    static let gridCard: ClosedRange<CGFloat> = 180 ... 260

    /// How many cards a row of the grid holds in `width`: as many of the
    /// narrowest as fit, as the grid lays them out; one at least.
    static func gridColumns(width: CGFloat, spacing: CGFloat) -> Int {
        max(1, Int((width + spacing) / (gridCard.lowerBound + spacing)))
    }

    /// The card chosen after a move of `step` cards from `current` (one
    /// to the side, or a row up or down), among the cards in their order:
    /// the first where none is chosen, the same where the move would
    /// leave the grid, nil where there is no card.
    static func chosen(after current: Asset.ID?, movingBy step: Int, among ids: [Asset.ID]) -> Asset.ID? {
        guard let first = ids.first else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return first }
        let next = index + step
        return ids.indices.contains(next) ? ids[next] : current
    }

    /// The line under a card's title in the Mac's grid, as the cloud
    /// app's: "status · type · who made it", with no time.
    static func gridLine(_ asset: Asset, agents: [String: String] = [:]) -> String {
        [statusLabel(asset), asset.type.displayName, madeBy(asset, agents: agents)].joined(separator: " · ")
    }

    /// Whether an asset can be sent to an agent: one that is proposed or
    /// approved, and that the key can open.
    static func canBeSentToAnAgent(_ asset: Asset) -> Bool {
        !asset.isUnreadable && (asset.status == .proposed || asset.status == .approved)
    }

    /// When something was last changed, in full: the day and the time.
    static func fullTime(_ date: Date) -> String {
        date.formatted(Date.FormatStyle().month(.abbreviated).day().hour().minute())
    }

    /// A file's size in words.
    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static let unreadable = "Your encryption key can't open this asset."
    /// What the Status filter calls its choice of no one status: everything
    /// but what is archived (the cloud app calls it "All Statuses" and
    /// leaves the archived out all the same).
    static let noStatusChosen = "Not Archived"

    /// Who made an asset, as its row says it.
    static func madeBy(_ asset: Asset, agents: [String: String] = [:]) -> String {
        guard let agentID = asset.madeByAgentID else { return "You" }
        // Strix is no stored agent; an agent that is gone has no name left.
        let name = agentID == TurnAssets.strix ? "Strix" : agents[agentID]
        return name.map { "\($0), agent" } ?? "Agent"
    }

    /// What an asset's card in a thread says under its title: where it
    /// stands, what it is, and how many files it has.
    static func cardLine(_ asset: Asset) -> String {
        var parts = [statusLabel(asset), asset.type.displayName]
        if !asset.isUnreadable, !asset.files.isEmpty {
            parts.append(asset.files.count == 1 ? "1 file" : "\(asset.files.count) files")
        }
        return parts.joined(separator: " · ")
    }

    /// An asset's status as its row says it: one the key cannot open is
    /// locked, whatever status it has.
    static func statusLabel(_ asset: Asset) -> String {
        asset.isUnreadable ? "Locked" : asset.status.displayName
    }

    /// When something was last changed, shortly, as the cloud app says it:
    /// "Just now", "12m ago", "5h ago", "Yesterday", "3 days", then the day
    /// and month. A time ahead of now is said as its day. Days are counted
    /// on the calendar, not in hours gone by: the day before yesterday is
    /// "2 days" from its first minute to its last.
    static func shortTime(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let day = Date.FormatStyle().month(.abbreviated).day()
        guard date <= now else { return date.formatted(day) }
        if calendar.isDate(date, inSameDayAs: now) {
            let since = calendar.dateComponents([.hour, .minute], from: date, to: now)
            if let hours = since.hour, hours > 0 { return "\(hours)h ago" }
            if let minutes = since.minute, minutes > 0 { return "\(minutes)m ago" }
            return "Just now"
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days == 1 { return "Yesterday" }
        return (2 ..< 7).contains(days) ? "\(days) days" : date.formatted(day)
    }

    /// The quiet line under an asset's title: "status · type · who made it
    /// · when".
    static func quietLine(_ asset: Asset, agents: [String: String] = [:], now: Date, calendar: Calendar = .current) -> String {
        [statusLabel(asset), asset.type.displayName, madeBy(asset, agents: agents), shortTime(asset.updatedAt, now: now, calendar: calendar)]
            .joined(separator: " · ")
    }

    /// Whether an asset's title, what says what it is, or one of its files'
    /// names holds what is searched for, whatever its case or accents.
    static func matches(_ asset: Asset, query: String) -> Bool {
        ([asset.title, asset.details] + asset.files.map(\.name)).contains {
            $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// What is searched for, without the space around it; nil for nothing.
    static func query(_ typed: String) -> String? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The assets the place shows, in the order given: those of the type
    /// and the status chosen that match the search. With no status chosen,
    /// everything but what is archived, as the cloud app lists a coven's.
    /// What is proposed comes first, under "Needs review".
    static func shown(_ assets: [Asset], search: String, type: AssetType?, status: AssetStatus?) -> (needsReview: [Asset], others: [Asset]) {
        let query = query(search)
        let listed = assets.filter { asset in
            (type == nil || asset.type == type)
                && (status.map { asset.status == $0 } ?? (asset.status != .archived))
                && (query.map { matches(asset, query: $0) } ?? true)
        }
        return (listed.filter { $0.status == .proposed }, listed.filter { $0.status != .proposed })
    }

    /// The filters in use, in words; nil for none.
    static func filterSummary(type: AssetType?, status: AssetStatus?) -> String? {
        let parts = [type?.displayName, status?.displayName].compactMap(\.self)
        return parts.isEmpty ? nil : "Showing " + parts.joined(separator: ", ")
    }
}

/// A file as the person chose it for a new asset.
nonisolated enum AssetFileChoice {
    /// Why a chosen file was not taken.
    enum Unread: Error, Equatable {
        case notOpened
        case tooLarge
    }

    /// Reads the file the person chose. One larger than a file of an asset
    /// may be is not read at all.
    static func read(_ file: URL) throws -> AssetRepository.NewFile {
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw Unread.notOpened }
        guard size <= AssetRepository.largestFile else { throw Unread.tooLarge }
        guard let data = try? Data(contentsOf: file) else { throw Unread.notOpened }
        return AssetRepository.NewFile(name: file.lastPathComponent, data: data)
    }
}

/// A scope's assets as the Assets place shows them: the list, the search
/// and the filters, and making a new one. What it shows is one account's
/// and one scope's: only its latest reading is shown, and nothing read or
/// made for an account that is no longer signed in.
@MainActor
final class AssetLibraryModel: ObservableObject {
    /// The store's side, which a test replaces.
    struct Source {
        var assets: @Sendable (_ covenID: String?, _ account: String) async throws -> [Asset]
        var create: @Sendable (_ new: NewAsset, _ covenID: String?, _ account: String) async throws -> Asset
        /// Moves the asset, as it was listed, to another status.
        var move: @Sendable (_ asset: Asset, _ next: AssetStatus, _ account: String) async throws -> Void
        /// The names of the coven's agents, by id (none for Strix's
        /// place); nil where they could not be read.
        var agents: @Sendable (_ covenID: String?) async -> [String: String]? = { _ in [:] }

        static let live = Source(
            assets: { try await AssetRepository.shared.assets(inCoven: $0, as: $1) },
            create: { new, covenID, account in
                try await AssetRepository.shared.create(
                    type: new.type, title: new.title, details: new.details, files: [new.file], inCoven: covenID, as: account
                )
            },
            move: { try await AssetRepository.shared.move($0.id, to: $1, listedAs: $0.version, as: $2) },
            agents: { covenID in
                guard let covenID else { return [:] }
                guard let roles = try? await RoleService.shared.loadRoles(covenId: covenID) else { return nil }
                return Dictionary(roles.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            }
        )
    }

    /// A new asset as the person filled it in.
    struct NewAsset {
        var type: AssetType
        var title: String
        var details: String
        var file: AssetRepository.NewFile
    }

    /// Every asset of the scope, the one last changed first.
    @Published private(set) var assets: [Asset] = []
    /// Whether the assets have been read at least once.
    @Published private(set) var hasRead = false
    /// Whether the latest reading failed: with nothing read before it, the
    /// place says so in place of the list; otherwise the list stays and a
    /// line says it could not be refreshed.
    @Published private(set) var loadFailed = false
    /// How many readings have failed: each is its own to tell of, also one
    /// that fails after another did.
    @Published private(set) var loadFailures = 0
    @Published var search = ""
    @Published var typeFilter: AssetType?
    @Published var statusFilter: AssetStatus?
    /// The names of the place's agents, by id, for who made an asset.
    @Published private(set) var agents: [String: String] = [:]
    /// Whether a new asset is being made: one at a time.
    @Published private(set) var isCreating = false
    /// The assets whose status is on its way: one change at a time for an asset.
    @Published private(set) var changing: Set<Asset.ID> = []
    /// What went wrong with the last thing asked of an asset: each time is
    /// its own, also one in the same words as the time before.
    struct ActionFailure: Equatable {
        let number: Int
        let assetID: String
        let words: String
    }

    @Published private(set) var actionFailure: ActionFailure?

    static let couldNotRefresh = "Couldn't refresh the assets."
    static let couldNotOpenFile = "AICoven couldn't open that file."
    static let fileTooLarge = "That file is larger than 10 MB. Choose a smaller one."
    static let tooMany = "As many assets as can be kept are kept here already."
    static let detailsTooLong = "That description is too long. Keep it under 5,000 characters."
    static let couldNotCreate = "Couldn't create the asset. Try again."
    static let needsUnlock = "Unlock your data to add an asset."
    static let couldNotChange = "Couldn't update the asset. Try again."
    static let changedMeanwhile = "That asset changed before this could be done. Look at it again."
    static let needsUnlockToChange = "Unlock your data to change an asset."

    /// The coven whose assets these are; nil for Strix's.
    let covenID: String?
    private let source: Source
    private let signedIn: () -> String
    /// Counts the readings, and remembers the latest that landed: one
    /// that lands after a later one did is not shown over it. A reading
    /// that was called off lands nothing, so one asked before it still can.
    private var readings = 0
    private var landed = 0

    /// The app's own store and account unless a test gives others.
    init(covenID: String?, source: Source? = nil, signedIn: (() -> String)? = nil) {
        self.covenID = covenID
        self.source = source ?? .live
        self.signedIn = signedIn ?? { UserScope.currentUserID }
    }

    /// What is shown: see `AssetLibraryRules.shown`.
    var shown: (needsReview: [Asset], others: [Asset]) {
        AssetLibraryRules.shown(assets, search: search, type: typeFilter, status: statusFilter)
    }

    /// Whether a search or a filter is in use.
    var isNarrowed: Bool {
        AssetLibraryRules.query(search) != nil || typeFilter != nil || statusFilter != nil
    }

    func clearSearchAndFilters() {
        search = ""
        typeFilter = nil
        statusFilter = nil
    }

    /// Reads the scope's assets.
    func load() async {
        readings += 1
        let reading = readings
        let account = signedIn()
        do {
            let read = try await source.assets(covenID, account)
            let names = await source.agents(covenID)
            guard reading > landed, signedIn() == account else { return }
            landed = reading
            assets = read
            // Names that could not be read again stay as they were read last.
            if let names { agents = names }
            hasRead = true
            loadFailed = false
        } catch is CancellationError {
            // Whoever asked was called off: nothing was read, and what is shown stays.
        } catch {
            guard reading > landed, signedIn() == account else { return }
            landed = reading
            // The kind of failure only.
            AppErrorReporter.log(message: "Could not read the assets (\(type(of: error)))", context: "AssetLibraryModel.load")
            loadFailed = true
            loadFailures += 1
        }
    }

    /// What came of making an asset.
    enum Made: Equatable {
        case made(Asset)
        /// Not made, with why in words.
        case failed(String)
    }

    /// Makes a new asset in the scope for `account`, who pressed Create,
    /// and reads the list again. One at a time: a second ask while one is
    /// under way does nothing (nil). Nothing is said (nil) to another
    /// account. A search or filter that would hide the new asset is
    /// cleared, so that it is seen.
    func create(_ new: NewAsset, as account: String) async -> Made? {
        guard !isCreating else { return nil }
        isCreating = true
        defer { isCreating = false }
        do {
            let asset = try await source.create(new, covenID, account)
            guard signedIn() == account else { return nil }
            // Read in a task of its own: whoever pressed Create may be
            // called off, and what was made is still to be shown.
            await Task { await self.load() }.value
            guard signedIn() == account else { return nil }
            // If the list could not be read again, what was made is shown
            // all the same, first, as the one last changed.
            if hasRead, !assets.contains(where: { $0.id == asset.id }) { assets.insert(asset, at: 0) }
            let shown = shown
            if !(shown.needsReview + shown.others).contains(where: { $0.id == asset.id }) { clearSearchAndFilters() }
            return .made(asset)
        } catch {
            guard signedIn() == account else { return nil }
            if !(error is AssetError), !(error is RepositoryError) {
                AppErrorReporter.log(message: "Could not create an asset (\(type(of: error)))", context: "AssetLibraryModel.create")
            }
            return .failed(Self.words(forNotCreating: error))
        }
    }

    /// Does what `action` does to an asset's status, for `account`, who
    /// pressed it, and reads the list again. One change at a time for an
    /// asset: a second ask while one is under way does nothing. What went
    /// wrong is said in words, to that account only; an asset that is gone
    /// is not said to have failed (the list, read again, shows so).
    func perform(_ action: AssetAction, on asset: Asset, as account: String) async {
        guard let next = action.status, changing.insert(asset.id).inserted else { return }
        defer { changing.remove(asset.id) }
        actionFailure = nil
        do {
            try await source.move(asset, next, account)
            // Its card in a thread, if it has one, says so too.
            NotificationCenter.default.post(name: Asset.didChange, object: nil)
        } catch AssetError.noSuchAsset {
            // Gone, with its coven or its account.
        } catch {
            guard signedIn() == account else { return }
            let words = switch error {
            case AssetError.notAllowed, AssetError.needsAFile, AssetError.changed: Self.changedMeanwhile
            case RepositoryError.dataLocked: Self.needsUnlockToChange
            default: Self.couldNotChange
            }
            if !(error is AssetError), !(error is RepositoryError) {
                AppErrorReporter.log(message: "Could not change an asset (\(type(of: error)))", context: "AssetLibraryModel.perform")
            }
            failures += 1
            actionFailure = ActionFailure(number: failures, assetID: asset.id, words: words)
        }
        guard signedIn() == account else { return }
        // In a task of its own: whoever pressed may be called off, and how
        // the asset stands now is still to be shown.
        await Task { await self.load() }.value
    }

    /// Counts what went wrong, so that each time is told apart.
    private var failures = 0

    /// What is said of an asset that was not made.
    static func words(forNotCreating error: Error) -> String {
        switch error {
        case AssetError.fileTooLarge, AssetFileChoice.Unread.tooLarge: fileTooLarge
        case AssetFileChoice.Unread.notOpened: couldNotOpenFile
        case AssetError.tooMany: tooMany
        case AssetError.tooLong: detailsTooLong
        case RepositoryError.dataLocked: needsUnlock
        default: couldNotCreate
        }
    }
}
