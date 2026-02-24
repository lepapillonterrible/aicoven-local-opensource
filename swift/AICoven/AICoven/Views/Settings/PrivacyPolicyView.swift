import SwiftUI

/// In-app Privacy Policy view displaying AICoven Local's privacy practices
/// including AI provider data handling, local-first architecture, and user rights.
struct PrivacyPolicyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                // Header section
                headerSection

                // Main content sections
                whoWeAreSection
                dataWeCollectSection
                localFirstSection
                encryptionSection
                aiProvidersSection
                aiProviderDataSection
                aiProviderRetentionSection
                aiProviderLinksSection
                localModelsSection
                yourControlSection
                analyticsSection
                dataRetentionSection
                yourRightsSection
                childrensPrivacySection
                changesSection
                contactSection
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.xl)
        }
        .background(NebulaBackground())
        .navigationTitle("Privacy Policy")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("AICoven Local Privacy Policy")
                .font(.aicovenDisplaySmall)
                .foregroundColor(.aicovenTextPrimary)

            Text("Last updated: February 2026")
                .font(.aicovenCaption)
                .foregroundColor(.aicovenTextTertiary)

            Text("AICoven Local is built around the principle of **privacy by default** with a **local-first architecture**. Your data stays on your device unless you explicitly choose to use cloud AI providers.")
                .font(.aicovenBody)
                .foregroundColor(.aicovenTextSecondary)
        }
    }

    // MARK: - Section 1: Who We Are

    private var whoWeAreSection: some View {
        PolicySection(title: "1. Who We Are") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("**AICoven** is operated by **Andreea Elena Papillon**.")
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextSecondary)

                Text("📧 Email: hello@aicoven.ai")
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextSecondary)

                Text("We are based in the United Kingdom and comply with the **UK GDPR** and the **Data Protection Act 2018**.")
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextSecondary)
            }
        }
    }

    // MARK: - Section 2: Data We Collect

    private var dataWeCollectSection: some View {
        PolicySection(title: "2. Data We Collect") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                DataCategoryRow(category: "Local account data", examples: "Email, authentication identifiers", purpose: "Account access")
                DataCategoryRow(category: "Messages & memory", examples: "Conversations, approved memory items", purpose: "Provide chat and recall")
                DataCategoryRow(category: "Provider keys", examples: "Encrypted API keys for cloud providers", purpose: "Enable cloud AI access")
                DataCategoryRow(category: "Analytics (optional)", examples: "Anonymized usage patterns, crash reports", purpose: "App improvement")

                Text("We do **not** sell or rent personal data.")
                    .font(.aicovenBodySmall)
                    .foregroundColor(.aicovenTextSecondary)
                    .padding(.top, Spacing.xs)
            }
        }
    }

    // MARK: - Section 3: Local-First Architecture

    private var localFirstSection: some View {
        PolicySection(title: "3. Local-First Architecture") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("AICoven Local stores all your data on your device:")
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextSecondary)

                BulletPoint("All conversations are stored locally in an encrypted SQLite database.")
                BulletPoint("Memory items remain on your device and are never uploaded.")
                BulletPoint("You maintain full control — delete data anytime through the app.")
                BulletPoint("No cloud sync unless you explicitly connect cloud providers.")

                Text("This architecture ensures your data never leaves your device unless you choose to use cloud AI providers.")
                    .font(.aicovenBodySmall)
                    .foregroundColor(.aicovenTextSecondary)
                    .padding(.top, Spacing.xs)
            }
        }
    }

    // MARK: - Section 4: Encryption

    private var encryptionSection: some View {
        PolicySection(title: "4. Encryption & Security") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                BulletPoint("Your local database is **encrypted at rest** using your device's secure enclave.")
                BulletPoint("API keys for cloud providers are stored in the **macOS/iOS Keychain**.")
                BulletPoint("All network traffic to cloud providers uses **TLS (HTTPS)**.")
                BulletPoint("No encryption keys are transmitted to or stored on our servers.")
            }
        }
    }

    // MARK: - Section 5: AI Providers

    private var aiProvidersSection: some View {
        PolicySection(title: "5. AI Providers") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("When you use cloud AI providers through AICoven Local:")
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextSecondary)

                BulletPoint("Requests are sent directly from your device to the provider (OpenAI, Anthropic, Google).")
                BulletPoint("Your API keys are used directly — we never proxy or log your requests.")
                BulletPoint("Provider data handling is subject to their privacy policies.")
            }
        }
    }

    // MARK: - Section 5.1: Data Sent to AI Providers

    private var aiProviderDataSection: some View {
        PolicySection(title: "5.1 Data Sent to AI Providers") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("When you send a message to a cloud provider:")
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextSecondary)

                BulletPoint("Your message content")
                BulletPoint("Relevant conversation history from the current thread")
                BulletPoint("Retrieved memory context")
                BulletPoint("System prompts and role configurations")

                Text("**Important:** This data is sent directly from your device to the provider. AICoven does not receive, log, or store this information.")
                    .font(.aicovenBodySmall)
                    .foregroundColor(.aicovenTextSecondary)
                    .padding(.top, Spacing.xs)
            }
        }
    }

    // MARK: - Section 5.2: AI Provider Retention

    private var aiProviderRetentionSection: some View {
        PolicySection(title: "5.2 AI Provider Data Retention") {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Each cloud provider has their own data handling practices:")
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextSecondary)

                ProviderRetentionRow(provider: "OpenAI", retention: "30 days for abuse monitoring, then deleted", training: "API data not used for training by default")
                ProviderRetentionRow(provider: "Anthropic", retention: "30 days for safety, then deleted", training: "API data not used for training")
                ProviderRetentionRow(provider: "Google Gemini", retention: "Not retained beyond request processing (paid API)", training: "Paid API data not used for training")
                ProviderRetentionRow(provider: "Ollama (Local)", retention: "No data leaves your device", training: "Runs entirely on-device")
                ProviderRetentionRow(provider: "Apple Intelligence", retention: "No data leaves your device", training: "Runs entirely on-device")

                Text("Note: Policies may change. Always consult the provider's current documentation.")
                    .font(.aicovenCaption)
                    .foregroundColor(.aicovenTextTertiary)
            }
        }
    }

    // MARK: - Section 5.3: AI Provider Links

    private var aiProviderLinksSection: some View {
        PolicySection(title: "5.3 AI Provider Privacy Policy Links") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Review each provider's privacy practices:")
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextSecondary)

                ProviderLinkRow(provider: "OpenAI", links: [
                    ("Privacy Policy", "https://openai.com/policies/privacy-policy"),
                    ("API Data Usage", "https://openai.com/policies/api-data-usage-policies"),
                ])

                ProviderLinkRow(provider: "Anthropic", links: [
                    ("Privacy Policy", "https://www.anthropic.com/legal/privacy"),
                    ("Commercial Terms", "https://www.anthropic.com/legal/commercial-terms"),
                ])

                ProviderLinkRow(provider: "Google Gemini", links: [
                    ("API Terms", "https://ai.google.dev/gemini-api/terms"),
                    ("Privacy Policy", "https://policies.google.com/privacy"),
                ])

                ProviderLinkRow(provider: "Ollama", links: [
                    ("Privacy Policy", "https://ollama.com/privacy"),
                ], note: "Runs locally — no data sent externally")

                ProviderLinkRow(provider: "Apple", links: [
                    ("Privacy Policy", "https://www.apple.com/legal/privacy/"),
                ], note: "Local models run entirely on-device")
            }
        }
    }

    // MARK: - Section 5.4: Local Models

    private var localModelsSection: some View {
        PolicySection(title: "5.4 Local Models & On-Device Processing") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("AICoven Local supports fully on-device AI processing:")
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextSecondary)

                BulletPoint("**Ollama:** Open-source local model runtime. All inference happens on your Mac — no data is transmitted externally.")
                BulletPoint("**Apple Intelligence:** Native on-device models using Apple's ML framework. Processing is performed locally.")

                Text("When using local models, your messages and context never leave your device, providing the highest level of privacy.")
                    .font(.aicovenBodySmall)
                    .foregroundColor(.aicovenTextSecondary)
                    .padding(.top, Spacing.xs)
            }
        }
    }

    // MARK: - Section 5.5: Your Control

    private var yourControlSection: some View {
        PolicySection(title: "5.5 Your Control Over AI Provider Data") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("You maintain control over your data flow:")
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextSecondary)

                BulletPoint("**Choose your providers:** Only providers you explicitly connect receive your data.")
                BulletPoint("**Use local models:** Process everything on-device with Ollama or Apple Intelligence.")
                BulletPoint("**Disconnect anytime:** Remove provider keys from Settings to stop data flow.")
                BulletPoint("**Request deletion:** Contact providers directly using their data subject request processes.")
            }
        }
    }

    // MARK: - Section 6: Analytics

    private var analyticsSection: some View {
        PolicySection(title: "6. Analytics & Telemetry") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Analytics are **opt-in** and disabled by default:")
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextSecondary)

                BulletPoint("**Product Analytics:** Anonymized usage patterns to help us improve the app.")
                BulletPoint("**Performance Monitoring:** Crash reports and performance metrics to identify issues.")

                Text("If enabled, analytics data is:")
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextSecondary)
                    .padding(.top, Spacing.xs)

                BulletPoint("Anonymized and hashed — we cannot identify individual users or conversations.")
                BulletPoint("Never includes message content, memories, or personal information.")
                BulletPoint("Used solely for improving the app.")

                Text("You can enable or disable analytics at any time in Settings → Privacy & Analytics.")
                    .font(.aicovenBodySmall)
                    .foregroundColor(.aicovenTextSecondary)
                    .padding(.top, Spacing.xs)
            }
        }
    }

    // MARK: - Section 7: Data Retention

    private var dataRetentionSection: some View {
        PolicySection(title: "7. Data Retention") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                BulletPoint("**Local data:** Retained on your device until you delete it.")
                BulletPoint("**Account data:** Retained while your account is active.")
                BulletPoint("**Analytics (if enabled):** Aggregated data retained for up to 14 months.")
            }
        }
    }

    // MARK: - Section 8: Your Rights

    private var yourRightsSection: some View {
        PolicySection(title: "8. Your Rights (UK GDPR)") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("You have the right to:")
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextSecondary)

                BulletPoint("Access your data")
                BulletPoint("Correct inaccuracies")
                BulletPoint("Request deletion")
                BulletPoint("Export your data")
                BulletPoint("Object to or restrict processing")

                Text("To exercise your rights, contact **hello@aicoven.ai**. You may also lodge a complaint with the UK Information Commissioner's Office (ICO).")
                    .font(.aicovenBodySmall)
                    .foregroundColor(.aicovenTextSecondary)
                    .padding(.top, Spacing.xs)
            }
        }
    }

    // MARK: - Section 9: Children's Privacy

    private var childrensPrivacySection: some View {
        PolicySection(title: "9. Children's Privacy") {
            Text("AICoven is not intended for users under **16 years old**. We do not knowingly collect data from minors.")
                .font(.aicovenBody)
                .foregroundColor(.aicovenTextSecondary)
        }
    }

    // MARK: - Section 10: Changes

    private var changesSection: some View {
        PolicySection(title: "10. Changes to This Policy") {
            Text("We may update this Privacy Policy to reflect changes in the service or legal requirements. Material changes will be announced in-app.")
                .font(.aicovenBody)
                .foregroundColor(.aicovenTextSecondary)
        }
    }

    // MARK: - Section 11: Contact

    private var contactSection: some View {
        PolicySection(title: "11. Contact") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Questions about privacy or data protection?")
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

/// A section wrapper with consistent styling for policy content
private struct PolicySection<Content: View>: View {
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

/// A bullet point item for lists
private struct BulletPoint: View {
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

/// A row displaying data category information
private struct DataCategoryRow: View {
    let category: String
    let examples: String
    let purpose: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(category)
                .font(.aicovenBodyMedium)
                .foregroundColor(.aicovenTextPrimary)

            Text("\(examples) → \(purpose)")
                .font(.aicovenCaption)
                .foregroundColor(.aicovenTextTertiary)
        }
        .padding(.vertical, Spacing.xxs)
    }
}

/// A row displaying AI provider retention information
private struct ProviderRetentionRow: View {
    let provider: String
    let retention: String
    let training: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(provider)
                .font(.aicovenBodyMedium)
                .foregroundColor(.aicovenTextPrimary)

            HStack(spacing: Spacing.sm) {
                Label(retention, systemImage: "clock")
                    .font(.aicovenCaption)
                    .foregroundColor(.aicovenTextTertiary)
            }

            HStack(spacing: Spacing.sm) {
                Label(training, systemImage: "brain")
                    .font(.aicovenCaption)
                    .foregroundColor(.aicovenTextTertiary)
            }
        }
        .padding(.vertical, Spacing.xs)
        .padding(.horizontal, Spacing.sm)
        .background(Color.aicovenGlass.opacity(0.5))
        .cornerRadius(BorderRadius.sm)
    }
}

/// A row displaying provider links
private struct ProviderLinkRow: View {
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
    }
}

#Preview {
    NavigationStack {
        PrivacyPolicyView()
    }
}
