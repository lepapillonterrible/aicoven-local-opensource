import Foundation

/// Service for uploading attachments to the backend.
///
/// In the open-source local-first client we keep this around so existing UI
/// compiles, but uploads are disabled by default and attachments remain
/// local-only.
actor UploadService {
    static let shared = UploadService()

    /// Feature flag for upload functionality (set to true to enable uploads).
    /// In the local-only client this is `false` so we never talk to the
    /// legacy backend and instead treat attachments as local files.
    private nonisolated static let uploadEnabled = false

    /// Upload a file and return attachment detail.
    ///
    /// In the local-only client, uploads never leave the device. We simply
    /// wrap the local file URL in a FileAttachmentDetail so tools and chat can
    /// reference it without talking to a backend.
    func upload(url: URL, threadId: String) async throws -> FileAttachmentDetail {
        let name = url.lastPathComponent
        let mime = mimeType(for: url.pathExtension)
        let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        AppErrorReporter.log(message: "Treating attachment as local-only file: \(name)", context: "UploadService.upload.local")
        return FileAttachmentDetail(
            id: UUID().uuidString,
            name: name,
            mimeType: mime,
            sizeBytes: size,
            width: nil,
            height: nil,
            url: url
        )
    }

    /// Fetch attachment details by ID.
    ///
    /// The local client does not maintain a remote attachment registry, so
    /// this API is intentionally unavailable.
    func fetchDetails(attachmentId: String) async throws -> FileAttachmentDetail {
        throw NSError(
            domain: "UploadService",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "UploadService.fetchDetails is unavailable in the local-only client"]
        )
    }

    private func mimeType(for ext: String) -> String? {
        let lower = ext.lowercased()
        switch lower {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "pdf": return "application/pdf"
        case "txt": return "text/plain"
        case "md": return "text/markdown"
        case "json": return "application/json"
        case "xml": return "application/xml"
        default: return "application/octet-stream"
        }
    }
}
