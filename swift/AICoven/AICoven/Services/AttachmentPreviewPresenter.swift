import Accessibility
internal import Combine
import Foundation
import SwiftUI

/// Opens an attachment in Quick Look. Its bytes are read from the
/// attachment store and written, in the clear, to a file of this
/// presenter's own that only this user can read, for as long as it is being
/// looked at: the file goes when another is opened, when the preview is
/// closed, and when the view that opened it goes.
@MainActor
final class AttachmentPreviewPresenter: ObservableObject {
    typealias Load = @Sendable (_ attachmentID: String) async throws -> Data

    /// The file Quick Look is showing; set to nil when the preview closes.
    @Published var previewURL: URL? {
        didSet {
            guard oldValue != previewURL, let oldValue else { return }
            try? fileManager.removeItem(at: oldValue.deletingLastPathComponent())
        }
    }

    @Published private(set) var isOpening = false
    @Published private(set) var errorMessage: String?

    static let cannotOpen = "This file could not be opened."

    private let fileManager: FileManager
    private let sessionDirectory: URL
    private let load: Load
    /// The account signed in, by its id.
    private let currentAccount: @MainActor () -> String
    /// The opening under way: a later one takes its place.
    private var opening: UUID?
    /// Previews left by a run of the app that ended while one was open are
    /// removed the first time one is made in this run.
    private static var didCleanDefaultRoot = false

    init(
        fileManager: FileManager = .default,
        rootDirectory: URL? = nil,
        load: @escaping Load = { try await AttachmentStore.shared.data(of: $0) },
        currentAccount: @escaping @MainActor () -> String = { UserScope.currentUserID }
    ) {
        self.fileManager = fileManager
        let defaultRoot = fileManager.temporaryDirectory.appendingPathComponent("AICovenAttachmentPreviews", isDirectory: true)
        if rootDirectory == nil, !Self.didCleanDefaultRoot {
            Self.didCleanDefaultRoot = true
            for left in (try? fileManager.contentsOfDirectory(at: defaultRoot, includingPropertiesForKeys: nil)) ?? [] {
                try? fileManager.removeItem(at: left)
            }
        }
        sessionDirectory = (rootDirectory ?? defaultRoot).appendingPathComponent(UUID().uuidString, isDirectory: true)
        self.load = load
        self.currentAccount = currentAccount
    }

    /// Reads the attachment and shows it. If another is asked for before
    /// this one is ready, this one is not shown.
    func open(attachmentID: String, filename: String) async {
        let request = UUID()
        let account = currentAccount()
        opening = request
        isOpening = true
        errorMessage = nil
        // What was open before is closed, and its file gone, whatever
        // becomes of this one.
        previewURL = nil
        defer {
            if opening == request {
                opening = nil
                isOpening = false
            }
        }
        do {
            let data = try await load(attachmentID)
            guard opening == request else { return }
            // Read as one account, it is not written out or shown for
            // another: the account can have changed while it was read.
            guard currentAccount() == account else { return }
            previewURL = try stage(data, named: filename)
        } catch {
            // Nor is its failure another account's to be told of.
            guard opening == request, currentAccount() == account else { return }
            errorMessage = Self.cannotOpen
            // Said, as well as shown under the attachment: focus stays on
            // the button that was pressed.
            AccessibilityNotification.Announcement(Self.cannotOpen).post()
        }
    }

    /// The view is going: nothing is left open or on disk.
    func teardown() {
        opening = nil
        isOpening = false
        previewURL = nil
        errorMessage = nil
        try? fileManager.removeItem(at: sessionDirectory)
    }

    /// Writes the bytes to a file of their own, readable by this user only,
    /// in a folder of its own.
    private func stage(_ data: Data, named filename: String) throws -> URL {
        let directory = sessionDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = directory.appendingPathComponent(Self.safeFilename(filename))
        do {
            // Protected from the moment it exists.
            var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
            #if os(iOS)
            attributes[.protectionKey] = FileProtectionType.complete
            #endif
            guard fileManager.createFile(atPath: destination.path, contents: data, attributes: attributes) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return destination
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    /// The name as a plain file name: no folders, no control characters.
    nonisolated static func safeFilename(_ name: String) -> String {
        let component = name
            .components(separatedBy: CharacterSet(charactersIn: "/\\"))
            .last?
            .unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return component.isEmpty || component == "." || component == ".." ? "Attachment" : component
    }
}
