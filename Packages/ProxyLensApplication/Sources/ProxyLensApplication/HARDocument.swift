import Foundation
import ProxyLensCore

enum HARDocument {
    static let creatorName = "ProxyLens"
    static let creatorVersion = "0.1.0"

    static var streamPreamble: Data {
        Data(
            """
            {
              "log" : {
                "creator" : {
                  "name" : "\(creatorName)",
                  "version" : "\(creatorVersion)"
                },
                "entries" : [

            """.utf8
        )
    }

    static let streamEntrySeparator = Data(",\n".utf8)
    static let streamEpilogue = Data(
        """

            ],
            "version" : "1.2"
          }
        }

        """.utf8
    )

    static func serialize(
        flow: Flow,
        requestBody: Data?,
        responseBody: Data?,
        comments: [String] = []
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(
            Document(
                log: Log(
                    version: "1.2",
                    creator: Creator(name: creatorName, version: creatorVersion),
                    entries: [
                        Entry(
                            flow: flow,
                            requestBody: requestBody,
                            responseBody: responseBody,
                            comments: comments
                        )
                    ]
                )
            )
        )
    }

    static func serializeEntry(
        flow: Flow,
        requestBody: Data?,
        responseBody: Data?,
        comments: [String] = []
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(
            Entry(
                flow: flow,
                requestBody: requestBody,
                responseBody: responseBody,
                comments: comments
            )
        )
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func elapsedMilliseconds(from start: Date, to end: Date) -> Double {
        max(0, end.timeIntervalSince(start) * 1_000)
    }

    private static func optionalMilliseconds(from start: Date?, to end: Date?) -> Double {
        guard let start, let end else {
            return -1
        }

        return elapsedMilliseconds(from: start, to: end)
    }

    private static func encodedText(_ data: Data) -> (text: String, encoding: String?) {
        if !data.contains(0), let text = String(data: data, encoding: .utf8) {
            return (text, nil)
        }

        return (data.base64EncodedString(), "base64")
    }

    private static func cookies(from headerValues: [String]) -> [NameValue] {
        headerValues.flatMap { value in
            value.split(separator: ";").compactMap { pair -> NameValue? in
                let trimmed = pair.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else {
                    return nil
                }
                if let separator = trimmed.firstIndex(of: "=") {
                    return NameValue(
                        name: String(trimmed[..<separator]),
                        value: String(trimmed[trimmed.index(after: separator)])
                    )
                }
                return NameValue(name: trimmed, value: "")
            }
        }
    }

    private static func setCookies(from headerValues: [String]) -> [NameValue] {
        headerValues.compactMap { value in
            let pair = value.split(separator: ";", maxSplits: 1).first.map(String.init) ?? value
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                return nil
            }
            if let separator = trimmed.firstIndex(of: "=") {
                return NameValue(
                    name: String(trimmed[..<separator]),
                    value: String(trimmed[trimmed.index(after: separator)])
                )
            }
            return NameValue(name: trimmed, value: "")
        }
    }

    private static func queryString(from url: URL) -> [NameValue] {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map { item in
            NameValue(name: item.name, value: item.value ?? "")
        } ?? []
    }

    private static func headers(from headers: HTTPHeaders) -> [NameValue] {
        headers.map { NameValue(name: $0.name, value: $0.value) }
    }

    private struct Document: Encodable {
        let log: Log
    }

    private struct Log: Encodable {
        let version: String
        let creator: Creator
        let entries: [Entry]
    }

    private struct Creator: Encodable {
        let name: String
        let version: String
    }

    private struct Entry: Encodable {
        let startedDateTime: String
        let time: Double
        let request: Request
        let response: Response
        let cache: Cache
        let timings: Timings
        let comment: String?

        init(
            flow: Flow,
            requestBody: Data?,
            responseBody: Data?,
            comments: [String]
        ) {
            startedDateTime = HARDocument.iso8601String(from: flow.timing.startedAt)
            timings = Timings(timing: flow.timing)
            time = timings.totalElapsed
            request = Request(request: flow.request, body: requestBody)
            response = Response(response: flow.response, body: responseBody)
            cache = Cache()
            let joined = comments.joined(separator: ". ")
            comment = joined.isEmpty ? nil : joined
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(startedDateTime, forKey: .startedDateTime)
            try container.encode(time, forKey: .time)
            try container.encode(request, forKey: .request)
            try container.encode(response, forKey: .response)
            try container.encode(cache, forKey: .cache)
            try container.encode(timings, forKey: .timings)
            try container.encodeIfPresent(comment, forKey: .comment)
        }

        private enum CodingKeys: String, CodingKey {
            case startedDateTime
            case time
            case request
            case response
            case cache
            case timings
            case comment
        }
    }

    private struct Request: Encodable {
        let method: String
        let url: String
        let httpVersion: String
        let cookies: [NameValue]
        let headers: [NameValue]
        let queryString: [NameValue]
        let postData: PostData?
        let headersSize: Int
        let bodySize: Int

