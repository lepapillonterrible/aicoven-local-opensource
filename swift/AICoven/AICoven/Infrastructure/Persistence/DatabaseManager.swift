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

    /// Gives each memory that was written for a coven, by an account that
    /// has exactly one coven, to that coven (the v14 migration's rule).
    static let givingMemoriesToAnOnlyCoven = """
    UPDATE memory_chunks
    SET coven_id = (SELECT id FROM covens WHERE covens.user_id = memory_chunks.user_id)
    WHERE scope IN ('coven', 'agent')
      AND (SELECT COUNT(*) FROM covens WHERE covens.user_id = memory_chunks.user_id) = 1
    """

    /// Takes away the thread summaries the app once offered as memories
    /// about the person and that still wait for an answer (v24).
    nonisolated static let summaryProposalsThatWait = """
    DELETE FROM memory_proposals
    WHERE status = 'pending' AND proposed_by = 'system' AND title = 'Thread Summary'
    """

    /// Compacts the file once (from v25), away from the main thread: what
    /// was in the clear before (and before secure delete was on) is not
    /// left in its free pages. Recorded only once it has been done, so a
    /// compaction that fails (no room, the app closed meanwhile) is tried
    /// again at the next start.
    nonisolated static let compacted = "compacted-after-v25"

    /// The compaction started as the database was opened (tests wait on it).
    private(set) var compaction: Task<Void, Never>?

    private nonisolated static func compactOnce(_ queue: DatabaseQueue) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            do {
                let done: Bool = try await queue.read { db in
                    try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM upkeep_done WHERE name = ?)", arguments: [compacted]) ?? false
                }
                guard !done else { return }
                try await queue.vacuum()
                try await queue.write { db in
                    try db.execute(sql: "INSERT OR IGNORE INTO upkeep_done (name) VALUES (?)", arguments: [compacted])
                }
            } catch {
                // The kind of failure only; tried again at the next start.
                AppErrorReporter.log(message: "The database could not be compacted (\(type(of: error)))", context: "DatabaseManager.compactOnce")
            }
        }
    }

    /// Call this early in app startup (e.g., in AICovenApp) to open the DB and run migrations.
    func configureIfNeeded() {
        guard dbQueue == nil else { return }

        do {
            var configuration = Configuration()
            configuration.foreignKeysEnabled = true
            // What is deleted or replaced is overwritten in the file, not
            // left readable in its free pages: text that was sealed or
            // taken away does not stay behind in the clear.
            configuration.prepareDatabase { db in
                try db.execute(sql: "PRAGMA secure_delete = ON")
            }
            let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
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

            // v6: enforce local user isolation at the database boundary.
            // Existing v4/v5 migrations added nullable user_id columns for compatibility;
            // triggers below fail closed for all future inserts/updates and prevent
            // child rows from referencing a parent owned by a different user.
            migrator.registerMigration("v6_user_isolation_guards") { db in
                for table in ["covens", "roles", "threads", "messages", "memory_chunks", "memory_proposals"] {
                    try db.execute(sql: """
                    CREATE TRIGGER IF NOT EXISTS \(table)_require_user_id_insert
                    BEFORE INSERT ON \(table)
                    WHEN NEW.user_id IS NULL OR length(trim(NEW.user_id)) = 0
                    BEGIN
                        SELECT RAISE(ABORT, '\(table).user_id is required');
                    END;
                    """)
                    try db.execute(sql: """
                    CREATE TRIGGER IF NOT EXISTS \(table)_require_user_id_update
                    BEFORE UPDATE OF user_id ON \(table)
                    WHEN NEW.user_id IS NULL OR length(trim(NEW.user_id)) = 0
                    BEGIN
                        SELECT RAISE(ABORT, '\(table).user_id is required');
                    END;
                    """)
                }

                try db.create(index: "roles_user_coven", on: "roles", columns: ["user_id", "coven_id"])
                try db.create(index: "messages_user_thread", on: "messages", columns: ["user_id", "thread_id"])

                try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS roles_match_coven_user_insert
                BEFORE INSERT ON roles
                WHEN NOT EXISTS (
                    SELECT 1 FROM covens
                    WHERE covens.id = NEW.coven_id AND covens.user_id = NEW.user_id
                )
                BEGIN
                    SELECT RAISE(ABORT, 'roles.coven_id must reference a coven owned by the same user');
                END;
                """)
                try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS roles_match_coven_user_update
                BEFORE UPDATE OF user_id, coven_id ON roles
                WHEN NOT EXISTS (
                    SELECT 1 FROM covens
                    WHERE covens.id = NEW.coven_id AND covens.user_id = NEW.user_id
                )
                BEGIN
                    SELECT RAISE(ABORT, 'roles.coven_id must reference a coven owned by the same user');
                END;
                """)

                try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS messages_match_thread_user_insert
                BEFORE INSERT ON messages
                WHEN NOT EXISTS (
                    SELECT 1 FROM threads
                    WHERE threads.id = NEW.thread_id AND threads.user_id = NEW.user_id
                )
                BEGIN
                    SELECT RAISE(ABORT, 'messages.thread_id must reference a thread owned by the same user');
                END;
                """)
                try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS messages_match_thread_user_update
                BEFORE UPDATE OF user_id, thread_id ON messages
                WHEN NOT EXISTS (
                    SELECT 1 FROM threads
                    WHERE threads.id = NEW.thread_id AND threads.user_id = NEW.user_id
                )
                BEGIN
                    SELECT RAISE(ABORT, 'messages.thread_id must reference a thread owned by the same user');
                END;
                """)
            }

            // v7: the app's own threads and messages move here from plain
            // JSON files. A thread's whole record, its title included, is in
            // `payload_ciphertext`. `payload_format` 1 marks a message whose
            // ciphertext is its whole record; 0 is the earlier plain content.
            migrator.registerMigration("v7_chat_history") { db in
                try db.alter(table: "threads") { t in
                    t.add(column: "payload_ciphertext", .blob)
                }
                try db.alter(table: "messages") { t in
                    t.add(column: "payload_format", .integer).notNull().defaults(to: 0)
                }
            }

            // v8: one row for each reply the app starts, from the person's
            // message to its outcome, so a reply cut off by the app closing
            // is known to have been running. Its work trace (v9) is the only
            // content a turn holds, and is encrypted.
            migrator.registerMigration("v8_turns") { db in
                try db.create(table: "turns") { t in
                    t.column("id", .text).primaryKey()
                    t.column("user_id", .text).notNull()
                    t.column("thread_id", .text).notNull()
                    t.column("status", .text).notNull()
                    t.column("started_at", .datetime).notNull()
                    t.column("finished_at", .datetime)
                    t.column("message_id", .text)
                    t.foreignKey(["thread_id"], references: "threads", columns: ["id"], onDelete: .cascade)
                }
                try db.create(index: "turns_user_thread_status", on: "turns", columns: ["user_id", "thread_id", "status"])
                // As for messages: a turn belongs to the user its thread does.
                try db.execute(sql: """
                CREATE TRIGGER turns_match_thread_user_insert
                BEFORE INSERT ON turns
                WHEN length(trim(NEW.user_id)) = 0 OR NOT EXISTS (
                    SELECT 1 FROM threads
                    WHERE threads.id = NEW.thread_id AND threads.user_id = NEW.user_id
                )
                BEGIN
                    SELECT RAISE(ABORT, 'turns.thread_id must reference a thread owned by the same user');
                END;
                """)
                try db.execute(sql: """
                CREATE TRIGGER turns_match_thread_user_update
                BEFORE UPDATE OF user_id, thread_id ON turns
                WHEN length(trim(NEW.user_id)) = 0 OR NOT EXISTS (
                    SELECT 1 FROM threads
                    WHERE threads.id = NEW.thread_id AND threads.user_id = NEW.user_id
                )
                BEGIN
                    SELECT RAISE(ABORT, 'turns.thread_id must reference a thread owned by the same user');
                END;
                """)
            }

            // v9: the work behind a turn's answer (its tools and reasoning,
            // with their times), kept encrypted with the turn.
            migrator.registerMigration("v9_turn_trace") { db in
                try db.alter(table: "turns") { t in
                    t.add(column: "trace_ciphertext", .blob)
                }
            }

            // v10: for a turn an agent of the person's own is running (a
            // Hermes run), which run it is, kept encrypted with the turn: the
            // run goes on when this app closes, and is picked up from this.
            migrator.registerMigration("v10_turn_run") { db in
                try db.alter(table: "turns") { t in
                    t.add(column: "run_ciphertext", .blob)
                }
            }

            // v11: what is typed in a thread's composer and not sent, kept
            // encrypted with the thread, so it is there when the thread is
            // opened again and goes when the thread does.
            migrator.registerMigration("v11_thread_draft") { db in
                try db.alter(table: "threads") { t in
                    t.add(column: "draft_ciphertext", .blob)
                }
            }

            // v12: the files attached to messages. A file's bytes are kept
            // encrypted in the app's own folder, under the attachment's id;
            // its row says whose it is and which thread it was attached in,
            // and holds its name and kind encrypted. `message_id` is set
            // once the message it went with has been stored: until then it
            // is only in a composer or waiting to be sent.
            migrator.registerMigration("v12_attachments") { db in
                try db.create(table: "attachments") { t in
                    t.column("id", .text).primaryKey()
                    t.column("user_id", .text).notNull()
                    t.column("thread_id", .text).notNull()
                    t.column("meta_ciphertext", .blob).notNull()
                    t.column("message_id", .text)
                    t.column("created_at", .datetime).notNull()
                    t.foreignKey(["thread_id"], references: "threads", columns: ["id"], onDelete: .cascade)
                }
                try db.create(index: "attachments_user_thread", on: "attachments", columns: ["user_id", "thread_id"])
                // As for messages and turns: an attachment belongs to the
                // user its thread does.
                try db.execute(sql: """
                CREATE TRIGGER attachments_match_thread_user_insert
                BEFORE INSERT ON attachments
                WHEN length(trim(NEW.user_id)) = 0 OR NOT EXISTS (
                    SELECT 1 FROM threads
                    WHERE threads.id = NEW.thread_id AND threads.user_id = NEW.user_id
                )
                BEGIN
                    SELECT RAISE(ABORT, 'attachments.thread_id must reference a thread owned by the same user');
                END;
                """)
                try db.execute(sql: """
                CREATE TRIGGER attachments_match_thread_user_update
                BEFORE UPDATE OF user_id, thread_id ON attachments
                WHEN length(trim(NEW.user_id)) = 0 OR NOT EXISTS (
                    SELECT 1 FROM threads
                    WHERE threads.id = NEW.thread_id AND threads.user_id = NEW.user_id
                )
                BEGIN
                    SELECT RAISE(ABORT, 'attachments.thread_id must reference a thread owned by the same user');
                END;
                """)
            }

            // v13: when each thread was last on screen, so that a reply
            // stored since is known not to have been seen. A time, kept as
            // it is. A thread from before this is read up to now: what it
            // holds was there before marks were, and a reply stored in it
            // from here on is one the person has not seen.
            migrator.registerMigration("v13_thread_read_at") { db in
                try db.alter(table: "threads") { t in
                    t.add(column: "read_at", .datetime)
                }
                try db.execute(sql: "UPDATE threads SET read_at = ?", arguments: [Date()])
            }

            // v14: a memory is one coven's, or kept in no coven (the
            // person's own, and Strix's). Until now a coven's memories were
            // stored without their coven, so the coven of one written
            // before this is not known: where its account has exactly one
            // coven it is that coven's, and otherwise it stays in no coven,
            // where Strix's pages show it. A coven's memory is stored only
            // in a coven of the same account, and a coven that is deleted
            // takes its memories, and the proposals made in it, with it.
            migrator.registerMigration("v14_memory_coven") { db in
                try db.alter(table: "memory_chunks") { t in
                    t.add(column: "coven_id", .text)
                }
                try db.create(index: "memory_chunks_user_coven", on: "memory_chunks", columns: ["user_id", "coven_id"])
                try db.execute(sql: Self.givingMemoriesToAnOnlyCoven)
                for (event, name) in [("INSERT", "insert"), ("UPDATE OF user_id, coven_id", "update")] {
                    try db.execute(sql: """
                    CREATE TRIGGER memory_chunks_match_coven_user_\(name)
                    BEFORE \(event) ON memory_chunks
                    WHEN NEW.coven_id IS NOT NULL AND NOT EXISTS (
                        SELECT 1 FROM covens
                        WHERE covens.id = NEW.coven_id AND covens.user_id = NEW.user_id
                    )
                    BEGIN
                        SELECT RAISE(ABORT, 'memory_chunks.coven_id must reference a coven owned by the same user');
                    END;
                    """)
                }
                try db.execute(sql: """
                CREATE TRIGGER covens_take_their_memory
                AFTER DELETE ON covens
                BEGIN
                    DELETE FROM memory_chunks WHERE coven_id = OLD.id;
                    DELETE FROM memory_proposals WHERE coven_id = OLD.id;
                END;
                """)
            }

            // v15: what every agent of a scope is told ("Every agent here
            // knows…"), one text for each coven of an account and one for
            // Strix, kept under an empty coven id. Encrypted. A coven's
            // text is kept only for a coven of the same account, and goes
            // with its coven.
            migrator.registerMigration("v15_coven_context") { db in
                try db.create(table: "coven_context") { t in
                    t.column("user_id", .text).notNull()
                    t.column("coven_id", .text).notNull().defaults(to: "")
                    t.column("text_ciphertext", .blob).notNull()
                    t.column("updated_at", .datetime).notNull()
                    t.primaryKey(["user_id", "coven_id"])
                }
                for (event, name) in [("INSERT", "insert"), ("UPDATE OF user_id, coven_id", "update")] {
                    try db.execute(sql: """
                    CREATE TRIGGER coven_context_require_user_id_\(name)
                    BEFORE \(event) ON coven_context
                    WHEN length(trim(NEW.user_id)) = 0
                    BEGIN
                        SELECT RAISE(ABORT, 'coven_context.user_id is required');
                    END;
                    """)
                    try db.execute(sql: """
                    CREATE TRIGGER coven_context_match_coven_user_\(name)
                    BEFORE \(event) ON coven_context
                    WHEN NEW.coven_id <> '' AND NOT EXISTS (
                        SELECT 1 FROM covens
                        WHERE covens.id = NEW.coven_id AND covens.user_id = NEW.user_id
                    )
                    BEGIN
                        SELECT RAISE(ABORT, 'coven_context.coven_id must reference a coven owned by the same user');
                    END;
                    """)
                }
                try db.execute(sql: """
                CREATE TRIGGER covens_take_their_context
                AFTER DELETE ON covens
                BEGIN
                    DELETE FROM coven_context WHERE user_id = OLD.user_id AND coven_id = OLD.id;
                END;
                """)
            }

            // v16: a memory proposal's text is kept encrypted. Rows from
            // before this hold it as text until the account's proposals are
            // next read with its key (`MemoryProposalRepository`), when it
            // is sealed and the text taken out. And a proposal is stored
            // only for a coven of the same account, or for none.
            migrator.registerMigration("v16_memory_proposal_ciphertext") { db in
                try db.alter(table: "memory_proposals") { t in
                    t.add(column: "content_ciphertext", .blob)
                }
                // As a coven's memory is: proposed only for a coven of the
                // same account.
                for (event, name) in [("INSERT", "insert"), ("UPDATE OF user_id, coven_id", "update")] {
                    try db.execute(sql: """
                    CREATE TRIGGER memory_proposals_match_coven_user_\(name)
                    BEFORE \(event) ON memory_proposals
                    WHEN NEW.coven_id IS NOT NULL AND NOT EXISTS (
                        SELECT 1 FROM covens
                        WHERE covens.id = NEW.coven_id AND covens.user_id = NEW.user_id
                    )
                    BEGIN
                        SELECT RAISE(ABORT, 'memory_proposals.coven_id must reference a coven owned by the same user');
                    END;
                    """)
                }
            }

            // v17: the account's skills. Title and text are encrypted; a
            // skill from a source takes the place of the one the account
            // already has from it.
            migrator.registerMigration("v17_skills") { db in
                try db.create(table: "skills") { t in
                    t.column("id", .text).primaryKey()
                    t.column("user_id", .text).notNull()
                    t.column("title_ciphertext", .blob).notNull()
                    t.column("text_ciphertext", .blob).notNull()
                    t.column("is_on", .boolean).notNull().defaults(to: false)
                    t.column("source_digest", .text)
                    t.column("created_at", .datetime).notNull()
                    t.column("updated_at", .datetime).notNull()
                }
                try db.create(index: "skills_user", on: "skills", columns: ["user_id"])
                try db.execute(sql: """
                CREATE UNIQUE INDEX skills_user_source ON skills (user_id, source_digest) WHERE source_digest IS NOT NULL
                """)
                for (event, name) in [("INSERT", "insert"), ("UPDATE OF user_id", "update")] {
                    try db.execute(sql: """
                    CREATE TRIGGER skills_require_user_id_\(name)
                    BEFORE \(event) ON skills
                    WHEN length(trim(NEW.user_id)) = 0
                    BEGIN
                        SELECT RAISE(ABORT, 'skills.user_id is required');
                    END;
                    """)
                }
            }

            // v18: the account's assets, each in a coven of the account's or
            // with Strix (an empty coven id), with its files. Titles, what
            // says what an asset is, and each file's name, size and bytes
            // are encrypted; the bytes are kept here with the asset, as the
            // row's last column, so that reading the rest does not read
            // them. An asset is kept only in a coven of the same account,
            // and goes with its coven; it stays when its thread goes.
            migrator.registerMigration("v18_assets") { db in
                try db.create(table: "assets") { t in
                    t.column("id", .text).primaryKey()
                    t.column("user_id", .text).notNull()
                    t.column("coven_id", .text).notNull().defaults(to: "")
                    t.column("type", .text).notNull()
                    t.column("status", .text).notNull()
                    t.column("title_ciphertext", .blob).notNull()
                    t.column("details_ciphertext", .blob).notNull()
                    t.column("made_by_agent_id", .text)
                    t.column("thread_id", .text)
                    t.column("source_message_id", .text)
                    t.column("created_at", .datetime).notNull()
                    t.column("updated_at", .datetime).notNull()
                }
                try db.create(index: "assets_user_coven", on: "assets", columns: ["user_id", "coven_id"])
                try db.create(table: "asset_files") { t in
                    t.column("id", .text).primaryKey()
                    t.column("asset_id", .text).notNull().indexed().references("assets", onDelete: .cascade)
                    t.column("meta_ciphertext", .blob).notNull()
                    t.column("created_at", .datetime).notNull()
                    t.column("body_ciphertext", .blob).notNull()
                }
                for (event, name) in [("INSERT", "insert"), ("UPDATE OF user_id, coven_id", "update")] {
                    try db.execute(sql: """
                    CREATE TRIGGER assets_match_coven_user_\(name)
                    BEFORE \(event) ON assets
                    WHEN length(trim(NEW.user_id)) = 0 OR (NEW.coven_id <> '' AND NOT EXISTS (
                        SELECT 1 FROM covens
                        WHERE covens.id = NEW.coven_id AND covens.user_id = NEW.user_id
                    ))
                    BEGIN
                        SELECT RAISE(ABORT, 'assets.coven_id must reference a coven owned by the same user');
                    END;
                    """)
                }
                try db.execute(sql: """
                CREATE TRIGGER covens_take_their_assets
                AFTER DELETE ON covens
                BEGIN
                    DELETE FROM assets WHERE user_id = OLD.user_id AND coven_id = OLD.id;
                END;
                """)
            }

            // v19: the account's tasks, each in a coven of the account's or
            // with Strix (an empty coven id). A task's title is encrypted;
            // what it is listed and ordered by is kept as it is. `revision`
            // counts the writes of a task, so that a write that must be
            // taken back is taken back only if nothing has written since.
            migrator.registerMigration("v19_tasks") { db in
                try db.create(table: "tasks") { t in
                    t.column("id", .text).primaryKey()
                    t.column("user_id", .text).notNull()
                    t.column("coven_id", .text).notNull().defaults(to: "")
                    t.column("title_ciphertext", .blob).notNull()
                    t.column("status", .text).notNull()
                    t.column("stage", .text).notNull()
                    t.column("due_date", .text)
                    t.column("due_time", .text)
                    t.column("pin_period", .text)
                    t.column("pin_expires_at", .datetime)
                    t.column("revision", .integer).notNull().defaults(to: 0)
                    t.column("created_at", .datetime).notNull()
                    t.column("updated_at", .datetime).notNull()
                }
                // A place's tasks by when they were last changed, with what
                // tells the open ones from the finished, for its listing.
                try db.create(index: "tasks_user_coven_changed", on: "tasks", columns: ["user_id", "coven_id", "updated_at", "status"])
                // A coven's tasks whoever's they are, for the trigger that
                // keeps a coven from being made over another account's.
                try db.create(index: "tasks_coven", on: "tasks", columns: ["coven_id"])
                for (event, name) in [("INSERT", "insert"), ("UPDATE OF user_id, coven_id", "update")] {
                    try db.execute(sql: """
                    CREATE TRIGGER tasks_match_coven_user_\(name)
                    BEFORE \(event) ON tasks
                    WHEN length(trim(NEW.user_id)) = 0 OR (NEW.coven_id <> '' AND NOT EXISTS (
                        SELECT 1 FROM covens
                        WHERE covens.id = NEW.coven_id AND covens.user_id = NEW.user_id
                    ))
                    BEGIN
                        SELECT RAISE(ABORT, 'tasks.coven_id must reference a coven owned by the same user');
                    END;
                    """)
                }
                try db.execute(sql: """
                CREATE TRIGGER covens_take_their_tasks
                AFTER DELETE ON covens
                BEGIN
                    DELETE FROM tasks WHERE user_id = OLD.user_id AND coven_id = OLD.id;
                END;
                """)
                // A coven that holds tasks keeps its id and its account,
                // whoever writes: its tasks are bound to both, and would
                // otherwise be left in a coven of another account's, and
                // behind when it is deleted.
                try db.execute(sql: """
                CREATE TRIGGER covens_with_tasks_keep_their_account
                BEFORE UPDATE OF id, user_id ON covens
                WHEN (NEW.id IS NOT OLD.id OR NEW.user_id IS NOT OLD.user_id)
                    AND EXISTS (SELECT 1 FROM tasks WHERE tasks.coven_id = OLD.id AND tasks.user_id = OLD.user_id)
                BEGIN
                    SELECT RAISE(ABORT, 'a coven that holds tasks keeps its id and its account');
                END;
                """)
                // Nor is a coven made, or put in another's place (a
                // replacing insert takes the row out without the triggers
                // above), under an id another account's tasks are kept under.
                try db.execute(sql: """
                CREATE TRIGGER covens_are_not_made_over_anothers_tasks
                BEFORE INSERT ON covens
                WHEN EXISTS (SELECT 1 FROM tasks WHERE tasks.coven_id = NEW.id AND tasks.user_id IS NOT NEW.user_id)
                BEGIN
                    SELECT RAISE(ABORT, 'a coven is not made under an id that holds another account''s tasks');
                END;
                """)
            }

            // v20: a task's thread, the agent that leads it, and the turn it
            // was handed over in. A thread that is deleted leaves its tasks
            // with no thread and no hand-off; an agent that is deleted
            // leaves its tasks with no lead agent. Each such change is a
            // writing of the task (`revision`).
            migrator.registerMigration("v20_task_threads") { db in
                try db.alter(table: "tasks") { t in
                    t.add(column: "thread_id", .text)
                    t.add(column: "lead_agent_id", .text)
                    t.add(column: "handoff_turn_id", .text)
                }
                try db.create(index: "tasks_thread", on: "tasks", columns: ["thread_id"])
                try db.create(index: "tasks_lead_agent", on: "tasks", columns: ["lead_agent_id"])
                for (event, name) in [("INSERT", "insert"), ("UPDATE OF thread_id, user_id", "update")] {
                    try db.execute(sql: """
                    CREATE TRIGGER tasks_match_thread_user_\(name)
                    BEFORE \(event) ON tasks
                    WHEN NEW.thread_id IS NOT NULL AND NOT EXISTS (
                        SELECT 1 FROM threads WHERE threads.id = NEW.thread_id AND threads.user_id = NEW.user_id
                    )
                    BEGIN
                        SELECT RAISE(ABORT, 'tasks.thread_id must reference a thread owned by the same user');
                    END;
                    """)
                }
                try db.execute(sql: """
                CREATE TRIGGER threads_leave_their_tasks
                AFTER DELETE ON threads
                BEGIN
                    UPDATE tasks SET thread_id = NULL, handoff_turn_id = NULL, revision = revision + 1 WHERE thread_id = OLD.id;
                END;
                """)
                try db.execute(sql: """
                CREATE TRIGGER roles_leave_their_tasks
                AFTER DELETE ON roles
                BEGIN
                    UPDATE tasks SET lead_agent_id = NULL, revision = revision + 1 WHERE lead_agent_id = OLD.id;
                END;
                """)
            }

            // Who a task was handed to, apart from who leads it: the lead
            // agent can be changed while the hand-off's own agent works.
            // None for Strix, which is no stored agent. (No task was
            // handed over before this: nothing made a hand-off yet.)
            migrator.registerMigration("v21_task_handoff_agent") { db in
                try db.alter(table: "tasks") { t in
                    t.add(column: "handoff_agent_id", .text)
                }
            }

            // A task's reminder, the person's own: the preset it was set
            // by (none for a time they picked), when it reminds, and the
            // time zone it was set in. Kept as they are, like a pin: the
            // time is what it is scheduled by.
            migrator.registerMigration("v22_task_reminders") { db in
                try db.alter(table: "tasks") { t in
                    t.add(column: "reminder_preset", .text)
                    t.add(column: "reminder_at", .datetime)
                    t.add(column: "reminder_time_zone", .text)
                }
            }

            // v23: where an asset came from. An asset can have a parent
            // (the asset it was made from), and two assets can be related:
            // the one relation this app writes is a hand-off brief's to
            // the asset it hands over, of which an asset has one. Both are
            // only between assets of one account in one place, whoever
            // writes (an asset that has either keeps its place); a
            // relation is written once and goes with either of its assets.
            migrator.registerMigration("v23_asset_lineage") { db in
                try db.alter(table: "assets") { t in
                    t.add(column: "parent_asset_id", .text).references("assets", onDelete: .setNull)
                }
                try db.create(index: "assets_parent", on: "assets", columns: ["parent_asset_id"])
                try db.create(table: "asset_relations") { t in
                    t.column("id", .text).primaryKey()
                    t.column("user_id", .text).notNull()
                    t.column("source_asset_id", .text).notNull().indexed().references("assets", onDelete: .cascade)
                    t.column("target_asset_id", .text).notNull().indexed().references("assets", onDelete: .cascade)
                    t.column("relation_type", .text).notNull()
                    t.column("created_at", .datetime).notNull()
                    t.check(sql: "source_asset_id <> target_asset_id")
                }
                try db.execute(sql: """
                CREATE UNIQUE INDEX asset_relations_one_handoff ON asset_relations (target_asset_id)
                WHERE relation_type = 'handoff_for'
                """)
                for (event, name) in [("INSERT", "insert"), ("UPDATE OF parent_asset_id, user_id, coven_id", "update")] {
                    try db.execute(sql: """
                    CREATE TRIGGER assets_parent_in_place_\(name)
                    BEFORE \(event) ON assets
                    WHEN NEW.parent_asset_id IS NOT NULL AND NOT EXISTS (
                        SELECT 1 FROM assets AS parent
                        WHERE parent.id = NEW.parent_asset_id AND parent.user_id = NEW.user_id AND parent.coven_id = NEW.coven_id
                    )
                    BEGIN
                        SELECT RAISE(ABORT, 'assets.parent_asset_id must be an asset of the same user in the same place');
                    END;
                    """)
                }
                try db.execute(sql: """
                CREATE TRIGGER asset_relations_in_place
                BEFORE INSERT ON asset_relations
                WHEN NOT EXISTS (
                    SELECT 1 FROM assets AS source JOIN assets AS target
                        ON target.user_id = source.user_id AND target.coven_id = source.coven_id
                    WHERE source.id = NEW.source_asset_id AND target.id = NEW.target_asset_id AND source.user_id = NEW.user_id
                )
                BEGIN
                    SELECT RAISE(ABORT, 'asset_relations must relate two assets of the same user in the same place');
                END;
                """)
                // An asset that others were made from, or that is related
                // to another, keeps its account and its place: moved, it
                // would leave them across places.
                try db.execute(sql: """
                CREATE TRIGGER assets_keep_their_place_when_related
                BEFORE UPDATE OF user_id, coven_id ON assets
                WHEN (NEW.user_id <> OLD.user_id OR NEW.coven_id <> OLD.coven_id) AND (
                    EXISTS (SELECT 1 FROM assets AS child WHERE child.parent_asset_id = OLD.id)
                    OR EXISTS (SELECT 1 FROM asset_relations WHERE source_asset_id = OLD.id OR target_asset_id = OLD.id)
                )
                BEGIN
                    SELECT RAISE(ABORT, 'an asset others were made from or are related to keeps its place');
                END;
                """)
                try db.execute(sql: """
                CREATE TRIGGER asset_relations_are_written_once
                BEFORE UPDATE ON asset_relations
                BEGIN
                    SELECT RAISE(ABORT, 'an asset relation is not changed');
                END;
                """)
            }

            // A thread's summary was once offered as a memory about the
            // person after every summarised turn ("Thread Summary", proposed
            // by the app itself): it is kept with its thread instead. The
            // ones still waiting are taken away, so that Activity does not
            // ask about each; none the person answered, or that anyone else
            // proposed, is touched.
            migrator.registerMigration("v24_no_summary_proposals") { db in
                try db.execute(sql: Self.summaryProposalsThatWait)
            }

            // v25: what is kept in the clear says no more than it must.
            // A proposal's text is sealed; of the rest, its tags (a word a
            // model chose) are kept as the page the entry would go on, one
            // of four, and its title, reason and review notes, which no
            // caller passes today, are taken away from older rows. And a
            // coven keeps its id and its account, whatever writes: rows of
            // every kind are bound to it (assets, coven context, memory,
            // agents, tasks). One with no account yet, from before
            // accounts were kept, can still be given its account.
            migrator.registerMigration("v25_less_in_the_clear") { db in
                let rows = try Row.fetchAll(db, sql: "SELECT id, proposed_tags FROM memory_proposals WHERE proposed_tags IS NOT NULL")
                for row in rows {
                    let id: String = row["id"]
                    let stored: String = row["proposed_tags"]
                    try db.execute(
                        sql: "UPDATE memory_proposals SET proposed_tags = ? WHERE id = ?",
                        arguments: [MemoryProposalRepository.storedTags((try? JSONDecoder().decode([String].self, from: Data(stored.utf8))) ?? []), id]
                    )
                }
                try db.execute(sql: "UPDATE memory_proposals SET title = NULL, reason = NULL, review_feedback = NULL")
                try db.execute(sql: """
                CREATE TRIGGER covens_keep_their_id_and_account
                BEFORE UPDATE OF id, user_id ON covens
                WHEN NEW.id IS NOT OLD.id OR (OLD.user_id IS NOT NULL AND NEW.user_id IS NOT OLD.user_id)
                BEGIN
                    SELECT RAISE(ABORT, 'a coven keeps its id and its account');
                END;
                """)
                // Nor is it put in another account's hands by a replacing
                // insert, which takes the row out without the trigger above.
                try db.execute(sql: """
                CREATE TRIGGER covens_are_not_replaced_by_anothers
                BEFORE INSERT ON covens
                WHEN EXISTS (SELECT 1 FROM covens WHERE id = NEW.id AND user_id IS NOT NULL AND user_id IS NOT NEW.user_id)
                BEGIN
                    SELECT RAISE(ABORT, 'a coven keeps its id and its account');
                END;
                """)
                // The tasks' own guard is part of the one above now.
                try db.execute(sql: "DROP TRIGGER IF EXISTS covens_with_tasks_keep_their_account")
                // What upkeep has been done, so that what must be done once
                // is retried until it has been.
                try db.execute(sql: "CREATE TABLE upkeep_done (name TEXT PRIMARY KEY NOT NULL)")
            }

            // v26: an agent's instructions are kept sealed with its
            // account's key (`system_prompt_ciphertext`); those stored as
            // text before are sealed when their account next reads them.
            migrator.registerMigration("v26_sealed_instructions") { db in
                try db.alter(table: "roles") { t in
                    t.add(column: "system_prompt_ciphertext", .blob)
                }
            }

            try migrator.migrate(queue)
            dbQueue = queue
            compaction = Self.compactOnce(queue)
        } catch {
            AppErrorReporter.log(error: error, context: "DatabaseManager.configureIfNeeded")
        }
    }
}
