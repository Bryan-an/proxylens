import Foundation

/// Formats a captured GraphQL request for inspection without replacing its raw bytes.
public enum GraphQLBodyView: Sendable {
    public static let maximumDecodedByteCount = 1_048_576
    public static let notGraphQLReason = "This body is not a GraphQL request."
    public static let truncatedReason = "Capture truncated"
    public static let exceedsDisplayLimitReason =
        "GraphQL request exceeds the 1 MB display limit."

    public enum Result: Equatable, Sendable {
        case formatted(String)
        case unavailable(reason: String)
    }

    public static func invalidGraphQLReason(_ message: String) -> String {
        "Invalid GraphQL request: \(message)"
    }

    /// Extracts bounded operation metadata for list, search, and filter discovery.
    /// Returns `nil` for unrelated, malformed, truncated, or oversized payloads.
    public static func operationMetadata(
        data: Data,
        contentType: String?,
        contentEncoding: String?,
        isTruncated: Bool = false
    ) -> GraphQLOperationMetadata? {
        guard !isTruncated else {
            return nil
        }
        let decoded: Data
        switch DerivedBodyData.unwrap(
            data,
            contentEncoding: contentEncoding,
            maximumOutputByteCount: maximumDecodedByteCount,
            exceedsLimitReason: exceedsDisplayLimitReason,
            isTruncated: false,
            truncatedReason: truncatedReason
        ) {
        case .decoded(let value):
            decoded = stripUTF8BOM(value)
        case .unavailable:
            return nil
        }

        let source: String
        let requestedOperationName: String?
        if normalizedMediaType(contentType) == "application/graphql" {
            guard let value = String(data: decoded, encoding: .utf8), !value.isEmpty else {
                return nil
            }
            source = value
            requestedOperationName = nil
        } else {
            guard
                let object = try? JSONSerialization.jsonObject(with: decoded),
                let envelope = object as? [String: Any],
                let value = envelope["query"] as? String,
                !value.isEmpty
            else {
                return nil
            }
            source = value
            switch envelope["operationName"] {
            case nil, is NSNull:
                requestedOperationName = nil
            case let name as String where !name.isEmpty:
                requestedOperationName = name
            default:
                return nil
            }
        }

        guard
            let tokens = try? GraphQLSourceFormatter.tokenize(source),
            (try? GraphQLSourceFormatter.format(tokens)) != nil
        else {
            return nil
        }
        return GraphQLSourceFormatter.operationMetadata(
            in: tokens,
            requestedName: requestedOperationName
        )
    }

    public static func render(
        data: Data,
        contentType: String?,
        contentEncoding: String?,
        isTruncated: Bool = false
    ) -> Result {
        let decoded: Data
        switch DerivedBodyData.unwrap(
            data,
            contentEncoding: contentEncoding,
            maximumOutputByteCount: maximumDecodedByteCount,
            exceedsLimitReason: exceedsDisplayLimitReason,
            isTruncated: isTruncated,
            truncatedReason: truncatedReason
        ) {
        case .decoded(let value):
            decoded = stripUTF8BOM(value)
        case .unavailable(let reason):
            return .unavailable(reason: reason)
        }

        let mediaType = normalizedMediaType(contentType)
        if mediaType == "application/graphql" {
            guard let source = String(data: decoded, encoding: .utf8), !source.isEmpty else {
                return failure("The query is empty or is not UTF-8 text.", isTruncated: isTruncated)
            }
            return format(
                source: source, operationName: nil, variables: nil, isTruncated: isTruncated)
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: decoded)
        } catch {
            return .unavailable(reason: notGraphQLReason)
        }
        guard let envelope = object as? [String: Any], envelope.keys.contains("query") else {
            return .unavailable(reason: notGraphQLReason)
        }
        guard let source = envelope["query"] as? String, !source.isEmpty else {
            return failure(
                "The JSON query field must be a non-empty string.", isTruncated: isTruncated)
        }

        let operationName: String?
        switch envelope["operationName"] {
        case nil, is NSNull:
            operationName = nil
        case let value as String where !value.isEmpty:
            operationName = value
        default:
            return failure(
                "The operationName field must be a non-empty string or null.",
                isTruncated: isTruncated
            )
        }