        init(request: HTTPRequest, body: Data?) {
            method = request.method.rawValue
            url = request.url.absoluteString
            httpVersion = request.version.rawValue
            cookies = HARDocument.cookies(from: request.headers.values(for: "Cookie"))
            headers = HARDocument.headers(from: request.headers)
            queryString = HARDocument.queryString(from: request.url)
            if let body, request.body != nil {
                let encoded = HARDocument.encodedText(body)
                postData = PostData(
                    mimeType: request.body?.contentType
                        ?? request.headers.firstValue(for: "Content-Type")
                        ?? "",
                    text: encoded.text,
                    encoding: encoded.encoding
                )
            } else {
                postData = nil
            }
            headersSize = -1
            bodySize = request.body.map { Int($0.byteCount) } ?? 0
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(method, forKey: .method)
            try container.encode(url, forKey: .url)
            try container.encode(httpVersion, forKey: .httpVersion)
            try container.encode(cookies, forKey: .cookies)
            try container.encode(headers, forKey: .headers)
            try container.encode(queryString, forKey: .queryString)
            try container.encodeIfPresent(postData, forKey: .postData)
            try container.encode(headersSize, forKey: .headersSize)
            try container.encode(bodySize, forKey: .bodySize)
        }

        private enum CodingKeys: String, CodingKey {
            case method
            case url
            case httpVersion
            case cookies
            case headers
            case queryString
            case postData
            case headersSize
            case bodySize
        }
    }

    private struct Response: Encodable {
        let status: Int
        let statusText: String
        let httpVersion: String
        let cookies: [NameValue]
        let headers: [NameValue]
        let content: Content
        let redirectURL: String
        let headersSize: Int
        let bodySize: Int

        init(response: HTTPResponse?, body: Data?) {
            guard let response else {
                status = 0
                statusText = ""
                httpVersion = HTTPVersion.http11.rawValue
                cookies = []
                headers = []
                content = Content(size: 0, mimeType: "", text: "", encoding: nil)
                redirectURL = ""
                headersSize = -1
                bodySize = 0
                return
            }

            status = response.statusCode
            statusText = response.reasonPhrase ?? ""
            httpVersion = response.version.rawValue
            cookies = HARDocument.setCookies(from: response.headers.values(for: "Set-Cookie"))
            headers = HARDocument.headers(from: response.headers)
            let mimeType =
                response.body?.contentType
                ?? response.headers.firstValue(for: "Content-Type")
                ?? ""
            if let body {
                let encoded = HARDocument.encodedText(body)
                content = Content(
                    size: Int(response.body?.byteCount ?? Int64(body.count)),
                    mimeType: mimeType,
                    text: encoded.text,
                    encoding: encoded.encoding
                )
            } else {
                content = Content(size: 0, mimeType: mimeType, text: "", encoding: nil)
            }
            redirectURL = response.headers.firstValue(for: "Location") ?? ""
            headersSize = -1
            bodySize = response.body.map { Int($0.byteCount) } ?? 0
        }
    }

    private struct Content: Encodable {
        let size: Int
        let mimeType: String
        let text: String
        let encoding: String?

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(size, forKey: .size)
            try container.encode(mimeType, forKey: .mimeType)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(encoding, forKey: .encoding)
        }

        private enum CodingKeys: String, CodingKey {
            case size
            case mimeType
            case text
            case encoding
        }
    }

    private struct PostData: Encodable {
        let mimeType: String
        let text: String
        let encoding: String?

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(mimeType, forKey: .mimeType)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(encoding, forKey: .encoding)
        }

        private enum CodingKeys: String, CodingKey {
            case mimeType
            case text
            case encoding
        }
    }

    private struct Timings: Encodable {
        let blocked: Double
        let dns: Double
        let connect: Double
        let send: Double
        let wait: Double
        let receive: Double
        let ssl: Double

        init(timing: FlowTiming) {
            blocked = -1
            dns = -1

            let sendEnd = timing.requestBodyCompletedAt ?? timing.startedAt
            send = HARDocument.elapsedMilliseconds(from: timing.startedAt, to: sendEnd)

            let connectEndMark = timing.tlsHandshakeCompletedAt ?? timing.upstreamConnectedAt
            let connectEnd: Date
            if let connectEndMark, connectEndMark >= sendEnd {
                connect = HARDocument.elapsedMilliseconds(from: sendEnd, to: connectEndMark)
                let sslDuration = HARDocument.optionalMilliseconds(
                    from: timing.upstreamConnectedAt,
                    to: timing.tlsHandshakeCompletedAt
                )
                ssl = sslDuration < 0 ? -1 : min(sslDuration, connect)
                connectEnd = connectEndMark
            } else {
                connect = -1
                ssl = -1
                connectEnd = sendEnd
            }

            let waitEnd =
                timing.responseHeadersReceivedAt
                ?? timing.completedAt
                ?? connectEnd
            wait = HARDocument.elapsedMilliseconds(
                from: connectEnd,
                to: waitEnd < connectEnd ? connectEnd : waitEnd
            )

            if timing.responseHeadersReceivedAt == nil {
                receive = 0
            } else {
                let receiveEnd =
                    timing.completedAt
                    ?? timing.responseBodyCompletedAt
                    ?? waitEnd
                receive = HARDocument.elapsedMilliseconds(
                    from: waitEnd,
                    to: receiveEnd < waitEnd ? waitEnd : receiveEnd
                )
            }
        }

        var totalElapsed: Double {
            send + wait + receive + (connect >= 0 ? connect : 0)
        }
    }

    private struct Cache: Encodable {}

    private struct NameValue: Encodable {
        let name: String
        let value: String
    }
}
