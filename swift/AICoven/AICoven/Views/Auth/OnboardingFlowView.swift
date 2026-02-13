import SwiftUI

/// Full FTUE onboarding flow shared between iOS and macOS.
///
/// This implements a 3-step flow based on the Figma designs:
/// 1. Privacy by Default (encryption + "what's encrypted" overview)
/// 2. Bring Your Own Keys (provider APIs + responsibility notice)
/// 3. Coven Overview (what covens are and how they work)
struct OnboardingFlowView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var authService: AuthService

    @State private var step: OnboardingStep = .privacy
    @State private var acceptedPrivacy = false
    @State private var acceptedBilling = false
    /// Controls presentation of the shared AddProviderKeySheet during FTUE.
    @State private var showAddProviderKeySheet = false

    enum OnboardingStep: Int, CaseIterable {
        case privacy
        case keys
        case agents
        case routing
        case memory

        var index: Int {
            rawValue + 1
        }

        static var totalCount: Int {
            allCases.count
        }

        var name: String {
            switch self {
            case .privacy: "privacy"
            case .keys: "keys"
            case .agents: "agents"
            case .routing: "routing"
            case .memory: "memory"
            }
        }
    }

    var body: some View {
        ZStack {
            NebulaBackground()

            VStack(spacing: Spacing.xl) {
                header

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: Spacing.lg) {
                            Color.clear
                                .frame(height: 1)
                                .id("onboarding-top")

                            switch step {
                            case .privacy:
                                PrivacyStepView(accepted: $acceptedPrivacy)
                            case .keys:
                                KeysStepView(
                                    accepted: $acceptedBilling,
                                    onAddProviderKey: { showAddProviderKeySheet = true }
                                )
                            case .agents:
                                AgentsStepView()
                            case .routing:
                                RoutingStepView()
                            case .memory:
                                MemoryStepView()
                            }
                        }
                        .padding(.horizontal, Spacing.lg)
                        .padding(.bottom, Spacing.lg)
                    }
                    .onChange(of: step) { _, _ in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo("onboarding-top", anchor: .top)
                        }
                    }
                }

                footer
            }
        }
        .sheet(isPresented: $showAddProviderKeySheet) {
            // Reuse the existing provider-key creation flow so that keys
            // created during onboarding are persisted exactly the same way
            // as when added from Settings.
            AddProviderKeySheet {
                // No-op for now; the standard flow persists the new key.
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            AnalyticsService.shared.track(
                event: "onboarding_started",
                properties: ["step": step.name]
            )
        }
    }

    // MARK: - Header / Footer

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Welcome to AICoven")
                    .font(.aicovenDisplaySmall)
                    .foregroundColor(.aicovenTextPrimary)

                Text("Step \(step.index) of \(OnboardingStep.totalCount)")
                    .font(.aicovenBodySmall)
                    .foregroundColor(.aicovenTextSecondary)

                // Simple progress bar matching the Figma feel
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.aicovenBorder.opacity(0.6))
                            .frame(height: 4)
                        Capsule()
                            .fill(Color.aicovenTeal)
                            .frame(width: proxy.size.width * progressFraction, height: 4)
                            .animation(.easeInOut(duration: 0.25), value: step)
                    }
                }
                .frame(height: 4)
            }

            Spacer()

            Button(action: finish) {
                Text("Skip")
                    .font(.aicovenBodySmall)
                    .foregroundColor(.aicovenTextSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.xl)
    }

    private var footer: some View {
        HStack(spacing: Spacing.md) {
            if step != .privacy {
                GradientButton("Back", icon: "chevron.left", style: .secondary) {
                    goBack()
                }
            }

            Spacer()

            GradientButton(nextButtonTitle, icon: nextButtonIcon, style: .primary) {
                goNext()
            }
            .disabled(!canAdvance)
            .opacity(canAdvance ? 1.0 : 0.5)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.bottom, Spacing.xl)
    }

    private var progressFraction: CGFloat {
        CGFloat(step.index) / CGFloat(OnboardingStep.totalCount)
    }

    private var nextButtonTitle: String {
        switch step {
        case .privacy: "Continue"
        case .keys: "Continue"
        case .agents: "Continue"
        case .routing: "Continue"
        case .memory: "Start Using AICoven"
        }
    }

    private var nextButtonIcon: String {
        switch step {
        case .privacy:
            "chevron.right"
        case .keys:
            "chevron.right"
        case .agents:
            "chevron.right"
        case .routing:
            "chevron.right"
        case .memory:
            "sparkles"
        }
    }

    private var canAdvance: Bool {
        switch step {
        case .privacy:
            acceptedPrivacy
        case .keys:
            acceptedBilling
        case .agents:
            true
        case .routing:
            true
        case .memory:
            true
        }
    }

    private func goNext() {
        switch step {
        case .privacy:
            guard acceptedPrivacy else { return }
            AnalyticsService.shared.track(
                event: "onboarding_step_completed",
                properties: ["step": "privacy"]
            )
            withAnimation(.easeInOut) {
                step = .keys
            }
            AnalyticsService.shared.track(
                event: "onboarding_step_viewed",
                properties: ["step": "keys"]
            )
        case .keys:
            guard acceptedBilling else { return }
            AnalyticsService.shared.track(
                event: "onboarding_step_completed",
                properties: ["step": "keys"]
            )
            withAnimation(.easeInOut) {
                step = .agents
            }
            AnalyticsService.shared.track(
                event: "onboarding_step_viewed",
                properties: ["step": "agents"]
            )
        case .agents:
            AnalyticsService.shared.track(
                event: "onboarding_step_completed",
                properties: ["step": "agents"]
            )
            withAnimation(.easeInOut) {
                step = .routing
            }
            AnalyticsService.shared.track(
                event: "onboarding_step_viewed",
                properties: ["step": "routing"]
            )
        case .routing:
            AnalyticsService.shared.track(
                event: "onboarding_step_completed",
                properties: ["step": "routing"]
            )
            withAnimation(.easeInOut) {
                step = .memory
            }
            AnalyticsService.shared.track(
                event: "onboarding_step_viewed",
                properties: ["step": "memory"]
            )
        case .memory:
            AnalyticsService.shared.track(
                event: "onboarding_step_completed",
                properties: ["step": "memory"]
            )
            finish()
        }
    }

    private func goBack() {
        let previousStep = step
        switch step {
        case .privacy:
            break
        case .keys:
            step = .privacy
        case .agents:
            step = .keys
        case .routing:
            step = .agents
        case .memory:
            step = .routing
        }
        AnalyticsService.shared.track(
            event: "onboarding_step_back",
            properties: [
                "from_step": previousStep.name,
                "to_step": step.name
            ]
        )
    }

    private func finish() {
        AnalyticsService.shared.track(
            event: "onboarding_completed",
            properties: ["total_steps": OnboardingStep.totalCount]
        )

        // Persist onboarding completion at the account level.
        // When the server update succeeds, AuthService will update
        // AppState.hasCompletedOnboarding, and ContentView will
        // transition away from FTUE.
        Task {
            await authService.markOnboardingCompleted()
        }
    }
}

