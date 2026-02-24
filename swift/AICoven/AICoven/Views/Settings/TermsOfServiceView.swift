import SwiftUI

/// In-app Terms of Service view displaying AICoven Local's terms
/// including BYOK responsibilities, AI provider terms, and usage policies.
struct TermsOfServiceView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                // Header section
                headerSection

                // Main content sections
                whatIsAICovenSection
                eligibilitySection
                yourAccountSection
                byokSection
                supportedProvidersSection
                thirdPartyTermsSection
                providerDataHandlingSection
                ownershipSection
                acceptableUseSection
                disclaimersSection
                liabilitySection
                terminationSection
                governingLawSection
                contactSection
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.xl)
        }
        .background(NebulaBackground())
        .navigationTitle("Terms of Service")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("AICoven Local Terms of Service")
                .font(.aicovenDisplaySmall)
                .foregroundColor(.aicovenTextPrimary)

            Text("Last updated: February 2026")
                .font(.aicovenCaption)
                .foregroundColor(.aicovenTextTertiary)

            Text("Welcome to **AICoven Local**, operated by **Andreea Elena Papillon** (\"we\", \"us\", or \"our\"). By accessing or using AICoven Local, you agree to these Terms of Service (\"Terms\"). If you do not agree, do not use the service.")
                .font(.aicovenBody)
                .foregroundColor(.aicovenTextSecondary)
        }
    }

    // MARK: - Section 1: What AICoven Is

    private var whatIsAICovenSection: some View {
        TermsSection(title: "1. What AICoven Local Is") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("AICoven Local is a **local-first AI workspace** for orchestrating multiple AI models, managing memory, and working with AI roles — all on your own device.")
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextSecondary)

                Text("AICoven Local operates under a **Bring Your Own Key (BYOK)** model. You connect your own AI provider accounts (such as OpenAI, Anthropic, or Google), and all model usage occurs under your credentials. You can also use fully local models with Ollama or Apple Intelligence.")
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextSecondary)
            }
        }
    }

    // MARK: - Section 2: Eligibility

    private var eligibilitySection: some View {
        TermsSection(title: "2. Eligibility") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("You must be at least **16 years old** to use AICoven Local.")
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextSecondary)

                Text("By using the service, you confirm that:")
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextSecondary)

                TermsBullet("You are legally permitted to use it.")
                TermsBullet("You have the authority to connect any third-party AI accounts you provide.")
                TermsBullet("You will comply with these Terms and all applicable laws.")
            }
        }
    }

    // MARK: - Section 3: Your Account

    private var yourAccountSection: some View {
        TermsSection(title: "3. Your Account & Local Data") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("You are responsible for:")
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextSecondary)

                TermsBullet("Maintaining the security of your device and login credentials.")
                TermsBullet("Safeguarding your connected API keys.")
                TermsBullet("Backing up your local data — data stored only on your device is not recoverable if lost.")
                TermsBullet("All activity performed through the app on your device.")

                Text("Since AICoven Local stores data locally, losing access to your device means losing access to your data.")
                    .font(.aicovenBodySmall)
                    .foregroundColor(.aicovenTextSecondary)
                    .padding(.top, Spacing.xs)
            }
        }
    }

    // MARK: - Section 4: BYOK

    private var byokSection: some View {
        TermsSection(title: "4. Bring Your Own Keys (BYOK)") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                TermsBullet("AICoven Local does **not** provide paid AI model access.")
                TermsBullet("You are solely responsible for all costs, limits, and obligations associated with your connected AI providers.")
                TermsBullet("Your API keys are stored securely in the macOS/iOS Keychain and are never transmitted to our servers.")

                Text("We may display warnings or errors if a connected provider key is invalid, revoked, or exceeds quota.")
                    .font(.aicovenBodySmall)
                    .foregroundColor(.aicovenTextSecondary)
                    .padding(.top, Spacing.xs)
            }
        }
    }

    // MARK: - Section 4.1: Supported Providers

    private var supportedProvidersSection: some View {
        TermsSection(title: "4.1 Supported AI Providers") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("AICoven Local supports the following AI providers:")
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextSecondary)

                TermsBullet("**Cloud Providers:** OpenAI, Anthropic, Google Gemini")
                TermsBullet("**Local Providers:** Ollama, Apple Intelligence (MLX)")

                Text("When using cloud providers, your data is transmitted directly from your device to their servers. When using local providers, all processing occurs entirely on your device.")
                    .font(.aicovenBodySmall)
                    .foregroundColor(.aicovenTextSecondary)
                    .padding(.top, Spacing.xs)
            }
        }
    }

    // MARK: - Section 4.2: Third-Party Terms

    private var thirdPartyTermsSection: some View {
        TermsSection(title: "4.2 Third-Party AI Provider Terms") {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("By connecting AI providers to AICoven Local, you agree to comply with each provider's terms of service:")
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextSecondary)

                ProviderTermsRow(provider: "OpenAI", links: [
                    ("Terms of Use", "https://openai.com/policies/terms-of-use"),
                    ("Usage Policies", "https://openai.com/policies/usage-policies"),
                ])

                ProviderTermsRow(provider: "Anthropic", links: [
                    ("Acceptable Use", "https://www.anthropic.com/legal/aup"),
                    ("Commercial Terms", "https://www.anthropic.com/legal/commercial-terms"),
                ])

                ProviderTermsRow(provider: "Google Gemini", links: [
                    ("API Terms", "https://ai.google.dev/gemini-api/terms"),
                    ("Google Terms", "https://policies.google.com/terms"),
                ])

                ProviderTermsRow(provider: "Ollama", links: [
                    ("MIT License", "https://github.com/ollama/ollama/blob/main/LICENSE"),
                ], note: "Open-source, runs locally")

                Text("You are responsible for ensuring your use of AI providers complies with their respective terms. AICoven is not liable for violations of third-party provider policies.")
                    .font(.aicovenBodySmall)
                    .foregroundColor(.aicovenTextSecondary)
                    .padding(.top, Spacing.xs)
            }
        }
    }

    // MARK: - Section 4.3: Provider Data Handling

    private var providerDataHandlingSection: some View {
        TermsSection(title: "4.3 AI Provider Data Handling") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("When you use cloud AI providers through AICoven Local:")
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextSecondary)

                TermsBullet("Your messages and context are sent directly from your device to the provider.")
                TermsBullet("Providers may retain data temporarily for abuse monitoring (typically 30 days for API usage).")
                TermsBullet("API data is generally not used for model training by major providers.")

                NavigationLink(destination: PrivacyPolicyView()) {
                    HStack {
                        Text("See our Privacy Policy for detailed provider retention information")
                            .font(.aicovenBodySmall)
                            .foregroundColor(.aicovenTeal)
                        Image(systemName: "chevron.right")
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTeal)
                    }
                }
                .padding(.top, Spacing.xs)
            }
        }
    }

    // MARK: - Section 5: Ownership

    private var ownershipSection: some View {
        TermsSection(title: "5. Ownership of Content") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("You retain full ownership of:")
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextSecondary)

                TermsBullet("Your messages and conversations")
                TermsBullet("Your memories")
                TermsBullet("Your configurations and settings")
                TermsBullet("Your connected provider accounts")

                Text("Since your data is stored locally on your device, you maintain complete control. We do not have access to your data unless you enable optional analytics.")
                    .font(.aicovenBodySmall)
                    .foregroundColor(.aicovenTextSecondary)
                    .padding(.top, Spacing.xs)
            }
        }
    }

    // MARK: - Section 6: Acceptable Use

    private var acceptableUseSection: some View {
        TermsSection(title: "6. Acceptable Use") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("You agree not to:")
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextSecondary)

                TermsBullet("Use AICoven Local for illegal, harmful, or abusive activities.")
                TermsBullet("Attempt to reverse-engineer or compromise the app's security.")
                TermsBullet("Use AICoven Local in ways that violate third-party AI provider terms.")
                TermsBullet("Redistribute or resell the app or its components without authorization.")
            }
        }
    }

    // MARK: - Section 7: Disclaimers

    private var disclaimersSection: some View {
        TermsSection(title: "7. Service Availability & Disclaimers") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("AICoven Local is provided **\"as is\"** and **\"as available.\"**")
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextSecondary)

                Text("We do not guarantee:")
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextSecondary)

                TermsBullet("Continuous availability of cloud provider services")
                TermsBullet("Error-free operation")
                TermsBullet("Accuracy of AI-generated outputs")

                Text("AI responses are produced by third-party providers or local models and may be incorrect or incomplete. Always verify important information.")
                    .font(.aicovenBodySmall)
                    .foregroundColor(.aicovenTextSecondary)
                    .padding(.top, Spacing.xs)
            }
        }
    }

    // MARK: - Section 8: Liability

    private var liabilitySection: some View {
        TermsSection(title: "8. Limitation of Liability") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("To the maximum extent permitted by law:")
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextSecondary)

                TermsBullet("We are not liable for indirect or consequential losses.")
                TermsBullet("We are not liable for data loss on your local device.")
                TermsBullet("Our total liability is limited to **£50**.")

                Text("Nothing in these Terms limits liability that cannot be excluded by law.")
                    .font(.aicovenBodySmall)
                    .foregroundColor(.aicovenTextSecondary)
                    .padding(.top, Spacing.xs)
            }
        }
    }

    // MARK: - Section 9: Termination

    private var terminationSection: some View {
        TermsSection(title: "9. Termination") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("You may stop using AICoven Local at any time by deleting the app.")
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextSecondary)

                Text("Upon termination:")
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextSecondary)

                TermsBullet("Your local data remains on your device unless you delete it.")
                TermsBullet("Your API keys remain in your Keychain unless you remove them.")
                TermsBullet("Your statutory rights are not affected.")
            }
        }
    }

    // MARK: - Section 10: Governing Law

    private var governingLawSection: some View {
        TermsSection(title: "10. Governing Law") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("These Terms are governed by the laws of **England and Wales**.")
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextSecondary)

                Text("Any disputes shall be subject to the exclusive jurisdiction of the courts of England and Wales.")
                    .font(.aicovenBodySmall)
                    .foregroundColor(.aicovenTextSecondary)
            }
        }
    }

    // MARK: - Section 11: Contact

    private var contactSection: some View {
        TermsSection(title: "11. Contact") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Questions about these Terms?")
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextSecondary)

                Text("📧 hello@aicoven.ai")
                    .font(.aicovenBodyMedium)
                    .foregroundColor(.aicovenTeal)
            }
        }
    }
}

