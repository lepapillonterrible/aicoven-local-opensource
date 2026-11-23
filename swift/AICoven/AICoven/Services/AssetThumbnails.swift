internal import Combine
import CoreGraphics
import Foundation
import ImageIO

/// Small pictures of assets, drawn on the device from an asset's own file
/// and kept in memory only: nothing of an asset is written outside the
/// encrypted store for one. (The cloud app draws them with Quick Look and
/// keeps them in a cache on disk; here a picture or a PDF is drawn in
/// memory, and any other kind of file keeps its type's symbol.) What is
/// held is one account's, under the key it was opened with: it is
/// forgotten when another account signs in and whenever the data key in
/// memory changes (the data locked, unlocked, or changing hands), at once,
/// whether or not anything is asked for then; and a view that shows a
/// picture drops it when that happens (`generation`).
@MainActor
final class AssetThumbnails: ObservableObject {
    static let shared = AssetThumbnails(followsTheKey: true)

    /// Advances each time everything held is forgotten: what a view shows
    /// was drawn under the generation it was asked in, and is no longer
    /// shown under another.
    @Published private(set) var generation = 0

    /// The longest edge of a thumbnail in pixels: 360 points at 2x, as the cloud app's.
    static let longestEdge = 720
    /// How much is kept, in bytes of drawn pictures.
    static let room = 64 * 1024 * 1024

    /// The store's and the key's side, which a test replaces.
    struct Hands {
        var data: @Sendable (_ fileID: String, _ account: String) async throws -> Data
        var signedIn: @MainActor () -> String
        /// Counts every lock and unlock of the account's data.
        var keyEpoch: @Sendable () async -> Int
        var draw: @Sendable (_ data: Data, _ mimeType: String) async -> CGImage?

        static let live = Hands(
            data: { try await AssetRepository.shared.data(ofFile: $0, as: $1) },
            signedIn: { UserScope.currentUserID },
            keyEpoch: { await DataEncryptionService.shared.keyEpoch },
            draw: { data, mimeType in await Task.detached { AssetThumbnails.draw(data, mimeType: mimeType) }.value }
        )
    }

    private let hands: Hands
    private let room: Int
    private var pictures: [String: CGImage] = [:]
    /// The files held, the one asked for longest ago first.
    private var order: [String] = []
    private var held = 0
    /// Files that cannot be drawn: not tried again.
    private var undrawable: Set<String> = []
    private var drawing: [String: Task<Drawn, Never>] = [:]

    /// What came of drawing a file.
    private enum Drawn {
        case picture(CGImage)
        /// Read, and not a picture this device draws: not tried again.
        case undrawable
        /// Not read (the store did not answer, or the drawing was called
        /// off): tried again the next time it is asked for.
        case unread
    }

    /// Whose pictures these are, and under which unlocking of their data.
    private var owner: (account: String, epoch: Int)?
    private var keyWatch: NSObjectProtocol?