// MARK: - Individual Steps

/// Step 1: Privacy by Default / encryption overview
private struct PrivacyStepView: View {
    @Binding var accepted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Privacy by Default")
                    .font(.aicovenH1)
                    .foregroundColor(.aicovenTextPrimary)

                Text("Understanding how we protect your data")
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextSecondary)
            }

            VStack(spacing: Spacing.md) {
                InfoCard(
                    icon: "eye.trianglebadge.exclamationmark",
                    title: "Ephemerally Blind",
                    text: "Your messages and memories are encrypted at rest. We only decrypt them just-in-time to serve your requests."
                )

                InfoCard(
                    icon: "key.icloud",
                    title: "Keys Never Leave Your Device",
                    text: "Your master encryption key is stored in the secure keychain on iOS/macOS, not on our servers."
                )

                InfoCard(
                    icon: "lock.rotation",
                    title: "Transient Decryption",
                    text: "Data is decrypted in RAM only while needed for AI processing, then immediately re-encrypted or discarded."
                )
            }

            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("What's Encrypted?")
                    .font(.aicovenH2)
                    .foregroundColor(.aicovenTextPrimary)

                BulletList(items: [
                    "All your messages & conversations",
                    "Agent memories (what they remember about you)",
                    "Your provider API keys",
                    "All metadata & usage logs"
                ])
            }

            Toggle(isOn: $accepted) {
                Text("I understand that if I lose my encryption keys, AICoven cannot recover my data.")
                    .font(.aicovenBodySmall)
                    .foregroundColor(.aicovenTextSecondary)
            }
            .onChange(of: accepted) { _, newValue in
                if newValue {
                    AnalyticsService.shared.track(
                        event: "onboarding_privacy_accepted",
                        properties: [:]
                    )
                }
            }
        }
    }
}

/// Step 2: Bring Your Own Keys (BYOK) overview
private struct KeysStepView: View {
    @Binding var accepted: Bool
    let onAddProviderKey: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Connect Your AI Providers")
                    .font(.aicovenH1)
                    .foregroundColor(.aicovenTextPrimary)

