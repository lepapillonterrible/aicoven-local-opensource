import SwiftUI

// MARK: - Memory (one page of sections and rows)

/// A scope's Memory as one page, as the cloud app's: its four sections,
/// each a heading with Add at its end, then its entries as rows. Strix's
/// also has About me first, the person's own memory. Rows edit in place;
/// nothing counts.
///
/// A `List`, because the iPhone's swipe actions only exist on a list row; the
/// page draws its own hairlines and has no container.
///
/// It is one scope's for as long as it lives: whoever shows it makes it
/// anew for another scope (`.id`), so what an action of one scope's page
/// comes to is never shown on another's.
struct MemoryPagesView: View {
    /// Whose memory: Strix's (with About me), or a coven's.
    let scope: ShellScope
    /// The scope by name: the coven's, or "Strix".
    let covenName: String

    @EnvironmentObject private var model: MemoryPagesModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var hoveredId: String?
    @FocusState private var focusedRow: String?
    @State private var editingId: String?
    @State private var editDraft = ""
    /// The text the open edit started from; `nil` when no edit is open.
    @State private var editOriginal: String?
    @FocusState private var isFieldFocused: Bool
    /// The entry asking "Forget this?" in its row, and where focus goes then.
    @State private var confirmingIds: Set<String> = []
    @FocusState private var forgetFocus: String?
    @AccessibilityFocusState private var headingFocus: MemorySection?
    @State private var addingTo: MemorySection?
    @State private var newEntry = ""
    @State private var isAdding = false
    /// False once the page has left the screen: what an action of its own
    /// then comes to is said by the page that shows the place, not by it.
    @State private var isOnScreen = false

    /// A section of the page; `page` is `nil` for About me.
    private struct MemorySection: Hashable {
        let page: MemoryPage?

        var title: String {
            page?.title ?? "About me"
        }
    }

    private var isStrix: Bool {
        scope == .strix
    }

    /// Where the four sections' entries are kept.
    private var pagesPlace: MemoryPlace {
        scope.covenID.map(MemoryPlace.coven) ?? .strix
    }

    /// Where a section's entries are kept: About me is the person's own.
    private func place(of section: MemorySection) -> MemoryPlace {
        section.page == nil ? .aboutMe : pagesPlace
    }

    private var sections: [MemorySection] {
        (isStrix ? [MemorySection(page: nil)] : []) + MemoryPage.allCases.map { MemorySection(page: $0) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if model.entries(in: pagesPlace) != nil {
                    if !isStrix {
                        explanationRow
                    }
                    if model.didLoadFail(in: pagesPlace) {
                        pageRow { MemoryLoadFailedLine(place: pagesPlace) }
                    }
                    ForEach(sections, id: \.self) { section in
                        // In Strix the line covers the four sections, so it
                        // sits below About me, which has its own.
                        if isStrix, section.page == MemoryPage.allCases.first {
                            explanationRow
                        }
                        sectionRows(section)
                    }
                } else if model.didLoadFail(in: pagesPlace) {
                    pageRow { MemoryLoadFailedLine(place: pagesPlace) }
                } else {
                    pageRow {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, Spacing.xl)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.aicovenSurface.ignoresSafeArea())
            .onChange(of: editedEntryIsGone) { _, gone in
                if gone { stopEditing() }
            }
            .onChange(of: addingTo) { _, section in
                guard let section else { return }
                // The field sits above the keyboard on the iPhone.
                withAnimation { proxy.scrollTo(addKey(section), anchor: .center) }
            }
        }
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
        .task(id: scope) {
            async let aboutMe: Void = loadAboutMe()
            await model.load(pagesPlace)
            await aboutMe
        }
    }

    /// About me is read with Strix's pages; its section shows loading until it is.
    private func loadAboutMe() async {
        if isStrix {
            await model.load(.aboutMe)
        }
    }

    // MARK: Page

