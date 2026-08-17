import Foundation
import ProxyLensCore

public enum PortableSessionError: Error, Equatable, LocalizedError, Sendable {
    case sessionNotFound
    case invalidPackage(String)
    case unsupportedVersion(Int)
    case tooManyFlows(maximum: Int)
    case metadataTooLarge(maximumByteCount: Int)
    case bodyTooLarge(flow: Int, side: String, maximumByteCount: Int64)
    case packageTooLarge(maximumByteCount: Int64)

    public var errorDescription: String? {
        switch self {
        case .sessionNotFound:
            "The session is no longer available"
        case .invalidPackage(let message):
            "Invalid ProxyLens session: \(message)"
        case .unsupportedVersion(let version):
            "This ProxyLens session uses unsupported format version \(version)"
        case .tooManyFlows(let maximum):
            "ProxyLens sessions cannot contain more than \(maximum.formatted()) flows"
        case .metadataTooLarge(let maximumByteCount):
            "ProxyLens session metadata cannot exceed \(Self.byteCount(Int64(maximumByteCount)))"
        case .bodyTooLarge(let flow, let side, let maximumByteCount):
            "Flow \(flow + 1) has a \(side) body larger than \(Self.byteCount(maximumByteCount))"
        case .packageTooLarge(let maximumByteCount):
            "ProxyLens session bodies cannot exceed \(Self.byteCount(maximumByteCount)) in total"
        }
    }

    private static func byteCount(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

public struct PortableSessionImportResult: Equatable, Sendable {
    public let session: Session
    public let flows: [Flow]

    public init(session: Session, flows: [Flow]) {
        self.session = session
        self.flows = flows
    }
}

/// Imports and exports ProxyLens' versioned, local-first session package.
///
/// The package keeps metadata and raw bodies in separate files so large sessions are processed
/// one flow at a time and captured bytes never need to be represented as base64 JSON.
public struct PortableSessionService: Sendable {
    public static let fileExtension = "proxylens"
    public static let defaultMaximumFlowCount = 10_000
    public static let defaultMaximumMetadataByteCount = 2 * 1_024 * 1_024
    public static let defaultMaximumBodyByteCount: Int64 = 50 * 1_024 * 1_024
    public static let defaultMaximumPackageBodyByteCount: Int64 = 2 * 1_024 * 1_024 * 1_024

    private let sessionStore: any SessionStore
    private let bodyStore: any BodyStore
    private let maximumFlowCount: Int
    private let maximumMetadataByteCount: Int
    private let maximumBodyByteCount: Int64
    private let maximumPackageBodyByteCount: Int64

    public init(
        sessionStore: any SessionStore,
        bodyStore: any BodyStore,
        maximumFlowCount: Int = Self.defaultMaximumFlowCount,
        maximumMetadataByteCount: Int = Self.defaultMaximumMetadataByteCount,
        maximumBodyByteCount: Int64 = Self.defaultMaximumBodyByteCount,
        maximumPackageBodyByteCount: Int64 = Self.defaultMaximumPackageBodyByteCount
    ) {
        self.sessionStore = sessionStore
        self.bodyStore = bodyStore
        self.maximumFlowCount = max(0, maximumFlowCount)
        self.maximumMetadataByteCount = max(0, maximumMetadataByteCount)
        self.maximumBodyByteCount = max(0, maximumBodyByteCount)
        self.maximumPackageBodyByteCount = max(0, maximumPackageBodyByteCount)
    }

    public func exportSession(sessionID: SessionID, to destinationURL: URL) async throws {
        guard let session = try await sessionStore.loadSession(sessionID: sessionID) else {
            throw PortableSessionError.sessionNotFound
        }
        let flows = try await sessionStore.listFlows(in: sessionID).sorted(by: Self.flowOrder)
        guard flows.count <= maximumFlowCount else {
            throw PortableSessionError.tooManyFlows(maximum: maximumFlowCount)
        }

        let fileManager = FileManager.default
        let destinationURL = destinationURL.standardizedFileURL
        let parentURL = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        let stagingURL = parentURL.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).\(UUID().uuidString).staging",
            isDirectory: true
        )
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
        do {
            let flowsURL = stagingURL.appendingPathComponent("flows", isDirectory: true)
            let bodiesURL = stagingURL.appendingPathComponent("bodies", isDirectory: true)
            try fileManager.createDirectory(at: flowsURL, withIntermediateDirectories: false)
            try fileManager.createDirectory(at: bodiesURL, withIntermediateDirectories: false)

            let exportedAt = Date()
            let manifest = Manifest(
                format: Manifest.formatIdentifier,
                version: Manifest.currentVersion,
                exportedAt: exportedAt,
                session: SessionRecord(session: session),
                flowCount: flows.count
            )
            try writeMetadata(
                manifest,
                to: stagingURL.appendingPathComponent("manifest.json")
            )

            var exportedBodyByteCount: Int64 = 0
            for (index, flow) in flows.enumerated() {
                try Task.checkCancellation()
                let requestBodyRecord = flow.request.body.map(BodyRecord.init(reference:))
                let responseBodyRecord = flow.response?.body.map(BodyRecord.init(reference:))
                exportedBodyByteCount = try validatePackageBodySize(
                    requestBodyRecord,
                    currentTotal: exportedBodyByteCount,
                    flowIndex: index,
                    side: .request
                )
                exportedBodyByteCount = try validatePackageBodySize(
                    responseBodyRecord,
                    currentTotal: exportedBodyByteCount,
                    flowIndex: index,
                    side: .response
                )
                let requestBody = try await exportBody(
                    flow.request.body,
                    flowIndex: index,
                    side: .request,
                    bodiesURL: bodiesURL
                )
                let responseBody = try await exportBody(
                    flow.response?.body,
                    flowIndex: index,
                    side: .response,
                    bodiesURL: bodiesURL
                )
                var metadataOnlyFlow = flow.replacingIdentityAndBodies(
                    id: flow.id,
                    sessionID: flow.sessionID,
                    requestBody: nil,
                    responseBody: nil
                )
                if !metadataOnlyFlow.state.isTerminal {
                    try metadataOnlyFlow.transition(
                        to: .failed(
                            .unknown("Session was exported before this flow completed")
                        )
                    )
                    metadataOnlyFlow.markCompleted(at: exportedAt)
                }
                let record = FlowRecord(
                    flow: metadataOnlyFlow,
                    requestBody: requestBody,
                    responseBody: responseBody
                )
                try writeMetadata(
                    record,
                    to: flowsURL.appendingPathComponent(Self.flowFileName(index))
                )
            }

            try Self.replaceItem(at: destinationURL, with: stagingURL, fileManager: fileManager)
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }
    }

