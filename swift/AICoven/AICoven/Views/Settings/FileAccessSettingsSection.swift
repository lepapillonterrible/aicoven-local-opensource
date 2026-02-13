import SwiftUI

#if os(macOS)
/// Settings section for managing folder access permissions.
/// Shows authorized folders with remove buttons and an "Add Folder" button.
/// Also listens for auto-prompt notifications from FileToolService.
struct FileAccessSettingsSection: View {
    @ObservedObject private var fileAccessManager = FileAccessManager.shared
    @State private var showAutoPromptAlert = false
    @State private var deniedPath: String = ""

    var body: some View {
        VStack(spacing: Spacing.md) {
            HStack {
                Text("File Access")
                    .font(.aicovenH3)
                    .foregroundColor(.aicovenTextPrimary)
                Spacer()
            }

            GlassCard {
                VStack(spacing: Spacing.md) {
                    // Info text
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "folder.badge.gearshape")
                            .font(.aicovenH3)
                            .foregroundColor(.aicovenTeal)
                            .frame(width: 32)

                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text("Allowed Folders")
                                .font(.aicovenBody)
                                .foregroundColor(.aicovenTextPrimary)
                            Text("Grant folder access so agents can read and write files on your behalf.")
                                .font(.aicovenCaption)
                                .foregroundColor(.aicovenTextSecondary)
                        }
                        Spacer()
                    }

                    // Show info banner when the app is not sandboxed
                    if fileAccessManager.isUnrestricted {
                        HStack(spacing: Spacing.sm) {
                            Image(systemName: "info.circle.fill")
                                .font(.aicovenBody)
                                .foregroundColor(.aicovenTeal)
                            Text("This build is not sandboxed — agents can access all files without folder grants. You can still add folders below to pre-authorize paths for sandboxed builds.")
                                .font(.aicovenCaption)
                                .foregroundColor(.aicovenTextSecondary)
                        }
                        .padding(Spacing.sm)
                        .background(Color.aicovenTeal.opacity(0.1))
                        .cornerRadius(8)
                    }

                    if !fileAccessManager.allowedFolders.isEmpty {
                        Divider()
                            .background(Color.aicovenBorder)

                        // List of allowed folders
                        ForEach(fileAccessManager.allowedFolders) { folder in
                            HStack(spacing: Spacing.sm) {
                                Image(systemName: "folder.fill")
                                    .font(.aicovenCaption)
                                    .foregroundColor(.aicovenPurple)

                                Text(folder.displayPath)
                                    .font(.aicovenBodySmall)
                                    .foregroundColor(.aicovenTextPrimary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                Spacer()

                                Button {
                                    fileAccessManager.removeFolder(folder)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.aicovenCaption)
                                        .foregroundColor(.aicovenTextTertiary)
                                }
                                .buttonStyle(.plain)
                                .help("Remove folder access")
                            }
                            .padding(.vertical, Spacing.xxs)
                        }
                    }

                    Divider()
                        .background(Color.aicovenBorder)

                    // Add folder button
                    Button {
                        fileAccessManager.promptForFolderAccess()
                    } label: {
                        HStack(spacing: Spacing.sm) {
                            Image(systemName: "plus.circle.fill")
                                .font(.aicovenBody)
                                .foregroundColor(.aicovenTeal)
                            Text("Add Folder")
                                .font(.aicovenBody)
                                .foregroundColor(.aicovenTeal)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, Spacing.lg)
        .onReceive(NotificationCenter.default.publisher(for: FileAccessManager.requestFolderAccessNotification)) { notification in
            if let path = notification.userInfo?["path"] as? String {
                deniedPath = path
                showAutoPromptAlert = true
            }
        }
        .alert("Folder Access Required", isPresented: $showAutoPromptAlert) {
            Button("Grant Access") {
                fileAccessManager.promptForFolderAccess()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The agent tried to access '\(deniedPath)' but this folder hasn't been authorized. Would you like to grant access now?")
        }
    }
}
#endif
