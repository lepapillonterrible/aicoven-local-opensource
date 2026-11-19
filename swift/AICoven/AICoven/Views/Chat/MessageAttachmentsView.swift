import ImageIO
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// A message's attachments in the thread: pictures as thumbnails, other
/// files as their file row. Either opens in Quick Look.
struct MessageAttachmentsView: View {
    let attachments: [FileAttachmentDetail]
    let alignment: HorizontalAlignment

    var body: some View {
        VStack(alignment: alignment, spacing: Spacing.xs) {
            ForEach(attachments) { attachment in
                AttachmentThumbnail(attachment: attachment)
            }
        }
    }
}

/// One attachment. Its bytes are read from the attachment store; it shows
/// as a picture only when they are one (by what they are, not their name),
/// and otherwise, or if it can no longer be read, as its file row.
struct AttachmentThumbnail: View {
    let attachment: FileAttachmentDetail

    @State private var thumbnail: AttachmentThumbnailImage?
    @State private var isLoading: Bool
    @StateObject private var presenter = AttachmentPreviewPresenter()

    /// Thumbnails, and files found not to be pictures, by attachment id,
    /// kept in memory so opening a thread again need not read them again.
    private static let cache = NSCache<NSString, AttachmentThumbnailImage>()
    nonisolated static let side: CGFloat = 220

    init(attachment: FileAttachmentDetail) {
        self.attachment = attachment
        // A file known not to be a picture is not read to find that out.
        _isLoading = State(initialValue: attachment.mimeType?.hasPrefix("image/") != false)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: Spacing.xxs) {
            Button {
                Task { await presenter.open(attachmentID: attachment.id, filename: thumbnail?.filename ?? attachment.name) }
            } label: {
                content
                    .overlay {
                        if presenter.isOpening {
                            ProgressView().controlSize(.small)
                        }
                    }
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
            .accessibilityLabel(Text(accessibilityName))
            .accessibilityHint("Opens it larger")
            .accessibilityIdentifier("message-attachment")
            if let errorMessage = presenter.errorMessage {
                Text(errorMessage)
                    .font(.aicovenCaption)
                    .foregroundStyle(Color.aicovenError)
            }
        }
        .task(id: attachment.id) { await load() }
        .quickLookPreview($presenter.previewURL)
        .onDisappear { presenter.teardown() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            RoundedRectangle(cornerRadius: BorderRadius.md, style: .continuous)
                .fill(Color.aicovenSurfaceElevated)
                .frame(width: Self.side, height: Self.side * 0.75)
                .overlay(ProgressView().controlSize(.small))
        } else if let image = thumbnail?.image {
            let size = Self.displaySize(width: image.width, height: image.height)
            Image(decorative: image, scale: 1)
                .resizable()
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: BorderRadius.md, style: .continuous))
        } else {
            // A row as wide as it needs, not as wide as the thread.
            FileAttachmentView(attachment: attachment, compact: true)
                .frame(maxWidth: 320)
        }
    }

    private var accessibilityName: String {
        if isLoading { return "Loading attachment" }
        return thumbnail?.image != nil ? "Picture, \(attachment.name)" : "File, \(attachment.name)"
    }

    /// Fits a picture in a `side` square, never larger than its pixels.
    nonisolated static func displaySize(width: Int, height: Int) -> CGSize {
        let width = CGFloat(width), height = CGFloat(height)
        guard width > 0, height > 0 else { return .zero }
        let scale = min(1, side / max(width, height))
        return CGSize(width: width * scale, height: height * scale)
    }

    private func load() async {
        guard isLoading else { return }
        if let cached = Self.cache.object(forKey: attachment.id as NSString) {
            thumbnail = cached
            isLoading = false
            return
        }
        let account = UserScope.currentUserID
        let id = attachment.id
        let name = attachment.name
        guard let data = try? await AttachmentStore.shared.data(of: id) else {
            // Gone, locked, or not this account's: its file row stands.
            guard !Task.isCancelled else { return }
            isLoading = false
            return
        }
        let decoded = await Task.detached { Self.decode(data, name: name) }.value
        // Nothing read as one account is shown or kept for another.
        guard !Task.isCancelled, UserScope.currentUserID == account else { return }
        Self.cache.setObject(decoded, forKey: id as NSString)
        thumbnail = decoded
        isLoading = false
    }

    /// A thumbnail when the bytes are a picture (by their content, not
    /// their name); otherwise an entry with no picture.
    nonisolated static func decode(_ data: Data, name: String) -> AttachmentThumbnailImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = (CGImageSourceGetType(source) as String?).flatMap(UTType.init),
              type.conforms(to: .image),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: Int(side * 3),
              ] as CFDictionary) else {
            return AttachmentThumbnailImage(image: nil, filename: name)
        }
        // Quick Look needs an extension to know what it is opening.
        let hasExtension = !(name as NSString).pathExtension.isEmpty
        let filename = hasExtension ? name : "\(name).\(type.preferredFilenameExtension ?? "image")"
        return AttachmentThumbnailImage(image: image, filename: filename)
    }
}

/// A decoded thumbnail, or the finding that a file is not a picture.
/// Immutable once made.
final nonisolated class AttachmentThumbnailImage: @unchecked Sendable {
    let image: CGImage?
    let filename: String

    init(image: CGImage?, filename: String) {
        self.image = image
        self.filename = filename
    }
}