    public func importSession(from packageURL: URL) async throws -> PortableSessionImportResult {
        let packageURL = packageURL.standardizedFileURL
        try Self.validatePackageDirectory(packageURL)
        let manifest: Manifest = try Self.decodeBoundedJSON(
            at: packageURL.appendingPathComponent("manifest.json"),
            maximumByteCount: maximumMetadataByteCount
        )
        guard manifest.format == Manifest.formatIdentifier else {
            throw PortableSessionError.invalidPackage("The format identifier is invalid")
        }
        guard manifest.version == Manifest.currentVersion else {
            throw PortableSessionError.unsupportedVersion(manifest.version)
        }
        guard (0...maximumFlowCount).contains(manifest.flowCount) else {
            throw PortableSessionError.tooManyFlows(maximum: maximumFlowCount)
        }
        let flowsURL = packageURL.appendingPathComponent("flows", isDirectory: true)
        let bodiesURL = packageURL.appendingPathComponent("bodies", isDirectory: true)
        try Self.validatePackageDirectory(flowsURL)
        try Self.validatePackageDirectory(bodiesURL)

        var session = try await sessionStore.createSession(startedAt: manifest.session.startedAt)
        var importedFlows: [Flow] = []
        importedFlows.reserveCapacity(manifest.flowCount)
        var writtenBodies: [BodyReference] = []
        writtenBodies.reserveCapacity(manifest.flowCount * 2)
        var importedBodyByteCount: Int64 = 0

        do {
            try session.rename(to: manifest.session.name)
            try await sessionStore.saveSession(session)
            let endedAt = manifest.session.endedAt ?? manifest.exportedAt
            try await sessionStore.stopSession(sessionID: session.id, at: endedAt)

            for index in 0..<manifest.flowCount {
                try Task.checkCancellation()
                let record: FlowRecord = try Self.decodeBoundedJSON(
                    at: flowsURL.appendingPathComponent(Self.flowFileName(index)),
                    maximumByteCount: maximumMetadataByteCount
                )
                guard record.flow.request.body == nil, record.flow.response?.body == nil else {
                    throw PortableSessionError.invalidPackage(
                        "Flow \(index + 1) embeds body data in its metadata"
                    )
                }
                importedBodyByteCount = try validatePackageBodySize(
                    record.requestBody,
                    currentTotal: importedBodyByteCount,
                    flowIndex: index,
                    side: .request
                )
                importedBodyByteCount = try validatePackageBodySize(
                    record.responseBody,
                    currentTotal: importedBodyByteCount,
                    flowIndex: index,
                    side: .response
                )
                let requestBody = try await importBody(
                    record.requestBody,
                    flowIndex: index,
                    side: .request,
                    bodiesURL: bodiesURL
                )
                if let requestBody {
                    writtenBodies.append(requestBody)
                }
                let responseBody = try await importBody(
                    record.responseBody,
                    flowIndex: index,
                    side: .response,
                    bodiesURL: bodiesURL
                )
                if let responseBody {
                    writtenBodies.append(responseBody)
                }
                let importedFlow = record.flow.replacingIdentityAndBodies(
                    id: FlowID(),
                    sessionID: session.id,
                    requestBody: requestBody,
                    responseBody: responseBody
                )
                try await sessionStore.save(importedFlow)
                importedFlows.append(importedFlow)
            }

            guard let stoppedSession = try await sessionStore.loadSession(sessionID: session.id)
            else {
                throw PortableSessionError.invalidPackage(
                    "The imported session could not be reloaded"
                )
            }
            return PortableSessionImportResult(session: stoppedSession, flows: importedFlows)
        } catch {
            try? await sessionStore.removeSession(sessionID: session.id)
            for body in writtenBodies {
                try? await bodyStore.remove(body)
            }
            throw error
        }
    }

