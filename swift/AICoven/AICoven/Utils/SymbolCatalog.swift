import Foundation

/// The SF Symbols the picker searches: the symbols the deployment targets
/// have, with the system's search keywords ("write" finds `pencil`). There
/// is no API that lists SF Symbols, so `SFSymbolCatalog.json` is the list
/// the cloud app generates from the Mac's symbol data. It is read on the
/// picker's first search.
nonisolated struct SymbolCatalog {
    static let shared = SymbolCatalog.loadBundled()

    /// Results past this are cut, so the grid stays light.
    static let resultLimit = 120

    private struct Entry {
        let name: String
        let keywords: String
    }

    private let entries: [Entry]

    init(symbols: [[String]]) {
        entries = symbols.compactMap { row in
            guard let name = row.first else { return nil }
            return Entry(name: name, keywords: row.count > 1 ? row[1].lowercased() : "")
        }
    }

    /// The catalog in the app's bundle; one with no symbols if it cannot
    /// be read (the picker then offers its suggested symbols only).
    private static func loadBundled() -> SymbolCatalog {
        struct File: Decodable { let symbols: [[String]] }
        guard let url = Bundle.main.url(forResource: "SFSymbolCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else {
            return SymbolCatalog(symbols: [])
        }
        return SymbolCatalog(symbols: file.symbols)
    }

    /// How many symbols it holds.
    var count: Int {
        entries.count
    }

    /// The symbols whose name or keywords contain `query`, names first, at
    /// most `resultLimit`. An empty query matches nothing.
    func search(_ query: String) -> [String] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        var named: [String] = []
        var keyworded: [String] = []
        for entry in entries {
            if entry.name.contains(query) {
                named.append(entry.name)
            } else if entry.keywords.contains(query) {
                keyworded.append(entry.name)
            }
            if named.count >= Self.resultLimit { break }
        }
        return Array((named + keyworded).prefix(Self.resultLimit))
    }
}
