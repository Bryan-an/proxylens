import CryptoKit
import Foundation
import GRDB
import ProxyLensCore

public actor FileBodyStore: BodyStore {
    private let database: DatabaseController
    private let directoryURL: URL
    private let inlineBodyThreshold: Int64

    public init(database: DatabaseController) {
        self.database = database
        self.directoryURL = database.configuration.bodyDirectoryURL.standardizedFileURL
        self.inlineBodyThreshold = database.configuration.inlineBodyThreshold
    }

    public func beginWrite(
        metadata: BodyMetadata,
        maximumByteCount: Int64?
    ) async throws -> any BodyWriter {
        if let maximumByteCount, maximumByteCount < 0 {
            throw PersistenceError.invalidMaximumBodyByteCount(maximumByteCount)
        }

        return try FileBodyWriter(
            id: BodyID(),
            metadata: metadata,
            maximumByteCount: maximumByteCount,
            inlineBodyThreshold: inlineBodyThreshold,
            directoryURL: directoryURL,
            database: database
        )
    }

    public func read(_ reference: BodyReference) async throws -> Data {
        switch reference.storage {
        case .inline(let data):
            try Self.validate(data, against: reference)
            return data
        case .external:
            let record = try await database.pool.read { database in
                try StoredBodyRecord.fetch(reference.id, from: database)
            }
            guard let record, let relativePath = record.relativePath else {
                throw PersistenceError.bodyNotFound(reference.id)
            }

            let fileURL = try managedFileURL(relativePath: relativePath)
            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            try Self.validate(data, against: reference)
            return data
        }
    }

    public func remove(_ reference: BodyReference) async throws {
        let relativePath = try await database.pool.write { database in
            let record = try StoredBodyRecord.fetch(reference.id, from: database)
            try database.execute(
                sql: "DELETE FROM bodies WHERE id = ?",
                arguments: [reference.id.description]
            )
            return record?.relativePath
        }

        if let relativePath {
            let fileURL = try managedFileURL(relativePath: relativePath)
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    /// Removes abandoned temporary files and body files without a matching database record.
    /// Call during startup recovery, before capture begins.
    @discardableResult
    public func cleanupOrphanedFiles() async throws -> Int {
        let trackedPaths = try await database.pool.read { database in
            Set(
                try String.fetchAll(
                    database,
                    sql: "SELECT relative_path FROM bodies WHERE relative_path IS NOT NULL"
                )
            )
        }

        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var removedCount = 0
        for fileURL in fileURLs {
            let name = fileURL.lastPathComponent
            guard name.hasSuffix(".body") || name.hasSuffix(".tmp") else {
                continue
            }
            guard !trackedPaths.contains(name) else {
                continue
            }

            try FileManager.default.removeItem(at: fileURL)
            removedCount += 1
        }
        return removedCount
    }

    /// Removes body records that are not referenced by any persisted flow, then removes stray
    /// files. Call during startup recovery, before capture begins.
    @discardableResult
    public func cleanupOrphanedBodies() async throws -> Int {
        let orphanedBodies = try await database.pool.write { database in
            let flowRows = try Row.fetchAll(database, sql: "SELECT snapshot FROM flows")
            var referencedBodyIDs = Set<String>()
            for row in flowRows {
                let snapshot: Data = row["snapshot"]
                let flow = try PersistenceCoding.decode(Flow.self, from: snapshot)
                if let requestBody = flow.request.body {
                    referencedBodyIDs.insert(requestBody.id.description)
                }
                if let responseBody = flow.response?.body {
                    referencedBodyIDs.insert(responseBody.id.description)
                }
            }

            let frameRows = try Row.fetchAll(
                database,
                sql: "SELECT snapshot FROM websocket_frames"
            )
            for row in frameRows {
                let snapshot: Data = row["snapshot"]
                let frame = try PersistenceCoding.decode(
                    CapturedWebSocketFrame.self,
                    from: snapshot
                )
                referencedBodyIDs.insert(frame.payload.id.description)
            }

            let bodyRows = try Row.fetchAll(
                database,
                sql: "SELECT id, relative_path FROM bodies"
            )
            var orphanedPaths: [String] = []
            var orphanedBodyCount = 0
            for row in bodyRows {
                let bodyID: String = row["id"]
                guard !referencedBodyIDs.contains(bodyID) else {
                    continue
                }
                orphanedBodyCount += 1
                if let relativePath: String = row["relative_path"] {
                    orphanedPaths.append(relativePath)
                }
                try database.execute(
                    sql: "DELETE FROM bodies WHERE id = ?",
                    arguments: [bodyID]
                )
            }
            return (count: orphanedBodyCount, paths: orphanedPaths)
        }

        for relativePath in orphanedBodies.paths {
            let fileURL = try managedFileURL(relativePath: relativePath)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        }
        return orphanedBodies.count + (try await cleanupOrphanedFiles())
    }

    private func managedFileURL(relativePath: String) throws -> URL {
        let candidate = directoryURL.appendingPathComponent(relativePath).standardizedFileURL
        let directoryPath =
            directoryURL.path.hasSuffix("/") ? directoryURL.path : directoryURL.path + "/"
        guard candidate.path.hasPrefix(directoryPath) else {
            throw PersistenceError.bodyFileEscapesStorageDirectory(relativePath)
        }
        return candidate
    }

    private static func validate(_ data: Data, against reference: BodyReference) throws {
        guard Int64(data.count) == reference.byteCount else {
            throw ProxyLensError.invalidBodySize(Int64(data.count))
        }

        guard let expectedDigest = reference.digest else {
            return
        }
        let actualDigest = BodyDigest(algorithm: .sha256, value: SHA256.hexDigest(of: data))
        guard expectedDigest.algorithm == actualDigest.algorithm,
            expectedDigest.value.lowercased() == actualDigest.value
        else {
            throw PersistenceError.bodyDigestMismatch(
                expected: expectedDigest,
                actual: actualDigest
            )
        }
    }
}

private actor FileBodyWriter: BodyWriter {
    private let id: BodyID
    private let metadata: BodyMetadata
    private let maximumByteCount: Int64?
    private let inlineBodyThreshold: Int64
    private let directoryURL: URL
    private let database: DatabaseController
    private let temporaryURL: URL
    private var fileHandle: FileHandle?
    private var hasher = SHA256()
    private var byteCount: Int64 = 0
    private var didTruncate = false
    private var finalizedReference: BodyReference?

    init(
        id: BodyID,
        metadata: BodyMetadata,
        maximumByteCount: Int64?,
        inlineBodyThreshold: Int64,
        directoryURL: URL,
        database: DatabaseController
    ) throws {
        self.id = id
        self.metadata = metadata
        self.maximumByteCount = maximumByteCount
        self.inlineBodyThreshold = inlineBodyThreshold
        self.directoryURL = directoryURL
        self.database = database
        self.temporaryURL = directoryURL.appendingPathComponent("\(id.description).tmp")

        guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        self.fileHandle = try FileHandle(forWritingTo: temporaryURL)
    }

    func append(_ data: Data) async throws {
        guard let fileHandle, finalizedReference == nil else {
            throw PersistenceError.bodyWriterClosed
        }
        guard !data.isEmpty else {
            return
        }

        let acceptedCount: Int
        if let maximumByteCount {
            let remaining = max(0, maximumByteCount - byteCount)
            acceptedCount = min(data.count, Int(clamping: remaining))
            if acceptedCount < data.count {
                didTruncate = true
            }
        } else {
            acceptedCount = data.count
        }

        guard acceptedCount > 0 else {
            didTruncate = true
            return
        }

        if acceptedCount == data.count {
            try fileHandle.write(contentsOf: data)
            hasher.update(data: data)
        } else {
            let acceptedData = Data(data.prefix(acceptedCount))
            try fileHandle.write(contentsOf: acceptedData)
            hasher.update(data: acceptedData)
        }
        byteCount += Int64(acceptedCount)
    }

    func finalize() async throws -> BodyReference {
        if let finalizedReference {
            return finalizedReference
        }
        guard let fileHandle else {
            throw PersistenceError.bodyWriterClosed
        }

        try fileHandle.close()
        self.fileHandle = nil

        let digest = BodyDigest(algorithm: .sha256, value: SHA256.hexDigest(hasher.finalize()))
        if let expectedDigest = metadata.digest,
            expectedDigest.algorithm != digest.algorithm
                || expectedDigest.value.lowercased() != digest.value
        {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw PersistenceError.bodyDigestMismatch(expected: expectedDigest, actual: digest)
        }

        let persistedMetadata = BodyMetadata(
            contentType: metadata.contentType,
            contentEncoding: metadata.contentEncoding,
            digest: digest,
            isTruncated: metadata.isTruncated || didTruncate
        )

        let reference: BodyReference
        let record: StoredBodyRecord
        if byteCount <= inlineBodyThreshold {
            let data = try Data(contentsOf: temporaryURL)
            reference = try BodyReference(
                id: id,
                byteCount: byteCount,
                contentType: persistedMetadata.contentType,
                contentEncoding: persistedMetadata.contentEncoding,
                digest: persistedMetadata.digest,
                isTruncated: persistedMetadata.isTruncated,
                storage: .inline(data)
            )
            record = StoredBodyRecord(reference: reference, relativePath: nil, inlineData: data)
            try FileManager.default.removeItem(at: temporaryURL)
        } else {
            let relativePath = "\(id.description).body"
            let finalURL = directoryURL.appendingPathComponent(relativePath)
            try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
            reference = try BodyReference(
                id: id,
                byteCount: byteCount,
                contentType: persistedMetadata.contentType,
                contentEncoding: persistedMetadata.contentEncoding,
                digest: persistedMetadata.digest,
                isTruncated: persistedMetadata.isTruncated,
                storage: .external(id)
            )
            record = StoredBodyRecord(
                reference: reference,
                relativePath: relativePath,
                inlineData: nil
            )
        }

        do {
            try await database.pool.write { database in
                try record.insert(into: database)
            }
        } catch {
            if let relativePath = record.relativePath {
                try? FileManager.default.removeItem(
                    at: directoryURL.appendingPathComponent(relativePath)
                )
            }
            throw error
        }

        finalizedReference = reference
        return reference
    }

    func cancel() async {
        if let fileHandle {
            try? fileHandle.close()
            self.fileHandle = nil
        }
        if finalizedReference == nil {
            try? FileManager.default.removeItem(at: temporaryURL)
        }
    }
}

private struct StoredBodyRecord: Sendable {
    let id: BodyID
    let byteCount: Int64
    let contentType: String?
    let contentEncoding: String?
    let digest: BodyDigest
    let isTruncated: Bool
    let storageKind: String
    let relativePath: String?
    let inlineData: Data?

    init(reference: BodyReference, relativePath: String?, inlineData: Data?) {
        self.id = reference.id
        self.byteCount = reference.byteCount
        self.contentType = reference.contentType
        self.contentEncoding = reference.contentEncoding
        self.digest = reference.digest ?? BodyDigest(algorithm: .sha256, value: "")
        self.isTruncated = reference.isTruncated
        self.storageKind = reference.isInline ? "inline" : "external"
        self.relativePath = relativePath
        self.inlineData = inlineData
    }

    static func fetch(_ bodyID: BodyID, from database: Database) throws -> StoredBodyRecord? {
        guard
            let row = try Row.fetchOne(
                database,
                sql: "SELECT * FROM bodies WHERE id = ?",
                arguments: [bodyID.description]
            )
        else {
            return nil
        }

        let algorithmValue: String = row["digest_algorithm"]
        guard let algorithm = BodyDigestAlgorithm(rawValue: algorithmValue) else {
            throw PersistenceError.bodyNotFound(bodyID)
        }
        return StoredBodyRecord(
            id: bodyID,
            byteCount: row["byte_count"],
            contentType: row["content_type"],
            contentEncoding: row["content_encoding"],
            digest: BodyDigest(algorithm: algorithm, value: row["digest_value"]),
            isTruncated: row["is_truncated"],
            storageKind: row["storage_kind"],
            relativePath: row["relative_path"],
            inlineData: row["inline_data"]
        )
    }

    private init(
        id: BodyID,
        byteCount: Int64,
        contentType: String?,
        contentEncoding: String?,
        digest: BodyDigest,
        isTruncated: Bool,
        storageKind: String,
        relativePath: String?,
        inlineData: Data?
    ) {
        self.id = id
        self.byteCount = byteCount
        self.contentType = contentType
        self.contentEncoding = contentEncoding
        self.digest = digest
        self.isTruncated = isTruncated
        self.storageKind = storageKind
        self.relativePath = relativePath
        self.inlineData = inlineData
    }

    func insert(into database: Database) throws {
        let arguments: StatementArguments = [
            id.description,
            byteCount,
            contentType,
            contentEncoding,
            digest.algorithm.rawValue,
            digest.value,
            isTruncated,
            storageKind,
            relativePath,
            inlineData,
            Date().timeIntervalSince1970
        ]
        try database.execute(
            sql: """
                INSERT INTO bodies (
                    id, byte_count, content_type, content_encoding, digest_algorithm,
                    digest_value, is_truncated, storage_kind, relative_path, inline_data,
                    created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: arguments
        )
    }
}

extension SHA256 {
    fileprivate static func hexDigest(of data: Data) -> String {
        hexDigest(hash(data: data))
    }

    fileprivate static func hexDigest<DigestBytes: Sequence>(_ digest: DigestBytes) -> String
    where DigestBytes.Element == UInt8 {
        let alphabet = Array("0123456789abcdef".utf8)
        var bytes = [UInt8]()
        bytes.reserveCapacity(64)
        for byte in digest {
            bytes.append(alphabet[Int(byte >> 4)])
            bytes.append(alphabet[Int(byte & 0x0F)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
