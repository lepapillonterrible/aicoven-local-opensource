import Foundation

/// The four sections a coven's memory reads as, as in the cloud app.
///
/// A memory has no page of its own, so its page comes from its tags
/// (`of(tags:)`): an explicit `page:` tag first, then the tags the cloud
/// app and its agents write, with Facts and figures holding the rest. An
/// entry added on a page carries that page's tag.
nonisolated enum MemoryPage: String, CaseIterable, Identifiable, Hashable {
    case purpose
    case people
    case howWeWork = "how"
    case facts

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .purpose: "What this coven is for"
        case .people: "Who's who"
        case .howWeWork: "How we work here"
        case .facts: "Facts and figures"
        }
    }

    /// What belongs on the page, said under an empty section's heading.
    var purpose: String {
        switch self {
        case .purpose: "The work this coven exists to do, and for whom."
        case .people: "People this coven works with, and how to reach them."
        case .howWeWork: "Rules and habits every agent here should follow."
        case .facts: "Names, numbers and details worth getting right."
        }
    }

    /// The tag that puts a memory on this page.
    var tag: String {
        "page:\(rawValue)"
    }

    /// Tags for an entry added on this page. How we work here also carries
    /// `coven:policy`, as the cloud app tags a coven's policies.
    var tagsForNewEntry: [String] {
        self == .howWeWork ? [tag, Self.policyTag] : [tag]
    }

    private static let policyTag = "coven:policy"
    private static let skillTag = "coven:skill"
    private static let peopleTags: Set<String> = ["person", "people", "contact", "contacts", "team"]

    /// The one page a memory with `tags` belongs on:
    /// 1. a `page:` tag naming a page;
    /// 2. `coven:policy` or `coven:skill` → How we work here;
    /// 3. a people tag (`person`, `people`, `contact`, `contacts`, `team`,
    ///    or one starting `person:`), any case → Who's who;
    /// 4. everything else → Facts and figures.
    static func of(tags: [String]) -> MemoryPage {
        for tag in tags {
            if let page = allCases.first(where: { $0.tag == tag }) {
                return page
            }
        }
        if tags.contains(policyTag) || tags.contains(skillTag) {
            return .howWeWork
        }
        if tags.contains(where: { tag in
            let lowered = tag.lowercased()
            return peopleTags.contains(lowered) || lowered.hasPrefix("person:")
        }) {
            return .people
        }
        return .facts
    }
}

extension Memory {
    var page: MemoryPage {
        MemoryPage.of(tags: tags ?? [])
    }
}