        let variables: [String: Any]?
        switch envelope["variables"] {
        case nil, is NSNull:
            variables = nil
        case let value as [String: Any]:
            variables = value
        default:
            return failure(
                "The variables field must be an object or null.",
                isTruncated: isTruncated
            )
        }
        return format(
            source: source,
            operationName: operationName,
            variables: variables,
            isTruncated: isTruncated
        )
    }

    private static func format(
        source: String,
        operationName: String?,
        variables: [String: Any]?,
        isTruncated: Bool
    ) -> Result {
        do {
            let tokens = try GraphQLSourceFormatter.tokenize(source)
            let query = try GraphQLSourceFormatter.format(tokens)
            let resolvedName = operationName ?? GraphQLSourceFormatter.operationName(in: tokens)
            var sections = ["Operation: \(resolvedName ?? "Anonymous")", query]
            if let variables {
                let data = try JSONSerialization.data(
                    withJSONObject: variables,
                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                )
                guard let text = String(data: data, encoding: .utf8) else {
                    return failure("Variables are not valid UTF-8 JSON.", isTruncated: isTruncated)
                }
                sections.append("Variables:\n\(text)")
            }
            let result = sections.joined(separator: "\n\n")
            guard result.utf8.count <= maximumDecodedByteCount else {
                return .unavailable(reason: exceedsDisplayLimitReason)
            }
            return .formatted(result)
        } catch let error as GraphQLSourceFormatter.FormatError {
            return failure(error.message, isTruncated: isTruncated)
        } catch {
            return failure("The request could not be formatted.", isTruncated: isTruncated)
        }
    }

    private static func failure(_ message: String, isTruncated: Bool) -> Result {
        if isTruncated {
            return .unavailable(reason: truncatedReason)
        }
        return .unavailable(reason: invalidGraphQLReason(message))
    }
}

private enum GraphQLSourceFormatter {
    struct FormatError: Error {
        let message: String
    }

    struct Token: Equatable {
        enum Kind: Equatable {
            case name
            case number
            case string
            case comment
            case punctuation
        }

        let kind: Kind
        let text: String
    }

    static func tokenize(_ source: String) throws -> [Token] {
        var tokens: [Token] = []
        var index = source.startIndex
        while index < source.endIndex {
            let character = source[index]
            if character.isWhitespace || character == "," || character == "\u{FEFF}" {
                index = source.index(after: index)
                continue
            }
            if character == "#" {
                let start = index
                while index < source.endIndex, source[index] != "\n", source[index] != "\r" {
                    index = source.index(after: index)
                }
                tokens.append(Token(kind: .comment, text: String(source[start..<index])))
                continue
            }
            if source[index...].hasPrefix("\"\"\"") {
                let start = index
                index = source.index(index, offsetBy: 3)
                var foundEnd = false
                while index < source.endIndex {
                    if source[index...].hasPrefix("\"\"\"") {
                        index = source.index(index, offsetBy: 3)
                        foundEnd = true
                        break
                    }
                    index = source.index(after: index)
                }
                guard foundEnd else {
                    throw FormatError(message: "A block string is not terminated.")
                }
                tokens.append(Token(kind: .string, text: String(source[start..<index])))
                continue
            }
            if character == "\"" {
                let start = index
                index = source.index(after: index)
                var escaped = false
                var foundEnd = false
                while index < source.endIndex {
                    let current = source[index]
                    index = source.index(after: index)
                    if escaped {
                        escaped = false
                    } else if current == "\\" {
                        escaped = true
                    } else if current == "\"" {
                        foundEnd = true
                        break
                    } else if current == "\n" || current == "\r" {
                        break
                    }
                }
                guard foundEnd else {
                    throw FormatError(message: "A string is not terminated.")
                }
                tokens.append(Token(kind: .string, text: String(source[start..<index])))
                continue
            }
            if source[index...].hasPrefix("...") {
                tokens.append(Token(kind: .punctuation, text: "..."))
                index = source.index(index, offsetBy: 3)
                continue
            }
            if isNameStart(character) {
                let start = index
                index = source.index(after: index)
                while index < source.endIndex, isNameContinuation(source[index]) {
                    index = source.index(after: index)
                }
                tokens.append(Token(kind: .name, text: String(source[start..<index])))
                continue
            }
            if character.isNumber || character == "-" {
                let start = index
                index = source.index(after: index)
                while index < source.endIndex, isNumberContinuation(source[index]) {
                    index = source.index(after: index)
                }
                tokens.append(Token(kind: .number, text: String(source[start..<index])))
                continue
            }
            if "!$&():=@[]{|}".contains(character) {
                tokens.append(Token(kind: .punctuation, text: String(character)))
                index = source.index(after: index)
                continue
            }
            throw FormatError(message: "Unexpected character \(character).")
        }
        guard !tokens.isEmpty else {
            throw FormatError(message: "The query is empty.")
        }
        return tokens
    }

    static func operationName(in tokens: [Token]) -> String? {
        operationMetadata(in: tokens, requestedName: nil)?.name
    }

