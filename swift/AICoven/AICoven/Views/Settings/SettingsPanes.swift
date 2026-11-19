import SwiftUI

// MARK: - Appearance

/// Theme and typography. Each choice applies at once.
struct AppearanceSettingsPane: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var typographyManager = TypographyManager.shared

    var body: some View {
        SettingsForm {
            Section {
                Picker("Theme", selection: Binding(
                    get: { themeManager.variant },
                    set: { themeManager.setVariant($0) }
                )) {
                    ForEach(ThemeVariant.allCases) { variant in
                        Text(variant.displayName).tag(variant)
                    }
                }
            } footer: {
                Text(themeManager.theme.tagline)
            }

            Section {
                Picker("Font style", selection: Binding(
                    get: { typographyManager.variant },
                    set: { typographyManager.setVariant($0) }
                )) {
                    ForEach(TypographyVariant.allCases) { variant in
                        Text(variant.displayName).tag(variant)
                    }
                }
                Picker("Font size", selection: Binding(
                    get: { typographyManager.sizeScale },
                    set: { typographyManager.setSizeScale($0) }
                )) {
                    ForEach(TypographySizeScale.allCases) { scale in
                        Text(scale.displayName).tag(scale)
                    }
                }
            } header: {
                Text("Typography")
            } footer: {
                Text(typographyManager.variant.tagline)
            }
        }
    }
}

// MARK: - About

/// A legal page About can open on.
enum LegalPage: Hashable {
    case terms
    case privacy

    init?(_ type: WorkspaceTabType) {
        switch type {
        case .terms: self = .terms
        case .privacy: self = .privacy
        default: return nil
        }
    }
}

/// Version, the legal pages, and the analytics choices.
struct AboutSettingsPane: View {
    /// The page a request asked for, shown on top of About.
    let initialPage: LegalPage?
    @State private var showsInitialPage: Bool
    @AppStorage("analytics_product_enabled") private var productAnalyticsEnabled = true
    @AppStorage("analytics_performance_enabled") private var performanceAnalyticsEnabled = true
    #if DEBUG
    @EnvironmentObject private var authService: AuthService
    #endif

    init(initialPage: LegalPage? = nil) {
        self.initialPage = initialPage
        _showsInitialPage = State(initialValue: initialPage != nil)
    }

    var body: some View {
        SettingsForm {
            Section {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")
                LabeledContent("Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown")
            }

            Section {
                NavigationLink("Terms & Conditions") { legalPage(.terms) }
                NavigationLink("Privacy Policy") { legalPage(.privacy) }
            }

            Section {
                Toggle("Product analytics", isOn: $productAnalyticsEnabled)
                Toggle("Performance monitoring", isOn: $performanceAnalyticsEnabled)
            } header: {
                Text("Privacy & Analytics")
            } footer: {
                Text("Analytics data is anonymized using SHA-256 hashing and never includes your messages, memories, documents, or personal content. We only collect usage patterns (e.g. which features are used, session duration) and performance data (e.g. crash reports, response times). You can disable analytics at any time.")
            }
            .onChange(of: productAnalyticsEnabled) { _, enabled in analyticsChoiceChanged("product", enabled: enabled) }
            .onChange(of: performanceAnalyticsEnabled) { _, enabled in analyticsChoiceChanged("performance", enabled: enabled) }

            #if DEBUG
            Section("Debug") {
                Button("Reset first-run onboarding for this account") {
                    Task { await authService.markOnboardingCompletedReset() }
                }
            }
            #endif
        }
        .navigationDestination(isPresented: $showsInitialPage) {
            if let initialPage {
                legalPage(initialPage)
            }
        }
    }

    @ViewBuilder
    private func legalPage(_ page: LegalPage) -> some View {
        switch page {
        case .terms:
            TermsOfServiceView()
                .navigationTitle("Terms & Conditions")
        case .privacy:
            PrivacyPolicyView()
                .navigationTitle("Privacy Policy")
        }
    }

    private func analyticsChoiceChanged(_ type: String, enabled: Bool) {
        AnalyticsService.shared.setAnalyticsConsent(productAnalyticsEnabled || performanceAnalyticsEnabled)
        if enabled {
            AnalyticsService.shared.track(event: "analytics_consent_granted", properties: ["type": type])
        }
    }
}

/// A Settings pane's Form: grouped, in the person's typography, on the
/// theme's surface.
struct SettingsForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form {
            Group { content }
                .listRowBackground(Color.aicovenSurfaceElevated)
        }
        .formStyle(.grouped)
        .font(.aicovenBody)
        .scrollContentBackground(.hidden)
        .background(Color.aicovenDark)
    }
}
