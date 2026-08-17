import Foundation
import ProxyLensCore

/// Parses a bounded cURL command into an HTTP request without invoking a shell or reading files.
public enum CURLRequestImporter {
    private static let maximumCommandCharacterCount = 256 * 1_024
    private static let maximumArgumentCount = 4_096

    public static func parse(_ command: String) throws -> HTTPRequest {
        guard command.count <= maximumCommandCharacterCount else {
            throw invalid("The cURL command exceeds the 256 KiB import limit")
        }

        var tokenizer = ShellTokenizer(command: command)
        let arguments = try tokenizer.arguments(maximumCount: maximumArgumentCount)
        guard let executable = arguments.first,
            URL(fileURLWithPath: executable).lastPathComponent == "curl"
        else {
            throw invalid("The imported command must start with curl")
        }

        var parser = ArgumentParser(arguments: Array(arguments.dropFirst()))
        return try parser.request()
    }

    private static func invalid(_ reason: String) -> ProxyLensError {
        .invalidHTTPMessage("Could not import cURL: \(reason)")
    }

    private struct ArgumentParser {
        let arguments: [String]
        var index = 0
        var method: String?
        var url: String?
        var headerLines: [String] = []
        var bodyParts: [String] = []
        var bodyWasProvided = false
        var usesJSONDefaults = false
        var version: HTTPVersion = .http11

        mutating func request() throws -> HTTPRequest {
            while index < arguments.count {
                let argument = arguments[index]
                index += 1

                if argument == "--" {
                    try consumePositionalArguments()
                } else if argument.hasPrefix("--") {
                    try consumeLongOption(argument)
                } else if argument.hasPrefix("-") && argument != "-" {
                    try consumeShortOption(argument)
                } else {
                    try setURL(argument)
                }
            }

            guard let url else {
                throw CURLRequestImporter.invalid("The command does not contain a URL")
            }

            if usesJSONDefaults {
                appendHeaderIfMissing(name: "Content-Type", value: "application/json")
                appendHeaderIfMissing(name: "Accept", value: "application/json")
            }

            let resolvedMethod = method ?? (bodyWasProvided ? "POST" : "GET")
            let firstLine = "\(resolvedMethod) \(url) \(version.rawValue)"
            let headersText = ([firstLine] + headerLines).joined(separator: "\n")
            let body =
                bodyWasProvided
                ? Data(bodyParts.joined(separator: "&").utf8)
                : nil
            return try HTTPMessageText.parseRequest(headersText: headersText, body: body)
        }

        private mutating func consumePositionalArguments() throws {
            while index < arguments.count {
                try setURL(arguments[index])
                index += 1
            }
        }

        private mutating func consumeLongOption(_ argument: String) throws {
            let (option, attachedValue) = splitLongOption(argument)
            switch option {
            case "--url":
                try setURL(try value(for: option, attachedValue: attachedValue))
            case "--request":
                method = try value(for: option, attachedValue: attachedValue)
            case "--header":
                try appendHeader(try value(for: option, attachedValue: attachedValue))
            case "--data", "--data-ascii", "--data-binary":
                try appendBody(
                    try value(for: option, attachedValue: attachedValue),
                    option: option,
                    allowsFilePrefix: false
                )
            case "--data-raw":
                try appendBody(
                    try value(for: option, attachedValue: attachedValue),
                    option: option,
                    allowsFilePrefix: true
                )
            case "--json":
                usesJSONDefaults = true
                try appendBody(
                    try value(for: option, attachedValue: attachedValue),
                    option: option,
                    allowsFilePrefix: false
                )
            case "--cookie":
                let cookie = try value(for: option, attachedValue: attachedValue)
                try rejectFileReference(cookie, option: option)
                appendSyntheticHeader(
                    name: "Cookie",
                    value: cookie
                )
            case "--user-agent":
                appendSyntheticHeader(
                    name: "User-Agent",
                    value: try value(for: option, attachedValue: attachedValue)
                )
            case "--referer":
                appendSyntheticHeader(
                    name: "Referer",
                    value: try value(for: option, attachedValue: attachedValue)
                )
            case "--head":
                method = "HEAD"
            case "--http1.0":
                version = .http10
            case "--http1.1":
                version = .http11
            case "--compressed", "--fail", "--globoff", "--include", "--insecure",
                "--location", "--location-trusted", "--no-progress-meter", "--show-error",
                "--silent":
                guard attachedValue == nil else {
                    throw CURLRequestImporter.invalid("\(option) does not accept a value")
                }
            case "--form", "--form-string", "--upload-file", "--data-urlencode":
                throw CURLRequestImporter.invalid(
                    "\(option) is not supported yet; use the request headers and body editors"
                )
            default:
                throw CURLRequestImporter.invalid("Unsupported cURL option: \(option)")
            }
        }

