import Foundation
import ProxyLensCore

public enum RequestCodeLanguage: String, CaseIterable, Sendable {
    case curl
    case httpie
    case javascriptFetch
    case javascriptAxios
    case pythonRequests
    case swiftURLSession
    case goNetHTTP
    case javaHttpClient

    public var displayName: String {
        switch self {
        case .curl: "cURL"
        case .httpie: "HTTPie"
        case .javascriptFetch: "JavaScript — fetch"
        case .javascriptAxios: "JavaScript — Axios"
        case .pythonRequests: "Python — requests"
        case .swiftURLSession: "Swift — URLSession"
        case .goNetHTTP: "Go — net/http"
        case .javaHttpClient: "Java — HttpClient"
        }
    }
}

public struct RequestCodeSnippet: Equatable, Sendable {
    public let language: RequestCodeLanguage
    public let source: String

    public init(language: RequestCodeLanguage, source: String) {
        self.language = language
        self.source = source
    }
}

enum RequestCodeGenerator {
    private static let skippedHeaderNames: Set<String> = [
        "content-length",
        "transfer-encoding",
        "connection",
        "keep-alive",
        "proxy-connection",
        "te",
        "trailers",
        "upgrade"
    ]

    static func generate(
        request: HTTPRequest,
        body: Data?,
        language: RequestCodeLanguage,
        comments: [String] = []
    ) -> String {
        let headers = request.headers.filter {
            !skippedHeaderNames.contains($0.name.lowercased())
        }
        return switch language {
        case .curl:
            CURLCommand.serialize(request: request, body: body, comments: comments)
        case .httpie:
            httpie(request: request, headers: headers, body: body, comments: comments)
        case .javascriptFetch:
            javascript(request: request, headers: headers, body: body, comments: comments)
        case .javascriptAxios:
            axios(request: request, headers: headers, body: body, comments: comments)
        case .pythonRequests:
            python(request: request, headers: headers, body: body, comments: comments)
        case .swiftURLSession:
            swift(request: request, headers: headers, body: body, comments: comments)
        case .goNetHTTP:
            goNetHTTP(request: request, headers: headers, body: body, comments: comments)
        case .javaHttpClient:
            javaHttpClient(request: request, headers: headers, body: body, comments: comments)
        }
    }

    private static func httpie(
        request: HTTPRequest,
        headers: [HTTPHeader],
        body: Data?,
        comments: [String]
    ) -> String {
        var lines = comments.map { "# \($0)" }
        var command = [
            "http",
            posixQuoted(request.method.rawValue),
            posixQuoted(request.url.absoluteString)
        ]
        command.append(contentsOf: headers.map { posixQuoted("\($0.name):\($0.value)") })

        guard let body else {
            lines.append(command.joined(separator: " "))
            return lines.joined(separator: "\n")
        }

        if let text = String(data: body, encoding: .utf8), !body.contains(0) {
            lines.append(
                "printf '%s' \(posixQuoted(text)) | \(command.joined(separator: " "))"
            )
        } else {
            let encoded = body.base64EncodedString()
            lines.append(
                "printf '%s' \(posixQuoted(encoded)) | base64 --decode | \(command.joined(separator: " "))"
            )
        }
        return lines.joined(separator: "\n")
    }

    private static func javascript(
        request: HTTPRequest,
        headers: [HTTPHeader],
        body: Data?,
        comments: [String]
    ) -> String {
        var lines = comments.map { "// \($0)" }
        lines.append("const headers = new Headers();")
        for header in headers {
            lines.append(
                "headers.append(\(javascriptLiteral(header.name)), \(javascriptLiteral(header.value)));"
            )
        }
        lines.append("")

        var bodyExpression: String?
        if let body {
            if let text = String(data: body, encoding: .utf8), !body.contains(0) {
                bodyExpression = javascriptLiteral(text)
            } else {
                lines.append(
                    "const body = Uint8Array.from(atob(\(javascriptLiteral(body.base64EncodedString()))), character => character.charCodeAt(0));"
                )
                lines.append("")
                bodyExpression = "body"
            }
        }

        lines.append(
            "const response = await fetch(\(javascriptLiteral(request.url.absoluteString)), {")
        lines.append("  method: \(javascriptLiteral(request.method.rawValue)),")
        lines.append("  headers,")
        if let bodyExpression {
            lines.append("  body: \(bodyExpression),")
        }
        lines.append("});")
        lines.append("")
        lines.append("console.log(await response.text());")
        return lines.joined(separator: "\n")
    }