    private var explanationRow: some View {
        pageRow {
            Text(
                isStrix
                    ? "Every agent in \(covenName) reads the sections below, whichever model it runs on. Nothing in them leaves the coven."
                    : "Every agent in \(covenName) reads this page, whichever model it runs on. Nothing on it leaves the coven."
            )
            .font(.aicovenBodySmall)
            .foregroundStyle(Color.aicovenTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, Spacing.xs)
        }
    }

    /// One row of the list, in the page's centred column with no separator or
    /// background of its own.
    private func pageRow(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
            .listRowInsets(EdgeInsets(
                top: 0,
                leading: horizontalSizeClass == .regular ? Spacing.xxl : Spacing.md,
                bottom: 0,
                trailing: horizontalSizeClass == .regular ? Spacing.xxl : Spacing.md
            ))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    // MARK: Sections

    @ViewBuilder
    private func sectionRows(_ section: MemorySection) -> some View {
        let place = place(of: section)
        let entries = model.entries(on: section.page, in: place)
        pageRow {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                // At accessibility text sizes the row can't hold the heading
                // and Add side by side, so Add goes on its own line under it.
                let headingLayout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.xxs))
                    : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Spacing.sm))
                headingLayout {
                    Text(section.title)
                        .font(.aicovenH2)
                        .foregroundStyle(Color.aicovenTextPrimary)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($headingFocus, equals: section)
                    if !dynamicTypeSize.isAccessibilitySize {
                        Spacer(minLength: 0)
                    }
                    if !isAboutMeLoading(section) {
                        addButton(section)
                    }
                }
                if section.page == nil {
                    Text("This is about you. Every agent in \(covenName) reads it, whichever model it runs on; your other covens don't.")
                        .font(.aicovenBodySmall)
                        .foregroundStyle(Color.aicovenTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if entries.isEmpty, let purpose = section.page?.purpose {
                    Text(purpose)
                        .font(.aicovenBodySmall)
                        .foregroundStyle(Color.aicovenTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if section.page == nil, model.didLoadFail(in: .aboutMe) {
                    MemoryLoadFailedLine(place: .aboutMe)
                        .padding(.top, Spacing.xxs)
                } else if isAboutMeLoading(section) {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.top, Spacing.xxs)
                }
            }
            .padding(.top, Spacing.lg)
            .padding(.bottom, Spacing.xs)
        }
        if addingTo == section {
            pageRow { addField(section) }
                .id(addKey(section))
        } else if model.failures[addKey(section)] != nil {
            // An Add begun on an earlier showing of the page, whose field is
            // gone, says here what it came to.
            pageRow {
                failureLine(addKey(section))
                    .padding(.horizontal, Spacing.xs)
                    .padding(.bottom, Spacing.xs)
            }
        }
        ForEach(entries) { entry in
            pageRow { entryRow(entry, in: place) }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button {
                        askToForget(entry)
                    } label: {
                        Label("Forget", systemImage: "trash")
                    }
                    .tint(.aicovenError)
                    .disabled(isLocked(entry))
                    if canEdit(entry) {
                        Button {
                            startEditing(entry)
                        } label: {
                            Label("Edit", systemImage: "pencil.line")
                        }
                        .tint(.aicovenTextSecondary)
                        .disabled(isLocked(entry))
                    }
                }
        }
    }

    // MARK: Entries

    private static let rowMinHeight: CGFloat = PlatformCapabilities.current.platform == .macOS ? 28 : 44

    private var rule: some View {
        Rectangle()
            .fill(Color.aicovenRule)
            .frame(height: 1)
    }

    private func isAboutMeLoading(_ section: MemorySection) -> Bool {
        section.page == nil && model.entries(in: .aboutMe) == nil && !model.didLoadFail(in: .aboutMe)
    }

    /// Whether an open Add or Edit field holds text that isn't saved. Until
    /// it is saved or cancelled, no other Edit, Add or Forget starts.
    private var draftHeld: Bool {
        MemoryDraft.holdsText(
            editing: editOriginal,
            editDraft: editDraft,
            adding: addingTo != nil,
            addDraft: newEntry
        )
    }

    /// Whether the entry being edited has left the list, as after a reload;
    /// its edit state then clears so the draft lock releases.
    private var editedEntryIsGone: Bool {
        guard let editingId, model.entries(in: pagesPlace) != nil,
              !isStrix || model.entries(in: .aboutMe) != nil
        else { return false }
        return !sections.contains { section in
            model.entries(on: section.page, in: place(of: section)).contains { $0.id == editingId }
        }
    }

    /// Whether Edit and Forget on `entry` can't start now.
    private func isLocked(_ entry: Memory) -> Bool {
        draftHeld || model.savingIds.contains(entry.id) || model.forgettingIds.contains(entry.id)
    }

    private func failureLine(_ key: String) -> some View {
        Text(model.failures[key] ?? "")
            .font(.aicovenBodySmall)
            .foregroundStyle(Color.aicovenError)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("memory-row-error")
    }

    /// An entry the account's key could not open is only removed.
    private func canEdit(_ entry: Memory) -> Bool {
        entry.unreadable != true
    }

    private func entryRow(_ entry: Memory, in place: MemoryPlace) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if editingId == entry.id {
                editingRow(entry, in: place)
            } else {
                readingRow(entry, in: place)
            }
            rule
        }
    }

    @ViewBuilder
    private func readingRow(_ entry: Memory, in place: MemoryPlace) -> some View {
        let isConfirming = confirmingIds.contains(entry.id) || model.forgettingIds.contains(entry.id)
        let isRevealed = hoveredId == entry.id || focusedRow == entry.id
        let editable = canEdit(entry)
        let locked = isLocked(entry)
        HStack(alignment: .top, spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                entryText(entry)
                    .accessibilityIdentifier("memory-entry:\(entry.id)")
                if isConfirming {
                    forgetQuestion(entry, in: place)
                }
                if model.failures[entry.id] != nil {
                    failureLine(entry.id)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isRevealed, !isConfirming {
                // The row takes keyboard focus (Return edits, Delete asks to
                // forget); these buttons are for the pointer.
                HStack(spacing: Spacing.sm) {
                    if editable {
                        Button("Edit") { startEditing(entry) }
                            .disabled(locked)
                            .accessibilityIdentifier("memory-entry-edit")
                    }
                    Button("Forget") { askToForget(entry) }
                        .disabled(locked)
                        .accessibilityIdentifier("memory-entry-forget")
                }
                .buttonStyle(.plain)
                .focusable(false)
                .font(.aicovenBodySmall)
                .foregroundStyle(Color.aicovenTextSecondary)
            }
        }
        .padding(.vertical, Spacing.sm)
        .padding(.horizontal, Spacing.xs)
        .frame(minHeight: Self.rowMinHeight, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: BorderRadius.sm)
                .fill(isRevealed || isConfirming ? Color.aicovenSelected : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                hoveredId = entry.id
            } else if hoveredId == entry.id {
                hoveredId = nil
            }
        }
        // The editor replaces this row without an exit event.
        .onDisappear {
            if hoveredId == entry.id { hoveredId = nil }
        }
        // After Edit closes, focusedRow can still name this row while the
        // keyboard is elsewhere, so a click clears it and asks again.
        .onTapGesture {
            focusedRow = nil
            Task { @MainActor in focusedRow = entry.id }
        }
        .focusable()
        .focused($focusedRow, equals: entry.id)
        .focusEffectDisabled()
        .onKeyPress(.return) {
            guard editable, !isConfirming else { return .ignored }
            startEditing(entry)
            return .handled
        }
        // The Mac's Delete key arrives as U+007F, which `.delete` (U+0008) does
        // not match; Forward Delete arrives as `.deleteForward`.
        .onKeyPress(keys: [.delete, .deleteForward, KeyEquivalent("\u{7F}")]) { _ in
            guard !isConfirming else { return .ignored }
            askToForget(entry)
            return .handled
        }
        .contextMenu {
            if editable {
                Button("Edit", systemImage: "pencil.line") { startEditing(entry) }
                    .disabled(locked)
            }
            Button("Forget", systemImage: "trash", role: .destructive) {
                askToForget(entry)
            }
            .disabled(locked)
        }
        .accessibilityElement(children: isConfirming ? .contain : .combine)
        .accessibilityActions {
            if editable, !locked {
                Button("Edit") { startEditing(entry) }
            }
            if !locked {
                Button("Forget") { askToForget(entry) }
            }
        }
    }

    /// "Forget this?" in the row: the entry stays readable above it. It
    /// announces itself and takes focus, on Cancel, when it appears.
    private func forgetQuestion(_ entry: Memory, in place: MemoryPlace) -> some View {
        let isForgetting = model.forgettingIds.contains(entry.id)
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("It comes off this page, and this can't be undone.")
                .font(.aicovenBodySmall)
                .foregroundStyle(Color.aicovenTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Spacing.xs) {
                Button("Cancel") {
                    cancelForget(entry)
                }
                .buttonStyle(.bordered)
                .disabled(isForgetting)
                .focused($forgetFocus, equals: entry.id)
                .onKeyPress(keys: [.return, .space]) { _ in
                    cancelForget(entry)
                    return .handled
                }
                .accessibilityIdentifier("memory-forget-cancel")
                Button("Forget") {
                    forget(entry, in: place)
                }
                .buttonStyle(.borderedProminent)
                .tint(.aicovenError)
                .disabled(isForgetting)
                .onKeyPress(keys: [.return, .space]) { _ in
                    forget(entry, in: place)
                    return .handled
                }
                .accessibilityIdentifier("memory-forget-confirm")
                if isForgetting {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .onAppear {
            // A page opened while the forget is on its way shows it busy
            // without asking again.
            guard !isForgetting else { return }
            forgetFocus = entry.id
            AccessibilityNotification.Announcement("Forget this? It comes off this page, and this can't be undone.").post()
        }
    }

    private func editingRow(_ entry: Memory, in place: MemoryPlace) -> some View {
        let isSaving = model.savingIds.contains(entry.id)
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            fieldBox(
                "Entry",
                text: $editDraft,
                identifier: "memory-entry-field",
                isBusy: isSaving,
                keepsLineBreaks: MemoryDraft.editsInMultilineField(editOriginal ?? "")
            ) {
                save(entry, in: place)
            }
            HStack(spacing: Spacing.xs) {
                Button("Save") {
                    save(entry, in: place)
                }
                .buttonStyle(StonePrimaryButtonStyle())
                .accessibilityIdentifier("memory-entry-save")
                .disabled(isSaving || trimmed(editDraft).isEmpty)
                Button("Cancel") {
                    stopEditing(restoringFocus: true)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("memory-entry-cancel")
                .disabled(isSaving)
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if model.failures[entry.id] != nil {
                failureLine(entry.id)
            }
        }
        .padding(.vertical, Spacing.sm)
        .padding(.horizontal, Spacing.xs)
    }

    /// The text field of an edit or an add: focused when it appears, and Esc
    /// puts the row back unless a save is on its way. On the Mac it grows and
    /// Return saves. On iPhone and iPad it is a single line where Return
    /// saves, except for an edit of an entry that has line breaks
    /// (`keepsLineBreaks`): a single-line field turns them into spaces, so
    /// that one is multi-line, its Return key types a new line, and Save
    /// saves.
    private func fieldBox(
        _ title: String,
        text: Binding<String>,
        identifier: String,
        isBusy: Bool,
        keepsLineBreaks: Bool,
        onSubmit: @escaping () -> Void
    ) -> some View {
        let submitsOnReturn = PlatformCapabilities.current.submitsMultilineFieldOnReturn
        return TextField(title, text: text, axis: submitsOnReturn || keepsLineBreaks ? .vertical : .horizontal)
            .accessibilityIdentifier(identifier)
            .disabled(isBusy)
            .onSubmit(onSubmit)
            .focused($isFieldFocused)
            .onAppear { isFieldFocused = true }
            // Disabling the field while a request runs drops its focus.
            .onChange(of: isBusy) { _, busy in
                if !busy { isFieldFocused = true }
            }
            .onKeyPress(.escape) {
                guard !isBusy else { return .handled }
                stopEditing(restoringFocus: true)
                stopAdding()
                return .handled
            }
            .font(.aicovenBody)
            .lineLimit(1 ... 12)
            .textFieldStyle(.plain)
            .submitLabel(keepsLineBreaks && !submitsOnReturn ? .return : .done)
            .padding(Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: BorderRadius.sm)
                    .fill(Color.aicovenSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: BorderRadius.sm)
                            .strokeBorder(Color.aicovenBorder, lineWidth: 1)
                    )
            )
    }

    private func entryText(_ entry: Memory) -> some View {
        Group {
            if entry.unreadable == true {
                Text("Your encryption key can't open this entry.")
                    .font(.aicovenBody)
                    .foregroundStyle(Color.aicovenTextSecondary)
            } else {
                Text(entry.content)
                    .font(.aicovenBody)
                    .lineSpacing(4)
                    .foregroundStyle(Color.aicovenTextPrimary)
            }
        }
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Add

    /// Where a section's Add is found: its field's place in the list, and
    /// where its failure is said.
    private func addKey(_ section: MemorySection) -> String {
        MemoryPagesModel.addKey(section.page, in: place(of: section))
    }

    /// Add, at the trailing end of the section's heading (under it at
    /// accessibility text sizes), so it stays in reach however many entries
    /// the section holds. It opens the field under the heading, and is off
    /// while that field is open. It keeps its own width, so its label never
    /// breaks across lines.
    private func addButton(_ section: MemorySection) -> some View {
        Button {
            startAdding(section)
        } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "plus")
                Text("Add")
            }
            .font(.aicovenBody)
            .foregroundStyle(Color.aicovenTextSecondary)
            .fixedSize()
            .frame(minHeight: Self.rowMinHeight)
            .padding(.horizontal, Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(draftHeld || addingTo == section)
        .accessibilityLabel("Add to \(section.title)")
        .accessibilityIdentifier("memory-add-heading")
    }

    private func addField(_ section: MemorySection) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            fieldBox("Add to \(section.title)", text: $newEntry, identifier: "memory-add", isBusy: isAdding, keepsLineBreaks: false) {
                add(section)
            }
            HStack(spacing: Spacing.xs) {
                Button("Save") {
                    add(section)
                }
                .buttonStyle(StonePrimaryButtonStyle())
                .accessibilityIdentifier("memory-add-button")
                .disabled(isAdding || trimmed(newEntry).isEmpty)
                Button("Cancel") {
                    stopAdding()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("memory-add-cancel")
                .disabled(isAdding)
                if isAdding {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if model.failures[addKey(section)] != nil {
                failureLine(addKey(section))
            }
        }
        .padding(.vertical, Spacing.sm)
        .padding(.horizontal, Spacing.xs)
    }

    // MARK: Intents

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One field is open at a time. A field holding unsaved text (`draftHeld`)
    /// stays until Save or Cancel, and nothing else starts meanwhile; an
    /// Edit, an Add or a Forget question otherwise closes the others.
    private func closeOpenRows() {
        stopEditing()
        stopAdding()
        // A Forget on its way keeps its row in the confirm, so a failure
        // leaves the row with its Cancel and Forget.
        confirmingIds = confirmingIds.filter { model.forgettingIds.contains($0) }
    }

    private func startAdding(_ section: MemorySection) {
        guard !draftHeld else { return }
        closeOpenRows()
        model.clearFailure(addKey(section))
        newEntry = ""
        addingTo = section
    }

    private func stopAdding() {
        if let addingTo { model.clearFailure(addKey(addingTo)) }
        addingTo = nil
        newEntry = ""
    }

    private func add(_ section: MemorySection) {
        let text = trimmed(newEntry)
        guard !text.isEmpty, !isAdding else { return }
        isAdding = true
        let place = place(of: section)
        Task {
            if await model.add(text, on: section.page, in: place) {
                if addingTo == section { stopAdding() }
                announce("Added to \(section.title)")
            } else {
                announce(model.failures[addKey(section)])
            }
            isAdding = false
        }
    }

    private func startEditing(_ entry: Memory) {
        guard canEdit(entry), !isLocked(entry) else { return }
        closeOpenRows()
        editDraft = entry.content
        editOriginal = entry.content
        editingId = entry.id
        model.clearFailure(entry.id)
    }

    private func save(_ entry: Memory, in place: MemoryPlace) {
        let text = trimmed(editDraft)
        guard !text.isEmpty, editingId == entry.id, !model.savingIds.contains(entry.id) else { return }
        guard !MemoryDraft.isUnchanged(editDraft, from: entry.content) else {
            stopEditing(restoringFocus: true)
            return
        }
        Task {
            if await model.edit(entry, to: text, in: place) {
                if editingId == entry.id { stopEditing(restoringFocus: true) }
                announce("Saved")
            } else {
                announce(model.failures[entry.id])
            }
        }
    }

    private func stopEditing(restoringFocus: Bool = false) {
        if restoringFocus, let editingId { focusedRow = editingId }
        if let editingId { model.clearFailure(editingId) }
        editingId = nil
        editDraft = ""
        editOriginal = nil
    }

    private func askToForget(_ entry: Memory) {
        guard !isLocked(entry) else { return }
        closeOpenRows()
        model.clearFailure(entry.id)
        confirmingIds.insert(entry.id)
    }

    private func cancelForget(_ entry: Memory) {
        guard !model.forgettingIds.contains(entry.id) else { return }
        model.clearFailure(entry.id)
        confirmingIds.remove(entry.id)
        focusedRow = entry.id
    }

    private func forget(_ entry: Memory, in place: MemoryPlace) {
        // Focus goes to the next row in the section, or its heading.
        let section = sections.first { section in
            model.entries(on: section.page, in: self.place(of: section)).contains { $0.id == entry.id }
        }
        let following = section.flatMap { section -> String? in
            let ids = model.entries(on: section.page, in: self.place(of: section)).map(\.id)
            guard let index = ids.firstIndex(of: entry.id), index + 1 < ids.count else { return nil }
            return ids[index + 1]
        }
        Task {
            guard await model.forget(entry, in: place) else {
                announce(model.failures[entry.id])
                return
            }
            confirmingIds.remove(entry.id)
            forgetFocus = nil
            // Focus moves on only if the person isn't in a field by now.
            if editingId == nil, addingTo == nil {
                if let following {
                    focusedRow = following
                } else {
                    headingFocus = section
                }
            }
            announce("Forgot it")
        }
    }

    /// Says to VoiceOver what an action of this page came to, while the
    /// page is still on screen: once it has left, the page that shows the
    /// place says it in its row, and nothing is said over wherever the
    /// person has gone.
    private func announce(_ message: String?) {
        guard isOnScreen, let message else { return }
        AccessibilityNotification.Announcement(message).post()
    }
}

/// The place's memory didn't load: rust words and Try again.
private struct MemoryLoadFailedLine: View {
    let place: MemoryPlace

    @EnvironmentObject private var model: MemoryPagesModel

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Text("Couldn't load this memory.")
                .font(.aicovenBodySmall)
                .foregroundStyle(Color.aicovenError)
            Button("Try again") {
                Task { await model.load(place) }
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("memory-try-again")
        }
    }
}
