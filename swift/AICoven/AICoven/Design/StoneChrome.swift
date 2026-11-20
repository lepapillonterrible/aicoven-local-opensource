import SwiftUI
#if os(iOS)
import UIKit
#endif

// The stone chrome, as the cloud app draws it. Built with the iOS 26 and
// macOS 26 SDKs, the system draws glass behind toolbar buttons and blurs the
// bar behind a title. The app draws its bars in the chrome tone with a
// hairline, its toolbar buttons as plain ink, and always shows thin overlay
// scroll bars on the Mac. Menus, alerts and the keyboard stay the system's.

// MARK: - Toolbar buttons

/// A toolbar item with no glass plate behind it. Before iOS 26 and macOS 26
/// the system draws no plate, so the item is the plain one.
struct StoneToolbarItem<Content: View>: ToolbarContent {
    let placement: ToolbarItemPlacement
    private let content: Content

    init(placement: ToolbarItemPlacement, @ViewBuilder content: () -> Content) {
        self.placement = placement
        self.content = content()
    }

    var body: some ToolbarContent {
        if #available(iOS 26, macOS 26, *) {
            ToolbarItem(placement: placement) { content }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: placement) { content }
        }
    }
}

/// The sidebar toggle without the glass plate the system draws behind its
/// own. The split view gives its own up (`.toolbar(removing:
/// .sidebarToggle)`) and this stands in with the same label and ⌃⌘S.
/// `systemShowsSidebar` is the iPad split view's own state, which a
/// visibility of `.automatic` hides from SwiftUI. In the iPad's layout it
/// sits in the bar's leading group, not `.navigation`, which there can put
/// it among the trailing buttons when the sidebar is hidden.
struct StoneSidebarToggle: ToolbarContent {
    @Binding var visibility: NavigationSplitViewVisibility
    let systemShowsSidebar: () -> Bool?
    @Environment(\.isPadLayout) private var isPadLayout

    private var placement: ToolbarItemPlacement {
        #if os(iOS)
        isPadLayout ? .topBarLeading : .navigation
        #else
        .navigation
        #endif
    }

    var body: some ToolbarContent {
        StoneToolbarItem(placement: placement) {
            Button {
                let showing = Self.isShowing(visibility, system: systemShowsSidebar())
                visibility = showing ? .detailOnly : .all
            } label: {
                Label("Toggle Sidebar", systemImage: "sidebar.leading")
            }
            .buttonStyle(.stoneToolbar)
            .keyboardShortcut("s", modifiers: [.command, .control])
            .help("Show or Hide Sidebar")
        }
    }

    /// Whether the sidebar shows. The split view's own state wins where it
    /// can be read; otherwise the visibility says, and `.automatic` is
    /// what the platform shows.
    static func isShowing(_ visibility: NavigationSplitViewVisibility, system: Bool?) -> Bool {
        if let system { return system }
        if visibility == .automatic { return PlatformCapabilities.current.automaticallyShowsSidebar }
        return visibility != .detailOnly
    }
}

#if os(iOS)
/// Reads the display mode of the `UISplitViewController` behind a
/// `NavigationSplitView`. On the iPad `.automatic` leaves the sidebar shown
/// or hidden by the window's shape, and Stage Manager and odd window sizes
/// make that shape no guide, so the toggle asks the split view itself.
final class SplitViewProbe {
    fileprivate weak var controller: UIViewController?

    /// Whether the sidebar shows, or nil before the split view is found.
    func sidebarIsShowing() -> Bool? {
        controller?.splitViewController.map { $0.displayMode != .secondaryOnly }
    }
}

private struct SplitViewProbeView: UIViewControllerRepresentable {
    let probe: SplitViewProbe

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        probe.controller = controller
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        probe.controller = controller
    }
}
#else
final class SplitViewProbe {
    /// The Mac's `.automatic` always shows the sidebar: nothing to read.
    func sidebarIsShowing() -> Bool? {
        nil
    }
}
#endif

extension View {
    /// Lets `probe` read the split view this view is a column of.
    @ViewBuilder
    func probingSplitView(_ probe: SplitViewProbe) -> some View {
        #if os(iOS)
        background { SplitViewProbeView(probe: probe).frame(width: 0, height: 0) }
        #else
        self
        #endif
    }

