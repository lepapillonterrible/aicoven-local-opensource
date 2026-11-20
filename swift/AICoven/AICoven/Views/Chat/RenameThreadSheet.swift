import SwiftUI

/// The prompt that renames a thread, as the cloud app's is: the field
/// opens holding the thread's title, selected. On the Mac it has a title
/// bar and a bar of buttons; on the iPhone and iPad, Cancel and Rename are
/// in the navigation bar.
struct RenameThreadSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: String
    @FocusState private var nameFocused: Bool
    /// The title was selected when editing first began (iOS).
    @State private var selectedOnOpen = false
    @State private var didRename = false

    let onRename: (String) -> Void

    init(thread: Thread, onRename: @escaping (String) -> Void) {
        self.onRename = onRename
        _draft = State(initialValue: thread.title ?? "")
    }

    private var canRename: Bool {
        ThreadListRules.name(from: draft) != nil
    }

    var body: some View {
        container
            .onAppear { nameFocused = true }
    }

    @ViewBuilder
    private var container: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            Text("Rename Thread")
                .font(.aicovenH3)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Color.aicovenChrome)
            Rectangle().fill(Color.aicovenRule).frame(height: 1)
            nameField
                .padding(Spacing.md)
            Rectangle().fill(Color.aicovenRule).frame(height: 1)
            HStack(spacing: Spacing.xs) {
                Spacer(minLength: Spacing.sm)
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: rename)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canRename)
            }
            .padding(.horizontal, Spacing.sm)
            .frame(height: 52)
            .background(Color.aicovenChrome)
        }
        .frame(width: 440)
        .background(Color.aicovenSurfaceElevated)
        #else
        NavigationStack {
            nameField
                .padding(Spacing.md)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color.aicovenSurface.ignoresSafeArea())
                .navigationTitle("Rename Thread")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Rename", action: rename)
                            .disabled(!canRename)
                    }
                }
        }
        .presentationDetents([.height(200)])
        #endif
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text("Name")
                .font(.aicovenCaption.weight(.semibold))
                .foregroundStyle(Color.aicovenTextTertiary)
                .accessibilityHidden(true)
            field
                .textFieldStyle(.plain)
                .focused($nameFocused)
                .submitLabel(.done)
                .onSubmit(rename)
            #if os(iOS)
                .textInputAutocapitalization(.sentences)
            #endif
                .padding(.horizontal, Spacing.sm)
                .frame(minHeight: fieldHeight)
                .background(
                    RoundedRectangle(cornerRadius: BorderRadius.sm)
                        .fill(fieldFill)
                        .overlay(RoundedRectangle(cornerRadius: BorderRadius.sm).strokeBorder(Color.aicovenBorder, lineWidth: 1))
                )
                .accessibilityIdentifier("rename-thread-name")
        }
    }

    /// Selected on open, once. The Mac's field selects its text when it
    /// takes focus; on iOS it is selected when editing first begins, since
    /// a selection set on appear is lost when the field takes focus.
    private var field: some View {
        TextField("Name", text: $draft, prompt: Text("Name"))
        #if os(iOS)
            .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)) { note in
                guard !selectedOnOpen, let field = note.object as? UITextField else { return }
                selectedOnOpen = true
                DispatchQueue.main.async { field.selectAll(nil) }
            }
        #endif
    }

    private var fieldHeight: CGFloat {
        #if os(iOS)
        44
        #else
        36
        #endif
    }

    private var fieldFill: Color {
        #if os(macOS)
        Color.aicovenSurface
        #else
        Color.aicovenSurfaceElevated
        #endif
    }

    private func rename() {
        // Once: Return in the field can reach both the field and the button.
        guard !didRename, let name = ThreadListRules.name(from: draft) else { return }
        didRename = true
        onRename(name)
        dismiss()
    }
}