                Text("Bring Your Own Keys (BYOK)")
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextSecondary)
            }

            InfoCard(
                icon: "wand.and.stars",
                title: "Add Your Provider Keys",
                text: "AICoven doesn't resell AI models. You'll connect your own API keys so you stay in control of cost, data, and model choice."
            )

            InfoCard(
                icon: "chart.bar",
                title: "Budgets & Usage",
                text: "Track token usage, set monthly budgets, and see cost breakdowns per provider."
            )

            VStack(spacing: Spacing.sm) {
                ProviderRow(
                    acronym: "AI",
                    name: "OpenAI",
                    subtitle: "GPT-4, GPT-4o, and more"
                )
                ProviderRow(
                    acronym: "A",
                    name: "Anthropic",
                    subtitle: "Claude 3.5 Sonnet, Opus, and more"
                )
                ProviderRow(
                    acronym: "G",
                    name: "Google Gemini",
                    subtitle: "Gemini Pro, Flash, and more"
                )
            }

            TutorialScreenshot(
                title: "Provider keys",
                imageName: "provider_keys"
            )

            TutorialScreenshot(
                title: "Budgets & usage",
                imageName: "budgets_usage"
            )

            // Inline call-to-action to open the full provider-keys flow
            // without leaving onboarding.
            GradientButton("Add Provider Key Now", icon: "plus.circle.fill", style: .primary) {
                AnalyticsService.shared.track(
                    event: "onboarding_add_provider_key_clicked",
                    properties: [:]
                )
                onAddProviderKey()
            }

            Text("You can add keys now or skip and add them later in Settings → Provider Keys.")
                .font(.aicovenBodySmall)
                .foregroundColor(.aicovenTextSecondary)

            Toggle(isOn: $accepted) {
                Text("I understand that I am responsible for my own API billing and usage across connected providers.")
                    .font(.aicovenBodySmall)
                    .foregroundColor(.aicovenTextSecondary)
            }
            .onChange(of: accepted) { _, newValue in
                if newValue {
                    AnalyticsService.shared.track(
                        event: "onboarding_billing_accepted",
                        properties: [:]
                    )
                }
            }
        }
    }
}

/// Step 3: Agents overview (create, edit, initialize)
private struct AgentsStepView: View {
    var body: some View {
        TutorialTwoColumn {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Set Up Your Agents")
                        .font(.aicovenH1)
                        .foregroundColor(.aicovenTextPrimary)

                    Text("Create, initialize, and edit roles for each coven")
                        .font(.aicovenBody)
                        .foregroundColor(.aicovenTextSecondary)
                }

                InfoCard(
                    icon: "person.2.wave.2",
                    title: "Agents are Roles",
                    text: "Each role has a name, prompt, model, and tools. Roles define how agents behave in a coven."
                )

                InfoCard(
                    icon: "sparkles",
                    title: "Initialize With Purpose",
                    text: "Start with a Strategist (planning), a Coder or Analyst (execution), and a Scribe (summaries & docs)."
                )

                InfoCard(
                    icon: "link",
                    title: "Connected Apps",
                    text: "Connect GitHub, Google Drive, and more to give agents access to the tools you already use — always with explicit permission."
                )

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Create & Edit Agents")
                        .font(.aicovenH2)
                        .foregroundColor(.aicovenTextPrimary)

                    BulletList(items: [
                        "Go to Coven → Roles to create a new agent.",
                        "Choose a provider key + model for each role.",
                        "Attach connected apps and tools when relevant.",
                        "Edit prompts as your workflow evolves."
                    ])
                }
            }
        } right: {
            VStack(spacing: Spacing.md) {
                TutorialScreenshot(
                    title: "Start from a template",
                    imageName: "create_agent_roles_from_template"
                )
                TutorialScreenshot(
                    title: "Connect apps",
                    imageName: "connect_apps"
                )
            }
        }
    }
}

/// Step 4: Routing & reconciliation
private struct RoutingStepView: View {
    var body: some View {
        TutorialTwoColumn {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Routing & Reconciliation")
                        .font(.aicovenH1)
                        .foregroundColor(.aicovenTextPrimary)

                    Text("How AICoven chooses models and merges answers")
                        .font(.aicovenBody)
                        .foregroundColor(.aicovenTextSecondary)
                }

                InfoCard(
                    icon: "arrow.triangle.branch",
                    title: "Smart Routing",
                    text: "Each role has a preferred model. If it's unavailable or rate‑limited, AICoven tries other healthy models and providers."
                )

                InfoCard(
                    icon: "scale.3d",
                    title: "Reconciliation",
                    text: "When multiple agents respond, AICoven helps reconcile differences so you get a clear, actionable result."
                )

                InfoCard(
                    icon: "at",
                    title: "@Mentions",
                    text: "Bring another agent into the thread by typing @RoleName. Their response is routed through their model and tools, then reconciled back into the conversation."
                )

                BulletList(items: [
                    "Pick models per role based on task type (reasoning, coding, drafting).",
                    "Use roundtables sparingly for the best signal.",
                    "Use @mentions to invite a specialist for a single turn.",
                    "Review reconciled outcomes before executing critical changes."
                ])
            }
        } right: {
            VStack(spacing: Spacing.md) {
                TutorialScreenshot(
                    title: "Mention an agent",
                    imageName: "mention_an_agent"
                )
                TutorialScreenshot(
                    title: "Mentioned agents reply",
                    imageName: "mentioned_agents_replying_in_the_same_thread"
                )
            }
        }
    }
}

