import Foundation

/// Evaluates a deliberately bounded JSONPath subset against a derived JSON body.
///
/// The evaluator never changes or replaces captured bytes. It accepts the JSON text
/// produced by `JSONBodyView` and returns bounded, pretty-printed matches for display.
public enum JSONPathBodyView: Sendable {
    public static let maximumInputByteCount = JSONBodyView.maximumDecodedByteCount
    public static let maximumMatchCount = 500
    public static let maximumDepth = 64
    public static let maximumRenderedMatchByteCount = 256 * 1_024

    public static let emptyQueryReason = "Enter a JSONPath expression."
    public static let notJSONReason = JSONBodyView.notJSONReason
    public static let exceedsDisplayLimitReason =
        "JSONPath input exceeds the 1 MB display limit."

    public enum Result: Equatable, Sendable {
        case matches([Match])
        case unavailable(reason: String)
    }

    public struct Match: Equatable, Sendable {
        public let path: String
        public let value: String

        public init(path: String, value: String) {
            self.path = path
            self.value = value
        }
    }

    public static func evaluate(json: String, query: String) -> Result {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            return .unavailable(reason: emptyQueryReason)
        }
        guard let data = json.data(using: .utf8), data.count <= maximumInputByteCount else {
            return .unavailable(reason: exceedsDisplayLimitReason)
        }

