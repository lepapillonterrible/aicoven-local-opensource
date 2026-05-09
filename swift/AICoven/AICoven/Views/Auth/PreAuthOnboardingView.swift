import SwiftUI

/// Pre-authentication onboarding — shown to users who haven't signed up yet.
///
/// Shows three swipeable value-prop slides before asking them to create an
/// account, answering "what is this app?" before requesting commitment.
struct PreAuthOnboardingView: View {
    @EnvironmentObject var authService: AuthService

    @State private var currentSlide = 0
    @State private var showSignUp = false
    @State private var showSignIn = false

    private static let slides: [Slide] = [
        Slide(
            imageName: "onboarding_keys",
            secondImageName: "onboarding_keys_2",
            title: "Your AI, Your Keys",
            subtitle: "Use your own API keys. Your data is encrypted and never seen by us. Just pure, private AI, on your terms.",
            analyticsTitle: "your_ai_your_keys"
        ),
        Slide(
            imageName: "onboarding_agents",
            title: "Multi-Agent Covens",
            subtitle: "Your own team of specialized AI agents. Different models, different skills, one shared workspace.",
            analyticsTitle: "multi_agent_covens"
        ),
        Slide(
            imageName: "onboarding_memory",
            title: "Memory & Integrations",
            subtitle: "Stop repeating yourself. Connect your tools and let your agents remember what matters, so work actually moves forward.",
            analyticsTitle: "memory_and_integrations"
        )
    ]

    var body: some View {
        #if os(iOS)
        iOSBody
        #else
        macOSBody
        #endif
    }

    // MARK: - iOS layout (swipeable TabView)

    #if os(iOS)
    private var iOSBody: some View {
        ZStack {
            NebulaBackground()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                TabView(selection: $currentSlide) {
                    ForEach(Array(Self.slides.enumerated()), id: \.offset) { index, slide in
                        SlideView(slide: slide)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut, value: currentSlide)
                .onChange(of: currentSlide, trackSlide)

                pageDotsView
                ctaView
            }
        }
        .themedColorScheme()
        .fullScreenCover(isPresented: $showSignUp) {
            LoginView(initialMode: .signup)
                .environmentObject(authService)
        }
        .fullScreenCover(isPresented: $showSignIn) {
            LoginView(initialMode: .signin)
                .environmentObject(authService)
        }
        .onAppear(perform: trackAppear)
    }
    #endif

    // MARK: - macOS layout (GeometryReader, no TabView)

