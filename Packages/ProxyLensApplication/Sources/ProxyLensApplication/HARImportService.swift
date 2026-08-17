import Foundation
import ProxyLensCore

public enum HARImportError: Error, Equatable, LocalizedError, Sendable {
    case fileTooLarge(maximumByteCount: Int)
    case tooManyEntries(maximum: Int)
    case bodyTooLarge(entry: Int, side: String, maximumByteCount: Int64)
    case invalidDocument(String)
    case invalidEntry(index: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .fileTooLarge(let maximumByteCount):
            "HAR files cannot exceed \(Self.byteCount(maximumByteCount))"
        case .tooManyEntries(let maximum):
            "HAR files cannot contain more than \(maximum.formatted()) entries"
        case .bodyTooLarge(let entry, let side, let maximumByteCount):
            "HAR entry \(entry + 1) has a \(side) body larger than \(Self.byteCount(maximumByteCount))"
        case .invalidDocument(let message):
            "Invalid HAR document: \(message)"
        case .invalidEntry(let index, let message):
            "Invalid HAR entry \(index + 1): \(message)"
        }
    }

    private static func byteCount(_ value: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }

    private static func byteCount(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

public struct HARImportResult: Equatable, Sendable {
    public let session: Session
    public let flows: [Flow]

    public init(session: Session, flows: [Flow]) {
        self.session = session
        self.flows = flows
    }
}

/// Imports a bounded HAR 1.2 document into a durable, offline session.
public struct HARImportService: Sendable {
    public static let defaultMaximumFileByteCount = 100 * 1_024 * 1_024
    public static let defaultMaximumEntryCount = 10_000
    public static let defaultMaximumBodyByteCount: Int64 = 50 * 1_024 * 1_024

    private let sessionStore: any SessionStore
    private let bodyStore: any BodyStore
    private let maximumFileByteCount: Int
    private let maximumEntryCount: Int
    private let maximumBodyByteCount: Int64

    public init(
        sessionStore: any SessionStore,
        bodyStore: any BodyStore,
        maximumFileByteCount: Int = Self.defaultMaximumFileByteCount,
        maximumEntryCount: Int = Self.defaultMaximumEntryCount,
        maximumBodyByteCount: Int64 = Self.defaultMaximumBodyByteCount
    ) {
        self.sessionStore = sessionStore
        self.bodyStore = bodyStore
        self.maximumFileByteCount = max(0, maximumFileByteCount)
        self.maximumEntryCount = max(0, maximumEntryCount)
        self.maximumBodyByteCount = max(0, maximumBodyByteCount)
    }

    public func importHAR(from fileURL: URL) async throws -> HARImportResult {
        let maximumFileByteCount = maximumFileByteCount
        let maximumEntryCount = maximumEntryCount
        let maximumBodyByteCount = maximumBodyByteCount
        let entries = try await Task.detached(priority: .userInitiated) {
            let data = try Self.readBoundedFile(
                at: fileURL,
                maximumByteCount: maximumFileByteCount
            )
            return try HARImportDocument.parse(
                data,
                maximumEntryCount: maximumEntryCount,
                maximumBodyByteCount: maximumBodyByteCount
            )
        }.value

        guard let firstStartedAt = entries.map(\.startedAt).min() else {
            throw HARImportError.invalidDocument("The log contains no entries")
        }

        var session = try await sessionStore.createSession(startedAt: firstStartedAt)
        var importedFlows: [Flow] = []
        importedFlows.reserveCapacity(entries.count)
        var writtenBodies: [BodyReference] = []
        writtenBodies.reserveCapacity(entries.count * 2)

        do {
            let fileName = fileURL.deletingPathExtension().lastPathComponent
            try session.rename(to: String(fileName.prefix(Session.maximumNameLength)))
            try await sessionStore.saveSession(session)
            let endedAt =
                entries
                .map { $0.startedAt.addingTimeInterval($0.totalDuration) }
                .max() ?? firstStartedAt
            try await sessionStore.stopSession(sessionID: session.id, at: endedAt)

            for entry in entries {
                let requestBody = try await write(entry.requestBody)
                if let requestBody {
                    writtenBodies.append(requestBody)
                }
                let responseBody = try await write(entry.responseBody)
                if let responseBody {
                    writtenBodies.append(responseBody)
                }
                let flow = try entry.makeFlow(
                    sessionID: session.id,
                    requestBody: requestBody,
                    responseBody: responseBody
                )
                try await sessionStore.save(flow)
                importedFlows.append(flow)
            }

            guard let stoppedSession = try await sessionStore.loadSession(sessionID: session.id)
            else {
                throw HARImportError.invalidDocument("The imported session could not be reloaded")
            }
            return HARImportResult(session: stoppedSession, flows: importedFlows)
        } catch {
            try? await sessionStore.removeSession(sessionID: session.id)
            for body in writtenBodies {
                try? await bodyStore.remove(body)
            }
            throw error
        }
    }

    private func write(_ body: HARImportDocument.Body?) async throws -> BodyReference? {
        guard let body else {
            return nil
        }
        return try await bodyStore.put(
            body.data,
            metadata: BodyMetadata(contentType: body.contentType)
        )
    }

    private static func readBoundedFile(at url: URL, maximumByteCount: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var data = Data()
        data.reserveCapacity(min(maximumByteCount, 1_024 * 1_024))
        while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            guard chunk.count <= maximumByteCount,
                data.count <= maximumByteCount - chunk.count
            else {
                throw HARImportError.fileTooLarge(maximumByteCount: maximumByteCount)
            }
            data.append(chunk)
        }
        return data
    }
}

