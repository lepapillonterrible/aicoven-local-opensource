internal import Combine
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// A file's bytes as the system's exporter writes them where the person
/// chooses. Held only while the exporter is up.
nonisolated struct AssetExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.data]

    let data: Data

    init(data: Data) {
        self.data = data
    }

    /// Nothing is read into one: it is only written out.
    init(configuration _: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// An asset's files as a view opens them: one looked at in Quick Look (from
/// a copy that exists only while it is looked at, as an attachment's), or
/// handed to the system's exporter to be saved where the person chooses.
/// The bytes are read as the account signed in, and nothing read for one
/// account is shown or handed on for another.
@MainActor
final class AssetFiles: ObservableObject {
    typealias Load = @Sendable (_ fileID: String, _ account: String) async throws -> Data

    /// Whose turn it is among the presenters of one place: the library's
    /// and its pages' share one, so that the download asked for last,
    /// wherever it was asked, is the only one offered.
    @MainActor
    final class Turn {
        fileprivate var asked: UUID?
    }

    /// Quick Look, with the file it shows.
    let preview: AttachmentPreviewPresenter
    /// Whether the exporter is up. When it goes, so do the bytes it held.
    @Published var isExporting = false {
        didSet {
            if !isExporting { document = nil }
        }
    }

    @Published private(set) var document: AssetExportDocument?
    /// The export the exporter was last put up for: its result is told
    /// with it, so that one that comes late is not taken for a later one's.
    @Published private(set) var export: UUID?
    /// The name the exporter offers.
    @Published private(set) var exportName = ""
    /// The file being read for the exporter, if one is.
    @Published private(set) var preparing: AssetFile.ID?
    /// What went wrong with the last file asked for, in words.
    @Published private(set) var failure: String?

    static let cannotOpen = "This file could not be opened."
    static let cannotSave = "The file couldn't be saved."

    /// The download last asked for in this place: a later one, asked of
    /// this presenter or of another that shares the turn, takes its place.
    let turn: Turn
    private let load: Load
    private let signedIn: @MainActor @Sendable () -> String
    /// The download this presenter is reading.
    private var reading: UUID?
    /// The account the exporter was last put up for; nil once this is torn down.
    private var offeredTo: String?
    private var followed: AnyCancellable?

    /// The app's own store and account unless a test gives others; a turn
    /// of its own unless it shares one.
    init(turn: Turn? = nil, load: Load? = nil, signedIn: (@MainActor @Sendable () -> String)? = nil, previewRoot: URL? = nil) {
        let load = load ?? { try await AssetRepository.shared.data(ofFile: $0, as: $1) }
        let signedIn = signedIn ?? { UserScope.currentUserID }
        self.turn = turn ?? Turn()
        self.load = load
        self.signedIn = signedIn
        preview = AttachmentPreviewPresenter(
            rootDirectory: previewRoot,
            load: { fileID in try await load(fileID, signedIn()) },
            currentAccount: signedIn
        )
        // What the preview says is this one's to say too.
        followed = preview.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    /// What is said under the files: the last failure of either kind.
    var said: String? {
        failure ?? preview.errorMessage
    }

    /// Shows a file in Quick Look.
    func look(at file: AssetFile) async {
        failure = nil
        await preview.open(attachmentID: file.id, filename: file.name)
    }

    /// Reads a file and puts up the exporter for it. If another is asked
    /// for before this one is read, here or of another presenter of the
    /// same place, this one is not offered.
    func download(_ file: AssetFile) async {
        let request = UUID()
        let account = signedIn()
        turn.asked = request
        reading = request
        preparing = file.id
        failure = nil
        defer {
            if reading == request {
                reading = nil
                preparing = nil
            }
        }
        do {
            let data = try await load(file.id, account)
            guard turn.asked == request, reading == request, signedIn() == account else { return }
            document = AssetExportDocument(data: data)
            exportName = file.name
            offeredTo = account
            export = request
            isExporting = true
        } catch {
            guard turn.asked == request, reading == request, signedIn() == account else { return }
            say(Self.cannotOpen)
        }
    }

    /// The exporter put up for `export` is done: closing it is no failure;
    /// anything else is said, if no later export has been offered since,
    /// to the account it was put up for and only while this is still in
    /// use. The bytes go when the exporter does (`isExporting`), not here:
    /// a result that comes late clears nothing newer.
    func exported(_ result: Result<URL, Error>, of export: UUID?) {
        guard let export, export == self.export, let account = offeredTo, signedIn() == account else { return }
        if case let .failure(error) = result, (error as? CocoaError)?.code != .userCancelled {
            say(Self.cannotSave)
        }
    }

    /// The view is going: nothing is left open, in memory or on disk, and
    /// nothing that comes in afterwards is said.
    func teardown() {
        if turn.asked == reading { turn.asked = nil }
        reading = nil
        preparing = nil
        offeredTo = nil
        export = nil
        isExporting = false
        failure = nil
        preview.teardown()
    }

    private func say(_ words: String) {
        failure = words
        AccessibilityNotification.Announcement(words).post()
    }
}

extension View {
    /// Puts up Quick Look and the exporter for what `files` opens, and
    /// clears both away when the view goes.
    func presenting(_ files: AssetFiles) -> some View {
        modifier(AssetFilesPresentation(files: files))
    }
}

private struct AssetFilesPresentation: ViewModifier {
    @ObservedObject var files: AssetFiles

    func body(content: Content) -> some View {
        content
            .quickLookPreview(Binding(get: { files.preview.previewURL }, set: { files.preview.previewURL = $0 }))
            .background {
                // An exporter of its own for each export: its result
                // comes back with the export it was put up for.
                let export = files.export
                Color.clear
                    .fileExporter(
                        isPresented: $files.isExporting, document: files.document, contentType: .data, defaultFilename: files.exportName
                    ) { result in
                        files.exported(result, of: export)
                    }
                    .id(export)
            }
            .onDisappear { files.teardown() }
    }
}
