import Foundation
import Combine
#if os(macOS)
import AppKit
#endif

/// Manages user-granted folder access via security-scoped bookmarks.
/// Provides both a Settings UI surface (pre-authorize folders) and
/// an automatic prompt when a file tool hits an unauthorized path.
@MainActor
final class FileAccessManager: ObservableObject {
    
    static let shared = FileAccessManager()
    
    // MARK: - Published State
    
    /// Folders the user has explicitly granted access to.
    @Published private(set) var allowedFolders: [AllowedFolder] = []
    
    // MARK: - Storage Keys
    
    private static let bookmarksKey = "aicoven_allowed_folder_bookmarks"
    
    // MARK: - Types
    
    struct AllowedFolder: Identifiable, Equatable {
        let id: UUID
        let url: URL
        let bookmarkData: Data
        
        var displayPath: String {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let path = url.path
            if path.hasPrefix(home) {
                return "~" + path.dropFirst(home.count)
            }
            return path
        }
    }
    
    // MARK: - Notifications
    
    /// Posted when a file tool is denied access and the user should be prompted.
    /// The notification's `userInfo` contains `["path": String]`.
    static let requestFolderAccessNotification = Notification.Name("FileAccessManager.requestFolderAccess")
    
    // MARK: - Initialization
    
    private init() {
        resolveBookmarks()
    }
    
    // MARK: - Public API
    
    /// Check whether a path falls under any user-granted folder.
    /// In non-sandboxed (debug) builds this always returns `true`.
    func isPathAccessible(_ path: String) -> Bool {
        #if DEBUG
        // Debug entitlements disable sandbox — allow everything.
        if !isAppSandboxed() { return true }
        #endif
        
        // If no folders are configured, nothing is accessible.
        guard !allowedFolders.isEmpty else { return false }
        
        let normalizedPath = normalizePath(path)
        return allowedFolders.contains { folder in
            let folderPath = folder.url.path
            return normalizedPath == folderPath || normalizedPath.hasPrefix(folderPath + "/")
        }
    }
    
    /// Open an `NSOpenPanel` for the user to pick a folder.
    /// Returns the granted URL on success, nil if cancelled.
    @discardableResult
    func promptForFolderAccess() -> URL? {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Grant Folder Access"
        panel.message = "Select a folder to allow AICoven agents to read and write files."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        
        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }
        
        return addFolder(url: url)
        #else
        return nil
        #endif
    }
    
    /// Programmatically add a folder (e.g., from a drag-and-drop or auto-prompt).
    @discardableResult
    func addFolder(url: URL) -> URL? {
        // Start security-scoped access
        guard url.startAccessingSecurityScopedResource() else {
            // Not a security-scoped URL — in non-sandboxed mode, create a
            // regular bookmark instead.
            return addFolderWithoutScope(url: url)
        }
        
        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            
            // Avoid duplicates
            if !allowedFolders.contains(where: { $0.url.path == url.path }) {
                let folder = AllowedFolder(id: UUID(), url: url, bookmarkData: bookmarkData)
                allowedFolders.append(folder)
                persistBookmarks()
            }
            
            return url
        } catch {
            print("⚠️ [FileAccessManager] Failed to create bookmark for \(url): \(error)")
            url.stopAccessingSecurityScopedResource()
            return nil
        }
    }
    
    /// Remove a previously granted folder.
    func removeFolder(_ folder: AllowedFolder) {
        folder.url.stopAccessingSecurityScopedResource()
        allowedFolders.removeAll { $0.id == folder.id }
        persistBookmarks()
    }
    
    /// Remove folder by URL path.
    func removeFolder(at path: String) {
        if let folder = allowedFolders.first(where: { $0.url.path == path }) {
            removeFolder(folder)
        }
    }
    
    // MARK: - Private Helpers
    
    /// Add a folder without security scope (for non-sandboxed builds).
    private func addFolderWithoutScope(url: URL) -> URL? {
        do {
            let bookmarkData = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            
            if !allowedFolders.contains(where: { $0.url.path == url.path }) {
                let folder = AllowedFolder(id: UUID(), url: url, bookmarkData: bookmarkData)
                allowedFolders.append(folder)
                persistBookmarks()
            }
            return url
        } catch {
            print("⚠️ [FileAccessManager] Failed to create non-scoped bookmark: \(error)")
            return nil
        }
    }
    
    /// Resolve all saved bookmarks on launch.
    private func resolveBookmarks() {
        guard let savedBookmarks = UserDefaults.standard.array(forKey: Self.bookmarksKey) as? [Data] else {
            return
        }
        
        var resolved: [AllowedFolder] = []
        var needsPersist = false
        
        for bookmarkData in savedBookmarks {
            var isStale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                
                guard url.startAccessingSecurityScopedResource() else {
                    // Try without security scope (non-sandboxed fallback)
                    let folder = AllowedFolder(id: UUID(), url: url, bookmarkData: bookmarkData)
                    resolved.append(folder)
                    continue
                }
                
                if isStale {
                    // Re-create the bookmark
                    if let newData = try? url.bookmarkData(
                        options: .withSecurityScope,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    ) {
                        let folder = AllowedFolder(id: UUID(), url: url, bookmarkData: newData)
                        resolved.append(folder)
                        needsPersist = true
                    }
                } else {
                    let folder = AllowedFolder(id: UUID(), url: url, bookmarkData: bookmarkData)
                    resolved.append(folder)
                }
            } catch {
                print("⚠️ [FileAccessManager] Failed to resolve bookmark: \(error)")
                // Skip invalid bookmarks — they'll be dropped on next persist
                needsPersist = true
            }
        }
        
        allowedFolders = resolved
        if needsPersist {
            persistBookmarks()
        }
    }
    
    /// Persist bookmark data to UserDefaults.
    private func persistBookmarks() {
        let bookmarkArray = allowedFolders.map { $0.bookmarkData }
        UserDefaults.standard.set(bookmarkArray, forKey: Self.bookmarksKey)
    }
    
    /// Normalize a file path for comparison (expand tilde, resolve symlinks).
    private func normalizePath(_ path: String) -> String {
        var resolved = path
        if resolved.hasPrefix("~") {
            resolved = (resolved as NSString).expandingTildeInPath
        }
        let url = URL(fileURLWithPath: resolved)
        return url.resolvingSymlinksInPath().path
    }
    
    /// Check if the app is actually sandboxed at runtime.
    private func isAppSandboxed() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home.contains("/Library/Containers/")
    }
}