    private static func python(
        request: HTTPRequest,
        headers: [HTTPHeader],
        body: Data?,
        comments: [String]
    ) -> String {
        var lines = comments.map { "# \($0)" }
        let isBinary =
            body.map { String(data: $0, encoding: .utf8) == nil || $0.contains(0) } ?? false
        if isBinary {
            lines.append("import base64")
        }
        lines.append("import requests")
        lines.append("")
        lines.append("headers = {")
        for header in headers {
            lines.append("    \(pythonLiteral(header.name)): \(pythonLiteral(header.value)),")
        }
        lines.append("}")

        var bodyExpression: String?
        if let body {
            if !isBinary, let text = String(data: body, encoding: .utf8) {
                bodyExpression = pythonLiteral(text)
            } else {
                bodyExpression = "base64.b64decode(\(pythonLiteral(body.base64EncodedString())))"
            }
        }

        lines.append("")
        lines.append("response = requests.request(")
        lines.append("    \(pythonLiteral(request.method.rawValue)),")
        lines.append("    \(pythonLiteral(request.url.absoluteString)),")
        lines.append("    headers=headers,")
        if let bodyExpression {
            lines.append("    data=\(bodyExpression),")
        }
        lines.append(")")
        lines.append("")
        lines.append("print(response.text)")
        return lines.joined(separator: "\n")
    }

    private static func axios(
        request: HTTPRequest,
        headers: [HTTPHeader],
        body: Data?,
        comments: [String]
    ) -> String {
        var lines = comments.map { "// \($0)" }
        lines.append("import axios from \"axios\";")
        lines.append("")

        var bodyExpression: String?
        if let body {
            if let text = String(data: body, encoding: .utf8), !body.contains(0) {
                bodyExpression = javascriptLiteral(text)
            } else {
                lines.append(
                    "const body = Buffer.from(\(javascriptLiteral(body.base64EncodedString())), \"base64\");"
                )
                lines.append("")
                bodyExpression = "body"
            }
        }

        lines.append("const response = await axios.request({")
        lines.append("  method: \(javascriptLiteral(request.method.rawValue)),")
        lines.append("  url: \(javascriptLiteral(request.url.absoluteString)),")
        lines.append("  headers: {")
        for header in headers {
            lines.append(
                "    \(javascriptLiteral(header.name)): \(javascriptLiteral(header.value)),"
            )
        }
        lines.append("  },")
        if let bodyExpression {
            lines.append("  data: \(bodyExpression),")
        }
        lines.append("});")
        lines.append("")
        lines.append("console.log(response.data);")
        return lines.joined(separator: "\n")
    }

    private static func swift(
        request: HTTPRequest,
        headers: [HTTPHeader],
        body: Data?,
        comments: [String]
    ) -> String {
        var lines = comments.map { "// \($0)" }
        lines.append("import Foundation")
        lines.append("")
        lines.append(
            "var request = URLRequest(url: URL(string: \(swiftLiteral(request.url.absoluteString)))!)"
        )
        lines.append("request.httpMethod = \(swiftLiteral(request.method.rawValue))")
        for header in headers {
            lines.append(
                "request.addValue(\(swiftLiteral(header.value)), forHTTPHeaderField: \(swiftLiteral(header.name)))"
            )
        }
        if let body {
            if let text = String(data: body, encoding: .utf8), !body.contains(0) {
                lines.append("request.httpBody = Data(\(swiftLiteral(text)).utf8)")
            } else {
                lines.append(
                    "request.httpBody = Data(base64Encoded: \(swiftLiteral(body.base64EncodedString())))!"
                )
            }
        }
        lines.append("")
        lines.append("let (data, response) = try await URLSession.shared.data(for: request)")
        lines.append("print(response)")
        lines.append("print(String(decoding: data, as: UTF8.self))")
        return lines.joined(separator: "\n")
    }

