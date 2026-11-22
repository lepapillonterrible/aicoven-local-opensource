import Foundation

/// Where a memory is kept, which is who reads it.
nonisolated enum MemoryPlace: Hashable {
    /// The person's own memory ("About me"): kept in no coven, with the
    /// scope "user". Strix's agents read it.
    case aboutMe
    /// Strix's own pages. Strix is no stored coven here, so its pages are
    /// the memories kept in no coven that are not the person's own (nor
    /// what a model once asked to keep for one conversation, scope
    /// "thread", which is read nowhere).
    case strix
    /// A coven's pages.
    case coven(String)

    /// The coven a memory kept here is stored under.
    var covenID: String? {
        if case let .coven(id) = self { id } else { nil }
    }

    /// The scope a memory added here is stored with.
    var scope: String {
        self == .aboutMe ? "user" : "coven"
    }

    /// The place the list and its forms mean by a coven and a scope: the
    /// person's own for "user"; with no scope, the coven's, or the
    /// person's own where there is no coven; for any other scope the
    /// coven's, or Strix's where there is no coven.
    init(covenID: String?, scope: String?) {
        let scope = scope.flatMap { $0.isEmpty || $0 == "all" ? nil : $0 }
        if scope == "user" || (scope == nil && covenID == nil) {
            self = .aboutMe
        } else if let covenID {
            self = .coven(covenID)
        } else {
            self = .strix
        }
    }

    /// What the turns of a thread read: in a coven, that coven's pages;
    /// in none (Strix's threads, and an agent run's own), About me and
    /// Strix's pages. The first of them is where what a model asks to keep
    /// in such a thread is kept (`ChatService`): the order matters.
    static func read(inCoven covenID: String?) -> [MemoryPlace] {
        if let covenID { [.coven(covenID)] } else { [.aboutMe, .strix] }
    }
}
