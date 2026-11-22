import Foundation

/// A place on GitHub that skills are added from, as the cloud app reads an
/// address: a repository, or a folder of one at a branch
/// (`https://github.com/<owner>/<repository>` or
/// `…/tree/<branch>/<folder>`).
nonisolated struct GitHubSkillsPlace: Equatable {
    let owner: String
    let repository: String
    /// The branch the address names; nil for the repository's own.
    let branch: String?
    /// The folder, step by step; none for the top of the repository.
    let folder: [String]

    /// Reads an address the person typed. Only an https address of
    /// github.com is one (written with or without "https://"), with
    /// nothing else in it: no user, port, query or fragment. Nil for
    /// anything else.
    init?(_ typed: String) {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard let parts = URLComponents(string: text), parts.scheme?.lowercased() == "https",
              let host = parts.host?.lowercased(), host == "github.com" || host == "www.github.com",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.query == nil, parts.fragment == nil else { return nil }
        // Step by step, as it is written. One slash may end it.
        var written = parts.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
        if written.last == "" { written.removeLast() }
        var steps: [String] = []
        for step in written {
            // A step that would not stay one step of a path is not read.
            guard let read = step.removingPercentEncoding, !read.contains("/"), RequestPath.step(read) != nil else { return nil }
            steps.append(read)
        }
        guard steps.count >= 2, Self.isName(steps[0]), Self.isName(steps[1]) else { return nil }
        owner = steps[0]
        repository = steps[1].hasSuffix(".git") && steps[1].count > 4 ? String(steps[1].dropLast(4)) : steps[1]
        if steps.count == 2 {
            branch = nil
            folder = []
        } else {
            // The first step after "tree" is the branch, as in the cloud app.
            guard steps.count >= 4, steps[2] == "tree" else { return nil }
            branch = steps[3]
            folder = Array(steps[4...])
        }
    }

    /// Whether a step reads as an owner's or a repository's name.
    private static func isName(_ step: String) -> Bool {
        step.count <= 100 && step.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }

    /// Where GitHub lists what is in the place. Each step is written so
    /// that it stays one step, and the branch so that it stays the branch.
    var listing: URL? {
        guard let path = RequestPath.path(of: ["repos", owner, repository, "contents"] + folder) else { return nil }
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = SkillsOnGitHub.listingHost
        parts.percentEncodedPath = path
        if let branch {
            guard let written = RequestPath.step(branch) else { return nil }
            parts.percentEncodedQuery = "ref=\(written)"
        }
        return parts.url
    }
}

/// Reading skills from a public repository on GitHub: the Markdown files
/// directly in a place, and each one's text. GitHub is asked as anyone
/// (no token is sent), and nothing of what is fetched is kept by the way.
nonisolated enum SkillsOnGitHub {
    static let listingHost = "api.github.com"
    /// Where GitHub serves a public file's text.
    static let fileHost = "raw.githubusercontent.com"
    /// The most files taken from one place.
    static let mostFiles = 50
    /// The largest listing read.
    static let largestListing = 2 * 1024 * 1024

    /// A Markdown file in the place.
    struct File: Equatable {
        let name: String
        /// The folder it is in, by name; the repository for one at its top.
        let folder: String
        /// Where its text is fetched from.
        let address: URL
    }

    /// Why a place's files were not listed.
    enum Failure: Error, Equatable {
        /// GitHub did not list it: there is no such public place, it is
        /// not a folder, or GitHub did not answer as expected.
        case notListed
    }

    /// The Markdown files directly in `place`, by name, `mostFiles` at
    /// most, and how many more were left out (beyond the most, too large
    /// to be a skill, or not served from where GitHub serves this
    /// repository's files).
    @concurrent
    static func files(in place: GitHubSkillsPlace, session: URLSession = UnkeptFetch.session) async throws -> (files: [File], leftOut: Int) {
        guard let listing = place.listing else { throw Failure.notListed }
        let data: Data
        do {
            data = try await UnkeptFetch.data(
                from: listing,
                headers: ["Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"],
                atMost: largestListing,
                session: session
            )
        } catch is UnkeptFetch.Failure {
            throw Failure.notListed
        }
        return try files(listed: data, in: place)
    }

    /// The files of a listing as GitHub gives one (an array of entries).
    static func files(listed data: Data, in place: GitHubSkillsPlace) throws -> (files: [File], leftOut: Int) {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw Failure.notListed }
        let markdown = entries
            .filter { $0["type"] as? String == "file" }
            .compactMap { entry in (entry["name"] as? String).map { (name: $0, entry: entry) } }
            .filter { $0.name.lowercased().hasSuffix(".md") }
            .sorted { $0.name < $1.name }
        var files: [File] = []
        var leftOut = 0
        for (name, entry) in markdown {
            guard files.count < mostFiles,
                  (entry["size"] as? Int).map({ $0 <= SkillFile.largest }) ?? true,
                  let link = entry["download_url"] as? String, let address = URL(string: link), isAFile(address, of: place) else {
                leftOut += 1
                continue
            }
            let parent = ((entry["path"] as? String ?? name) as NSString).deletingLastPathComponent
            files.append(File(name: name, folder: parent.isEmpty ? place.repository : (parent as NSString).lastPathComponent, address: address))
        }
        return (files, leftOut)
    }

    /// Whether an address a listing gave is where GitHub serves a file of
    /// this repository: an https address of its file host and nothing
    /// else (no user, port, query or fragment), under the repository.
    static func isAFile(_ address: URL, of place: GitHubSkillsPlace) -> Bool {
        guard let parts = URLComponents(url: address, resolvingAgainstBaseURL: false), parts.scheme?.lowercased() == "https",
              parts.host?.lowercased() == fileHost, parts.user == nil, parts.password == nil, parts.port == nil,
              parts.query == nil, parts.fragment == nil else { return false }
        let steps = address.pathComponents.dropFirst()
        return steps.count >= 3
            && steps.prefix(2).map { $0.lowercased() } == [place.owner.lowercased(), place.repository.lowercased()]
            && !steps.contains("..")
    }

    /// A file's text: no more of it than a skill may be, and only text.
    @concurrent
    static func text(of file: File, session: URLSession = UnkeptFetch.session) async throws -> String {
        let data = try await UnkeptFetch.data(from: file.address, atMost: SkillFile.largest, session: session)
        guard let text = String(data: data, encoding: .utf8) else { throw SkillFile.Unread.notText }
        return text
    }
}
