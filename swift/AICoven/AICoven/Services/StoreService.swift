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
        UserScope.currentUserID != nil
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
        case .shellTool, .githubTool, .googleDriveTool:
            return hasToolsPack
        }
    }

    /// Human-readable tier name required to unlock a feature.
    func requiredTier(for feature: PurchasableFeature) -> String {
        switch feature {
        case .covens, .multipleAgents, .modelCustomization:
            "Creator"
        case .shellTool, .githubTool, .googleDriveTool:
            "Tools Pack"
        }
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
        let userID = UserScope.currentUserID ?? "<none>"
        print("💳 StoreService.reloadForCurrentUser: userID=\(userID)")

        await MainActor.run {
            // Clear cached purchases (they were for a different user)
            purchasedProductIDs = []

            // Only load purchases if user is authenticated
            guard UserScope.currentUserID != nil else {
                AppErrorReporter.log(message: "Clearing purchases - no authenticated user", context: "StoreService.reloadForCurrentUser")
                return
            }

            // Load any cached purchases for this user
            loadPersistedPurchases()
            print("💳 Loaded cached purchases for user: \(purchasedProductIDs)")
        }

        // Only refresh from StoreKit if authenticated
        guard UserScope.currentUserID != nil else { return }
        await refreshEntitlements()
        print("💳 After StoreKit refresh: \(purchasedProductIDs)")
    }

    /// Clear stale test purchases that were cached for this user but made by automated tests.
    /// Call this once to clean up after running tests with a real Firebase account.
    func clearStalePurchasesForCurrentUser() {
        guard UserScope.currentUserID != nil else { return }
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
        // Don't load persisted purchases here - they're unscoped if no user is signed in.
        // Instead, load them in reloadForCurrentUser() which is called after auth.
        transactionListenerTask = listenForTransactions()
        Task {
            await loadProducts()
            // Don't refresh entitlements here either - wait for reloadForCurrentUser()
        }
    }

    deinit {
        transactionListenerTask?.cancel()
    }

    /// Listen for StoreKit transaction updates (e.g. purchases made on
    /// another device, family sharing changes, refunds).
    private func listenForTransactions() -> Task<Void, Never> {
        Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                if case let .verified(transaction) = result {
                    await MainActor.run {
                        self.purchasedProductIDs.insert(transaction.productID)
                        self.persistPurchases()
                    }
                    await transaction.finish()
                }
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
        guard UserScope.currentUserID != nil else {
            purchaseError = "Please sign in to make a purchase."
            return
        }

        do {
            let result = try await product.purchase()

            switch result {
            case let .success(verification):
                if case let .verified(transaction) = verification {
                    purchasedProductIDs.insert(transaction.productID)
                    persistPurchases()
                    await transaction.finish()
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

    func restorePurchases() async {
        await refreshEntitlements()
    }

    /// Walk current entitlements and update purchased set.
    ///
    /// NOTE: StoreKit entitlements are tied to Apple ID, not Firebase user.
    /// We only add NEW purchases from StoreKit (made during this session),
    /// we don't replace the user's cached purchases with Apple ID purchases.
    /// This prevents User A from inheriting User B's purchases when they
    /// share the same Apple ID but have different Firebase accounts.
    private func refreshEntitlements() async {
        // Get current StoreKit entitlements (tied to Apple ID)
        var storeKitEntitlements: Set<String> = []
        for await result in Transaction.currentEntitlements {
            if case let .verified(transaction) = result {
                if Self.allProductIDs.contains(transaction.productID) {
                    storeKitEntitlements.insert(transaction.productID)
                }
            }
        }

        // Only ADD purchases that are in both StoreKit AND were made during
        // this user's session. Don't replace the user's purchases with
        // StoreKit entitlements from a different Firebase user.
        //
        // The flow is:
        // 1. User makes purchase -> StoreKit returns it -> we add to purchasedProductIDs -> persist
        // 2. User signs out, different user signs in
        // 3. That user's cached purchases are loaded (empty or their own)
        // 4. StoreKit still returns the first user's purchase
        // 5. We DON'T add it because it's not in the new user's cache
        //
        // To properly sync purchases across devices/users, you'd need a backend.

        print("💳 StoreKit entitlements (Apple ID): \(storeKitEntitlements)")
        print("💳 User's cached purchases: \(purchasedProductIDs)")

        // Only keep purchases that are both cached for this user AND valid in StoreKit
        // This handles refunds: if StoreKit no longer has it, remove it
        let validPurchases = purchasedProductIDs.intersection(storeKitEntitlements)

        if validPurchases != purchasedProductIDs {
            print("💳 Removing invalid/refunded purchases: \(purchasedProductIDs.subtracting(validPurchases))")
            purchasedProductIDs = validPurchases
            persistPurchases()
        }
    }
}
