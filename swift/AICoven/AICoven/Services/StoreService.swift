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

    var hasCreator: Bool {
        purchasedProductIDs.contains(Self.creatorID) ||
            purchasedProductIDs.contains(Self.everythingID)
    }

    var hasToolsPack: Bool {
        purchasedProductIDs.contains(Self.toolsPackID) ||
            purchasedProductIDs.contains(Self.everythingID)
    }

    var hasEverything: Bool {
        purchasedProductIDs.contains(Self.everythingID)
    }

    /// Check whether a specific feature is unlocked.
    func hasEntitlement(_ feature: PurchasableFeature) -> Bool {
        switch feature {
        case .covens, .multipleAgents, .modelCustomization:
            hasCreator
        case .shellTool, .githubTool, .googleDriveTool:
            hasToolsPack
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

    private static let purchasedIDsKey = "StoreService.purchasedProductIDs"

    private func persistPurchases() {
        UserDefaults.standard.set(
            Array(purchasedProductIDs),
            forKey: Self.purchasedIDsKey
        )
    }

    private func loadPersistedPurchases() {
        if let saved = UserDefaults.standard.stringArray(forKey: Self.purchasedIDsKey) {
            purchasedProductIDs = Set(saved)
        }
    }

    // MARK: - Transaction listener

    private var transactionListenerTask: Task<Void, Never>?

    private init() {
        loadPersistedPurchases()
        transactionListenerTask = listenForTransactions()
        Task {
            await loadProducts()
            await refreshEntitlements()
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

    func purchase(_ product: Product) async {
        purchaseError = nil

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
    private func refreshEntitlements() async {
        var entitled: Set<String> = []

        for await result in Transaction.currentEntitlements {
            if case let .verified(transaction) = result {
                if Self.allProductIDs.contains(transaction.productID) {
                    entitled.insert(transaction.productID)
                }
            }
        }

        purchasedProductIDs = entitled
        persistPurchases()
    }
}
