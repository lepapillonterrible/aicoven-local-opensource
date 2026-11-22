import Foundation

/// What a turn takes from the settings of the agent it is for: how freely
/// it answers, how long an answer may be, and how many tool steps it may
/// take. A turn for no agent (Strix's), and an agent that says nothing of
/// one of them, takes the app's own.
nonisolated struct AgentTurnSettings: Equatable {
    /// What a turn takes where no agent says otherwise.
    static let standard = AgentTurnSettings(temperature: 0.7, maxTokens: nil, mostSteps: nil)

    /// The most tool steps an agent's turn is given: a stored number far
    /// beyond any turn's need does not keep a turn calling tools without
    /// end. The agent form saves no more than this.
    static let mostStepsAllowed = 100

    let temperature: Double
    /// The longest answer, in tokens, where the agent sets one: sent only
    /// where `usesMaxTokens` says, which is not every client that could
    /// send one.
    let maxTokens: Int?
    /// The most tool steps of a turn; nil where the agent sets none, and
    /// the app's own number is used.
    let mostSteps: Int?

    init(temperature: Double, maxTokens: Int?, mostSteps: Int?) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.mostSteps = mostSteps
    }

    /// An agent's settings as its turns take them: a temperature from 0
    /// to 2, and numbers that are no limit (zero or less) taken as none.
    init(of role: Role) {
        temperature = min(max(role.temperature ?? Self.standard.temperature, 0), 2)
        maxTokens = role.maxTokens.flatMap { $0 > 0 ? $0 : nil }
        mostSteps = (role.settings?.autonomousMaxSteps).flatMap { steps in
            steps > 0 ? min(steps, Self.mostStepsAllowed) : nil
        }
    }

    // MARK: - Which settings a turn uses, by what answers it

    /// Whether a turn answered by `provider` is run by an agent of the
    /// person's own, which takes its own steps and is sent none of these
    /// settings. OpenClaw is one where its connection names a Gateway
    /// (`hasGateway`); without one its turns are a model's.
    static func runsItself(provider: String, hasGateway: Bool) -> Bool {
        switch provider.lowercased() {
        case "hermes": true
        case "openclaw": hasGateway
        default: false
        }
    }

    /// Whether the client of `provider` sends a temperature for `model`.
    static func usesTemperature(provider: String, model: String) -> Bool {
        switch provider.lowercased() {
        // A model on this device is run with the temperature MLX gives it.
        case "mlx", "hermes": false
        default: ModelTemperature.isSent(provider: provider, model: model)
        }
    }

    /// Whether a turn answered by `provider` is sent the longest an
    /// answer may be: Anthropic's, which must be told one, and a model on
    /// this device. The others are not: OpenAI's newer models refuse the
    /// parameter the older ones take, and a server that passes requests on
    /// (OpenRouter, OpenClaw, an OpenAI-compatible one) may reach either.
    static func usesMaxTokens(provider: String) -> Bool {
        ["anthropic", "mlx"].contains(provider.lowercased())
    }
}
