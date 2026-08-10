import GRDB

public enum SchemaMigrations {
    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_create_capture_storage") { database in
            try database.create(table: "sessions") { table in
                table.column("id", .text).primaryKey()
                table.column("started_at", .double).notNull()
                table.column("ended_at", .double)
                table.column("state", .text).notNull()
                table.column("flow_count", .integer).notNull()
                table.column("snapshot", .blob).notNull()
                table.column("updated_at", .double).notNull()
            }

            try database.create(table: "flows") { table in
                table.column("id", .text).primaryKey()
                table.column("session_id", .text).notNull()
                    .references("sessions", onDelete: .cascade)
                table.column("created_at", .double).notNull()
                table.column("source_kind", .text).notNull()
                table.column("source_label", .text).notNull()
                table.column("client_address", .text)
                table.column("method", .text).notNull()
                table.column("url", .text).notNull()
                table.column("status_code", .integer)
                table.column("state", .text).notNull()
                table.column("request_byte_count", .integer)
                table.column("response_byte_count", .integer)
                table.column("total_duration", .double)
                table.column("snapshot", .blob).notNull()
                table.column("updated_at", .double).notNull()
            }
            try database.create(
                index: "flows_session_created",
                on: "flows",
                columns: ["session_id", "created_at"]
            )
            try database.create(index: "flows_method", on: "flows", columns: ["method"])
            try database.create(index: "flows_state", on: "flows", columns: ["state"])
            try database.create(index: "flows_status", on: "flows", columns: ["status_code"])

            try database.create(table: "bodies") { table in
                table.column("id", .text).primaryKey()
                table.column("byte_count", .integer).notNull()
                table.column("content_type", .text)
                table.column("content_encoding", .text)
                table.column("digest_algorithm", .text).notNull()
                table.column("digest_value", .text).notNull()
                table.column("is_truncated", .boolean).notNull()
                table.column("storage_kind", .text).notNull()
                table.column("relative_path", .text)
                table.column("inline_data", .blob)
                table.column("created_at", .double).notNull()
            }
        }

        return migrator
    }
}