/// Step 5: Memory & context
private struct MemoryStepView: View {
    var body: some View {
        TutorialTwoColumn {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Memory & Context")
                        .font(.aicovenH1)
                        .foregroundColor(.aicovenTextPrimary)

                    Text("Keep long‑term knowledge consistent and safe")
                        .font(.aicovenBody)
                        .foregroundColor(.aicovenTextSecondary)
                }

                InfoCard(
                    icon: "brain",
                    title: "Scoped Memory",
                    text: "Memories can be agent‑specific, personal, or coven‑wide. You control what gets saved."
                )

                InfoCard(
                    icon: "checkmark.seal",
                    title: "Approval Required",
                    text: "Agents propose memory writes. You approve them to keep long‑term behavior aligned."
                )

                BulletList(items: [
                    "Use the Memory Explorer to review and pin key context.",
                    "Approved memories are pulled into future conversations automatically.",
                    "Delete or update stale memories to keep agents sharp."
                ])
            }
        } right: {
            VStack(spacing: Spacing.md) {
                TutorialScreenshot(
                    title: "Memory explorer",
                    imageName: "memory"
                )
                TutorialScreenshot(
                    title: "Memory and agent roles",
                    imageName: "coven_memory_and_agent_roles"
                )
            }
        }
    }
}

private struct TutorialTwoColumn<Left: View, Right: View>: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ViewBuilder let left: Left
    @ViewBuilder let right: Right

    var body: some View {
        if horizontalSizeClass == .compact {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                left
                right
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        } else {
            HStack(alignment: .top, spacing: Spacing.xl) {
                left
                    .frame(maxWidth: .infinity, alignment: .leading)
                right
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }
}

private struct TutorialScreenshot: View {
    let title: String
    let imageName: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title)
                .font(.aicovenCaption)
                .foregroundColor(.aicovenTextSecondary)

            Image(imageName)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 160)
                .clipShape(RoundedRectangle(cornerRadius: BorderRadius.lg))
                .overlay(
                    RoundedRectangle(cornerRadius: BorderRadius.lg)
                        .strokeBorder(Color.aicovenBorder, lineWidth: 1)
                )
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Reusable Components

private struct InfoCard: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            IconBadge(icon: icon, size: 32, color: .aicovenTeal)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title)
                    .font(.aicovenH3)
                    .foregroundColor(.aicovenTextPrimary)

                Text(text)
                    .font(.aicovenBodySmall)
                    .foregroundColor(.aicovenTextSecondary)
            }

            Spacer(minLength: 0)
        }
        .glassMorphism(cornerRadius: BorderRadius.lg, padding: Spacing.md)
    }
}

private struct ProviderRow: View {
    let acronym: String
    let name: String
    let subtitle: String

    var body: some View {
        HStack(spacing: Spacing.md) {
            ZStack {
                Circle()
                    .fill(Color.aicovenGlass)
                    .frame(width: 40, height: 40)
                Text(acronym)
                    .font(.aicovenBodyMedium)
                    .foregroundColor(.aicovenTextPrimary)
            }

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(name)
                    .font(.aicovenH3)
                    .foregroundColor(.aicovenTextPrimary)
                Text(subtitle)
                    .font(.aicovenCaption)
                    .foregroundColor(.aicovenTextSecondary)
            }

            Spacer()
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Color.aicovenGlass)
        .cornerRadius(BorderRadius.md)
    }
}

struct BulletList: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: Spacing.sm) {
                    Circle()
                        .fill(Color.aicovenTeal)
                        .frame(width: 6, height: 6)
                        .padding(.top, 6)

                    Text(item)
                        .font(.aicovenBodySmall)
                        .foregroundColor(.aicovenTextSecondary)
                }
            }
        }
    }
}

#if DEBUG
#Preview {
    OnboardingFlowView()
        .environmentObject(AppState.shared)
        .environmentObject(AuthService.shared)
}
#endif
