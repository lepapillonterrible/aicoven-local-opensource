import Foundation

/// What kind of thing an asset is. An open set, as the cloud app's: a type
/// is a name, and these are the ones the cloud app starts with.
nonisolated struct AssetType: RawRepresentable, Hashable {
    let rawValue: String

    static let image = AssetType(rawValue: "image")
    static let designMockup = AssetType(rawValue: "design_mockup")
    static let chart = AssetType(rawValue: "chart")
    static let dataset = AssetType(rawValue: "dataset")
    static let implementationBrief = AssetType(rawValue: "implementation_brief")
    static let socialCreative = AssetType(rawValue: "social_creative")
    static let deck = AssetType(rawValue: "deck")
    static let report = AssetType(rawValue: "report")

    /// The types a person is offered for a new asset and to filter by, in
    /// the cloud app's order.
    static let offered: [AssetType] = [.image, .designMockup, .chart, .dataset, .implementationBrief, .socialCreative, .deck]

    /// The type in words: "Design Mockup" for `design_mockup`.
    var displayName: String {
        rawValue.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// The type's symbol; a type the app has none for has the general one.
    var iconSystemName: String {
        switch self {
        case .image: "photo"
        case .designMockup: "rectangle.3.group"
        case .chart: "chart.xyaxis.line"
        case .dataset: "tablecells"
        case .implementationBrief: "doc.text"
        case .socialCreative: "megaphone"
        case .deck: "rectangle.on.rectangle.angled"
        case .report: "doc.richtext"
        default: "shippingbox"
        }
    }

    /// The few letters that stand for the type where there is no room for
    /// its symbol, as the cloud app writes them.
    var thumbnailTag: String {
        switch self {
        case .implementationBrief: "MD"
        case .dataset: "CSV"
        case .report: "DOC"
        default: String(rawValue.prefix(3)).uppercased()
        }
    }

    /// Whether `rawValue` reads as a type's name: lowercase letters, digits
    /// and underscores, starting with a letter, 64 at most.
    var isName: Bool {
        guard let first = rawValue.unicodeScalars.first, ("a" ... "z").contains(first), rawValue.unicodeScalars.count <= 64 else { return false }
        return rawValue.unicodeScalars.allSatisfy { ("a" ... "z").contains($0) || ("0" ... "9").contains($0) || $0 == "_" }
    }
}

/// Where an asset stands, as in the cloud app: it starts as a draft, is
/// proposed for review, and is approved or sent back; archived, it is out
/// of the way until it is taken out again.
nonisolated enum AssetStatus: String, CaseIterable {
    case draft
    case proposed
    case approved
    case archived

    var displayName: String {
        switch self {
        case .draft: "Draft"
        case .proposed: "Proposed"
        case .approved: "Approved"
        case .archived: "Archived"
        }
    }

    /// Whether the person may move an asset from this status to `next`, as
    /// the cloud app has it: a draft is proposed; what is proposed is
    /// approved or sent back to a draft; anything is archived; and what is
    /// archived comes back as a draft.
    func canMove(to next: AssetStatus) -> Bool {
        switch (self, next) {
        case (.draft, .proposed), (.proposed, .approved), (.proposed, .draft), (.archived, .draft): true
        case (.archived, .archived): false
        case (_, .archived): true
        default: false
        }
    }
}

/// One file of an asset: what is known of it without its bytes.
nonisolated struct AssetFile: Identifiable, Equatable {
    let id: String
    let name: String
    let mimeType: String
    let sizeBytes: Int

    /// A file's name as it is kept: the last step of what was given, on
    /// one line, without what a path is written with, 255 bytes at most
    /// (what a file system takes for a name); "file" for a name with
    /// nothing left. The name is later used to name a copy of the file, so
    /// it never says where to put it. A colon, which some systems read as
    /// a separator, is kept as a hyphen: "Report: Q3.pdf" stays one name.
    static func keptName(_ given: String) -> String {
        // Read scalar by scalar: a separator is one whatever follows it
        // (a slash with an accent put on it is still a slash).
        let steps = given.unicodeScalars.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        let last = steps.last.map { String(String.UnicodeScalarView($0)) } ?? ""
        var name = String(String.UnicodeScalarView(last.unicodeScalars.compactMap { scalar -> Unicode.Scalar? in
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) { return nil }
            return scalar == ":" ? "-" : scalar
        })).trimmingCharacters(in: .whitespaces)
        while name.utf8.count > 255 {
            name.removeLast()
        }
        return name.unicodeScalars.allSatisfy { $0 == "." } ? "file" : name
    }
}

/// An asset: a piece of work kept on purpose in a coven (or with Strix),
/// with its files, as the cloud app's. It is not a message's attachment:
/// it has a title, a type and a status, and stays when the thread it was
/// made in is gone.
nonisolated struct Asset: Identifiable, Equatable {
    let id: String
    /// The coven it is kept in; nil for Strix's.
    let covenID: String?
    let type: AssetType
    let status: AssetStatus
    /// Its title; empty for an asset that is unreadable.
    let title: String
    /// What it is, in the person's or the agent's words; empty for none.
    let details: String
    /// The agent that made it; nil for one the person added.
    let madeByAgentID: String?
    /// The thread it was made in, and the message it came with, where it
    /// came from one. The thread may be gone since.
    let threadID: String?
    let sourceMessageID: String?
    let files: [AssetFile]
    /// Whether what is kept of it cannot be opened with the account's key.
    var isUnreadable = false
    /// What tells the asset as it was listed from the same asset changed
    /// since: a digest of what is stored of its title, of what says what
    /// it is, and of its files (all sealed, so it says nothing of them).
    /// An asset is approved only as it was listed. Empty for one that was
    /// not read from the store.
    var version = ""
    let createdAt: Date
    let updatedAt: Date

    /// Posted when an asset was made or changed (by an agent's tool, or by
    /// the person somewhere else on screen), so that whatever shows assets
    /// reads them again.
    static let didChange = Notification.Name("AICovenAssetsDidChange")

    /// Where a reply's metadata keeps the ids of the assets made in its turn.
    static let messageMetadataKey = "asset_ids"

    /// The ids of the assets a stored message says were made in its turn,
    /// in order, each once; none for a message that names none.
    static func ids(in metadata: [String: AnyJSONValue]) -> [String] {
        guard case let .array(kept)? = metadata[messageMetadataKey] else { return [] }
        var seen: Set<String> = []
        return kept.compactMap { id in
            guard case let .string(id) = id, !id.isEmpty, seen.insert(id).inserted else { return nil }
            return id
        }
    }
}