        private mutating func consumeShortOption(_ argument: String) throws {
            if let value = attachedValue(for: "-X", in: argument) {
                method = try resolvedShortValue(value, option: "-X")
            } else if let value = attachedValue(for: "-H", in: argument) {
                try appendHeader(try resolvedShortValue(value, option: "-H"))
            } else if let value = attachedValue(for: "-d", in: argument) {
                try appendBody(
                    try resolvedShortValue(value, option: "-d"),
                    option: "-d",
                    allowsFilePrefix: false
                )
            } else if let value = attachedValue(for: "-b", in: argument) {
                let cookie = try resolvedShortValue(value, option: "-b")
                try rejectFileReference(cookie, option: "-b")
                appendSyntheticHeader(
                    name: "Cookie",
                    value: cookie
                )
            } else if let value = attachedValue(for: "-A", in: argument) {
                appendSyntheticHeader(
                    name: "User-Agent",
                    value: try resolvedShortValue(value, option: "-A")
                )
            } else if let value = attachedValue(for: "-e", in: argument) {
                appendSyntheticHeader(
                    name: "Referer",
                    value: try resolvedShortValue(value, option: "-e")
                )
            } else if argument == "-I" {
                method = "HEAD"
            } else if isIgnoredShortOptionBundle(argument) {
                return
            } else if argument == "-F" || argument.hasPrefix("-F")
                || argument == "-T" || argument.hasPrefix("-T")
            {
                throw CURLRequestImporter.invalid(
                    "\(String(argument.prefix(2))) is not supported yet; use the request headers and body editors"
                )
            } else {
                throw CURLRequestImporter.invalid("Unsupported cURL option: \(argument)")
            }
        }

        private mutating func setURL(_ candidate: String) throws {
            guard url == nil else {
                throw CURLRequestImporter.invalid("The command contains more than one URL")
            }
            url = candidate
        }

        private mutating func appendHeader(_ header: String) throws {
            guard !header.hasPrefix("@") else {
                throw CURLRequestImporter.invalid("Header file references are not supported")
            }
            guard let separator = header.firstIndex(of: ":") else {
                throw CURLRequestImporter.invalid("Invalid header: \(header)")
            }
            let name = header[..<separator].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                throw CURLRequestImporter.invalid("A header name cannot be empty")
            }
            headerLines.append("\(name):\(header[separator...].dropFirst())")
        }

        private mutating func appendSyntheticHeader(name: String, value: String) {
            headerLines.append("\(name): \(value)")
        }

        private mutating func appendHeaderIfMissing(name: String, value: String) {
            let prefix = name.lowercased() + ":"
            guard !headerLines.contains(where: { $0.lowercased().hasPrefix(prefix) }) else {
                return
            }
            appendSyntheticHeader(name: name, value: value)
        }

        private mutating func appendBody(
            _ value: String,
            option: String,
            allowsFilePrefix: Bool
        ) throws {
            if !allowsFilePrefix, value.hasPrefix("@") {
                throw CURLRequestImporter.invalid(
                    "\(option) file references are not supported; paste the body content instead"
                )
            }
            bodyWasProvided = true
            bodyParts.append(value)
        }

        private func rejectFileReference(_ value: String, option: String) throws {
            guard !value.hasPrefix("@") else {
                throw CURLRequestImporter.invalid(
                    "\(option) file references are not supported; paste the value instead"
                )
            }
        }

        private mutating func value(
            for option: String,
            attachedValue: String?
        ) throws -> String {
            if let attachedValue {
                guard !attachedValue.isEmpty else {
                    throw CURLRequestImporter.invalid("\(option) requires a value")
                }
                return attachedValue
            }
            guard index < arguments.count else {
                throw CURLRequestImporter.invalid("\(option) requires a value")
            }
            defer { index += 1 }
            return arguments[index]
        }

        private mutating func resolvedShortValue(_ attached: String, option: String) throws
            -> String
        {
            if !attached.isEmpty {
                return attached
            }
            return try value(for: option, attachedValue: nil)
        }

        private func attachedValue(for option: String, in argument: String) -> String? {
            guard argument == option || argument.hasPrefix(option) else {
                return nil
            }
            return String(argument.dropFirst(option.count))
        }

        private func splitLongOption(_ argument: String) -> (String, String?) {
            guard let separator = argument.firstIndex(of: "=") else {
                return (argument, nil)
            }
            return (
                String(argument[..<separator]),
                String(argument[argument.index(after: separator)...])
            )
        }