    #if !os(iOS)
    private var macOSBody: some View {
        GeometryReader { geo in
            ZStack {
                NebulaBackground()

                VStack(spacing: 0) {
                    ZStack {
                        SlideView(slide: Self.slides[currentSlide])
                            .frame(width: geo.size.width, height: geo.size.height * 0.72)
                            .id(currentSlide)
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)
                            ))
                            .animation(.easeInOut(duration: 0.3), value: currentSlide)
                            .onChange(of: currentSlide, trackSlide)

                        HStack {
                            if currentSlide > 0 {
                                Button(action: {
                                    withAnimation { currentSlide -= 1 }
                                }) {
                                    Image(systemName: "chevron.left.circle.fill")
                                        .font(.system(size: 32))
                                        .foregroundStyle(.white.opacity(0.7))
                                        .padding(.leading, Spacing.lg)
                                }
                                .buttonStyle(.plain)
                            }
                            Spacer()
                            if currentSlide < Self.slides.count - 1 {
                                Button(action: {
                                    withAnimation { currentSlide += 1 }
                                }) {
                                    Image(systemName: "chevron.right.circle.fill")
                                        .font(.system(size: 32))
                                        .foregroundStyle(.white.opacity(0.7))
                                        .padding(.trailing, Spacing.lg)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(width: geo.size.width, height: geo.size.height * 0.72)
                    }

                    pageDotsView
                    ctaView
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .themedColorScheme()
        .sheet(isPresented: $showSignUp) {
            LoginView(initialMode: .signup)
                .environmentObject(authService)
        }
        .sheet(isPresented: $showSignIn) {
            LoginView(initialMode: .signin)
                .environmentObject(authService)
        }
        .onAppear(perform: trackAppear)
    }
    #endif

    // MARK: - Shared sub-views

    private var pageDotsView: some View {
        HStack(spacing: 8) {
            ForEach(0 ..< Self.slides.count, id: \.self) { index in
                Capsule()
                    .fill(index == currentSlide ? Color.aicovenTeal : Color.aicovenBorder)
                    .frame(width: index == currentSlide ? 20 : 8, height: 8)
                    .animation(.easeInOut(duration: 0.25), value: currentSlide)
            }
        }
        .padding(.top, Spacing.lg)
    }

    private var ctaView: some View {
        VStack(spacing: Spacing.sm) {
            GradientButton("Get Started", icon: "sparkles", style: .primary) {
                AnalyticsService.shared.track(
                    event: "preauth_onboarding_get_started_tapped",
                    properties: ["current_slide": currentSlide]
                )
                showSignUp = true
            }

            Button(action: {
                AnalyticsService.shared.track(
                    event: "preauth_onboarding_login_tapped",
                    properties: ["current_slide": currentSlide]
                )
                showSignIn = true
            }) {
                Text("Already have an account? **Log In**")
                    .font(.aicovenBodySmall)
                    .foregroundColor(.aicovenTextSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.xl)
        .padding(.bottom, Spacing.xxl)
    }

    // MARK: - Analytics helpers

    private func trackSlide(_ oldValue: Int, _ newValue: Int) {
        let slide = Self.slides[newValue]
        AnalyticsService.shared.track(
            event: "preauth_onboarding_slide_viewed",
            properties: ["slide": newValue, "title": slide.analyticsTitle]
        )
    }

    private func trackAppear() {
        AnalyticsService.shared.track(event: "preauth_onboarding_viewed", properties: [:])
        AnalyticsService.shared.track(
            event: "preauth_onboarding_slide_viewed",
            properties: ["slide": 0, "title": Self.slides[0].analyticsTitle]
        )
    }
}

// MARK: - Slide Model

private struct Slide {
    let imageName: String
    var secondImageName: String?
    let title: String
    let subtitle: String
    let analyticsTitle: String
}

// MARK: - Slide View

private struct SlideView: View {
    let slide: Slide

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()

            // Screenshot(s)
            if let second = slide.secondImageName {
                // Two screenshots layered with depth offset
                ZStack {
                    Image(slide.imageName)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 260)
                        .clipShape(RoundedRectangle(cornerRadius: BorderRadius.lg))
                        .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 6)
                        .overlay(
                            RoundedRectangle(cornerRadius: BorderRadius.lg)
                                .strokeBorder(Color.aicovenBorder.opacity(0.4), lineWidth: 1)
                        )
                        .rotationEffect(.degrees(-4))
                        .offset(x: -30, y: 10)

                    Image(second)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 180)
                        .clipShape(RoundedRectangle(cornerRadius: BorderRadius.lg))
                        .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 8)
                        .overlay(
                            RoundedRectangle(cornerRadius: BorderRadius.lg)
                                .strokeBorder(Color.aicovenBorder.opacity(0.5), lineWidth: 1)
                        )
                        .rotationEffect(.degrees(3))
                        .offset(x: 30, y: -10)
                }
                .frame(maxHeight: 300)
                .padding(.horizontal, Spacing.xl)
            } else {
                Image(slide.imageName)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: BorderRadius.lg))
                    .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 8)
                    .overlay(
                        RoundedRectangle(cornerRadius: BorderRadius.lg)
                            .strokeBorder(Color.aicovenBorder.opacity(0.5), lineWidth: 1)
                    )
                    .padding(.horizontal, Spacing.xl)
            }

            // Text
            VStack(spacing: Spacing.sm) {
                Text(slide.title)
                    .font(.aicovenDisplaySmall)
                    .foregroundColor(.aicovenTextPrimary)
                    .multilineTextAlignment(.center)

                Text(slide.subtitle)
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Spacing.xl)

            Spacer()
        }
    }
}
