import CryptoKit
import Foundation
import StoreKit
internal import Combine

/// Features that can be gated behind in-app purchases.
enum PurchasableFeature: String, CaseIterable {
    // Creator tier
    case covens
    case multipleAgents
    case modelCustomization
    // Tools Pack tier
    case shellTool
    case githubTool
    case googleDriveTool
    case figmaTool
    case linearTool
}

/// Manages StoreKit 2 in-app purchases for AICoven.
///
/// Three non-consumable products:
/// - **Creator**: Unlocks covens, multiple agents, model customisation.
/// - **Tools Pack**: Unlocks shell, GitHub, and Google Drive tools.
/// - **Everything Forever**: Unlocks all paid features.
@MainActor
class StoreService: ObservableObject {
    static let shared = StoreService()

    // MARK: - Product identifiers

    /// Product IDs matching App Store Connect configuration.
    static let creatorID = "com.aicoven.creator"
    static let toolsPackID = "com.aicoven.toolspack"
    static let everythingID = "com.aicoven.everything"

    static let allProductIDs: Set<String> = [
        creatorID, toolsPackID, everythingID
    ]

    // MARK: - Published state

    @Published private(set) var products: [Product] = []
    @Published private(set) var purchasedProductIDs: Set<String> = []
    @Published private(set) var isLoading = false
    @Published var purchaseError: String?

    // MARK: - Entitlement helpers

    /// Whether user is authenticated. Entitlements require authentication.
    private var isAuthenticated: Bool {
        UserScope.firebaseUserID != nil
    }

    var hasCreator: Bool {
        // Require authentication - no entitlements for unauthenticated users
        guard isAuthenticated else { return false }
        return purchasedProductIDs.contains(Self.creatorID) ||
            purchasedProductIDs.contains(Self.everythingID)
    }

    var hasToolsPack: Bool {
        // Require authentication - no entitlements for unauthenticated users
        guard isAuthenticated else { return false }
        return purchasedProductIDs.contains(Self.toolsPackID) ||
            purchasedProductIDs.contains(Self.everythingID)
    }

    var hasEverything: Bool {
        // Require authentication - no entitlements for unauthenticated users
        guard isAuthenticated else { return false }
        return purchasedProductIDs.contains(Self.everythingID)
    }

    /// Check whether a specific feature is unlocked.
    /// Returns false if user is not authenticated.
    func hasEntitlement(_ feature: PurchasableFeature) -> Bool {
        guard isAuthenticated else { return false }
        switch feature {
        case .covens, .multipleAgents, .modelCustomization:
            return hasCreator
        case .shellTool, .githubTool, .googleDriveTool, .figmaTool, .linearTool:
            return hasToolsPack
        }
    }

    /// The name of the upgrade that unlocks a feature, as the App Store
    /// names it.
    func requiredTier(for feature: PurchasableFeature) -> String {
        switch feature {
        case .covens, .multipleAgents, .modelCustomization:
            name(of: Self.creatorID)
        case .shellTool, .githubTool, .googleDriveTool, .figmaTool, .linearTool:
            name(of: Self.toolsPackID)
        }
    }

    /// A product's name as the App Store gives it, or as App Store Connect
    /// names it where the products are not loaded yet.
    func name(of productID: String) -> String {
        products.first { $0.id == productID }?.displayName ?? Self.shownName(of: productID)
    }

    /// The products' names in App Store Connect.
    nonisolated static func shownName(of productID: String) -> String {
        switch productID {
        case creatorID: "Starter Pack"
        case toolsPackID: "Connected Apps"
        case everythingID: "Everything Forever"
        default: productID
        }
    }

    // MARK: - Whose purchases

