internal import Combine
import Foundation

/// A file as a skill is added from it: what the skill is called, and its text.
nonisolated struct SkillFile: Equatable {
    let title: String
    let text: String
    /// Where it came from, which tells it from another file.
    let source: String

    /// Why a file was not read as a skill.
    enum Unread: Error, Equatable {
        /// It could not be opened.
        case notOpened
        /// What is in it is not text.
        case notText
        /// It is larger than a skill may be.
        case tooLarge
    }

    /// The largest file read: a skill's longest text in UTF-8, at most
    /// four bytes a character.
    static let largest = SkillRepository.longestText * 4

    /// Reads the file the person chose: its text, and its title as the
    /// cloud app names a skill (`SkillTitle`). A file larger than a skill
    /// may be is not read at all.
    static func read(_ file: URL) throws -> SkillFile {
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw Unread.notOpened }
        guard size <= largest else { throw Unread.tooLarge }
        guard let data = try? Data(contentsOf: file) else { throw Unread.notOpened }
        guard let text = String(data: data, encoding: .utf8) else { throw Unread.notText }
        return SkillFile(
            title: SkillTitle.of(text: text, fileName: file.lastPathComponent, folder: file.deletingLastPathComponent().lastPathComponent),
            text: text,
            source: file.absoluteString
        )
    }
}

/// The account's skills as Settings › Learning & skills shows them: the
/// list, adding one from a file, turning one on or off, deleting one. What
/// it shows is one account's: only its latest reading is shown, and
/// nothing read or done for an account that is no longer signed in. What
/// went wrong is said of the latest thing asked only: an earlier one that
/// fails after a later one was asked is not said over the later one's
/// outcome (the list, read again, shows how the skill stands).
@MainActor
final class SkillsModel: ObservableObject {
    @Published private(set) var skills: [Skill] = []
    /// Whether the skills could not be read.
    @Published private(set) var loadFailed = false
    /// What went wrong with the last thing asked, in words; nil for nothing.
    @Published private(set) var failure: String?
    /// The last thing that went wrong, as it is said aloud: each time is
    /// its own, also one in the same words as the time before.
    struct Announcement: Equatable {
        let number: Int
        let words: String
    }

    /// What VoiceOver is told: every failure that is said, and every
    /// reading of the skills that failed, once each.
    @Published private(set) var announcement: Announcement?
    /// The skills whose switch is on its way: one at a time for a skill.
    @Published private(set) var changing: Set<Skill.ID> = []
    /// The skills being deleted. A skill is deleted whether or not its
    /// switch is on its way: Delete, once confirmed, is never dropped.
    @Published private(set) var deleting: Set<Skill.ID> = []

    static let couldNotLoad = "Couldn't load your skills. Open this page again to retry."

    static let couldNotOpen = "AICoven couldn't open that file."
    static let notText = "That file couldn't be read as text."
    static let tooLong = "That file is too long to be a skill."
    static let empty = "That file has nothing in it."
    static let tooMany = "You have as many skills as can be kept. Delete one to add another."
    static let couldNotAdd = "Couldn't add the skill. Try again."
    static let couldNotChange = "Couldn't change the skill. Try again."
    static let changedMeanwhile = "That skill was replaced just now, so it wasn't turned on. Turn it on again if you still want it."
    static let couldNotDelete = "Couldn't delete the skill. Try again."
    static let unreadable = "Your encryption key can't open this skill."

    /// What is said under the address of a repository before anything is asked.
    static let fromGitHubHint = "Each Markdown file directly in a public repository, or in the folder the address names, becomes a skill. "
        + "Skills are added off: turn on the ones you want your agents to follow."

    private let store: SkillRepository
    private let signedIn: () -> String
    /// What GitHub is asked with.
    private let session: URLSession
    /// Counts the readings, so that only the latest is shown.
    private var readings = 0
    /// Counts the things asked, so that only the latest says what went wrong.
    private var asks = 0

    init(
        store: SkillRepository = .shared,
        signedIn: @escaping () -> String = { UserScope.currentUserID },
        session: URLSession = UnkeptFetch.session
    ) {
        self.store = store
        self.signedIn = signedIn
        self.session = session
    }

    /// Reads the account's skills.
    func load() async {
        readings += 1
        let reading = readings
        let account = signedIn()
        do {
            let read = try await store.skills(as: account)
            guard reading == readings, signedIn() == account else { return }
            skills = read
            loadFailed = false
        } catch {
            guard reading == readings, signedIn() == account else { return }
            // The kind of failure only.
            AppErrorReporter.log(message: "Could not read the skills (\(type(of: error)))", context: "SkillsModel.load")
            skills = []
            loadFailed = true
            announce(Self.couldNotLoad)
        }
    }

    /// Adds the file the person chose as a skill, off. `account` is
    /// whoever chose it. Says what went wrong, if anything did.
    func add(from file: URL, as account: String) async {
        let ask = asking()
        do {
            let read = try SkillFile.read(file)
            _ = try await store.add(title: read.title, text: read.text, source: read.source, as: account)
        } catch {
            say(Self.words(forNotAdding: error), of: ask, to: account)
        }
        await load()
    }

    /// The file `account` chose was not handed over by the system: said
    /// as a file that could not be opened.
    func fileNotHandedOver(to account: String) {
        say(Self.couldNotOpen, of: asking(), to: account)
    }

