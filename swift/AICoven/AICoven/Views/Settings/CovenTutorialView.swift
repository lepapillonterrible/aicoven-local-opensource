import SwiftUI

/// Long-form tutorial for how to create and use covens, roles, keys, and memory.
///
/// This view is intended as the detailed follow-up to the FTUE screens and can
/// be opened from Settings > Tutorial or other entry points.
struct CovenTutorialView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                header

                sectionCovens
                sectionProviderKeys
                sectionConnectedApps
                sectionRoles
                sectionBudgets
                sectionThreadsAndOrchestration
                sectionRouting
                sectionMemory
                sectionTips
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.bottom, Spacing.xxl)
        }
        .background(NebulaBackground())
        .navigationTitle("Tutorial")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: Spacing.sm) {
            IconBadge(icon: "sparkles", size: 60, color: .aicovenTeal)

            Text("Welcome to Covens")
                .font(.aicovenDisplaySmall)
                .foregroundColor(.aicovenTextPrimary)

            Text("Learn how to set up covens, connect providers and apps, and orchestrate multiple AI roles with shared memory.")
                .font(.aicovenBody)
                .foregroundColor(.aicovenTextSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, Spacing.xl)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Sections

    private var sectionCovens: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("1. What is a Coven?")
                    .font(.aicovenH2)
                    .foregroundColor(.aicovenTextPrimary)

                Text("A Coven is a shared workspace for a project or team. You, your collaborators, and multiple AI roles all work in the same space.")
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextSecondary)

                BulletList(items: [
                    "Each coven contains threads (chats or tasks).",
                    "Each coven has roles (agents) with their own models and tools.",
                    "Coven memory stores project knowledge that all roles can reuse."
                ])
            }
        }
    }

    private var sectionProviderKeys: some View {
        GlassCard {
            TutorialTwoColumn {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    Text("2. Connect Your AI Providers (BYOK)")
                        .font(.aicovenH2)
                        .foregroundColor(.aicovenTextPrimary)

                    Text("AICoven does not resell models. You bring your own keys for providers like OpenAI, Anthropic, and Google Gemini.")
                        .font(.aicovenBody)
                        .foregroundColor(.aicovenTextSecondary)

                    BulletList(items: [
                        "Go to Settings → Provider Keys to add or manage keys.",
                        "Use clear display names (e.g., 'OpenAI – Team', 'Claude – Research').",
                        "Keys are encrypted at rest and only decrypted in memory when needed."
                    ])

                    Text("Important: if you lose your encryption keys, AICoven cannot recover the data they protect. Treat provider keys like passwords to your AI accounts.")
                        .font(.aicovenCaption)
                        .foregroundColor(.aicovenTextSecondary)
                }
            } right: {
                TutorialScreenshot(
                    title: "Provider keys",
                    imageName: "provider_keys"
                )
            }
        }
    }

    private var sectionConnectedApps: some View {
        GlassCard {
            TutorialTwoColumn {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    Text("3. Connect Apps like GitHub & Google Drive")
                        .font(.aicovenH2)
                        .foregroundColor(.aicovenTextPrimary)

                    Text("Connected apps let your covens read and write code, docs, and files in tools you already use — always with your explicit permission.")
                        .font(.aicovenBody)
                        .foregroundColor(.aicovenTextSecondary)

                    BulletList(items: [
                        "Go to Settings → Connected Apps to connect GitHub, Google Drive, and more.",
                        "Each connection is tied to your account and can be revoked at any time.",
                        "Tokens are stored encrypted; agents only access the repos and folders you’ve approved."
                    ])

                    Text("Tip: start by connecting the repos and project folders that match a specific coven so roles stay focused on the right sources of truth.")
                        .font(.aicovenCaption)
                        .foregroundColor(.aicovenTextSecondary)
                }
            } right: {
                TutorialScreenshot(
                    title: "Connected apps",
                    imageName: "connect_apps"
                )
            }
        }
    }

    private var sectionBudgets: some View {
        GlassCard {
            TutorialTwoColumn {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    Text("4. Budgets & Usage")
                        .font(.aicovenH2)
                        .foregroundColor(.aicovenTextPrimary)

                    Text("Track token usage and control spending across providers.")
                        .font(.aicovenBody)
                        .foregroundColor(.aicovenTextSecondary)

                    BulletList(items: [
                        "Set monthly budgets to keep spend predictable.",
                        "Review recent activity to see model usage and costs.",
                        "Use budgets to keep experiments and production separate."
                    ])
                }
            } right: {
                TutorialScreenshot(
                    title: "Budgets & usage",
                    imageName: "budgets_usage"
                )
            }
        }
    }

    private var sectionRoles: some View {
        GlassCard {
            TutorialTwoColumn {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    Text("5. Create Roles (Agents)")
                        .font(.aicovenH2)
                        .foregroundColor(.aicovenTextPrimary)

                    Text("Roles are AI agents with names, prompts, models, and tools. They define how each assistant behaves in a coven.")
                        .font(.aicovenBody)
                        .foregroundColor(.aicovenTextSecondary)

                    BulletList(items: [
                        "Give each role a clear name and emoji (e.g., 🧠 Strategist, 👩‍💻 Coder, 🧾 Scribe).",
                        "Choose a provider account and model for each role.",
                        "Attach tools like GitHub, Google Docs, or Sheets when relevant."
                    ])

                    Text("Pattern: start with a Strategist (plans), a Coder or Analyst (execution), and a Scribe (summaries & docs) per coven.")
                        .font(.aicovenCaption)
                        .foregroundColor(.aicovenTextSecondary)
                }
            } right: {
                VStack(spacing: Spacing.sm) {
                    TutorialScreenshot(
                        title: "Add an agent role",
                        imageName: "add_agent_role"
                    )
                    TutorialScreenshot(
                        title: "Start from a role template",
                        imageName: "create_agent_roles_from_template"
                    )
                    TutorialScreenshot(
                        title: "Select a preferred model",
                        imageName: "select_the_preffered_model_for_the_agent_role"
                    )
                }
            }
        }
    }

    private var sectionThreadsAndOrchestration: some View {
        GlassCard {
            TutorialTwoColumn {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    Text("6. Threads & Orchestration")
                        .font(.aicovenH2)
                        .foregroundColor(.aicovenTextPrimary)

                    Text("Threads are conversations or tasks inside a coven. Each thread can have a primary role, plus additional roles brought in via @mentions or roundtables.")
                        .font(.aicovenBody)
                        .foregroundColor(.aicovenTextSecondary)

                    BulletList(items: [
                        "Create a new thread for each major task, spec, or decision.",
                        "Set a primary role that will respond by default.",
                        "Use @mentions to invite other roles into the conversation when needed."
                    ])

                    Text("@Mentions: type @RoleName in any message to pull a specialist into the thread for a single response. AICoven routes the request to that role’s model and tools, then reconciles the result back into the conversation.")
                        .font(.aicovenCaption)
                        .foregroundColor(.aicovenTextSecondary)

                    Text("Example: let 🧠 Strategist own the thread, @Coder propose implementation details, and @Scribe turn the outcome into a spec or doc.")
                        .font(.aicovenCaption)
                        .foregroundColor(.aicovenTextSecondary)
                }
            } right: {
                VStack(spacing: Spacing.sm) {
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

    private var sectionRouting: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("7. Models & Routing")
                    .font(.aicovenH2)
                    .foregroundColor(.aicovenTextPrimary)

                Text("Each role chooses a single provider account and preferred model. At runtime, AICoven will automatically try other available models and providers when the preferred one fails or is temporarily unavailable.")
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextSecondary)

                BulletList(items: [
                    "Pick the model that best fits the role’s job (reasoning, coding, drafting, etc.).",
                    "If a provider is down or rate‑limited, AICoven walks the list of available models and tries alternatives for you.",
                    "The default assistant uses the same routing logic across all configured providers so it can still answer if any model is healthy."
                ])
            }
        }
    }

    private var sectionMemory: some View {
        GlassCard {
            TutorialTwoColumn {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    Text("8. Memory & Context")
                        .font(.aicovenH2)
                        .foregroundColor(.aicovenTextPrimary)

                    Text("Memory lets roles remember what matters across threads while keeping control in your hands.")
                        .font(.aicovenBody)
                        .foregroundColor(.aicovenTextSecondary)

                    BulletList(items: [
                        "Agents propose memory writes during chat; you approve them.",
                        "Scopes: agent‑specific, personal (user), and coven‑wide memories.",
                        "Use the Memory Explorer to search, approve, and pin important items."
                    ])

                    Text("When you send a message, AICoven retrieves relevant memories and builds a context sandwich: role prompt + memory + recent messages + your new input.")
                        .font(.aicovenCaption)
                        .foregroundColor(.aicovenTextSecondary)
                }
            } right: {
                VStack(spacing: Spacing.sm) {
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

    private var sectionTips: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("9. Practical Tips")
                    .font(.aicovenH2)
                    .foregroundColor(.aicovenTextPrimary)

                BulletList(items: [
                    "Name covens by team and project (e.g., 'Growth – Q2 Launch').",
                    "Use different provider keys for personal vs team work.",
                    "Design roles narrowly: one clear job per role beats 'do everything' agents.",
                    "Review proposed memories regularly so long‑term behavior stays aligned.",
                    "Use roundtables sparingly (2–3 key roles) to keep comparisons readable."
                ])
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

#Preview {
    NavigationStack {
        CovenTutorialView()
    }
}