    /// The token every purchase made by an account carries (StoreKit's
    /// `appAccountToken`): a UUID made from the account's id, the same on
    /// every device. What an Apple ID bought is then given back to the
    /// account that bought it, on any device, and not to another account
    /// signed in with the same Apple ID.
    nonisolated static func accountToken(for account: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("aicoven.purchases.\(account)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// One of the Apple ID's current entitlements, as far as what it
    /// unlocks and for whom.
    nonisolated struct Entitlement: Equatable {
        let productID: String
        let accountToken: UUID?
        let isRevoked: Bool
    }

    /// What `account` owns of the Apple ID's entitlements: those bought with
    /// its token, and those bought before purchases carried one (made in
    /// an earlier version, they cannot say whose they are). Nothing that
    /// was refunded or revoked, and nothing bought by another account.
    nonisolated static func owned(of entitlements: [Entitlement], by account: String) -> Set<String> {
        let token = accountToken(for: account)
        return Set(entitlements.filter { entitlement in
            allProductIDs.contains(entitlement.productID) && !entitlement.isRevoked
                && (entitlement.accountToken == nil || entitlement.accountToken == token)
        }.map(\.productID))
    }

    // MARK: - Persistence (backup)

    /// User-scoped storage key so each Firebase user gets their own purchase cache.
    private var purchasedIDsKey: String {
        UserScope.scopedKey("StoreService.purchasedProductIDs")
    }

    private func persistPurchases() {
        UserDefaults.standard.set(
            Array(purchasedProductIDs),
            forKey: purchasedIDsKey
        )
    }

    private func loadPersistedPurchases() {
        if let saved = UserDefaults.standard.stringArray(forKey: purchasedIDsKey) {
            purchasedProductIDs = Set(saved)
        } else {
            purchasedProductIDs = []
        }
    }

    /// Reload entitlements for the current user. Call after user switch.
    /// Requires authentication - clears entitlements if no user is signed in.
    func reloadForCurrentUser() async {
        let userID = UserScope.currentUserID
        print("💳 StoreService.reloadForCurrentUser")

        await MainActor.run {
            // Clear cached purchases (they were for a different user)
            purchasedProductIDs = []

            // Only load purchases if user is authenticated
            guard isAuthenticated else {
                AppErrorReporter.log(message: "Clearing purchases - no authenticated user", context: "StoreService.reloadForCurrentUser")
                return
            }

            // Load any cached purchases for this user
            loadPersistedPurchases()
            print("💳 Loaded cached purchases for user: \(purchasedProductIDs)")
        }

        // Only refresh from StoreKit if authenticated
        guard isAuthenticated else { return }
        await refreshEntitlements()
        print("💳 After StoreKit refresh: \(purchasedProductIDs)")
    }

    /// Clear stale test purchases that were cached for this user but made by automated tests.
    /// Call this once to clean up after running tests with a real Firebase account.
    func clearStalePurchasesForCurrentUser() {
        guard isAuthenticated else { return }
        print("🧹 Clearing stale purchases for current user")
        print("   Was: \(purchasedProductIDs)")
        purchasedProductIDs = []
        persistPurchases()
        print("   Now: \(purchasedProductIDs)")
    }

    /// Debug: Clear all cached purchase data (useful for testing)
    /// WARNING: This does not affect actual StoreKit entitlements
    func debugClearCachedPurchases() {
        print("⚠️ DEBUG: Clearing cached purchases from UserDefaults")
        purchasedProductIDs = []
        persistPurchases()
    }

    // MARK: - Transaction listener

    private var transactionListenerTask: Task<Void, Never>?

    private init() {
        // Don't load persisted purchases here. The active user scope may change
        // after authentication, so entitlements load in reloadForCurrentUser().
        transactionListenerTask = listenForTransactions()
        Task {
            await loadProducts()
            // Don't refresh entitlements here either - wait for reloadForCurrentUser()
        }
    }

    deinit {
        transactionListenerTask?.cancel()
    }

    /// Listen for StoreKit transaction updates (purchases made on another
    /// device, a purchase approved later, refunds). Each is finished, and
    /// what the signed-in account owns is read again from the Apple ID's
    /// entitlements: a refund takes the upgrade away at once, and a
    /// purchase made by another account on the same Apple ID gives this one
    /// nothing.
    private func listenForTransactions() -> Task<Void, Never> {
        Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                if case let .verified(transaction) = result {
                    await transaction.finish()
                }
                await refreshEntitlements()
            }
        }
    }

    // MARK: - Load products

    func loadProducts() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let storeProducts = try await Product.products(for: Self.allProductIDs)
            // Sort: Creator → Tools Pack → Everything
            products = storeProducts.sorted { a, b in
                let order: [String: Int] = [
                    Self.creatorID: 0,
                    Self.toolsPackID: 1,
                    Self.everythingID: 2
                ]
                return (order[a.id] ?? 99) < (order[b.id] ?? 99)
            }
        } catch {
            AppErrorReporter.log(error: error, context: "StoreService.loadProducts")
        }
    }

    // MARK: - Purchase

    /// Purchase a product. Requires authentication.
    func purchase(_ product: Product) async {
        purchaseError = nil

        // Require authentication before allowing purchase
        guard isAuthenticated else {
            purchaseError = "Please sign in to make a purchase."
            return
        }

        // Bought for the account signed in now: the purchase carries its
        // token, so it is given back to this account and no other.
        let account = UserScope.currentUserID
        do {
            let result = try await product.purchase(options: [.appAccountToken(Self.accountToken(for: account))])

            switch result {
            case let .success(verification):
                if case let .verified(transaction) = verification {
                    await transaction.finish()
                    if UserScope.currentUserID == account {
                        purchasedProductIDs.insert(transaction.productID)
                        persistPurchases()
                    }
                } else {
                    purchaseError = "Purchase could not be verified."
                }

            case .userCancelled:
                break // No error for user-initiated cancel

            case .pending:
                purchaseError = "Purchase is pending approval."

            @unknown default:
                break
            }
        } catch {
            purchaseError = error.localizedDescription
            AppErrorReporter.log(error: error, context: "StoreService.purchase")
        }
    }

    // MARK: - Restore purchases

    /// Asks the App Store for the Apple ID's purchases (which may ask the
    /// person to sign in to it), then gives the signed-in account what it
    /// owns of them.
    func restorePurchases() async {
        do {
            try await AppStore.sync()
        } catch {
            // The kind of failure only; the entitlements on the device are
            // still read.
            AppErrorReporter.log(message: "The App Store could not be synced (\(type(of: error)))", context: "StoreService.restorePurchases")
        }
        await refreshEntitlements()
    }

    /// What the signed-in account owns, read from the Apple ID's current
    /// entitlements (`owned(of:by:)`), kept as its own: purchases made on
    /// another device come back, a refund is taken away, and what another
    /// account on the same Apple ID bought is not given. Nothing is kept
    /// once another account has signed in meanwhile.
    private func refreshEntitlements() async {
        let account = UserScope.currentUserID
        var entitlements: [Entitlement] = []
        for await result in Transaction.currentEntitlements {
            if case let .verified(transaction) = result {
                entitlements.append(Entitlement(
                    productID: transaction.productID, accountToken: transaction.appAccountToken, isRevoked: transaction.revocationDate != nil
                ))
            }
        }
        guard isAuthenticated, UserScope.currentUserID == account else { return }
        let owned = Self.owned(of: entitlements, by: account)
        if owned != purchasedProductIDs {
            purchasedProductIDs = owned
            persistPurchases()
        }
    }
}
