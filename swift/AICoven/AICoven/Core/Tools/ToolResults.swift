import Foundation

/// What a turn's tools have told so far, as its model is given it with
/// each later request. A result is kept whole: when there are more than
/// the turn has room for, the oldest are left out first, and a line says
/// so. A result is never cut down to its end. Its beginning says what it
/// is (and, for what was read from a file or an asset, that it is content
/// and where the content starts), so a result that is too long by itself
/// keeps its beginning and loses its end.
nonisolated enum ToolResults {
    static let leftOutNote = "... (older tool results left out)"
    static let cutMark = "\n...(truncated)..."
    private static let separator = "\n\n"

    /// The room a turn has for its tools' results, in characters. A model
    /// on this device or this network has little (less on an iPhone, where
    /// it shares memory with the model); a cloud model has room for
    /// several long reads (one is 20,000 characters at most).
    static func room(isLocalModel: Bool, isMobileDevice: Bool) -> Int {
        guard isLocalModel else { return 60000 }
        return isMobileDevice ? 2000 : 3000
    }

    /// The results as one text of at most about `room` characters: as
    /// many of the latest as fit, each whole, in the order they came. The
    /// latest is always there; alone and too long, it is cut at its end.
    static func text(of results: [String], room: Int) -> String {
        guard let latest = results.last else { return "" }
        guard latest.count <= room else {
            let kept = String(latest.prefix(max(0, room))) + cutMark
            return results.count > 1 ? leftOutNote + separator + kept : kept
        }
        var kept = [latest]
        var used = latest.count
        for result in results.dropLast().reversed() {
            guard used + separator.count + result.count <= room else { break }
            kept.insert(result, at: 0)
            used += separator.count + result.count
        }
        let text = kept.joined(separator: separator)
        return kept.count < results.count ? leftOutNote + separator + text : text
    }
}
