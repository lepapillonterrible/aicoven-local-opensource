import SwiftUI
#if os(iOS)
import UIKit
#endif

/// What differs between the platforms the layouts turn on, as rules that
/// can be tested apart from any view. Side-effect free.
nonisolated struct PlatformCapabilities: Equatable {
    enum Platform: Equatable {
        case iOS
        case macOS
    }

    let platform: Platform

    /// For tests; the app asks `current`.
    init(platform: Platform) {
        self.platform = platform
    }

    /// The platform the app was compiled for.
    static var current: PlatformCapabilities {
        #if os(macOS)
        PlatformCapabilities(platform: .macOS)
        #else
        PlatformCapabilities(platform: .iOS)
        #endif
    }

    /// Whether a multi-line (vertical-axis) text field submits on Return, as on
    /// the Mac. iPhone and iPad type a newline there, so a field that saves on
    /// Return stays a single line.
    var submitsMultilineFieldOnReturn: Bool {
        platform == .macOS
    }

    /// The iPad. It shares iOS with the iPhone, but some layouts differ
    /// between them in the same size class.
    @MainActor static var isPad: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
        #else
        false
        #endif
    }

    /// An iPhone, including a foldable one when open.
    @MainActor static var isPhone: Bool {
        current.platform == .iOS && !isPad
    }

    /// Whether the shell is the split layout (sidebar and content) rather
    /// than the phone's. An iPhone has it only when both size classes are
    /// regular, as an open foldable one is; a large iPhone in landscape is
    /// regular wide and compact tall, and stays on the phone's layout.
    /// Elsewhere the horizontal size class decides: the iPad is split
    /// unless compact, and the Mac, which has none, always is.
    static func usesSplitLayout(
        isPhone: Bool,
        horizontal: UserInterfaceSizeClass?,
        vertical: UserInterfaceSizeClass?
    ) -> Bool {
        isPhone ? horizontal == .regular && vertical == .regular : horizontal != .compact
    }

    /// Whether a split view whose sidebar visibility is `.automatic` shows
    /// the sidebar. The Mac's does; the iPad's decides by its window, so
    /// there the split view itself is asked (`SplitViewProbe`).
    var automaticallyShowsSidebar: Bool {
        platform == .macOS
    }
}

extension EnvironmentValues {
    /// Whether controls take the iPad's shape: on an iPad, and on an
    /// iPhone in the split layout. The Mac, and an iPhone in the phone's
    /// layout, are false. `HomeView` sets it from its layout, so a sheet or
    /// popover the shell presents reads the shell's answer and not its own
    /// size class.
    @Entry var isPadLayout = false
}
