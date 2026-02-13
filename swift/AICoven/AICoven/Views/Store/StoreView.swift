import SwiftUI
import StoreKit

/// Full store / upgrade view displaying available in-app purchases.
struct StoreView: View {
    @EnvironmentObject var storeService: StoreService
    @Environment(\.dismiss) private var dismiss
    @State private var purchasing: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.xl) {
                    // Header
                    VStack(spacing: Spacing.md) {
                        IconBadge(icon: "sparkles", size: 80, color: .aicovenTeal)

                        Text("Upgrade AICoven")
                            .font(.aicovenDisplayMedium)
                            .foregroundColor(.aicovenTextPrimary)

                        Text("Unlock powerful features with a one-time purchase")
                            .font(.aicovenBody)
                            .foregroundColor(.aicovenTextSecondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 500)
                    }
                    .padding(.top, Spacing.xl)

                    // Free tier (always shown)
                    FreeTierCard()
                        .padding(.horizontal, Spacing.lg)

                    // Purchasable products
                    if storeService.isLoading {
                        ProgressView("Loading products…")
                            .tint(.aicovenTeal)
                            .padding(.vertical, Spacing.xxl)
                    } else if storeService.products.isEmpty {
                        // Products not yet configured in App Store Connect
                        VStack(spacing: Spacing.md) {
                            Image(systemName: "clock")
                                .font(.system(size: 40))
                                .foregroundColor(.aicovenTextTertiary)
                            Text("Products coming soon")
                                .font(.aicovenBody)
                                .foregroundColor(.aicovenTextSecondary)
                            Text("In-app purchases are being set up. Check back later!")
                                .font(.aicovenCaption)
                                .foregroundColor(.aicovenTextTertiary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.vertical, Spacing.xxl)
                    } else {
                        ForEach(storeService.products, id: \.id) { product in
                            ProductCard(
                                product: product,
                                isPurchased: storeService.purchasedProductIDs.contains(product.id),
                                isPurchasing: purchasing == product.id
                            ) {
                                Task {
                                    purchasing = product.id
                                    await storeService.purchase(product)
                                    purchasing = nil
                                }
                            }
                            .padding(.horizontal, Spacing.lg)
                        }
                    }

                    // Error
                    if let error = storeService.purchaseError {
                        Text(error)
                            .font(.aicovenCaption)
                            .foregroundColor(.red)
                            .padding(.horizontal, Spacing.lg)
                    }

                    // Restore
                    Button {
                        Task { await storeService.restorePurchases() }
                    } label: {
                        Text("Restore Purchases")
                            .font(.aicovenBodySmall)
                            .foregroundColor(.aicovenTeal)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, Spacing.xl)
                }
            }
            .background(NebulaBackground())
            .navigationTitle("Store")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                            .foregroundColor(.aicovenTeal)
                    }
                }
        }
    }
}

// MARK: - Free Tier Card

private struct FreeTierCard: View {
    var body: some View {
        VStack(spacing: Spacing.md) {
            HStack {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "gift")
                            .foregroundColor(.aicovenTeal)
                        Text("Free / Lite")
                            .font(.aicovenH2)
                            .foregroundColor(.aicovenTextPrimary)
                    }
                    Text("Included by default")
                        .font(.aicovenCaption)
                        .foregroundColor(.aicovenTeal)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: Spacing.xs) {
                FeatureRow(icon: "message", text: "Personal chat")
                FeatureRow(icon: "sparkles", text: "Default AI agent")
                FeatureRow(icon: "globe", text: "Web search")
                FeatureRow(icon: "doc.text", text: "File read & write")
                FeatureRow(icon: "photo", text: "Image generation & vision")
            }
        }
        .padding(Spacing.lg)
        .glassMorphism(cornerRadius: BorderRadius.lg, padding: 0)
    }
}

// MARK: - Product Card

private struct ProductCard: View {
    let product: Product
    let isPurchased: Bool
    let isPurchasing: Bool
    let onPurchase: () -> Void

