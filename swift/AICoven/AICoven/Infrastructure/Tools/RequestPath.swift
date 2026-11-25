import Foundation

/// The path of a request, written from its steps. Each step is written so
/// that it stays one step, whatever it holds: a name, id or range given by
/// a model cannot add a step, a query or a fragment, nor climb out with
/// "." or "..".
nonisolated enum RequestPath {
    /// The characters a step keeps as they are; every other is written
    /// with a percent sign.
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// One step as it is written in a path. Nil if it is empty, "." or
    /// "..".
    static func step(_ step: String) -> String? {
        guard !step.isEmpty, step != ".", step != ".." else { return nil }
        return step.addingPercentEncoding(withAllowedCharacters: unreserved)
    }

    /// The path of these steps, with a slash before each. Nil if any step
    /// cannot be written.
    static func path(of steps: [String]) -> String? {
        var written: [String] = []
        for step in steps {
            guard let encoded = self.step(step) else { return nil }
            written.append(encoded)
        }
        return "/" + written.joined(separator: "/")
    }
}