    /// A toolbar menu as an icon-only stone button, like the buttons beside it.
    func stoneToolbarMenu() -> some View {
        menuStyle(.button)
            .buttonStyle(.stoneToolbar)
            .menuIndicator(.hidden)
    }
}

/// An icon-only toolbar button: the icon in primary ink on the bar, a stone
/// square while the pointer is over it, a darker one while pressed. 30 pt on
/// the Mac, 40 pt in the iPad's layout (an iPhone in the split layout
/// too), 44 pt in the phone's.
struct StoneToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StoneToolbarButton(configuration: configuration)
    }
}

extension ButtonStyle where Self == StoneToolbarButtonStyle {
    static var stoneToolbar: StoneToolbarButtonStyle {
        StoneToolbarButtonStyle()
    }
}

private struct StoneToolbarButton: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false
    #if os(iOS)
    @Environment(\.isPadLayout) private var isPadLayout
    #endif

    #if os(macOS)
    private let side: CGFloat = 30
    private let radius: CGFloat = 7
    #else
    private var side: CGFloat {
        isPadLayout ? 40 : 44
    }

    private let radius: CGFloat = 9
    #endif

    var body: some View {
        configuration.label
            .labelStyle(.iconOnly)
            .imageScale(.large)
            .foregroundStyle(Color.aicovenTextPrimary)
            .frame(width: side, height: side)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill)
            )
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { isHovering = $0 }
    }

    private var fill: Color {
        if configuration.isPressed { return .aicovenRule }
        return isHovering ? .aicovenSurface : .clear
    }
}

// MARK: - The bar behind a title

/// The hairline at a bar's edge, in the rule tone. Increase Contrast draws it
/// in the stronger border tone.
struct StoneHairline: View {
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        (contrast == .increased ? Color.aicovenBorder : Color.aicovenRule)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

extension View {
    /// On the Mac, a window's toolbar as solid chrome with a hairline under
    /// it, and the content scrolling below it, not under it.
    @ViewBuilder
    func stoneWindowBar() -> some View {
        #if os(macOS)
        toolbarBackground(Color.aicovenChrome, for: .windowToolbar)
            .toolbarBackground(.visible, for: .windowToolbar)
            .safeAreaInset(edge: .top, spacing: 0) { StoneHairline() }
        #else
        self
        #endif
    }
}

// MARK: - App-wide appearance

enum StoneChrome {
    /// Called once at launch.
    static func configure() {
        #if os(iOS)
        configureBars()
        #elseif os(macOS)
        // The scroll bar style follows the system setting, "Automatically
        // based on mouse or trackpad", which falls back to the thick
        // classic bars on a Mac without a trackpad. The app's own value
        // overrides the system's for this app only.
        UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")
        #endif
    }

    #if os(iOS)
    /// A colour that resolves against the bar's own traits, so the bars
    /// follow light and dark, and Increase Contrast, live.
    private static func dynamic(_ color: @escaping (UITraitCollection) -> Color) -> UIColor {
        UIColor { UIColor(color($0)).resolvedColor(with: $0) }
    }

    /// Solid chrome behind every navigation bar, with a hairline at its
    /// edge: no blur, no glass, no scroll-edge fade.
    private static func configureBars() {
        let chrome = dynamic { _ in .aicovenChrome }
        let hairline = dynamic { $0.accessibilityContrast == .high ? .aicovenBorder : .aicovenRule }

        let bar = UINavigationBarAppearance()
        bar.configureWithOpaqueBackground()
        bar.backgroundColor = chrome
        bar.shadowColor = hairline
        bar.titleTextAttributes = [.foregroundColor: UIColor.label]
        bar.largeTitleTextAttributes = [.foregroundColor: UIColor.label]
        let navigationBar = UINavigationBar.appearance()
        navigationBar.standardAppearance = bar
        navigationBar.compactAppearance = bar
        navigationBar.scrollEdgeAppearance = bar
        navigationBar.compactScrollEdgeAppearance = bar
    }
    #endif
}