// MARK: - Helper Components

/// A section wrapper with consistent styling for terms content
private struct TermsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(title)
                .font(.aicovenH2)
                .foregroundColor(.aicovenTextPrimary)

            content
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.aicovenGlass)
        .cornerRadius(BorderRadius.md)
    }
}

/// A bullet point item for terms lists
private struct TermsBullet: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Circle()
                .fill(Color.aicovenTeal)
                .frame(width: 6, height: 6)
                .padding(.top, 6)

            Text(.init(text))
                .font(.aicovenBodySmall)
                .foregroundColor(.aicovenTextSecondary)
        }
    }
}

/// A row displaying provider terms links
private struct ProviderTermsRow: View {
    let provider: String
    let links: [(String, String)]
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(provider)
                .font(.aicovenBodyMedium)
                .foregroundColor(.aicovenTextPrimary)

            HStack(spacing: Spacing.sm) {
                ForEach(links, id: \.0) { link in
                    if let url = URL(string: link.1) {
                        Link(link.0, destination: url)
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTeal)
                    }
                }
            }

            if let note {
                Text(note)
                    .font(.aicovenCaption)
                    .foregroundColor(.aicovenTextTertiary)
                    .italic()
            }
        }
        .padding(.vertical, Spacing.xs)
        .padding(.horizontal, Spacing.sm)
        .background(Color.aicovenGlass.opacity(0.5))
        .cornerRadius(BorderRadius.sm)
    }
}

#Preview {
    NavigationStack {
        TermsOfServiceView()
    }
}
