import Foundation
import ProxyLensCore

public enum OpenAPIExportError: LocalizedError, Equatable, Sendable {
    case noFlows
    case unsupportedMethod(String)

    public var errorDescription: String? {
        switch self {
        case .noFlows:
            "Select at least one flow to export as OpenAPI."
        case .unsupportedMethod(let method):
            "The HTTP method \(method) cannot be represented by an OpenAPI operation."
        }
    }
}

public struct OpenAPIExportOptions: Equatable, Sendable {
    public let title: String
    public let version: String

    public init(
        title: String = "ProxyLens Capture",
        version: String = "1.0.0"
    ) {
        self.title =
            title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "ProxyLens Capture"
            : title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.version =
            version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "1.0.0"
            : version.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Builds a small, deterministic OpenAPI 3.0 description from captured flows.
///
/// Header values and body examples are intentionally omitted. The export describes the
/// observed API shape while avoiding accidental disclosure of authorization, cookie, or
/// customer data. Raw bodies remain available through the flow and HAR exports.
enum OpenAPIDocument {
    private static let supportedMethods = [
        "get", "put", "post", "delete", "options", "head", "patch", "trace"
    ]
    private static let maximumSchemaBodyByteCount = 1_048_576

    static func serialize(
        flows: [Flow],
        requestBodies: [FlowID: Data?],
        responseBodies: [FlowID: Data?],
        options: OpenAPIExportOptions
    ) throws -> Data {
        guard !flows.isEmpty else {
            throw OpenAPIExportError.noFlows
        }

        var servers = Set<String>()
        var paths: [String: [String: OperationDraft]] = [:]

        for flow in flows {
            let method = try operationMethod(for: flow.request.method)
            let path = openAPIPath(for: flow.request.url)
            if let server = serverURL(for: flow.request.url) {
                servers.insert(server)
            }

            var operation = paths[path, default: [:]][method] ?? OperationDraft()
            operation.queryNames.formUnion(queryNames(for: flow.request.url))
            if let body = flow.request.body {
                let mediaType = normalizedMediaType(body.contentType)
                operation.requestContent[mediaType] = schema(
                    for: body,
                    data: requestBodies[flow.id] ?? nil
                )
            }

            if let response = flow.response {
                let status = String(response.statusCode)
                var responseDraft =
                    operation.responses[status]
                    ?? ResponseDraft(description: responseDescription(for: response), content: [:])
                if let body = response.body {
                    let mediaType = normalizedMediaType(body.contentType)
                    responseDraft.content[mediaType] = schema(
                        for: body,
                        data: responseBodies[flow.id] ?? nil
                    )
                }
                operation.responses[status] = responseDraft
            } else {
                operation.responses["default"] = ResponseDraft(
                    description: "Response was not captured.",
                    content: [:]
                )
            }
            paths[path, default: [:]][method] = operation
        }

        let generatedDescription = "Generated from \(flows.count) captured flow(s)."
        var lines = [
            "openapi: \"3.0.3\"",
            "info:",
            "  title: \(yamlScalar(options.title))",
            "  version: \(yamlScalar(options.version))",
            "  description: \(yamlScalar(generatedDescription))"
        ]
        if !servers.isEmpty {
            lines.append("servers:")
            for server in servers.sorted() {
                lines.append("  - url: \(yamlScalar(server))")
            }
        }

        lines.append("paths:")
        for path in paths.keys.sorted() {
            lines.append("  \(yamlScalar(path)):")
            let operations = paths[path] ?? [:]
            for method in supportedMethods where operations[method] != nil {
                guard let operation = operations[method] else {
                    continue
                }
                lines.append("    \(method):")
                lines.append(
                    "      operationId: \(yamlScalar(operationID(method: method, path: path)))")
                appendParameters(operation.queryNames, to: &lines)
                appendRequestBody(operation.requestContent, to: &lines)
                lines.append("      responses:")
                for status in operation.responses.keys.sorted(by: responseKeySort) {
                    guard let response = operation.responses[status] else {
                        continue
                    }
                    lines.append("        \(yamlScalar(status)):")
                    lines.append("          description: \(yamlScalar(response.description))")
                    appendContent(response.content, indent: 10, to: &lines)
                }
            }
        }

        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private struct OperationDraft {
        var queryNames = Set<String>()
        var requestContent: [String: OpenAPISchema] = [:]
        var responses: [String: ResponseDraft] = [:]
    }

    private struct ResponseDraft {
        let description: String
        var content: [String: OpenAPISchema]
    }

    private indirect enum OpenAPISchema: Equatable {
        case object(properties: [String: OpenAPISchema])
        case array(OpenAPISchema)
        case string(format: String?)
        case integer
        case number
        case boolean
        case null
    }

    private static func operationMethod(for method: HTTPMethod) throws -> String {
        let value = method.rawValue.lowercased()
        guard supportedMethods.contains(value) else {
            throw OpenAPIExportError.unsupportedMethod(method.rawValue)
        }
        return value
    }

    private static func openAPIPath(for url: URL) -> String {
        let path =
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        return path.isEmpty ? "/" : (path.hasPrefix("/") ? path : "/\(path)")
    }

    private static func serverURL(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else {
            return nil
        }
        let renderedHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        var result = "\(scheme)://\(renderedHost)"
        if let port = url.port,
            !((scheme == "http" && port == 80) || (scheme == "https" && port == 443))
        {
            result += ":\(port)"
        }
        return result
    }

    private static func queryNames(for url: URL) -> Set<String> {
        Set(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.compactMap {
                let name = $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? nil : name
            } ?? []
        )
    }

    private static func normalizedMediaType(_ contentType: String?) -> String {
        guard let contentType else {
            return "application/octet-stream"
        }
        let value =
            contentType.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? "application/octet-stream" : normalized
    }

    private static func schema(for reference: BodyReference, data: Data?) -> OpenAPISchema {
        let mediaType = normalizedMediaType(reference.contentType)
        guard mediaType == "application/json" || mediaType.hasSuffix("+json") else {
            return .string(format: mediaType == "application/octet-stream" ? "binary" : nil)
        }
        guard !reference.isTruncated, let data, data.count <= maximumSchemaBodyByteCount else {
            return .string(format: nil)
        }
        guard
            let decoded = try? HTTPContentCoding.decode(
                data,
                contentEncoding: reference.contentEncoding,
                maximumOutputByteCount: maximumSchemaBodyByteCount
            ),
            let object = try? JSONSerialization.jsonObject(
                with: decoded,
                options: [.fragmentsAllowed]
            )
        else {
            return .string(format: nil)
        }
        return schema(for: object)
    }

    private static func schema(for value: Any) -> OpenAPISchema {
        switch value {
        case let dictionary as [String: Any]:
            return .object(
                properties: dictionary.keys.sorted().reduce(into: [:]) { result, key in
                    if let value = dictionary[key] {
                        result[key] = schema(for: value)
                    }
                }
            )
        case let array as [Any]:
            if let first = array.first {
                return .array(schema(for: first))
            }
            return .array(.string(format: nil))
        case is Bool:
            return .boolean
        case is Int, is Int8, is Int16, is Int32, is Int64, is UInt, is UInt8, is UInt16,
            is UInt32, is UInt64:
            return .integer
        case is Double, is Float, is Decimal:
            return .number
        case is NSNull:
            return .null
        default:
            return .string(format: nil)
        }
    }

    private static func appendParameters(_ names: Set<String>, to lines: inout [String]) {
        guard !names.isEmpty else {
            return
        }
        lines.append("      parameters:")
        for name in names.sorted() {
            lines.append("        - in: \"query\"")
            lines.append("          name: \(yamlScalar(name))")
            lines.append("          required: false")
            lines.append("          schema:")
            lines.append("            type: \"string\"")
        }
    }

    private static func appendRequestBody(
        _ content: [String: OpenAPISchema],
        to lines: inout [String]
    ) {
        guard !content.isEmpty else {
            return
        }
        lines.append("      requestBody:")
        lines.append("        required: true")
        appendContent(content, indent: 8, to: &lines)
    }

    private static func appendContent(
        _ content: [String: OpenAPISchema],
        indent: Int,
        to lines: inout [String]
    ) {
        guard !content.isEmpty else {
            return
        }
        let prefix = String(repeating: " ", count: indent)
        lines.append("\(prefix)content:")
        for mediaType in content.keys.sorted() {
            guard let schema = content[mediaType] else {
                continue
            }
            lines.append("\(prefix)  \(yamlScalar(mediaType)):")
            lines.append("\(prefix)    schema:")
            appendSchema(schema, indent: indent + 6, to: &lines)
        }
    }

    private static func appendSchema(
        _ schema: OpenAPISchema,
        indent: Int,
        to lines: inout [String]
    ) {
        let prefix = String(repeating: " ", count: indent)
        switch schema {
        case .object(let properties):
            lines.append("\(prefix)type: \"object\"")
            guard !properties.isEmpty else {
                return
            }
            lines.append("\(prefix)properties:")
            for key in properties.keys.sorted() {
                guard let value = properties[key] else {
                    continue
                }
                lines.append("\(prefix)  \(yamlScalar(key)):")
                appendSchema(value, indent: indent + 4, to: &lines)
            }
        case .array(let item):
            lines.append("\(prefix)type: \"array\"")
            lines.append("\(prefix)items:")
            appendSchema(item, indent: indent + 2, to: &lines)
        case .string(let format):
            lines.append("\(prefix)type: \"string\"")
            if let format {
                lines.append("\(prefix)format: \(yamlScalar(format))")
            }
        case .integer:
            lines.append("\(prefix)type: \"integer\"")
        case .number:
            lines.append("\(prefix)type: \"number\"")
        case .boolean:
            lines.append("\(prefix)type: \"boolean\"")
        case .null:
            lines.append("\(prefix)nullable: true")
        }
    }

    private static func responseDescription(for response: HTTPResponse) -> String {
        let reason = response.reasonPhrase?.trimmingCharacters(in: .whitespacesAndNewlines)
        return reason?.isEmpty == false ? reason! : "HTTP \(response.statusCode)"
    }

    private static func responseKeySort(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == "default" {
            return false
        }
        if rhs == "default" {
            return true
        }
        return (Int(lhs) ?? Int.max) < (Int(rhs) ?? Int.max)
    }

    private static func operationID(method: String, path: String) -> String {
        let words = path.split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !$0.isEmpty }
        let suffix = words.map { word in
            word.prefix(1).uppercased() + word.dropFirst()
        }.joined()
        return method + (suffix.isEmpty ? "Root" : suffix)
    }

    private static func yamlScalar(_ value: String) -> String {
        let escaped =
            value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}
