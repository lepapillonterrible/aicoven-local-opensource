internal import Combine
import SwiftUI
import UniformTypeIdentifiers

/// A scope's assets, as the cloud app's library. On the iPhone and iPad: a
/// list with the system search field, a Filter menu, what is proposed
/// first under "Needs review", and each row pushing the asset. On the Mac:
/// a table, with the selected asset in an inspector; double-click or
/// Return opens it full size in a sheet and Space previews its file in
/// Quick Look.
struct AssetLibraryView: View {
    @StateObject private var model: AssetLibraryModel
    /// Quick Look and the exporter for what a row's menu or Space opens.
    @StateObject private var files = AssetFiles()
    @State private var isCreating = false
    @State private var isOnScreen = false
    /// The asset open full size: pushed on the iPhone and iPad, a sheet on the Mac.
    @State private var openID: Asset.ID?
    /// The asset being sent to an agent from its row's menu.
    @State private var sending: Asset?
    #if os(macOS)
    /// List or Grid, as the cloud Mac's library: the window's own choice.
    @SceneStorage(AssetLibraryRules.layoutKey) private var layout = AssetLibraryLayout.list
    /// How many cards a row of the grid holds, as it is laid out now.
    @State private var gridColumns = 1
    #endif
    #if os(macOS)
    /// The row selected in the table, shown in the inspector.
    @State private var selectedID: Asset.ID?
    #endif
    /// Whether Try Again is reading: it says so, and is not pressed twice.
    @State private var isRetrying = false
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// What the search reads, said before a search starts.
    static let searchScope = "Search runs on this device. It reads titles, descriptions, and file names."

    /// Asks this place to show an asset (from its card in a thread), and
    /// opens the thread an asset was made in.
    @ObservedObject private var navigator: ShellNavigator
    private let covenID: String?

    init(covenID: String?, navigator: ShellNavigator) {
        self.covenID = covenID
        self.navigator = navigator
        _model = StateObject(wrappedValue: AssetLibraryModel(covenID: covenID))
    }

    /// Shows the asset this place was asked for, once its assets are
    /// read: a search or a filter that hides it is cleared.
    private func showWhatWasAsked() {
        guard model.hasRead, let id = navigator.takeAssetAsk(in: ShellScope(covenID: covenID)) else { return }
        guard let asset = model.assets.first(where: { $0.id == id }) else { return }
        let shown = model.shown
        if !(shown.needsReview + shown.others).contains(where: { $0.id == id }) {
            model.clearSearchAndFilters()
            // What is archived is shown only where it is asked for.
            if asset.status == .archived { model.statusFilter = .archived }
        }
        #if os(macOS)
        selectedID = id
        #else
        openID = id
        #endif
    }

    /// Opens the thread an asset was made in, leaving whatever of this
    /// place is over it.
    private func open(_ thread: Thread) {
        openID = nil
        navigator.open(thread)
    }

