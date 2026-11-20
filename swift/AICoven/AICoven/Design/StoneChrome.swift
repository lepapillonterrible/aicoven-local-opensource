import SwiftUI

// The stone chrome, as the cloud app draws it. Built with the iOS 26 and
// macOS 26 SDKs, the system draws glass behind toolbar buttons and blurs the
// bar behind a title. The app draws its window bar in the chrome tone with a
// hairline and its toolbar buttons as plain ink. Menus and alerts stay the
// system's.

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
struct StoneSidebarToggle: ToolbarContent {
    @Binding var visibility: NavigationSplitViewVisibility

    var body: some ToolbarContent {
        StoneToolbarItem(placement: .navigation) {
            Button {
                visibility = Self.isShowing(visibility) ? .detailOnly : .all
            } label: {
                Label("Toggle Sidebar", systemImage: "sidebar.leading")
            }
            .buttonStyle(.stoneToolbar)
            .keyboardShortcut("s", modifiers: [.command, .control])
            .help("Show or Hide Sidebar")
        }
    }

    /// Whether the sidebar shows: unless the split view shows the detail
    /// only (the Mac's `.automatic` shows the sidebar).
    static func isShowing(_ visibility: NavigationSplitViewVisibility) -> Bool {
        visibility != .detailOnly
    }
}

/// An icon-only toolbar button: the icon in primary ink on the bar, a stone
/// square while the pointer is over it, a darker one while pressed. 30 pt on
/// the Mac, 44 pt on touch.
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

    #if os(macOS)
    private let side: CGFloat = 30
    private let radius: CGFloat = 7
    #else
    private let side: CGFloat = 44
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
