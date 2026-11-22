import Foundation

/// The skills that are on, as a turn is told them: the cloud app's block
/// ("[Local Skills Context]", then each skill under "## Skill: <title>"),
/// in the order the store gives them, which is by title.
nonisolated enum SkillsTold {
    static let heading = "[Local Skills Context]"
    /// The most characters of skills a turn is told, whatever its model.
    static let mostCharacters = 20000
    /// What ends a skill that was cut.
    static let cutMark = "\n...(truncated)..."

    /// The room a turn has for its skills: a quarter of its prompt (at
    /// four characters a token, as many characters as the prompt has
    /// tokens), and never more than `mostCharacters`. A turn with no
    /// limit of its own has `mostCharacters`.
    static func room(promptTokens: Int?) -> Int {
        min(mostCharacters, max(0, promptTokens ?? mostCharacters))
    }

    /// The block for `skills`, no longer than `room` characters: each
    /// whole while it fits. The first that does not fit is cut where the
    /// room ends, and says so; those after it are not told. Nil where
    /// there is nothing to tell.
    static func block(of skills: [(title: String, text: String)], room: Int) -> String? {
        var told = heading + "\n"
        var toldAny = false
        for skill in skills {
            let title = "\n## Skill: \(skill.title)\n"
            let left = room - told.count
            if title.count + skill.text.count <= left {
                told += title + skill.text
                toldAny = true
                continue
            }
            let leftForText = left - title.count - cutMark.count
            if leftForText > 0 {
                told += title + skill.text.prefix(leftForText) + cutMark
                toldAny = true
            }
            break
        }
        return toldAny ? told : nil
    }
}