    var body: some View {
        content
            .searchable(text: $model.search, placement: searchPlacement, prompt: "Search assets")
            .toolbar { toolbarContent }
            .sheet(isPresented: $isCreating) {
                NewAssetSheet(model: model) { made in
                    #if os(macOS)
                    selectedID = made.id
                    #else
                    openID = made.id
                    #endif
                }
            }
            .presenting(files)
            .sheet(item: $sending) { asset in
                AssetHandoffSheet(asset: asset) { thread in
                    sending = nil
                    open(thread)
                }
            }
        #if os(macOS)
            .sheet(item: Binding(get: { openID.map(OpenAsset.init) }, set: { openID = $0?.id })) { open in
                NavigationStack {
                    page(of: open.id)
                        .navigationTitle("Asset")
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { openID = nil }
                            }
                        }
                }
                .frame(minWidth: 560, idealWidth: 640, minHeight: 520, idealHeight: 600)
            }
        #else
            .navigationDestination(item: $openID) { id in
                page(of: id)
                    .navigationTitle("Asset")
                    .navigationBarTitleDisplayMode(.inline)
                    .stoneBackButton()
            }
        #endif
            .task {
                await model.load()
                showWhatWasAsked()
            }
            .onChange(of: navigator.assetAsked) { showWhatWasAsked() }
            .onChange(of: model.hasRead) { showWhatWasAsked() }
            // An agent made or changed an asset, or the person approved one
            // from its card in a thread, while this place is open.
            .onReceive(NotificationCenter.default.publisher(for: Asset.didChange).receive(on: RunLoop.main)) { _ in
                Task { await model.load() }
            }
            .onAppear { isOnScreen = true }
            .onDisappear { isOnScreen = false }
            .onChange(of: model.actionFailure) { _, failed in
                // What went wrong with an asset is said to VoiceOver once,
                // here, whether it was asked from a row's menu or from the
                // asset's page (which covers this place on the iPhone).
                if let failed, isOnScreen || openID != nil {
                    AccessibilityNotification.Announcement(failed.words).post()
                }
            }
            .onChange(of: model.loadFailures) {
                // Said to VoiceOver too, while the place is on screen: each
                // failed reading, also one that fails after another did.
                if isOnScreen {
                    AccessibilityNotification.Announcement(model.hasRead ? AssetLibraryModel.couldNotRefresh : "Couldn't load assets.").post()
                }
            }
    }

    #if os(iOS)
    /// On a compact screen the field is pinned under the navigation bar, so
    /// it shows without pulling the list down.
    private var searchPlacement: SearchFieldPlacement {
        horizontalSizeClass == .compact ? .navigationBarDrawer(displayMode: .always) : .automatic
    }
    #else
    private var searchPlacement: SearchFieldPlacement {
        .automatic
    }
    #endif

    @ViewBuilder
    private var content: some View {
        if model.hasRead {
            // Drawn again each minute, so that "5m ago" does not go stale
            // while the place stays open.
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                listed(now: timeline.date)
            }
        } else if model.loadFailed {
            ContentUnavailableView {
                Label("Couldn't Load Assets", systemImage: "exclamationmark.triangle")
            } description: {
                Text("AICoven couldn't read the assets kept on this device.")
            } actions: {
                Button("Try Again") {
                    isRetrying = true
                    Task {
                        await model.load()
                        isRetrying = false
                    }
                }
                .disabled(isRetrying)
                if isRetrying {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Reading the assets")
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func listed(now: Date) -> some View {
        #if os(macOS)
        Group {
            if layout == .grid {
                grid
            } else {
                table(now: now)
            }
        }
        .overlay { emptyState }
        .safeAreaInset(edge: .bottom) {
            footer
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.md)
        }
        .onKeyPress(.space) {
            guard let file = selected?.files.first, selected?.isUnreadable == false else { return .ignored }
            Task { await files.look(at: file) }
            return .handled
        }
        .inspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selectedID = nil } })) {
            if let selected {
                AssetDetailView(asset: selected, model: model, sharing: files.turn, onOpenThread: open)
                    .id(selected.id)
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
            }
        }
        #else
        list(now: now)
            .overlay { emptyState }
        #endif
    }

    /// An asset's page; one that is gone says so.
    @ViewBuilder
    private func page(of id: Asset.ID) -> some View {
        if let asset = model.assets.first(where: { $0.id == id }) {
            AssetDetailView(asset: asset, model: model, sharing: files.turn, onOpenThread: open)
        } else {
            ContentUnavailableView("This asset is no longer here", systemImage: "tray")
        }
    }

    #if os(macOS)
    /// The asset selected in the table, as it is listed now.
    private var selected: Asset? {
        selectedID.flatMap { id in model.assets.first { $0.id == id } }
    }
    #endif

    /// What a long press or a right click on an asset offers.
    @ViewBuilder
    private func menu(for asset: Asset) -> some View {
        Button {
            openID = asset.id
        } label: {
            Label("Open", systemImage: "arrow.up.forward.square")
        }
        ForEach(AssetLibraryRules.reviewActions(asset) + AssetLibraryRules.otherActions(asset)) { action in
            Button {
                switch action {
                case .download:
                    guard let file = asset.files.first else { return }
                    Task { await files.download(file) }
                case .sendToAgent:
                    sending = asset
                case .copyReference:
                    _ = ThreadMarkdownExport.writeClipboard(AssetLibraryRules.reference(to: asset))
                default:
                    let account = UserScope.currentUserID
                    Task { await model.perform(action, on: asset, as: account) }
                }
            } label: {
                Label(action.title, systemImage: action.iconSystemName)
            }
            .disabled(action == .download ? files.preparing != nil : action.status != nil && model.changing.contains(asset.id))
        }
    }

    /// An asset's title as a row shows it: one the key cannot open has none.
    private func title(_ asset: Asset) -> String {
        asset.isUnreadable ? AssetLibraryRules.unreadable : asset.title
    }

    // MARK: - iPhone and iPad

    #if os(iOS)
    private func list(now: Date) -> some View {
        let shown = model.shown
        return List {
            Section {
                Button {
                    isCreating = true
                } label: {
                    Label("New Asset…", systemImage: "plus.square.fill")
                }
            }
            .listRowBackground(Color.aicovenSurfaceElevated)

            if let summary = AssetLibraryRules.filterSummary(type: model.typeFilter, status: model.statusFilter) {
                Section {
                    HStack {
                        Text(summary)
                            .foregroundStyle(Color.aicovenTextSecondary)
                        Spacer()
                        Button("Clear") {
                            model.typeFilter = nil
                            model.statusFilter = nil
                        }
                    }
                }
                .listRowBackground(Color.aicovenSurfaceElevated)
            }

            if !shown.needsReview.isEmpty {
                Section("Needs review · \(shown.needsReview.count)") {
                    ForEach(shown.needsReview) { row($0, now: now) }
                }
                .listRowBackground(Color.aicovenSurfaceElevated)
            }

            Section {
                ForEach(shown.others) { row($0, now: now) }
            } header: {
                if !shown.needsReview.isEmpty, !shown.others.isEmpty {
                    Text("Everything else")
                }
            } footer: {
                footer
            }
            .listRowBackground(Color.aicovenSurfaceElevated)
        }
        .scrollContentBackground(.hidden)
        .background(Color.aicovenSurface)
        .refreshable { await model.load() }
    }

    private func row(_ asset: Asset, now: Date) -> some View {
        Button {
            openID = asset.id
        } label: {
            HStack(spacing: Spacing.sm) {
                AssetThumbnail(asset: asset, width: 40, height: 40)
                VStack(alignment: .leading, spacing: Spacing.xxxs) {
                    Text(title(asset))
                        .foregroundStyle(Color.aicovenTextPrimary)
                    Text(AssetLibraryRules.quietLine(asset, agents: model.agents, now: now))
                        .font(.aicovenBodySmall)
                        .foregroundStyle(Color.aicovenTextSecondary)
                }
                Spacer(minLength: Spacing.xs)
                Image(systemName: "chevron.right")
                    .font(.aicovenCaption.weight(.semibold))
                    .foregroundStyle(Color.aicovenTextTertiary)
            }
            .opacity(asset.status == .archived ? 0.75 : 1)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.plain)
        .contextMenu { menu(for: asset) }
    }
    #endif

    // MARK: - Mac

    #if os(macOS)
    private func table(now: Date) -> some View {
        let shown = model.shown
        return Table(shown.needsReview + shown.others, selection: $selectedID) {
            TableColumn("Asset") { asset in
                HStack(spacing: Spacing.sm) {
                    AssetThumbnail(asset: asset, width: 28, height: 21)
                    Text(title(asset))
                }
            }
            .width(min: 180, ideal: 280)
            TableColumn("Type") { asset in
                Text(asset.type.displayName)
                    .foregroundStyle(Color.aicovenTextSecondary)
            }
            .width(min: 90, ideal: 120)
            TableColumn("Made by") { asset in
                Text(AssetLibraryRules.madeBy(asset, agents: model.agents))
                    .foregroundStyle(Color.aicovenTextSecondary)
            }
            .width(min: 80, ideal: 110)
            TableColumn("Status") { asset in
                Text(AssetLibraryRules.statusLabel(asset))
                    .foregroundStyle(asset.status == .proposed && !asset.isUnreadable ? Color.aicovenTextPrimary : Color.aicovenTextSecondary)
            }
            .width(min: 70, ideal: 90)
            TableColumn("Updated") { asset in
                Text(AssetLibraryRules.shortTime(asset.updatedAt, now: now))
                    .foregroundStyle(Color.aicovenTextSecondary)
            }
            .width(min: 60, ideal: 80)
        }
        .alternatingRowBackgrounds(.disabled)
        .scrollContentBackground(.hidden)
        .background(Color.aicovenSurface)
        .contextMenu(forSelectionType: Asset.ID.self) { ids in
            if let asset = ids.first.flatMap({ id in model.assets.first { $0.id == id } }) {
                menu(for: asset)
            }
        } primaryAction: { ids in
            openID = ids.first
        }
    }

    /// The cloud Mac's grid: each asset a card with its picture, under
    /// "Needs review" and "Everything else". A click selects (its page is
    /// then in the inspector), a double click or Return opens it.
    private var grid: some View {
        let shown = model.shown
        let ids = (shown.needsReview + shown.others).map(\.id)
        return ScrollViewReader { scroller in
            gridCards(shown)
                // The arrow keys choose a card (the first where none is
                // chosen), Return opens it and Space previews it, as in the table.
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                    let step = switch press.key {
                    case .leftArrow: -1
                    case .rightArrow: 1
                    case .upArrow: -gridColumns
                    default: gridColumns
                    }
                    guard let next = AssetLibraryRules.chosen(after: selectedID, movingBy: step, among: ids) else { return .ignored }
                    selectedID = next
                    scroller.scrollTo(next)
                    return .handled
                }
                .onKeyPress(.return) {
                    guard let chosen = selectedID ?? ids.first else { return .ignored }
                    selectedID = chosen
                    openID = chosen
                    return .handled
                }
        }
    }

    private func gridCards(_ shown: (needsReview: [Asset], others: [Asset])) -> some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(
                    .adaptive(minimum: AssetLibraryRules.gridCard.lowerBound, maximum: AssetLibraryRules.gridCard.upperBound), spacing: Spacing.md,
                    alignment: .top
                )],
                alignment: .leading, spacing: Spacing.md
            ) {
                if !shown.needsReview.isEmpty {
                    Section {
                        ForEach(shown.needsReview) { card($0) }
                    } header: {
                        gridHeader("Needs review · \(shown.needsReview.count)")
                    }
                }
                Section {
                    ForEach(shown.others) { card($0) }
                } header: {
                    if !shown.needsReview.isEmpty, !shown.others.isEmpty {
                        gridHeader("Everything else")
                    }
                }
            }
            .padding(Spacing.md)
            // How many cards a row holds, for the up and down arrows.
            .background(GeometryReader { proxy in
                Color.clear
                    .onAppear { gridColumns = AssetLibraryRules.gridColumns(width: proxy.size.width - 2 * Spacing.md, spacing: Spacing.md) }
                    .onChange(of: proxy.size.width) { _, width in
                        gridColumns = AssetLibraryRules.gridColumns(width: width - 2 * Spacing.md, spacing: Spacing.md)
                    }
            })
        }
        .background(Color.aicovenSurface)
        .focusable()
        .focusEffectDisabled()
    }

    private func gridHeader(_ words: String) -> some View {
        Text(words)
            .font(.aicovenBodySmall.weight(.semibold))
            .foregroundStyle(Color.aicovenTextSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    private func card(_ asset: Asset) -> some View {
        let isSelected = selectedID == asset.id
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            AssetThumbnail(asset: asset)
                .overlay(
                    RoundedRectangle(cornerRadius: BorderRadius.xs)
                        .strokeBorder(Color.accentColor, lineWidth: isSelected ? 3 : 0)
                )
            Text(title(asset))
                .font(.aicovenBody.weight(.semibold))
                .foregroundStyle(Color.aicovenTextPrimary)
                .lineLimit(2)
            Text(AssetLibraryRules.gridLine(asset, agents: model.agents))
                .font(.aicovenBodySmall)
                .foregroundStyle(Color.aicovenTextSecondary)
                .lineLimit(1)
        }
        .opacity(asset.status == .archived ? 0.75 : 1)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { openID = asset.id }
        .simultaneousGesture(TapGesture().onEnded { selectedID = asset.id })
        .contextMenu { menu(for: asset) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { selectedID = asset.id }
        .accessibilityAction(named: "Open") { openID = asset.id }
        .id(asset.id)
    }

    /// The asset open full size, as a sheet takes it.
    private struct OpenAsset: Identifiable {
        let id: Asset.ID
    }
    #endif

    // MARK: - Shared pieces

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        StoneToolbarItem(placement: .primaryAction) {
            filterMenu
                .stoneToolbarMenu()
        }
        #if os(macOS)
        StoneToolbarItem(placement: .primaryAction) {
            Picker("Layout", selection: $layout) {
                ForEach(AssetLibraryLayout.allCases) { layout in
                    Text(layout.title).tag(layout)
                }
            }
            .pickerStyle(.segmented)
            .help("Layout")
        }
        StoneToolbarItem(placement: .primaryAction) {
            Button("New Asset…") { isCreating = true }
        }
        #endif
    }

    /// Type and Status, each applying when picked.
    private var filterMenu: some View {
        Menu {
            Picker("Type", selection: $model.typeFilter) {
                Text("All Types").tag(AssetType?.none)
                ForEach(AssetType.offered, id: \.rawValue) { type in
                    Text(type.displayName).tag(AssetType?.some(type))
                }
            }
            Picker("Status", selection: $model.statusFilter) {
                // With no status chosen, what is archived is left out: the
                // choice is named for what it shows.
                Text(AssetLibraryRules.noStatusChosen).tag(AssetStatus?.none)
                ForEach(AssetStatus.allCases, id: \.rawValue) { status in
                    Text(status.displayName).tag(AssetStatus?.some(status))
                }
            }
        } label: {
            Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
        }
    }

    @ViewBuilder
    private var footer: some View {
        if model.loadFailed || model.actionFailure != nil || files.said != nil {
            // What failed: a refresh (the list stays as it was read
            // before), the last thing asked of an asset, or a file.
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                ForEach([model.loadFailed ? AssetLibraryModel.couldNotRefresh : nil, model.actionFailure?.words, files.said].compactMap(\.self), id: \.self) {
                    Text($0)
                }
            }
            .font(.aicovenBodySmall)
            .foregroundStyle(Color.aicovenError)
        } else {
            #if os(macOS)
            HStack(spacing: Spacing.sm) {
                Text(Self.searchScope)
                    .font(.aicovenBodySmall)
                    .foregroundStyle(Color.aicovenTextSecondary)
                if let summary = AssetLibraryRules.filterSummary(type: model.typeFilter, status: model.statusFilter) {
                    Spacer()
                    Text(summary)
                        .font(.aicovenBodySmall)
                        .foregroundStyle(Color.aicovenTextSecondary)
                    Button("Clear") {
                        model.typeFilter = nil
                        model.statusFilter = nil
                    }
                    .buttonStyle(.link)
                }
            }
            #else
            Text(Self.searchScope)
                .font(.aicovenBodySmall)
            #endif
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        let shown = model.shown
        if shown.needsReview.isEmpty, shown.others.isEmpty {
            if model.isNarrowed {
                ContentUnavailableView {
                    Label("No Matching Assets", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("Nothing matches the search and filters.")
                } actions: {
                    Button("Clear Search and Filters") { model.clearSearchAndFilters() }
                }
            } else {
                ContentUnavailableView {
                    Label("No Assets Yet", systemImage: "photo.on.rectangle")
                } description: {
                    Text("Mockups, charts, datasets, and briefs your agents make land here, so they aren't lost in a thread.")
                }
            }
        }
    }
}

/// The well an asset's thumbnail sits in, as the cloud app draws it before
/// there is a picture: the type's symbol, or its short tag where the well
/// is small; a lock for an asset the key cannot open.
struct AssetThumbnail: View {
    let asset: Asset
    /// Its size; with none it fills the width it is given, at 4:3.
    var width: CGFloat?
    var height: CGFloat?
    /// The asset's picture, once drawn (`AssetThumbnails`): of its latest
    /// picture or PDF. Any other asset keeps its type's well. Kept with
    /// what it was drawn for (the files, and the thumbnails' generation):
    /// it is shown only while that is still what the view asks for, so a
    /// picture is gone at once when the thumbnails are forgotten, and one
    /// drawn for an earlier file never shows over a later one's.
    @State private var drawn: (key: String, picture: CGImage)?
    @ObservedObject private var thumbnails = AssetThumbnails.shared

    private var key: String {
        "\(AssetThumbnails.key(of: asset))#\(thumbnails.generation)"
    }

    private var picture: CGImage? {
        drawn?.key == key ? drawn?.picture : nil
    }

    private var type: AssetType {
        asset.type
    }

    private var isLocked: Bool {
        asset.isUnreadable
    }

    @ViewBuilder
    private var well: some View {
        if let width, let height {
            Color.aicovenSurfaceElevated.frame(width: width, height: height)
        } else {
            Color.aicovenSurfaceElevated.aspectRatio(4 / 3, contentMode: .fit)
        }
    }

    var body: some View {
        well
            .overlay {
                if let picture, !isLocked {
                    Image(decorative: picture, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else if isLocked {
                    Image(systemName: "lock")
                        .font(.system(size: glyphSize, weight: .semibold))
                        .foregroundStyle(Color.aicovenTextSecondary)
                } else if (height ?? 40) >= 40 {
                    Image(systemName: type.iconSystemName)
                        .font(.system(size: glyphSize))
                        .foregroundStyle(Color.aicovenTextTertiary)
                } else {
                    Text(type.thumbnailTag)
                        .font(.aicovenCaption.weight(.semibold))
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .foregroundStyle(Color.aicovenTextTertiary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: BorderRadius.xs))
            .overlay(
                RoundedRectangle(cornerRadius: BorderRadius.xs)
                    .strokeBorder(Color.aicovenBorder, lineWidth: 1)
            )
            .accessibilityHidden(true)
            // Drawn for the files it can be drawn from: again when they
            // change (a newer file, an asset the key can open again) and
            // when the thumbnails were forgotten.
            .task(id: key) {
                let asked = key
                // A picture drawn for something else (another file, or
                // before the thumbnails were forgotten) is let go of, not
                // only hidden: the view holds nothing it does not show.
                if drawn?.key != asked { drawn = nil }
                guard let picture = await thumbnails.picture(of: asset, as: UserScope.currentUserID), !Task.isCancelled else { return }
                drawn = (asked, picture)
            }
    }

    private var glyphSize: CGFloat {
        guard let width, let height else { return 34 }
        return min(width, height) * 0.42
    }
}

/// New Asset, as the cloud app's sheet with what a device alone needs: a
/// title, a type, a description and one file. There is no thread to choose
/// and no "Who can read": nothing leaves this device.
private struct NewAssetSheet: View {
    @ObservedObject var model: AssetLibraryModel
    /// Told of the asset that was made, as the sheet is asked to close on it.
    let onMade: (Asset) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var type: AssetType = .image
    @State private var details = ""
    @State private var file: AssetRepository.NewFile?
    @State private var isChoosingFile = false
    /// Whether the chosen file is being read: Create waits for it.
    @State private var isReadingFile = false
    /// Whether the sheet is up: a file read after it has gone says nothing.
    @State private var isShown = false
    /// The account the file chooser was put up for.
    @State private var choosingAs: String?
    @State private var failure: String?

    #if os(iOS)
    private static let descriptionPrompt = "Description (optional)"
    #else
    private static let descriptionPrompt = "Optional"
    #endif

    private var canCreate: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && file != nil && !model.isCreating && !isReadingFile
    }

    var body: some View {
        NavigationStack {
            SettingsForm {
                Section {
                    FormTextField(label: "Title", text: $title, prompt: "Required")
                    Picker("Type", selection: $type) {
                        ForEach(AssetType.offered, id: \.rawValue) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    // iOS forms show only a field's prompt, so there it names the field too.
                    TextField("Description", text: $details, prompt: Text(Self.descriptionPrompt), axis: .vertical)
                        .lineLimit(3 ... 8)
                }
                .disabled(model.isCreating)

                Section {
                    Button {
                        choosingAs = UserScope.currentUserID
                        isChoosingFile = true
                    } label: {
                        Label(file.map { AssetFile.keptName($0.name) } ?? "Choose File…", systemImage: "plus.square.fill")
                    }
                    .disabled(model.isCreating || isReadingFile)
                } footer: {
                    Group {
                        if let failure {
                            Text(failure)
                                .foregroundStyle(Color.aicovenError)
                        } else {
                            Text("Up to 10 MB.")
                        }
                    }
                    .font(.aicovenBodySmall)
                }
            }
            .navigationTitle("New Asset")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .disabled(model.isCreating)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if model.isCreating {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("Creating the asset")
                        } else {
                            Button("Create", action: create)
                                .disabled(!canCreate)
                        }
                    }
                }
                .fileImporter(isPresented: $isChoosingFile, allowedContentTypes: [.data], allowsMultipleSelection: false, onCompletion: receive)
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 360)
        #endif
        .interactiveDismissDisabled(model.isCreating)
        .onAppear { isShown = true }
        .onDisappear { isShown = false }
    }

    /// Takes the file the person chose, or says why it was not taken.
    private func receive(_ result: Result<[URL], Error>) {
        // The chooser's answer is for whoever put it up, in this sheet:
        // nothing of it is kept or said once either has gone.
        let account = UserScope.currentUserID
        guard isShown, choosingAs == account else { return }
        switch result {
        case let .success(files):
            guard let chosen = files.first else { return }
            // Read away from the main actor: a large file, or one a file
            // provider has to fetch, does not hold the sheet up.
            isReadingFile = true
            Task {
                let read = await Task.detached { Result { try AssetFileChoice.read(chosen) } }.value
                isReadingFile = false
                // Read for whoever chose it, in the sheet they chose it in:
                // nothing of it is kept or said once either has gone.
                guard isShown, UserScope.currentUserID == account else { return }
                switch read {
                case let .success(read):
                    file = read
                    failure = nil
                case let .failure(error):
                    // A file chosen before is not kept under the failure of
                    // the one chosen after it.
                    file = nil
                    say(AssetLibraryModel.words(forNotCreating: error))
                }
            }
        case let .failure(error):
            // Closing the chooser is no failure; anything else is said.
            if (error as? CocoaError)?.code != .userCancelled { say(AssetLibraryModel.couldNotOpenFile) }
        }
    }

    /// Makes the asset for the account that pressed Create.
    private func create() {
        guard canCreate, let file else { return }
        failure = nil
        let account = UserScope.currentUserID
        let new = AssetLibraryModel.NewAsset(type: type, title: title, details: details, file: file)
        Task {
            switch await model.create(new, as: account) {
            case let .made(asset):
                AccessibilityNotification.Announcement("Asset created").post()
                dismiss()
                onMade(asset)
            case let .failed(words):
                say(words)
            case nil:
                // Another account is signed in, or one was being made already.
                break
            }
        }
    }

    private func say(_ words: String) {
        failure = words
        AccessibilityNotification.Announcement(words).post()
    }
}