    static func operationMetadata(
        in tokens: [Token],
        requestedName: String?
    ) -> GraphQLOperationMetadata? {
        var delimiterDepth = 0
        var candidates: [GraphQLOperationMetadata] = []
        if tokens.first(where: { $0.kind != .comment })?.text == "{" {
            candidates.append(GraphQLOperationMetadata(kind: .query, name: nil))
        }

        for (index, token) in tokens.enumerated() {
            if delimiterDepth == 0, token.kind == .name,
                let kind = GraphQLOperationMetadata.Kind(rawValue: token.text)
            {
                let nextIndex = index + 1
                let name =
                    nextIndex < tokens.count && tokens[nextIndex].kind == .name
                    ? tokens[nextIndex].text : nil
                candidates.append(GraphQLOperationMetadata(kind: kind, name: name))
            }

            if ["{", "(", "["].contains(token.text) {
                delimiterDepth += 1
            } else if ["}", ")", "]"].contains(token.text) {
                delimiterDepth = max(0, delimiterDepth - 1)
            }
        }

        if let requestedName {
            return candidates.first { $0.name == requestedName }
        }
        return candidates.first
    }

    static func format(_ tokens: [Token]) throws -> String {
        var lines: [String] = []
        var current = ""
        var indent = 0
        var delimiters: [String] = []
        var previous: Token?

        func flush() {
            let text = current.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                lines.append(String(repeating: "  ", count: indent) + text)
            }
            current = ""
        }

        func append(_ text: String, separated: Bool = false) {
            if separated, !current.isEmpty, !current.hasSuffix(" ") {
                current.append(" ")
            }
            current.append(text)
        }

        func isInsideBraces() -> Bool {
            delimiters.contains("{")
        }

        func isInsideInlineDelimiter() -> Bool {
            delimiters.last == "(" || delimiters.last == "["
        }

        for token in tokens {
            if token.kind == .comment {
                flush()
                current = token.text
                flush()
                previous = token
                continue
            }

            if token.kind == .name || token.kind == .number || token.kind == .string {
                let previousText = previous?.text
                let startsSibling =
                    token.kind == .name
                    && isInsideBraces()
                    && !isInsideInlineDelimiter()
                    && !current.isEmpty
                    && previous?.kind != .comment
                    && !["...", "@", "$", ":", "on"].contains(previousText ?? "")
                    && (previous?.kind == .name || previous?.kind == .number
                        || previous?.kind == .string || previousText == ")"
                        || previousText == "]")
                if startsSibling {
                    flush()
                }
                let attaches = ["...", "@", "$", "(", "["].contains(previousText ?? "")
                let afterColon = previousText == ":"
                append(token.text, separated: !current.isEmpty && !attaches || afterColon)
                previous = token
                continue
            }

            switch token.text {
            case "{":
                append("{", separated: !current.isEmpty)
                flush()
                delimiters.append("{")
                indent += 1
            case "}":
                flush()
                guard delimiters.last == "{" else {
                    throw FormatError(message: "Braces are not balanced.")
                }
                delimiters.removeLast()
                indent -= 1
                current = "}"
                flush()
            case "(":
                append("(")
                delimiters.append("(")
            case ")":
                guard delimiters.last == "(" else {
                    throw FormatError(message: "Parentheses are not balanced.")
                }
                delimiters.removeLast()
                append(")")
            case "[":
                append("[", separated: previous?.text == ":" || previous?.text == "=")
                delimiters.append("[")
            case "]":
                guard delimiters.last == "[" else {
                    throw FormatError(message: "Brackets are not balanced.")
                }
                delimiters.removeLast()
                append("]")
            case ":", "!":
                append(token.text)
            case "$":
                append("$", separated: previous?.text == ":" || previous?.kind == .name)
            case "@":
                append("@", separated: !current.isEmpty)
            case "...":
                if isInsideBraces(), !isInsideInlineDelimiter(), !current.isEmpty {
                    flush()
                }
                append("...", separated: !current.isEmpty)
            case "=", "|", "&":
                append(token.text, separated: true)
                current.append(" ")
            default:
                append(token.text)
            }
            previous = token
        }
        flush()
        guard delimiters.isEmpty else {
            throw FormatError(message: "The query has an unterminated delimiter.")
        }
        return lines.joined(separator: "\n")
    }

    private static func isNameStart(_ character: Character) -> Bool {
        character == "_" || character.isASCII && character.isLetter
    }

    private static func isNameContinuation(_ character: Character) -> Bool {
        isNameStart(character) || character.isASCII && character.isNumber
    }

    private static func isNumberContinuation(_ character: Character) -> Bool {
        character.isASCII
            && (character.isNumber || [".", "e", "E", "+", "-"].contains(character))
    }
}