private enum HARImportDocument {
    struct Body: Sendable {
        let data: Data
        let contentType: String?
    }

    struct Entry: Sendable {
        let index: Int
        let startedAt: Date
        let totalDuration: TimeInterval
        let sendDuration: TimeInterval
        let receiveDuration: TimeInterval
        let request: Request
        let response: Response?
        let requestBody: Body?
        let responseBody: Body?
        let comment: String?

        func makeFlow(
            sessionID: SessionID,
            requestBody: BodyReference?,
            responseBody: BodyReference?
        ) throws -> Flow {
            let port = request.url.port ?? (request.url.scheme == "https" ? 443 : 80)
            guard let host = request.url.host, let port = UInt16(exactly: port) else {
                throw HARImportError.invalidEntry(
                    index: index, message: "URL host or port is invalid")
            }
            let protocolKind: ConnectionProtocol = request.url.scheme == "https" ? .https : .http
            let graphqlOperation = self.requestBody.flatMap { body in
                GraphQLBodyView.operationMetadata(
                    data: body.data,
                    contentType: body.contentType,
                    contentEncoding: nil
                )
            }
            var flow = Flow(
                sessionID: sessionID,
                source: FlowSource(kind: .importedSession, label: "HAR Import"),
                request: HTTPRequest(
                    method: HTTPMethod(rawValue: request.method),
                    url: request.url,
                    headers: request.headers,
                    body: requestBody,
                    version: request.version,
                    rawTarget: request.url.pathAndQuery,
                    graphqlOperation: graphqlOperation
                ),
                connection: ConnectionInfo(
                    protocolKind: protocolKind,
                    upstreamHost: host,
                    upstreamPort: port,
                    tlsIntercepted: false
                ),
                startedAt: startedAt
            )
            try flow.transition(to: .receivingRequest)
            flow.markRequestHeadersReceived(at: startedAt)
            flow.markRequestBodyCompleted(at: startedAt.addingTimeInterval(sendDuration))

            let completedAt = startedAt.addingTimeInterval(totalDuration)
            guard let response else {
                try flow.transition(
                    to: .failed(.unknown(comment ?? "Response was not captured in the HAR file"))
                )
                flow.markCompleted(at: completedAt)
                return flow
            }

            try flow.transition(to: .connectingUpstream)
            let connectedAt = startedAt.addingTimeInterval(sendDuration)
            flow.markUpstreamConnected(at: connectedAt)
            if protocolKind == .https {
                flow.markTLSHandshakeCompleted(at: connectedAt)
            }
            try flow.transition(to: .receivingResponse)
            flow.attachResponse(
                try HTTPResponse(
                    statusCode: response.statusCode,
                    reasonPhrase: response.reasonPhrase,
                    headers: response.headers,
                    body: responseBody,
                    version: response.version
                )
            )
            let responseStartedAt = completedAt.addingTimeInterval(-receiveDuration)
            flow.markResponseHeadersReceived(at: max(responseStartedAt, connectedAt))
            flow.markResponseBodyCompleted(at: completedAt)
            try flow.transition(to: .completed)
            flow.markCompleted(at: completedAt)
            return flow
        }
    }

    struct Request: Sendable {
        let method: String
        let url: URL
        let version: HTTPVersion
        let headers: HTTPHeaders
    }