    private func exportBody(
        _ reference: BodyReference?,
        flowIndex: Int,
        side: BodySide,
        bodiesURL: URL
    ) async throws -> BodyRecord? {
        guard let reference else {
            return nil
        }
        guard reference.byteCount <= maximumBodyByteCount else {
            throw PortableSessionError.bodyTooLarge(
                flow: flowIndex,
                side: side.rawValue,
                maximumByteCount: maximumBodyByteCount
            )
        }
        let data = try await bodyStore.read(reference)
        guard Int64(data.count) == reference.byteCount else {
            throw PortableSessionError.invalidPackage(
                "Flow \(flowIndex + 1) \(side.rawValue) body size does not match its metadata"
            )
        }
        try data.write(
            to: bodiesURL.appendingPathComponent(Self.bodyFileName(flowIndex, side: side)),
            options: .atomic
        )
        return BodyRecord(reference: reference)
    }

    private func importBody(
        _ record: BodyRecord?,
        flowIndex: Int,
        side: BodySide,
        bodiesURL: URL
    ) async throws -> BodyReference? {
        guard let record else {
            return nil
        }
        let fileURL = bodiesURL.appendingPathComponent(Self.bodyFileName(flowIndex, side: side))
        try Self.validateRegularFile(fileURL)
        let writer = try await bodyStore.beginWrite(
            metadata: record.metadata,
            maximumByteCount: maximumBodyByteCount
        )
        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            var byteCount: Int64 = 0
            while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                guard Int64(chunk.count) <= maximumBodyByteCount - byteCount else {
                    throw PortableSessionError.bodyTooLarge(
                        flow: flowIndex,
                        side: side.rawValue,
                        maximumByteCount: maximumBodyByteCount
                    )
                }
                byteCount += Int64(chunk.count)
                try await writer.append(chunk)
            }
            guard byteCount == record.byteCount else {
                throw PortableSessionError.invalidPackage(
                    "Flow \(flowIndex + 1) \(side.rawValue) body size does not match its metadata"
                )
            }
            return try await writer.finalize()
        } catch {
            await writer.cancel()
            throw error
        }
    }

    private func validatePackageBodySize(
        _ record: BodyRecord?,
        currentTotal: Int64,
        flowIndex: Int,
        side: BodySide
    ) throws -> Int64 {
        guard let record else {
            return currentTotal
        }
        guard let digest = record.digest,
            digest.value.utf8.count == 64,
            digest.value.unicodeScalars.allSatisfy(Self.isHexadecimalDigit)
        else {
            throw PortableSessionError.invalidPackage(
                "Flow \(flowIndex + 1) \(side.rawValue) body has no valid SHA-256 digest"
            )
        }
        guard record.byteCount >= 0, record.byteCount <= maximumBodyByteCount else {
            throw PortableSessionError.bodyTooLarge(
                flow: flowIndex,
                side: side.rawValue,
                maximumByteCount: maximumBodyByteCount
            )
        }
        guard record.byteCount <= maximumPackageBodyByteCount - currentTotal else {
            throw PortableSessionError.packageTooLarge(
                maximumByteCount: maximumPackageBodyByteCount
            )
        }
        return currentTotal + record.byteCount
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func writeMetadata<T: Encodable>(_ value: T, to fileURL: URL) throws {
        let data = try Self.encode(value)
        guard data.count <= maximumMetadataByteCount else {
            throw PortableSessionError.metadataTooLarge(
                maximumByteCount: maximumMetadataByteCount
            )
        }
        try data.write(to: fileURL, options: .atomic)
    }

    private static func decodeBoundedJSON<T: Decodable>(
        at fileURL: URL,
        maximumByteCount: Int
    ) throws -> T {
        try validateRegularFile(fileURL)
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var data = Data()
        data.reserveCapacity(min(maximumByteCount, 64 * 1_024))
        while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            guard chunk.count <= maximumByteCount,
                data.count <= maximumByteCount - chunk.count
            else {
                throw PortableSessionError.metadataTooLarge(
                    maximumByteCount: maximumByteCount
                )
            }
            data.append(chunk)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        do {
            return try decoder.decode(T.self, from: data)
        } catch let error as PortableSessionError {
            throw error
        } catch {
            throw PortableSessionError.invalidPackage(error.localizedDescription)
        }
    }

    private static func validatePackageDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw PortableSessionError.invalidPackage("Choose a .proxylens package")
        }
    }

    private static func validateRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw PortableSessionError.invalidPackage(
                "The package contains a missing or unsafe file"
            )
        }
    }

    private static func replaceItem(
        at destinationURL: URL,
        with stagingURL: URL,
        fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: destinationURL.path) else {
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
            return
        }
        let backupName = ".\(destinationURL.lastPathComponent).\(UUID().uuidString).backup"
        _ = try fileManager.replaceItemAt(
            destinationURL,
            withItemAt: stagingURL,
            backupItemName: backupName
        )
        let backupURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(backupName)
        try? fileManager.removeItem(at: backupURL)
    }

    private static func flowOrder(_ lhs: Flow, _ rhs: Flow) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id.description < rhs.id.description
    }

    private static func flowFileName(_ index: Int) -> String {
        String(format: "%08d.json", index)
    }

    private static func bodyFileName(_ index: Int, side: BodySide) -> String {
        String(format: "%08d-%@.body", index, side.rawValue)
    }

    private static func isHexadecimalDigit(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...70, 97...102:
            true
        default:
            false
        }
    }
}