    private var tierInfo: (icon: String, color: Color, features: [String]) {
        switch product.id {
        case StoreService.creatorID:
            (
                "person.3.fill",
                .aicovenPurple,
                [
                    "Create & manage covens",
                    "Multiple AI agent roles",
                    "Model customization"
                ]
            )
        case StoreService.toolsPackID:
            (
                "wrench.and.screwdriver.fill",
                .aicovenTeal,
                [
                    "Shell command execution",
                    "GitHub integration",
                    "Google Drive integration"
                ]
            )
        case StoreService.everythingID:
            (
                "star.fill",
                .aicovenPink,
                [
                    "All Creator features",
                    "All Tools Pack features",
                    "All future features"
                ]
            )
        default:
            ("questionmark", .gray, [])
        }
    }

    var body: some View {
        let info = tierInfo

        VStack(spacing: Spacing.md) {
            HStack {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: info.icon)
                            .foregroundColor(info.color)
                        Text(product.displayName)
                            .font(.aicovenH2)
                            .foregroundColor(.aicovenTextPrimary)
                    }
                    Text(product.description)
                        .font(.aicovenCaption)
                        .foregroundColor(.aicovenTextSecondary)
                        .lineLimit(2)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: Spacing.xs) {
                ForEach(info.features, id: \.self) { feature in
                    FeatureRow(icon: "checkmark.circle.fill", text: feature, color: info.color)
                }
            }

            // Purchase / purchased button
            if isPurchased {
                HStack {
                    Image(systemName: "checkmark.seal.fill")
                    Text("Purchased")
                }
                .font(.aicovenBodyMedium)
                .foregroundColor(.green)
                .frame(maxWidth: .infinity)
                .padding(Spacing.md)
                .background(Color.green.opacity(0.15))
                .cornerRadius(BorderRadius.md)
            } else {
                Button(action: onPurchase) {
                    Group {
                        if isPurchasing {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text(product.displayPrice)
                                .font(.aicovenBodyMedium)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(Spacing.md)
                    .background(
                        LinearGradient(
                            colors: [info.color, info.color.opacity(0.7)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .foregroundColor(.white)
                    .cornerRadius(BorderRadius.md)
                }
                .buttonStyle(.plain)
                .disabled(isPurchasing)
            }
        }
        .padding(Spacing.lg)
        .glassMorphism(cornerRadius: BorderRadius.lg, padding: 0)
        .overlay(
            RoundedRectangle(cornerRadius: BorderRadius.lg)
                .strokeBorder(
                    product.id == StoreService.everythingID
                        ? info.color.opacity(0.5)
                        : Color.clear,
                    lineWidth: 1
                )
        )
    }
}

// MARK: - Feature Row

private struct FeatureRow: View {
    let icon: String
    let text: String
    var color: Color = .aicovenTextSecondary

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(color)
                .frame(width: 18)
            Text(text)
                .font(.aicovenBodySmall)
                .foregroundColor(.aicovenTextPrimary)
        }
    }
}

// MARK: - Upsell Sheet

/// Compact upsell prompt shown when a user hits a gated feature.
struct FeatureUpsellView: View {
    let feature: PurchasableFeature
    let featureDescription: String
    @EnvironmentObject var storeService: StoreService
    @Environment(\.dismiss) private var dismiss
    @State private var showStore = false

    private var tierName: String {
        storeService.requiredTier(for: feature)
    }

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()

            Image(systemName: "lock.fill")
                .font(.system(size: 48))
                .foregroundColor(.aicovenPurple)

            VStack(spacing: Spacing.sm) {
                Text("\(tierName) Required")
                    .font(.aicovenH1)
                    .foregroundColor(.aicovenTextPrimary)

                Text(featureDescription)
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            GradientButton("View Upgrade Options", icon: "sparkles", style: .primary) {
                showStore = true
            }
            .padding(.horizontal, Spacing.xl)

            Button("Not Now") { dismiss() }
                .font(.aicovenBodySmall)
                .foregroundColor(.aicovenTeal)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(NebulaBackground())
        .sheet(isPresented: $showStore) {
            StoreView()
                .environmentObject(storeService)
        }
    }
}

#Preview {
    StoreView()
        .environmentObject(StoreService.shared)
}
