import Foundation
import GRDB
import ProxyLensCore

struct SessionRepository: Sendable {
    static func save(_ session: Session, in database: Database) throws {
        let snapshot = try PersistenceCoding.encode(session)
        let arguments: StatementArguments = [
            session.id.description,
            session.startedAt.timeIntervalSince1970,
            session.endedAt?.timeIntervalSince1970,
            session.state.rawValue,
            session.flowCount,
            snapshot,
            Date().timeIntervalSince1970
        ]

        try database.execute(
            sql: """
                INSERT INTO sessions (
                    id, started_at, ended_at, state, flow_count, snapshot, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    started_at = excluded.started_at,
                    ended_at = excluded.ended_at,
                    state = excluded.state,
                    flow_count = excluded.flow_count,
                    snapshot = excluded.snapshot,
                    updated_at = excluded.updated_at
                """,
            arguments: arguments
        )
    }

    static func fetch(_ sessionID: SessionID, from database: Database) throws -> Session? {
        guard
            let snapshot = try Data.fetchOne(
                database,
                sql: "SELECT snapshot FROM sessions WHERE id = ?",
                arguments: [sessionID.description]
            )
        else {
            return nil
        }

        return try PersistenceCoding.decode(Session.self, from: snapshot)
    }

    static func fetchAll(from database: Database, state: SessionState? = nil) throws -> [Session] {
        let rows: [Row]
        if let state {
            rows = try Row.fetchAll(
                database,
                sql: "SELECT snapshot FROM sessions WHERE state = ? ORDER BY started_at DESC",
                arguments: [state.rawValue]
            )
        } else {
            rows = try Row.fetchAll(
                database,
                sql: "SELECT snapshot FROM sessions ORDER BY started_at DESC"
            )
        }

        return try rows.map { row in
            let snapshot: Data = row["snapshot"]
            return try PersistenceCoding.decode(Session.self, from: snapshot)
        }
    }

    static func delete(_ sessionID: SessionID, from database: Database) throws {
        try database.execute(
            sql: "DELETE FROM sessions WHERE id = ?",
            arguments: [sessionID.description]
        )
    }
}