extension PortableSessionService {
    fileprivate enum BodySide: String {
        case request
        case response
    }

    fileprivate struct Manifest: Codable {
        static let formatIdentifier = "com.proxylens.session"
        static let currentVersion = 1

        let format: String
        let version: Int
        let exportedAt: Date
        let session: SessionRecord
        let flowCount: Int
    }

    fileprivate struct SessionRecord: Codable {
        let name: String?
        let startedAt: Date
        let endedAt: Date?
        let originalState: SessionState

        init(session: Session) {
            self.name = session.name
            self.startedAt = session.startedAt
            self.endedAt = session.endedAt
            self.originalState = session.state
        }
    }

    fileprivate struct FlowRecord: Codable {
        let flow: Flow
        let requestBody: BodyRecord?
        let responseBody: BodyRecord?
    }

    fileprivate struct BodyRecord: Codable {
        let byteCount: Int64
        let contentType: String?
        let contentEncoding: String?
        let digest: BodyDigest?
        let isTruncated: Bool

        init(reference: BodyReference) {
            self.byteCount = reference.byteCount
            self.contentType = reference.contentType
            self.contentEncoding = reference.contentEncoding
            self.digest = reference.digest
            self.isTruncated = reference.isTruncated
        }

        var metadata: BodyMetadata {
            BodyMetadata(
                contentType: contentType,
                contentEncoding: contentEncoding,
                digest: digest,
                isTruncated: isTruncated
            )
        }
    }
}
