import SwiftUI

/// Renders a file attachment (compact or full)
struct FileAttachmentView: View {
    let attachment: FileAttachmentDetail
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.name)
                    .font(.system(size: compact ? 12 : 13, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let size = attachment.sizeBytes { Text(byteCount(size)) }
                    if let w = attachment.width, let h = attachment.height { Text("\(w)×\(h)") }
                    if let mime = attachment.mimeType { Text(mime) }
                }
                .font(.system(size: compact ? 10 : 11))
                .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(8)
        .background(.quaternary.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var iconName: String {
        if let mime = attachment.mimeType, mime.hasPrefix("image/") { return "photo" }
        return "doc"
    }

    private func byteCount(_ n: Int) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: Int64(n))
    }
}

/// Convenience list of attachments
struct AttachmentsListView: View {
    let attachments: [FileAttachmentDetail]
    var compact: Bool = false
    var onRemove: ((String) -> Void)?
    var showRemove: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(attachments, id: \.id) { a in
                HStack(spacing: 8) {
                    FileAttachmentView(attachment: a, compact: compact)
                    if showRemove {
                        Button(role: .destructive) { onRemove?(a.id) } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }
}

#if DEBUG
struct FileAttachmentView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(alignment: .leading, spacing: 12) {
            FileAttachmentView(attachment: .init(id: "1", name: "Report.pdf", mimeType: "application/pdf", sizeBytes: 128_000, width: nil, height: nil, url: nil))
            FileAttachmentView(attachment: .init(id: "2", name: "Photo.jpg", mimeType: "image/jpeg", sizeBytes: 2_300_000, width: 1920, height: 1080, url: nil))
            AttachmentsListView(attachments: [
                .init(id: "1", name: "Report.pdf", mimeType: "application/pdf", sizeBytes: 128_000, width: nil, height: nil, url: nil),
                .init(id: "2", name: "Photo.jpg", mimeType: "image/jpeg", sizeBytes: 2_300_000, width: 1920, height: 1080, url: nil),
            ], compact: true, onRemove: { _ in }, showRemove: true)
        }
        .frame(width: 480)
        .padding()
    }
}
#endif
