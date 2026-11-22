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
/// nothing read or done for an account that is no longer signed in.
@MainActor
final class SkillsModel: ObservableObject {
    @Published private(set) var skills: [Skill] = []
    /// Whether the skills could not be read.
    @Published private(set) var loadFailed = false
    /// What went wrong with the last thing asked, in words; nil for nothing.
    @Published private(set) var failure: String?
    /// The skills a change is on its way for: one change of a skill at a time.
    @Published private(set) var changing: Set<Skill.ID> = []

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

    private let store: SkillRepository
    private let signedIn: () -> String
    /// Counts the readings, so that only the latest is shown.
    private var readings = 0

    init(store: SkillRepository = .shared, signedIn: @escaping () -> String = { UserScope.currentUserID }) {
        self.store = store
        self.signedIn = signedIn
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
        }
    }

    /// Adds the file the person chose as a skill, off. `account` is
    /// whoever chose it. Says what went wrong, if anything did.
    func add(from file: URL, as account: String) async {
        failure = nil
        do {
            let read = try SkillFile.read(file)
            _ = try await store.add(title: read.title, text: read.text, source: read.source, as: account)
        } catch {
            say(Self.words(forNotAdding: error), to: account)
        }
        await load()
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

    /// Turns a skill on or off, once at a time for one skill.
    func setOn(_ isOn: Bool, _ skill: Skill, as account: String) async {
        guard changing.insert(skill.id).inserted else { return }
        defer { changing.remove(skill.id) }
        failure = nil
        do {
            try await store.setOn(isOn, id: skill.id, as: account)
        } catch SkillError.changed {
            // Its text is not the one the switch was pressed for: nothing was turned on.
            say(Self.changedMeanwhile, to: account)
        } catch {
            AppErrorReporter.log(message: "Could not change a skill (\(type(of: error)))", context: "SkillsModel.setOn")
            say(Self.couldNotChange, to: account)
        }
        await load()
    }

    /// Deletes a skill, once.
    func delete(_ skill: Skill, as account: String) async {
        guard changing.insert(skill.id).inserted else { return }
        defer { changing.remove(skill.id) }
        failure = nil
        do {
            try await store.delete(id: skill.id, as: account)
        } catch {
            AppErrorReporter.log(message: "Could not delete a skill (\(type(of: error)))", context: "SkillsModel.delete")
            say(Self.couldNotDelete, to: account)
        }
        await load()
    }

    /// Says what went wrong, to the account that asked and no other.
    private func say(_ words: String, to account: String) {
        guard signedIn() == account else { return }
        failure = words
    }
}