        let root: Any
        do {
            root = try JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
            )
        } catch {
            return .unavailable(reason: notJSONReason)
        }

        do {
            var parser = Parser(query: normalizedQuery)
            let tokens = try parser.parse()
            var matches: [(path: String, value: Any)] = []
            matches.reserveCapacity(min(maximumMatchCount, 16))
            resolve(
                value: root,
                path: "$",
                tokens: tokens,
                tokenIndex: 0,
                depth: 0,
                into: &matches
            )

            return .matches(
                matches.prefix(maximumMatchCount).compactMap { match in
                    guard let value = render(match.value) else {
                        return nil
                    }
                    return Match(path: match.path, value: value)
                }
            )
        } catch let error as JSONPathError {
            return .unavailable(reason: error.reason)
        } catch {
            return .unavailable(reason: "Invalid JSONPath.")
        }
    }

    private enum Token: Equatable {
        case key(String)
        case index(Int)
        case wildcard
    }

    private enum JSONPathError: Error {
        case invalid(String)
        case tooDeep

        var reason: String {
            switch self {
            case .invalid(let message):
                "Invalid JSONPath: \(message)"
            case .tooDeep:
                "JSONPath exceeds the maximum depth of \(maximumDepth)."
            }
        }
    }

    private struct Parser {
        let characters: [Character]
        var index: Int = 0

        init(query: String) {
            characters = Array(query)
        }

        mutating func parse() throws -> [Token] {
            guard consume("$") else {
                throw JSONPathError.invalid("an expression must start with '$'.")
            }
            var tokens: [Token] = []
            while index < characters.count {
                if consume(".") {
                    if consume(".") {
                        throw JSONPathError.invalid("recursive descent ('..') is not supported.")
                    }
                    if consume("*") {
                        tokens.append(.wildcard)
                    } else {
                        tokens.append(.key(try identifier()))
                    }
                } else if consume("[") {
                    tokens.append(try bracketToken())
                } else {
                    throw JSONPathError.invalid("unexpected character at position \(index + 1).")
                }
                guard tokens.count <= maximumDepth else {
                    throw JSONPathError.tooDeep
                }
            }
            return tokens
        }

        private mutating func bracketToken() throws -> Token {
            guard index < characters.count else {
                throw JSONPathError.invalid("missing closing ']'.")
            }
            if consume("*") {
                guard consume("]") else {
                    throw JSONPathError.invalid("wildcard must end with ']'.")
                }
                return .wildcard
            }
            if characters[index] == "\"" || characters[index] == "'" {
                let quote = characters[index]
                index += 1
                var value = ""
                while index < characters.count, characters[index] != quote {
                    if characters[index] == "\\" {
                        index += 1
                        guard index < characters.count else {
                            throw JSONPathError.invalid("unterminated quoted key.")
                        }
                    }
                    value.append(characters[index])
                    index += 1
                }
                guard index < characters.count, characters[index] == quote else {
                    throw JSONPathError.invalid("unterminated quoted key.")
                }
                index += 1
                guard consume("]"), !value.isEmpty else {
                    throw JSONPathError.invalid("quoted key must end with ']'.")
                }
                return .key(value)
            }

            let start = index
            while index < characters.count, characters[index].isNumber {
                index += 1
            }
            guard start < index else {
                throw JSONPathError.invalid("expected an array index, key, or wildcard.")
            }
            let text = String(characters[start..<index])
            guard let value = Int(text) else {
                throw JSONPathError.invalid("array index is out of range.")
            }
            guard consume("]") else {
                throw JSONPathError.invalid("array index must end with ']'.")
            }
            return .index(value)
        }

        private mutating func identifier() throws -> String {
            let start = index
            while index < characters.count {
                let character = characters[index]
                guard
                    character.isLetter || character.isNumber || character == "_" || character == "-"
                else {
                    break
                }
                index += 1
            }
            guard start < index else {
                throw JSONPathError.invalid("expected an object key after '.'.")
            }
            return String(characters[start..<index])
        }

        private mutating func consume(_ character: Character) -> Bool {
            guard index < characters.count, characters[index] == character else {
                return false
            }
            index += 1
            return true
        }
    }

    private static func resolve(
        value: Any,
        path: String,
        tokens: [Token],
        tokenIndex: Int,
        depth: Int,
        into matches: inout [(path: String, value: Any)]
    ) {
        guard depth <= maximumDepth else {
            return
        }
        guard tokenIndex < tokens.count else {
            matches.append((path, value))
            return
        }

        switch tokens[tokenIndex] {
        case .key(let key):
            guard let object = value as? [String: Any], let child = object[key] else {
                return
            }
            resolve(
                value: child,
                path: "\(path).\(key)",
                tokens: tokens,
                tokenIndex: tokenIndex + 1,
                depth: depth + 1,
                into: &matches
            )
        case .index(let index):
            guard let array = value as? [Any], array.indices.contains(index) else {
                return
            }
            resolve(
                value: array[index],
                path: "\(path)[\(index)]",
                tokens: tokens,
                tokenIndex: tokenIndex + 1,
                depth: depth + 1,
                into: &matches
            )
        case .wildcard:
            if let object = value as? [String: Any] {
                for key in object.keys.sorted() {
                    guard matches.count < maximumMatchCount else { return }
                    resolve(
                        value: object[key] as Any,
                        path: "\(path).\(key)",
                        tokens: tokens,
                        tokenIndex: tokenIndex + 1,
                        depth: depth + 1,
                        into: &matches
                    )
                }
            } else if let array = value as? [Any] {
                for index in array.indices {
                    guard matches.count < maximumMatchCount else { return }
                    resolve(
                        value: array[index],
                        path: "\(path)[\(index)]",
                        tokens: tokens,
                        tokenIndex: tokenIndex + 1,
                        depth: depth + 1,
                        into: &matches
                    )
                }
            }
        }
    }

    private static func render(_ value: Any) -> String? {
        guard
            JSONSerialization.isValidJSONObject(value) || value is String || value is NSNumber
                || value is NSNull
        else {
            return nil
        }
        if value is String || value is NSNumber || value is NSNull {
            guard
                let wrapper = try? JSONSerialization.data(
                    withJSONObject: ["value": value],
                    options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]
                )
            else {
                return nil
            }
            let text = String(decoding: wrapper, as: UTF8.self)
            guard let start = text.firstIndex(of: ":"), let end = text.lastIndex(of: "\n") else {
                return String(decoding: wrapper, as: UTF8.self)
            }
            let valueText = text[text.index(after: start)..<end]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return valueText
        }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            ), data.count <= maximumRenderedMatchByteCount
        else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}
