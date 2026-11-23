internal import Combine
import SwiftUI

/// The assets a reply's turn made, each as a card under the reply, as the
/// cloud app shows an asset in the thread it was made in: what it is, where
/// it stands, and the way to it in Assets. A proposed one can be approved
/// from its card.
struct AssetCardsView: View {
    let assetIDs: [String]
    /// Opens the asset in the Assets place of where it is kept.
    var onOpen: ((Asset) -> Void)?

    @StateObject private var model: AssetCardsModel

    init(assetIDs: [String], onOpen: ((Asset) -> Void)? = nil) {
        self.assetIDs = assetIDs
        self.onOpen = onOpen
        _model = StateObject(wrappedValue: AssetCardsModel(ids: assetIDs))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(model.assets) { asset in
                card(asset)
            }
        }
        .task { await model.load() }
        // Approved, sent back or archived elsewhere: the card says so.
        .onReceive(NotificationCenter.default.publisher(for: Asset.didChange).receive(on: RunLoop.main)) { _ in
            Task { await model.load() }
        }
        // What came of Approve is said to VoiceOver: the card that was
        // pressed is on screen.
        .onChange(of: model.said) { _, said in
            if let said { AccessibilityNotification.Announcement(said.words).post() }
        }
    }

    /// How a card's buttons name its asset to VoiceOver: several cards in
    /// a thread would otherwise have buttons of the same name.
    static func name(of asset: Asset) -> String {
        asset.isUnreadable ? "the locked asset" : asset.title
    }

    private func card(_ asset: Asset) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: Spacing.sm) {
                AssetThumbnail(type: asset.type, isLocked: asset.isUnreadable, width: 64, height: 48)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(asset.isUnreadable ? AssetLibraryRules.unreadable : asset.title)
                        .font(.aicovenBodyMedium)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.aicovenTextPrimary)
                        .lineLimit(2)
                    Text(AssetLibraryRules.cardLine(asset))
                        .font(.aicovenCaption)
                        .foregroundStyle(Color.aicovenTextSecondary)
                    HStack(spacing: Spacing.xs) {
                        if let onOpen {
                            Button("Open in Assets") { onOpen(asset) }
                                .accessibilityLabel("Open \(Self.name(of: asset)) in Assets")
                        }
                        if asset.status == .proposed, !asset.isUnreadable {
                            Button("Approve") {
                                let account = UserScope.currentUserID
                                Task { await model.approve(asset, as: account) }
                            }
                            .disabled(model.approving.contains(asset.id))
                            .accessibilityLabel("Approve \(Self.name(of: asset))")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, Spacing.xxxs)
                    if let failure = model.failure, failure.assetID == asset.id {
                        Text(failure.words)
                            .font(.aicovenCaption)
                            .foregroundStyle(Color.aicovenError)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Spacing.sm)

            Divider().overlay(Color.aicovenBorder.opacity(0.5))

            Text(asset.covenID == nil ? "Saved to your library." : "Saved to the coven library.")
                .font(.aicovenCaption)
                .foregroundStyle(Color.aicovenTextTertiary)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
        }
        .frame(maxWidth: 440, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: BorderRadius.md).fill(Color.aicovenSurfaceElevated))
        .overlay(RoundedRectangle(cornerRadius: BorderRadius.md).strokeBorder(Color.aicovenBorder, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Asset: \(asset.isUnreadable ? "locked" : asset.title), \(AssetLibraryRules.statusLabel(asset))")
    }
}