    private static func goNetHTTP(
        request: HTTPRequest,
        headers: [HTTPHeader],
        body: Data?,
        comments: [String]
    ) -> String {
        var imports = ["fmt", "io", "net/http"]
        if body != nil {
            imports.append("bytes")
        }
        let isBinary =
            body.map { String(data: $0, encoding: .utf8) == nil || $0.contains(0) } ?? false
        if isBinary {
            imports.append("encoding/base64")
        }
        imports.sort()

        var lines = comments.map { "// \($0)" }
        lines.append("package main")
        lines.append("")
        lines.append("import (")
        lines.append(contentsOf: imports.map { "\t\(goLiteral($0))" })
        lines.append(")")
        lines.append("")
        lines.append("func main() {")

        let bodyReader: String
        if let body {
            if isBinary {
                lines.append(
                    "\tbody, err := base64.StdEncoding.DecodeString(\(goLiteral(body.base64EncodedString())))"
                )
                lines.append("\tif err != nil { panic(err) }")
            } else {
                let text = String(decoding: body, as: UTF8.self)
                lines.append("\tbody := []byte(\(goLiteral(text)))")
            }
            bodyReader = "bytes.NewReader(body)"
        } else {
            bodyReader = "nil"
        }

        lines.append(
            "\treq, err := http.NewRequest(\(goLiteral(request.method.rawValue)), \(goLiteral(request.url.absoluteString)), \(bodyReader))"
        )
        lines.append("\tif err != nil { panic(err) }")
        for header in headers {
            lines.append("\treq.Header.Add(\(goLiteral(header.name)), \(goLiteral(header.value)))")
        }
        lines.append("")
        lines.append("\tresponse, err := http.DefaultClient.Do(req)")
        lines.append("\tif err != nil { panic(err) }")
        lines.append("\tdefer response.Body.Close()")
        lines.append("")
        lines.append("\tresponseBody, err := io.ReadAll(response.Body)")
        lines.append("\tif err != nil { panic(err) }")
        lines.append("\tfmt.Println(response.Status)")
        lines.append("\tfmt.Println(string(responseBody))")
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    private static func javaHttpClient(
        request: HTTPRequest,
        headers: [HTTPHeader],
        body: Data?,
        comments: [String]
    ) -> String {
        let isBinary =
            body.map { String(data: $0, encoding: .utf8) == nil || $0.contains(0) } ?? false
        var imports = [
            "java.net.URI",
            "java.net.http.HttpClient",
            "java.net.http.HttpRequest",
            "java.net.http.HttpResponse"
        ]
        if body != nil {
            imports.append(isBinary ? "java.util.Base64" : "java.nio.charset.StandardCharsets")
        }
        imports.sort()

        var lines = comments.map { "// \($0)" }
        lines.append(contentsOf: imports.map { "import \($0);" })
        lines.append("")
        lines.append("public class Main {")
        lines.append("    public static void main(String[] args) throws Exception {")
        if let body {
            if isBinary {
                lines.append(
                    "        byte[] body = Base64.getDecoder().decode(\(javaLiteral(body.base64EncodedString())));"
                )
            } else {
                lines.append(
                    "        byte[] body = \(javaLiteral(String(decoding: body, as: UTF8.self))).getBytes(StandardCharsets.UTF_8);"
                )
            }
        }
        lines.append("        HttpRequest request = HttpRequest.newBuilder()")
        lines.append("            .uri(URI.create(\(javaLiteral(request.url.absoluteString))))")
        for header in headers {
            lines.append(
                "            .header(\(javaLiteral(header.name)), \(javaLiteral(header.value)))"
            )
        }
        let publisher =
            body == nil
            ? "HttpRequest.BodyPublishers.noBody()" : "HttpRequest.BodyPublishers.ofByteArray(body)"
        lines.append(
            "            .method(\(javaLiteral(request.method.rawValue)), \(publisher))"
        )
        lines.append("            .build();")
        lines.append("")
        lines.append("        HttpClient client = HttpClient.newHttpClient();")
        lines.append(
            "        HttpResponse<String> response = client.send(request, HttpResponse.BodyHandlers.ofString());"
        )
        lines.append("        System.out.println(response.statusCode());")
        lines.append("        System.out.println(response.body());")
        lines.append("    }")
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    private static func posixQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func javascriptLiteral(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
            let literal = String(data: data, encoding: .utf8)
        else {
            return "\"\""
        }
        return literal
    }

    private static func pythonLiteral(_ value: String) -> String {
        javascriptLiteral(value)
    }

    private static func goLiteral(_ value: String) -> String {
        javascriptLiteral(value)
    }

    private static func javaLiteral(_ value: String) -> String {
        javascriptLiteral(value)
    }

    private static func swiftLiteral(_ value: String) -> String {
        String(reflecting: value)
    }
}