        private func isIgnoredShortOptionBundle(_ argument: String) -> Bool {
            let ignored: Set<Character> = ["L", "s", "S", "f", "g", "i", "k"]
            return argument.count > 1 && argument.dropFirst().allSatisfy(ignored.contains)
        }
    }

    private struct ShellTokenizer {
        private enum Quote {
            case none
            case single
            case double
            case ansiC
        }

        let characters: [Character]
        var index = 0

        init(command: String) {
            characters = Array(command)
        }

        mutating func arguments(maximumCount: Int) throws -> [String] {
            var result: [String] = []
            var current = ""
            var quote = Quote.none
            var tokenStarted = false

            while index < characters.count {
                let character = characters[index]
                switch quote {
                case .none:
                    if character.isWhitespace {
                        appendTokenIfNeeded(&result, current: &current, started: &tokenStarted)
                        index += 1
                    } else if character == "#", !tokenStarted {
                        skipComment()
                    } else if character == "'" {
                        quote = .single
                        tokenStarted = true
                        index += 1
                    } else if character == "\"" {
                        quote = .double
                        tokenStarted = true
                        index += 1
                    } else if character == "$", peek() == "'" {
                        quote = .ansiC
                        tokenStarted = true
                        index += 2
                    } else if character == "\\" {
                        let escapesLineBreak = peek()?.isNewline == true
                        try appendEscapedCharacter(to: &current, inDoubleQuotes: false)
                        if !escapesLineBreak {
                            tokenStarted = true
                        }
                    } else {
                        current.append(character)
                        tokenStarted = true
                        index += 1
                    }
                case .single:
                    if character == "'" {
                        quote = .none
                    } else {
                        current.append(character)
                    }
                    index += 1
                case .double:
                    if character == "\"" {
                        quote = .none
                        index += 1
                    } else if character == "\\" {
                        try appendEscapedCharacter(to: &current, inDoubleQuotes: true)
                    } else {
                        current.append(character)
                        index += 1
                    }
                case .ansiC:
                    if character == "'" {
                        quote = .none
                        index += 1
                    } else if character == "\\" {
                        try appendANSIEscape(to: &current)
                    } else {
                        current.append(character)
                        index += 1
                    }
                }

                guard result.count <= maximumCount else {
                    throw CURLRequestImporter.invalid("The cURL command has too many arguments")
                }
            }

            guard quote == .none else {
                throw CURLRequestImporter.invalid("The cURL command contains an unterminated quote")
            }
            appendTokenIfNeeded(&result, current: &current, started: &tokenStarted)
            guard result.count <= maximumCount else {
                throw CURLRequestImporter.invalid("The cURL command has too many arguments")
            }
            return result
        }

        private mutating func appendEscapedCharacter(
            to value: inout String,
            inDoubleQuotes: Bool
        ) throws {
            index += 1
            guard index < characters.count else {
                throw CURLRequestImporter.invalid("The cURL command ends with an escape")
            }
            let escaped = characters[index]
            index += 1
            if escaped.isNewline {
                return
            }
            if inDoubleQuotes, !["$", "`", "\"", "\\"].contains(escaped) {
                value.append("\\")
            }
            value.append(escaped)
        }

        private mutating func appendANSIEscape(to value: inout String) throws {
            index += 1
            guard index < characters.count else {
                throw CURLRequestImporter.invalid("The cURL command ends with an escape")
            }
            let escaped = characters[index]
            index += 1
            switch escaped {
            case "n": value.append("\n")
            case "r": value.append("\r")
            case "t": value.append("\t")
            case "\\": value.append("\\")
            case "'": value.append("'")
            case "\"": value.append("\"")
            case "x":
                guard index + 1 < characters.count,
                    let byte = UInt8(String(characters[index...index + 1]), radix: 16)
                else {
                    throw CURLRequestImporter.invalid("Invalid hexadecimal cURL body escape")
                }
                guard byte > 0, byte < 128, let scalar = UnicodeScalar(UInt32(byte)) else {
                    throw CURLRequestImporter.invalid(
                        "Binary cURL escapes are not supported by the text editor"
                    )
                }
                value.unicodeScalars.append(scalar)
                index += 2
            default:
                value.append(escaped)
            }
        }

        private mutating func appendTokenIfNeeded(
            _ result: inout [String],
            current: inout String,
            started: inout Bool
        ) {
            guard started else {
                return
            }
            result.append(current)
            current.removeAll(keepingCapacity: true)
            started = false
        }

        private mutating func skipComment() {
            while index < characters.count, !characters[index].isNewline {
                index += 1
            }
        }

        private func peek() -> Character? {
            let next = index + 1
            return next < characters.count ? characters[next] : nil
        }
    }
}
