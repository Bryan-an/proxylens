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

        migrator.registerMigration("v2_add_flow_annotations") { database in
            try database.alter(table: "flows") { table in
                table.add(column: "annotation_comment", .text)
                table.add(column: "highlight_color", .text)
                table.add(column: "is_struck_through", .boolean).notNull().defaults(to: false)
            }
            try database.create(
                index: "flows_highlight_color",
                on: "flows",
                columns: ["highlight_color"]
            )
        }

        migrator.registerMigration("v3_add_websocket_frames") { database in
            try database.create(table: "websocket_frames") { table in
                table.column("id", .text).primaryKey()
                table.column("flow_id", .text).notNull()
                    .references("flows", onDelete: .cascade)
                table.column("sequence_number", .integer).notNull()
                table.column("direction", .text).notNull()
                table.column("opcode", .text).notNull()
                table.column("received_at", .double).notNull()
                table.column("payload_byte_count", .integer).notNull()
                table.column("snapshot", .blob).notNull()
                table.column("updated_at", .double).notNull()
                table.uniqueKey(["flow_id", "sequence_number"])
            }
            try database.create(
                index: "websocket_frames_flow_sequence",
                on: "websocket_frames",
                columns: ["flow_id", "sequence_number"]
            )
        }

        migrator.registerMigration("v4_add_server_sent_events") { database in
            try database.create(table: "server_sent_events") { table in
                table.column("id", .text).primaryKey()
                table.column("flow_id", .text).notNull()
                    .references("flows", onDelete: .cascade)
                table.column("sequence_number", .integer).notNull()
                table.column("event_type", .text).notNull()
                table.column("event_id", .text)
                table.column("retry_milliseconds", .integer)
                table.column("received_at", .double).notNull()
                table.column("data_byte_count", .integer).notNull()
                table.column("snapshot", .blob).notNull()
                table.column("updated_at", .double).notNull()
                table.uniqueKey(["flow_id", "sequence_number"])
            }
            try database.create(
                index: "server_sent_events_flow_sequence",
                on: "server_sent_events",
                columns: ["flow_id", "sequence_number"]
            )
        }

        return migrator
    }
}