    /// `followsTheKey` is for the app's own: it forgets everything as
    /// soon as the data key in memory changes.
    init(hands: Hands = .live, room: Int = AssetThumbnails.room, followsTheKey: Bool = false) {
        self.hands = hands
        self.room = room
        if followsTheKey {
            keyWatch = NotificationCenter.default.addObserver(forName: DataEncryptionService.keyDidChange, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.forgetAll() }
            }
        }
    }

    /// The files an asset's picture can be drawn from, by their kind, the
    /// latest first: none for an asset the key cannot open. The picture
    /// is of the first of them that is in fact drawn.
    nonisolated static func files(of asset: Asset) -> [AssetFile] {
        asset.isUnreadable ? [] : asset.files.reversed().filter { canDraw($0.mimeType) }
    }

    /// What tells one asking for an asset's picture from another: the
    /// files it can be drawn from. A view asks again when it changes.
    nonisolated static func key(of asset: Asset) -> String {
        files(of: asset).map(\.id).joined(separator: "|")
    }

    /// Whether a file of this type is drawn: a picture ImageIO reads, or a PDF.
    nonisolated static func canDraw(_ mimeType: String) -> Bool {
        mimeType == "application/pdf" || (mimeType.hasPrefix("image/") && mimeType != "image/svg+xml")
    }

    /// Everything held is forgotten: another account signed in, or the
    /// data key in memory changed.
    func forgetAll() {
        drawing.values.forEach { $0.cancel() }
        (pictures, order, held, undrawable, drawing, owner) = ([:], [], 0, [], [:], nil)
        generation += 1
    }

    /// The asset's picture, drawn once and then kept: of its latest file
    /// that is in fact drawn (an older one where a later one cannot be);
    /// nil where it has none. Read as `account`, and nothing is answered
    /// or kept once another account is signed in or the data key changed
    /// meanwhile.
    func picture(of asset: Asset, as account: String) async -> CGImage? {
        let files = Self.files(of: asset)
        guard !files.isEmpty, hands.signedIn() == account else { return nil }
        let epoch = await hands.keyEpoch()
        guard hands.signedIn() == account else { return nil }
        // Held for this account as its data is unlocked now, or not at all.
        if let owner, owner.account != account || owner.epoch != epoch { forgetAll() }
        owner = (account, epoch)
        for file in files {
            if let picture = pictures[file.id] {
                order.removeAll { $0 == file.id }
                order.append(file.id)
                return picture
            }
            guard !undrawable.contains(file.id) else { continue }
            // One drawing of a file at a time: whoever asks meanwhile waits for it.
            let task = drawing[file.id] ?? Task { [hands] () -> Drawn in
                guard let data = try? await hands.data(file.id, account), !Task.isCancelled else { return .unread }
                return await hands.draw(data, file.mimeType).map(Drawn.picture) ?? .undrawable
            }
            drawing[file.id] = task
            let outcome = await task.value
            let now = await hands.keyEpoch()
            // Until here it stood for whoever asked meanwhile; from here
            // on what it came to is kept, or nobody is answered by it.
            if drawing[file.id] == task { drawing[file.id] = nil }
            // Still the same account under the same unlocking: what was read is theirs to keep and show.
            guard hands.signedIn() == account, let owner, owner.account == account, owner.epoch == epoch, now == epoch, !task.isCancelled else {
                return nil
            }
            switch outcome {
            case let .picture(picture):
                keep(picture, of: file.id)
                return picture
            case .undrawable:
                // Not a picture after all: an older file may be.
                undrawable.insert(file.id)
            case .unread:
                return nil
            }
        }
        return nil
    }

    private func keep(_ picture: CGImage, of fileID: String) {
        guard pictures[fileID] == nil else { return }
        pictures[fileID] = picture
        order.append(fileID)
        held += picture.bytesPerRow * picture.height
        // The ones asked for longest ago make room.
        while held > room, order.count > 1, let oldest = order.first {
            order.removeFirst()
            if let gone = pictures.removeValue(forKey: oldest) { held -= gone.bytesPerRow * gone.height }
        }
    }

    /// Draws a picture or the first page of a PDF, no larger than a
    /// thumbnail is; nil for what cannot be read as either.
    nonisolated static func draw(_ data: Data, mimeType: String) -> CGImage? {
        if mimeType == "application/pdf" || data.starts(with: Data("%PDF-".utf8)) {
            return firstPage(ofPDF: data)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Upright, as the picture is meant to be seen.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longestEdge,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private nonisolated static func firstPage(ofPDF data: Data) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider), !document.isEncrypted || document.isUnlocked,
              let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        // As the page is shown: one turned a quarter is as wide as its box is tall.
        let isTurned = (page.rotationAngle / 90) % 2 != 0
        let shown = isTurned ? CGSize(width: box.height, height: box.width) : box.size
        let scale = min(CGFloat(longestEdge) / max(shown.width, shown.height), 4)
        // Whole pixels, and never past the longest edge: the product can
        // come out a hair above it before it is rounded up.
        let longest = CGFloat(longestEdge)
        let size = CGSize(width: min(longest, (shown.width * scale).rounded(.up)), height: min(longest, (shown.height * scale).rounded(.up)))
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        // On white, as a page is.
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.scaleBy(x: scale, y: scale)
        // The page's own turn and origin, into a rectangle of its shown size.
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: shown), rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        return context.makeImage()
    }
}
