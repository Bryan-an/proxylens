import Foundation
import GRDB
import ProxyLensCore

struct ServerSentEventRepository: Sendable {
    static func save(_ event: CapturedServerSentEvent, in database: Database) throws {
        try database.execute(
            sql: """
                INSERT INTO server_sent_events (
                    id, flow_id, sequence_number, event_type, event_id,
                    retry_milliseconds, received_at, data_byte_count, snapshot, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    flow_id = excluded.flow_id,
                    sequence_number = excluded.sequence_number,
                    event_type = excluded.event_type,
                    event_id = excluded.event_id,
                    retry_milliseconds = excluded.retry_milliseconds,
                    received_at = excluded.received_at,
                    data_byte_count = excluded.data_byte_count,
                    snapshot = excluded.snapshot,
                    updated_at = excluded.updated_at
                """,
            arguments: [
                event.id.uuidString,
                event.flowID.description,
                event.sequenceNumber,
                event.eventType,
                event.eventID,
                event.retryMilliseconds,
                event.receivedAt.timeIntervalSince1970,
                event.dataByteCount,
                try PersistenceCoding.encode(event),
                Date().timeIntervalSince1970
            ]
        )
    }

    static func fetchAll(for flowID: FlowID, from database: Database) throws
        -> [CapturedServerSentEvent]
    {
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT snapshot FROM server_sent_events
                WHERE flow_id = ? ORDER BY sequence_number ASC
                """,
            arguments: [flowID.description]
        )
        return try rows.map { row in
            let snapshot: Data = row["snapshot"]
            return try PersistenceCoding.decode(CapturedServerSentEvent.self, from: snapshot)
        }
    }

    static func deleteAll(for flowID: FlowID, from database: Database) throws {
        try database.execute(
            sql: "DELETE FROM server_sent_events WHERE flow_id = ?",
            arguments: [flowID.description]
        )
    }
}
