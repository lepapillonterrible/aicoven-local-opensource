import Foundation
import GRDB

/// Manages the SQLite database used by the local AICoven client.
///
/// Responsibilities:
/// - Open the database in Application Support.
/// - Run schema migrations on startup.
/// - Provide a shared entry point for read/write access.
///
/// Marked @MainActor to ensure thread-safe access to shared database state.
/// Repository actors should access this via await.
@MainActor
final class DatabaseManager {
    static let shared = DatabaseManager()

    /// Path to the SQLite database file.
    let databaseURL: URL

    /// Shared GRDB queue. Configure this once at app startup.
    private(set) var dbQueue: DatabaseQueue?

    private init() {
        // Resolve Application Support directory.
        let fileManager = FileManager.default
        let baseURL: URL = if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            appSupport
        } else {
            // Fallback to documents directory if Application Support is unavailable.
            fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        }

        let dirURL = baseURL.appendingPathComponent("AICoven", isDirectory: true)
        do {
            try fileManager.createDirectory(at: dirURL, withIntermediateDirectories: true)
        } catch {
            AppErrorReporter.log(error: error, context: "DatabaseManager.init.createDirectory")
        }

        databaseURL = dirURL.appendingPathComponent("aicoven.sqlite")
    }

    /// Call this early in app startup (e.g., in AICovenApp) to open the DB and run migrations.
    func configureIfNeeded() {
        guard dbQueue == nil else { return }

        do {
            let queue = try DatabaseQueue(path: databaseURL.path)
            var migrator = DatabaseMigrator()

            migrator.registerMigration("v1_schema") { db in
                try db.create(table: "threads") { t in
                    t.column("id", .text).primaryKey()
                    t.column("title", .text)
                    t.column("created_at", .datetime).notNull()
                    t.column("updated_at", .datetime)
                    t.column("summary_ciphertext", .blob)
                    t.column("metadata", .text)
                }

                try db.create(table: "messages") { t in
                    t.column("id", .text).primaryKey()
                    t.column("thread_id", .text).notNull().indexed()
                    t.column("role", .text).notNull()
                    t.column("created_at", .datetime).notNull()
                    t.column("content_ciphertext", .blob).notNull()
                    t.column("metadata", .text)
                    t.foreignKey(["thread_id"], references: "threads", columns: ["id"], onDelete: .cascade)
                }

                try db.create(table: "memory_chunks") { t in
                    t.column("id", .text).primaryKey()
                    t.column("scope", .text).notNull()
                    t.column("pii_flag", .boolean).notNull().defaults(to: false)
                    t.column("tags", .text)
                    t.column("created_at", .datetime).notNull()
                    t.column("created_by", .text)
                    t.column("source", .text)
                    t.column("text_ciphertext", .blob).notNull()
                    t.column("embedding", .blob)
                }

                try db.create(table: "user_settings") { t in
                    t.column("id", .text).primaryKey()
                    t.column("settings_ciphertext", .blob).notNull()
                }

                try db.create(table: "provider_accounts") { t in
                    t.column("id", .text).primaryKey()
                    t.column("provider_id", .text).notNull()
                    t.column("display_name", .text)
                    t.column("created_at", .datetime).notNull()
                    t.column("updated_at", .datetime)
                    t.column("api_key_ciphertext", .blob)
                    t.column("keychain_identifier", .text)
                    t.column("config_ciphertext", .blob)
                }

                try db.create(table: "agent_runs") { t in
                    t.column("id", .text).primaryKey()
                    t.column("thread_id", .text)
                    t.column("agent_type", .text).notNull()
                    t.column("max_steps", .integer).notNull()
                    t.column("status", .text).notNull()
                    t.column("created_at", .datetime).notNull()
                    t.column("updated_at", .datetime)
                }

                try db.create(table: "agent_steps") { t in
                    t.column("id", .text).primaryKey()
                    t.column("run_id", .text).notNull().indexed()
                    t.column("step_index", .integer).notNull()
                    t.column("input_ciphertext", .blob).notNull()
                    t.column("output_ciphertext", .blob).notNull()
                    t.column("tool_calls_ciphertext", .blob)
                    t.column("created_at", .datetime).notNull()
                    t.foreignKey(["run_id"], references: "agent_runs", columns: ["id"], onDelete: .cascade)
                }
            }

            // Local-only v2: add a table for memory write proposals so the
            // Swift client can surface, approve, and reject them entirely on
            // device without a backend.
            migrator.registerMigration("v2_memory_proposals") { db in
                try db.create(table: "memory_proposals") { t in
                    t.column("id", .text).primaryKey()
                    t.column("event_id", .text)
                    t.column("coven_id", .text)
                    t.column("proposed_content", .text).notNull()
                    t.column("proposed_tags", .text)
                    t.column("scope", .text)
                    t.column("reason", .text)
                    t.column("source_message_id", .text)
                    t.column("status", .text).notNull().defaults(to: "pending")
                    t.column("proposed_by", .text)
                    t.column("reviewed_by", .text)
                    t.column("created_at", .datetime).notNull()
                    t.column("reviewed_at", .datetime)
                    t.column("title", .text)
                    t.column("review_feedback", .text)
                }
            }

            // v3: add local coven and role tables for organizing
            // agents into collaborative workspaces.
            migrator.registerMigration("v3_covens_roles") { db in
                try db.create(table: "covens") { t in
                    t.column("id", .text).primaryKey()
                    t.column("name", .text).notNull()
                    t.column("description", .text)
                    t.column("avatar", .text)
                    t.column("settings", .text) // JSON-encoded CovenSettings
                    t.column("created_at", .datetime).notNull()
                    t.column("updated_at", .datetime).notNull()
                }

                try db.create(table: "roles") { t in
                    t.column("id", .text).primaryKey()
                    t.column("coven_id", .text).notNull().indexed()
                    t.column("name", .text).notNull()
                    t.column("emoji", .text)
                    t.column("description", .text)
                    t.column("system_prompt", .text)
                    t.column("model", .text)
                    t.column("provider", .text)
                    t.column("provider_account_id", .text)
                    t.column("temperature", .double)
                    t.column("max_tokens", .integer)
                    t.column("settings", .text) // JSON-encoded RoleSettings
                    t.column("created_at", .datetime).notNull()
                    t.column("updated_at", .datetime).notNull()
                    t.foreignKey(["coven_id"], references: "covens", columns: ["id"], onDelete: .cascade)
                }
            }

            // v4: add user_id to covens and roles for per-user data isolation.
            migrator.registerMigration("v4_user_id") { db in
                try db.alter(table: "covens") { t in
                    t.add(column: "user_id", .text)
                }
                try db.alter(table: "roles") { t in
                    t.add(column: "user_id", .text)
                }
            }

            // v5: CRITICAL PRIVACY FIX - add user_id to threads, messages,
            // memory_chunks, and memory_proposals for per-user data isolation.
            // Without this, all users on the same machine see each other's data.
            migrator.registerMigration("v5_user_isolation") { db in
                try db.alter(table: "threads") { t in
                    t.add(column: "user_id", .text)
                }
                try db.alter(table: "messages") { t in
                    t.add(column: "user_id", .text)
                }
                try db.alter(table: "memory_chunks") { t in
                    t.add(column: "user_id", .text)
                }
                try db.alter(table: "memory_proposals") { t in
                    t.add(column: "user_id", .text)
                }

                // Create indexes for efficient user-scoped queries
                try db.create(index: "threads_user_id", on: "threads", columns: ["user_id"])
                try db.create(index: "messages_user_id", on: "messages", columns: ["user_id"])
                try db.create(index: "memory_chunks_user_id", on: "memory_chunks", columns: ["user_id"])
                try db.create(index: "memory_proposals_user_id", on: "memory_proposals", columns: ["user_id"])
            }

            try migrator.migrate(queue)
            dbQueue = queue
        } catch {
            AppErrorReporter.log(error: error, context: "DatabaseManager.configureIfNeeded")
        }
    }
}