    struct Response: Sendable {
        let statusCode: Int
        let reasonPhrase: String?
        let version: HTTPVersion
        let headers: HTTPHeaders
    }

    static func parse(
        _ data: Data,
        maximumEntryCount: Int,
        maximumBodyByteCount: Int64
    ) throws -> [Entry] {
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            throw HARImportError.invalidDocument(error.localizedDescription)
        }
        guard document.log.version == "1.2" else {
            throw HARImportError.invalidDocument(
                "Unsupported HAR version \(document.log.version); expected 1.2"
            )
        }
        guard document.log.entries.count <= maximumEntryCount else {
            throw HARImportError.tooManyEntries(maximum: maximumEntryCount)
        }
        return try document.log.entries.enumerated().map { index, entry in
            try prepare(
                entry,
                index: index,
                maximumBodyByteCount: maximumBodyByteCount
            )
        }
    }

    private static func prepare(
        _ entry: DecodedEntry,
        index: Int,
        maximumBodyByteCount: Int64
    ) throws -> Entry {
        let startedAt = try date(entry.startedDateTime, entryIndex: index)
        let requestURL = try url(entry.request.url, entryIndex: index)
        let requestHeaders = try headers(entry.request.headers, entryIndex: index)
        let requestVersion = try version(entry.request.httpVersion, entryIndex: index)
        let requestBody = try body(
            text: entry.request.postData?.text,
            encoding: entry.request.postData?.encoding,
            contentType: entry.request.postData?.mimeType
                ?? requestHeaders.firstValue(for: "Content-Type"),
            declaredSize: nil,
            entryIndex: index,
            side: "request",
            maximumByteCount: maximumBodyByteCount
        )

        let responseHeaders = try headers(entry.response.headers, entryIndex: index)
        let response: Response?
        let responseBody: Body?
        if entry.response.status == 0 {
            response = nil
            responseBody = nil
        } else {
            response = Response(
                statusCode: entry.response.status,
                reasonPhrase: entry.response.statusText.nilIfEmpty,
                version: try version(entry.response.httpVersion, entryIndex: index),
                headers: responseHeaders
            )
            responseBody = try body(
                text: entry.response.content?.text,
                encoding: entry.response.content?.encoding,
                contentType: entry.response.content?.mimeType?.nilIfEmpty
                    ?? responseHeaders.firstValue(for: "Content-Type"),
                declaredSize: entry.response.content?.size,
                entryIndex: index,
                side: "response",
                maximumByteCount: maximumBodyByteCount
            )
        }

        let totalMilliseconds = max(0, entry.time ?? entry.timings.total)
        return Entry(
            index: index,
            startedAt: startedAt,
            totalDuration: totalMilliseconds / 1_000,
            sendDuration: min(max(0, entry.timings.send ?? 0), totalMilliseconds) / 1_000,
            receiveDuration: min(max(0, entry.timings.receive ?? 0), totalMilliseconds) / 1_000,
            request: Request(
                method: entry.request.method,
                url: requestURL,
                version: requestVersion,
                headers: requestHeaders
            ),
            response: response,
            requestBody: requestBody,
            responseBody: responseBody,
            comment: entry.comment?.nilIfEmpty
        )
    }

    private static func date(_ value: String, entryIndex: Int) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: value) else {
            throw HARImportError.invalidEntry(
                index: entryIndex,
                message: "startedDateTime is not ISO 8601"
            )
        }
        return date
    }

    private static func url(_ value: String, entryIndex: Int) throws -> URL {
        guard let url = URL(string: value),
            let scheme = url.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            url.host != nil
        else {
            throw HARImportError.invalidEntry(
                index: entryIndex,
                message: "request URL must be an absolute HTTP or HTTPS URL"
            )
        }
        return url
    }

    private static func version(_ value: String, entryIndex: Int) throws -> HTTPVersion {
        switch value.uppercased() {
        case "HTTP/1.0":
            return .http10
        case "HTTP/1.1", "":
            return .http11
        case "HTTP/2", "HTTP/2.0", "H2":
            return .http2
        case "HTTP/3", "HTTP/3.0", "H3":
            return .http3
        default:
            throw HARImportError.invalidEntry(
                index: entryIndex,
                message: "unsupported HTTP version \(value)"
            )
        }
    }

    private static func headers(_ values: [NameValue], entryIndex: Int) throws -> HTTPHeaders {
        do {
            return try HTTPHeaders(values.map { try HTTPHeader(name: $0.name, value: $0.value) })
        } catch {
            throw HARImportError.invalidEntry(
                index: entryIndex,
                message: "invalid header: \(error.localizedDescription)"
            )
        }
    }

    private static func body(
        text: String?,
        encoding: String?,
        contentType: String?,
        declaredSize: Int?,
        entryIndex: Int,
        side: String,
        maximumByteCount: Int64
    ) throws -> Body? {
        guard let text, !text.isEmpty || (declaredSize ?? 0) > 0 else {
            return nil
        }
        let data: Data
        switch encoding?.lowercased() {
        case nil, "":
            data = Data(text.utf8)
        case "base64":
            let normalized = String(text.filter { !$0.isWhitespace })
            guard let decoded = Data(base64Encoded: normalized) else {
                throw HARImportError.invalidEntry(
                    index: entryIndex,
                    message: "\(side) body is not valid base64"
                )
            }
            data = decoded
        case .some(let encoding):
            throw HARImportError.invalidEntry(
                index: entryIndex,
                message: "unsupported \(side) body encoding \(encoding)"
            )
        }
        guard Int64(data.count) <= maximumByteCount else {
            throw HARImportError.bodyTooLarge(
                entry: entryIndex,
                side: side,
                maximumByteCount: maximumByteCount
            )
        }
        return Body(data: data, contentType: contentType?.nilIfEmpty)
    }

    private struct Document: Decodable {
        let log: Log
    }

    private struct Log: Decodable {
        let version: String
        let entries: [DecodedEntry]
    }

    private struct DecodedEntry: Decodable {
        let startedDateTime: String
        let time: Double?
        let request: DecodedRequest
        let response: DecodedResponse
        let timings: Timings
        let comment: String?
    }

    private struct DecodedRequest: Decodable {
        let method: String
        let url: String
        let httpVersion: String
        let headers: [NameValue]
        let postData: PostData?

        private enum CodingKeys: String, CodingKey {
            case method
            case url
            case httpVersion
            case headers
            case postData
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            method = try container.decode(String.self, forKey: .method)
            url = try container.decode(String.self, forKey: .url)
            httpVersion = try container.decodeIfPresent(String.self, forKey: .httpVersion) ?? ""
            headers = try container.decodeIfPresent([NameValue].self, forKey: .headers) ?? []
            postData = try container.decodeIfPresent(PostData.self, forKey: .postData)
        }
    }

    private struct DecodedResponse: Decodable {
        let status: Int
        let statusText: String
        let httpVersion: String
        let headers: [NameValue]
        let content: Content?

        private enum CodingKeys: String, CodingKey {
            case status
            case statusText
            case httpVersion
            case headers
            case content
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try container.decode(Int.self, forKey: .status)
            statusText = try container.decodeIfPresent(String.self, forKey: .statusText) ?? ""
            httpVersion = try container.decodeIfPresent(String.self, forKey: .httpVersion) ?? ""
            headers = try container.decodeIfPresent([NameValue].self, forKey: .headers) ?? []
            content = try container.decodeIfPresent(Content.self, forKey: .content)
        }
    }

    private struct NameValue: Decodable {
        let name: String
        let value: String
    }

    private struct PostData: Decodable {
        let mimeType: String?
        let text: String?
        let encoding: String?
    }

    private struct Content: Decodable {
        let size: Int?
        let mimeType: String?
        let text: String?
        let encoding: String?
    }

    private struct Timings: Decodable {
        let send: Double?
        let wait: Double?
        let receive: Double?
        let connect: Double?

        var total: Double {
            [send, wait, receive, connect]
                .compactMap { $0 }
                .filter { $0 > 0 }
                .reduce(0, +)
        }

        private enum CodingKeys: String, CodingKey {
            case send
            case wait
            case receive
            case connect
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            send = try container.decodeIfPresent(Double.self, forKey: .send)
            wait = try container.decodeIfPresent(Double.self, forKey: .wait)
            receive = try container.decodeIfPresent(Double.self, forKey: .receive)
            connect = try container.decodeIfPresent(Double.self, forKey: .connect)
        }
    }
}

extension URL {
    fileprivate var pathAndQuery: String {
        var target = path.isEmpty ? "/" : path
        if let query {
            target += "?\(query)"
        }
        return target
    }
}

extension String {
    fileprivate var nilIfEmpty: String? {
        let normalized = trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
