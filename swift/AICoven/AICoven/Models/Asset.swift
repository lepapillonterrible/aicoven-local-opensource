import Foundation

/// What kind of thing an asset is. An open set, as the cloud app's: a type
/// is a name, and the ones the app knows have an icon of their own.
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

    /// The types a person is offered for a new asset, in the cloud app's order.
    static let offered: [AssetType] = [.image, .designMockup, .chart, .dataset, .implementationBrief, .socialCreative, .deck]

    /// Whether `rawValue` reads as a type's name: lowercase letters, digits
    /// and underscores, starting with a letter, 64 at most.
    var isName: Bool {
        guard let first = rawValue.unicodeScalars.first, ("a" ... "z").contains(first), rawValue.unicodeScalars.count <= 64 else { return false }
        return rawValue.unicodeScalars.allSatisfy { ("a" ... "z").contains($0) || ("0" ... "9").contains($0) || $0 == "_" }
    }

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

    /// The type in words: "Design Mockup" for `design_mockup`.
    var displayName: String {
        rawValue.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
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
    /// one line, without what a path is written with, 255 characters at
    /// most; "file" for a name with nothing left. The name is later used
    /// to name a copy of the file, so it never says where to put it.
    static func keptName(_ given: String) -> String {
        let last = given.split(whereSeparator: { $0 == "/" || $0 == "\\" || $0 == ":" }).last.map(String.init) ?? ""
        let plain = String(last.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0) })
            .trimmingCharacters(in: .whitespaces)
        let name = String(plain.prefix(255))
        return name.isEmpty || name.allSatisfy { $0 == "." } ? "file" : name
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
    let createdAt: Date
    let updatedAt: Date
}
