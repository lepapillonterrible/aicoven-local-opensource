internal import Combine
import Foundation

/// The assets a reply's turn made, as cards under the reply show them:
/// read by their ids as the account signed in, wherever each is kept, and
/// approved from the card as the person approves one on its page. Only the
/// latest reading is shown, and nothing read or done for an account that is
/// no longer signed in.
@MainActor
final class AssetCardsModel: ObservableObject {
    /// The store's side, which a test replaces.
    struct Source {
        var assets: @Sendable (_ ids: [String], _ account: String) async throws -> [Asset]
        /// Approves the asset as it is listed on its card.
        var approve: @Sendable (_ asset: Asset, _ account: String) async throws -> Void

        static let live = Source(
            assets: { try await AssetRepository.shared.assets(withIDs: $0, as: $1) },
            approve: { _ = try await AssetRepository.shared.move($0.id, to: .approved, listedAs: $0.version, as: $1) }
        )
    }

    /// The assets that are still there, in the order they were made.
    @Published private(set) var assets: [Asset] = []
    /// The assets whose approval is on its way.
    @Published private(set) var approving: Set<Asset.ID> = []
    /// What went wrong with the last approval asked for, and of which asset.
    @Published private(set) var failure: (assetID: String, words: String)?

    static let couldNotApprove = "Couldn't approve the asset. Try again."

    private let ids: [String]
    private let source: Source
    private let signedIn: () -> String
    private var readings = 0
    private var landed = 0

    /// The app's own store and account unless a test gives others.
    init(ids: [String], source: Source? = nil, signedIn: (() -> String)? = nil) {
        self.ids = ids
        self.source = source ?? .live
        self.signedIn = signedIn ?? { UserScope.currentUserID }
    }

    /// Reads the assets as they are now. One that is gone is no longer
    /// shown; if they cannot be read, what was shown stays.
    func load() async {
        readings += 1
        let reading = readings
        let account = signedIn()
        guard let read = try? await source.assets(ids, account) else { return }
        guard reading > landed, signedIn() == account else { return }
        landed = reading
        assets = read
    }

    /// Approves a proposed asset as its card shows it, for `account`, who
    /// pressed Approve: one at a time for an asset. One that has changed
    /// since the card was read is not approved; the card then shows it as
    /// it is.
    func approve(_ asset: Asset, as account: String) async {
        guard approving.insert(asset.id).inserted else { return }
        defer { approving.remove(asset.id) }
        failure = nil
        do {
            try await source.approve(asset, account)
            NotificationCenter.default.post(name: Asset.didChange, object: nil)
        } catch AssetError.noSuchAsset {
            // Gone: the card goes with the next reading.
        } catch {
            guard signedIn() == account else { return }
            let words = switch error {
            case AssetError.changed, AssetError.notAllowed: AssetLibraryModel.changedMeanwhile
            case RepositoryError.dataLocked: AssetLibraryModel.needsUnlockToChange
            default: Self.couldNotApprove
            }
            failure = (asset.id, words)
        }
        guard signedIn() == account else { return }
        await Task { await self.load() }.value
    }
}