    /// What is said of a file that was not added.
    static func words(forNotAdding error: Error) -> String {
        switch error {
        case SkillFile.Unread.notOpened: couldNotOpen
        case SkillFile.Unread.notText: notText
        case SkillFile.Unread.tooLarge, SkillError.tooLong: tooLong
        case SkillError.empty: empty
        case SkillError.tooMany: tooMany
        default: couldNotAdd
        }
    }

    /// What came of adding skills from GitHub.
    enum FromGitHub: Equatable {
        /// How many skills were added, and how many Markdown files there
        /// could not be.
        case added(Int, notAdded: Int)
        /// What was typed is no address of a repository on GitHub, or
        /// GitHub listed nothing for it.
        case notListed
        /// No Markdown file is directly there.
        case nothingThere
    }

    /// Adds the Markdown files directly in the place on GitHub that
    /// `typed` names, each as a skill that is off, for `account`, who
    /// asked. A file added before from the same place takes its skill's
    /// place, as the store has it. No more is added once the asking is
    /// called off or another account is signed in.
    func addFromGitHub(_ typed: String, as account: String) async -> FromGitHub {
        _ = asking()
        guard let place = GitHubSkillsPlace(typed) else { return .notListed }
        let listed: (files: [SkillsOnGitHub.File], leftOut: Int)
        do {
            listed = try await SkillsOnGitHub.files(in: place, session: session)
        } catch {
            // The kind of failure only.
            AppErrorReporter.log(message: "GitHub did not list a place (\(type(of: error)))", context: "SkillsModel.addFromGitHub")
            return .notListed
        }
        guard !listed.files.isEmpty || listed.leftOut > 0 else { return .nothingThere }
        var added = 0
        var notAdded = listed.leftOut
        for file in listed.files {
            guard !Task.isCancelled, signedIn() == account else { break }
            do {
                let text = try await SkillsOnGitHub.text(of: file, session: session)
                let title = SkillTitle.of(text: text, fileName: file.name, folder: file.folder)
                _ = try await store.add(title: title, text: text, source: file.address.absoluteString, as: account)
                added += 1
            } catch {
                notAdded += 1
            }
        }
        await load()
        return .added(added, notAdded: notAdded)
    }

    /// What is said of what came of adding from GitHub; nil where every
    /// file there was added.
    static func words(for outcome: FromGitHub) -> String? {
        func files(_ count: Int) -> String {
            count == 1 ? "1 file" : "\(count) files"
        }
        switch outcome {
        case .added(_, notAdded: 0): return nil
        case let .added(0, notAdded): return "\(files(notAdded)) there couldn't be added."
        case let .added(added, notAdded): return "Added \(added == 1 ? "1 skill" : "\(added) skills"). \(files(notAdded)) couldn't be added."
        case .notListed: return "The skills couldn't be added. Check the address."
        case .nothingThere: return "No Markdown files were found there."
        }
    }

    /// Turns a skill on or off, as it is listed here: once at a time for
    /// one skill, and not while it is being deleted (its switch is off
    /// for both, `isBusy`).
    func setOn(_ isOn: Bool, _ skill: Skill, as account: String) async {
        guard !deleting.contains(skill.id), changing.insert(skill.id).inserted else { return }
        defer { changing.remove(skill.id) }
        let ask = asking()
        do {
            try await store.setOn(isOn, skill, as: account)
        } catch SkillError.changed {
            // Its text is not the one the switch was pressed for: nothing was turned on.
            say(Self.changedMeanwhile, of: ask, to: account)
        } catch SkillError.noSuchSkill {
            // It was deleted meanwhile: the list, read again, shows so.
        } catch SkillError.unreadable {
            // Trying again would not help: the list, read again, shows it as one the key cannot open.
            say(Self.unreadable, of: ask, to: account)
        } catch {
            AppErrorReporter.log(message: "Could not change a skill (\(type(of: error)))", context: "SkillsModel.setOn")
            say(Self.couldNotChange, of: ask, to: account)
        }
        await load()
    }

    /// Deletes a skill, also one whose switch is on its way. A second
    /// Delete of a skill that is being deleted is the same Delete.
    func delete(_ skill: Skill, as account: String) async {
        guard deleting.insert(skill.id).inserted else { return }
        defer { deleting.remove(skill.id) }
        let ask = asking()
        do {
            try await store.delete(id: skill.id, as: account)
        } catch SkillError.noSuchSkill {
            // It is gone, which is what was asked.
        } catch {
            AppErrorReporter.log(message: "Could not delete a skill (\(type(of: error)))", context: "SkillsModel.delete")
            say(Self.couldNotDelete, of: ask, to: account)
        }
        await load()
    }

    /// Whether a skill's switch is on its way or it is being deleted: its
    /// switch is off meanwhile.
    func isBusy(_ skill: Skill) -> Bool {
        changing.contains(skill.id) || deleting.contains(skill.id)
    }

    /// Something new is asked: what was said of the last thing goes.
    private func asking() -> Int {
        asks += 1
        failure = nil
        return asks
    }

    /// Says what went wrong with the thing asked as `ask`, if nothing was
    /// asked since, to the account that asked and no other.
    private func say(_ words: String, of ask: Int, to account: String) {
        guard ask == asks, signedIn() == account else { return }
        failure = words
        announce(words)
    }

    private func announce(_ words: String) {
        announcement = Announcement(number: (announcement?.number ?? 0) + 1, words: words)
    }
}
