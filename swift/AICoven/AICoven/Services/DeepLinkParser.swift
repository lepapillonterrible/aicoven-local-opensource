import Foundation

/// Reads an `aicoven-local://` link, as the cloud app's parser does for the
/// places this app has. A link comes from outside the app (a page, a
/// message, another app), so it is read strictly: only the shapes listed
/// here lead anywhere, and one that carries anything more (a user, a
/// port, a fragment, a query that is not asked for) is refused, not
/// trimmed. Every place a link leads is one the person could open with a
/// click and that changes nothing by being opened: a place in Settings, or
/// Strix's new-thread page, as the person left it. No link carries a key,
/// a token or words to send, and none connects, approves or sends anything.
///
/// The scheme is this app's own, not the cloud app's `aicoven`: both apps
/// can be installed side by side, and the system gives a scheme claimed by
/// two apps to either of them, so the cloud app's links and sign-in
/// callbacks opened this app and led nowhere.
nonisolated enum DeepLinkParser {
    static let scheme = "aicoven-local"

    static func target(for url: URL) -> DeepLinkTarget? {
        guard url.scheme?.lowercased() == scheme,
              url.user == nil, url.password == nil, url.port == nil, url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems ?? []
        // The path as it is written, step by step: an empty step (a doubled
        // slash) or one spelled with escapes is not one of the shapes
        // below. One slash at the end is none.
        var written = components.percentEncodedPath
        if written.hasPrefix("/") { written.removeFirst() }
        var path: [String] = []
        if !written.isEmpty {
            if written.hasSuffix("/") { written.removeLast() }
            path = written.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard !path.contains("") else { return nil }
        }

        switch (url.host?.lowercased() ?? "", path) {
        case ("connected-services", []), ("connected-apps", []), ("settings", ["connected-apps"]):
            return items.isEmpty ? .connectedApps : nil
        case ("providers", []), ("settings", ["providers"]):
            return items.isEmpty ? .providerKeys : nil
        case ("providers", ["add"]), ("settings", ["providers", "add"]):
            // The cloud app's link to add a key may name the provider. It
            // leads to the keys here whichever it names; anything else in
            // the query is refused.
            return items.count <= 1 && items.allSatisfy { $0.name == "provider" } ? .providerKeys : nil
        case ("budgets", []), ("settings", ["budgets"]):
            return items.isEmpty ? .budgets : nil
        case ("usage", []), ("settings", ["usage"]):
            return items.isEmpty ? .usage : nil
        case ("settings", _):
            // Settings itself, also for a place in it this app does not
            // know by name.
            return items.isEmpty ? .settings : nil
        case ("strix", ["new-thread"]):
            return items.isEmpty ? .newThread : nil
        default:
            return nil
        }
    }
}
