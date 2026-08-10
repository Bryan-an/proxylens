import Foundation
import GRDB

public final class DatabaseController: Sendable {
    public let configuration: DatabaseConfiguration
    let pool: DatabasePool

    public init(configuration: DatabaseConfiguration) throws {
        self.configuration = configuration

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: configuration.databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: configuration.bodyDirectoryURL,
            withIntermediateDirectories: true
        )

        var grdbConfiguration = GRDB.Configuration()
        grdbConfiguration.foreignKeysEnabled = true
        grdbConfiguration.journalMode = .wal
        grdbConfiguration.busyMode = .timeout(configuration.busyTimeout)

        let pool = try DatabasePool(
            path: configuration.databaseURL.path,
            configuration: grdbConfiguration
        )
        try SchemaMigrations.migrator.migrate(pool)
        self.pool = pool
    }

    public func journalMode() async throws -> String {
        try await pool.read { database in
            try String.fetchOne(database, sql: "PRAGMA journal_mode") ?? ""
        }
    }

    public func foreignKeysEnabled() async throws -> Bool {
        try await pool.read { database in
            try Bool.fetchOne(database, sql: "PRAGMA foreign_keys") ?? false
        }
    }
}
