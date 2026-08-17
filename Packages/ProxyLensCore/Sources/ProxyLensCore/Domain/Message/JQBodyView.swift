import CoreFoundation
import Foundation

/// Evaluates a deliberately small, side-effect-free jq subset over derived JSON text.
///
/// This type never invokes an external executable and never changes captured bytes. Parsing,
/// intermediate streams, and rendered output are all bounded for untrusted traffic.
public enum JQBodyView: Sendable {
    public static let maximumInputByteCount = JSONBodyView.maximumDecodedByteCount
    public static let maximumQueryByteCount = 4 * 1_024
    public static let maximumPipelineStageCount = 32
    public static let maximumTraversalDepth = 64
    public static let maximumValueCount = 500
    public static let maximumRenderedOutputByteCount = 512 * 1_024

    public static let emptyQueryReason = "Enter a jq expression."
    public static let notJSONReason = JSONBodyView.notJSONReason
    public static let exceedsDisplayLimitReason = "jq input exceeds the 1 MB display limit."
    public static let queryLimitReason = "jq query exceeds the 4 KiB limit."
    public static let pipelineLimitReason =
        "jq query exceeds the maximum of \(maximumPipelineStageCount) pipeline stages."
    public static let traversalLimitReason =
        "jq query exceeds the maximum traversal depth of \(maximumTraversalDepth)."
    public static let valueLimitReason =
        "jq result exceeds the maximum of \(maximumValueCount) values."
    public static let renderedOutputLimitReason = "jq output exceeds the 512 KiB display limit."

    public enum Result: Equatable, Sendable {
        case values([String])
        case unavailable(reason: String)
    }

    public static func evaluate(json: String, query: String) -> Result {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            return .unavailable(reason: emptyQueryReason)
        }
        guard normalizedQuery.utf8.count <= maximumQueryByteCount else {
            return .unavailable(reason: queryLimitReason)
        }
        guard let data = json.data(using: .utf8), data.count <= maximumInputByteCount else {
            return .unavailable(reason: exceedsDisplayLimitReason)
        }

        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            return .unavailable(reason: notJSONReason)
        }

        do {
            var parser = Parser(query: normalizedQuery)
            let stages = try parser.parse()
            var values: [Any] = [root]
            for stage in stages {
                values = try evaluate(stage, inputs: values)
            }
            return .values(try render(values))
        } catch let error as JQError {
            return .unavailable(reason: error.reason)
        } catch {
            return .unavailable(reason: "Invalid jq query.")
        }
    }

    private enum Stage {
        case path([PathComponent])
        case select(path: [PathComponent], comparison: ComparisonOperator, literal: Scalar)
    }

    private enum PathComponent {
        case key(String)
        case index(Int)
        case iterate
    }

    private enum ComparisonOperator: String {
        case equal = "=="
        case notEqual = "!="
        case lessThan = "<"
        case lessThanOrEqual = "<="
        case greaterThan = ">"
        case greaterThanOrEqual = ">="
    }

    private enum Scalar {
        case string(String)
        case number(Double)
        case bool(Bool)
        case null
    }

    private enum JQError: Error {
        case invalid(String)
        case pipelineLimit
        case traversalLimit
        case valueLimit
        case renderedOutputLimit

        var reason: String {
            switch self {
            case .invalid(let message):
                "Invalid jq query: \(message)"
            case .pipelineLimit:
                pipelineLimitReason
            case .traversalLimit:
                traversalLimitReason
            case .valueLimit:
                valueLimitReason
            case .renderedOutputLimit:
                renderedOutputLimitReason
            }
        }
    }

    private struct Parser {
        private let query: String
        private var traversalComponentCount = 0

        init(query: String) {
            self.query = query
        }

        mutating func parse() throws -> [Stage] {
            let stageSources = try splitPipeline(query)
            guard stageSources.count <= maximumPipelineStageCount else {
                throw JQError.pipelineLimit
            }
            return try stageSources.map { try parseStage($0) }
        }

        private mutating func parseStage(_ source: String) throws -> Stage {
            let stage = source.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stage.isEmpty else {
                throw JQError.invalid("a pipeline stage is empty.")
            }
            if stage.hasPrefix("select") {
                return try parseSelect(stage)
            }
            return .path(try parsePath(stage))
        }

        private mutating func parseSelect(_ source: String) throws -> Stage {
            guard source.hasPrefix("select("), source.hasSuffix(")") else {
                throw JQError.invalid("select must contain a comparison in parentheses.")
            }
            let start = source.index(source.startIndex, offsetBy: "select(".count)
            let end = source.index(before: source.endIndex)
            let condition = String(source[start..<end])
            let comparison = try splitComparison(condition)
            let path = try parsePath(comparison.left)
            guard let literal = Self.parseScalar(comparison.right) else {
                throw JQError.invalid("select comparisons require a JSON scalar literal.")
            }
            return .select(path: path, comparison: comparison.comparison, literal: literal)
        }

        private mutating func parsePath(_ source: String) throws -> [PathComponent] {
            let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
            var cursor = PathParser(source: trimmed)
            let components = try cursor.parse()
            traversalComponentCount += components.count
            guard traversalComponentCount <= maximumTraversalDepth else {
                throw JQError.traversalLimit
            }
            return components
        }

        private func splitPipeline(_ source: String) throws -> [String] {
            let characters = Array(source)
            var result: [String] = []
            var start = 0
            var quote: Character?
            var isEscaped = false
            var bracketDepth = 0
            var parenthesisDepth = 0

            for index in characters.indices {
                let character = characters[index]
                if let currentQuote = quote {
                    if isEscaped {
                        isEscaped = false
                    } else if character == "\\" {
                        isEscaped = true
                    } else if character == currentQuote {
                        quote = nil
                    }
                    continue
                }
                switch character {
                case "\"":
                    quote = character
                case "[":
                    bracketDepth += 1
                case "]":
                    bracketDepth -= 1
                case "(":
                    parenthesisDepth += 1
                case ")":
                    parenthesisDepth -= 1
                case "|" where bracketDepth == 0 && parenthesisDepth == 0:
                    result.append(String(characters[start..<index]))
                    start = index + 1
                default:
                    break
                }
                guard bracketDepth >= 0, parenthesisDepth >= 0 else {
                    throw JQError.invalid("delimiters are unbalanced.")
                }
            }
            guard quote == nil, bracketDepth == 0, parenthesisDepth == 0 else {
                throw JQError.invalid("delimiters are unbalanced.")
            }
            result.append(String(characters[start..<characters.count]))
            return result
        }

        private func splitComparison(
            _ source: String
        ) throws -> (left: String, comparison: ComparisonOperator, right: String) {
            let characters = Array(source)
            var quote: Character?
            var isEscaped = false
            var bracketDepth = 0
            var index = 0
            let operators: [(String, ComparisonOperator)] = [
                ("==", .equal), ("!=", .notEqual), ("<=", .lessThanOrEqual),
                (">=", .greaterThanOrEqual), ("<", .lessThan), (">", .greaterThan)
            ]

            while index < characters.count {
                let character = characters[index]
                if let currentQuote = quote {
                    if isEscaped {
                        isEscaped = false
                    } else if character == "\\" {
                        isEscaped = true
                    } else if character == currentQuote {
                        quote = nil
                    }
                    index += 1
                    continue
                }
                if character == "\"" {
                    quote = character
                    index += 1
                    continue
                }
                if character == "[" {
                    bracketDepth += 1
                } else if character == "]" {
                    bracketDepth -= 1
                } else if bracketDepth == 0 {
                    for candidate in operators {
                        let end = index + candidate.0.count
                        guard end <= characters.count else { continue }
                        if String(characters[index..<end]) == candidate.0 {
                            let left = String(characters[0..<index])
                            let right = String(characters[end..<characters.count])
                            guard
                                !left.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                !right.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            else {
                                throw JQError.invalid("select comparison is incomplete.")
                            }
                            return (left, candidate.1, right)
                        }
                    }
                }
                guard bracketDepth >= 0 else {
                    throw JQError.invalid("select comparison delimiters are unbalanced.")
                }
                index += 1
            }
            throw JQError.invalid("select requires a comparison operator.")
        }

        private static func parseScalar(_ source: String) -> Scalar? {
            let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = text.data(using: .utf8),
                let value = try? JSONSerialization.jsonObject(
                    with: data,
                    options: [.fragmentsAllowed]
                )
            else {
                return nil
            }
            return JQBodyView.scalar(value)
        }
    }

    private struct PathParser {
        private let characters: [Character]
        private var index = 0

        init(source: String) {
            characters = Array(source)
        }

        mutating func parse() throws -> [PathComponent] {
            guard consume(".") else {
                throw JQError.invalid("a path must start with '.'.")
            }
            var components: [PathComponent] = []
            if index < characters.count, Self.isIdentifierStart(characters[index]) {
                components.append(.key(parseIdentifier()))
            }

            while index < characters.count {
                if consume(".") {
                    guard index < characters.count, Self.isIdentifierStart(characters[index]) else {
                        throw JQError.invalid("expected an object key after '.'.")
                    }
                    components.append(.key(parseIdentifier()))
                } else if consume("[") {
                    components.append(try parseBracket())
                } else {
                    throw JQError.invalid("unsupported path syntax at position \(index + 1).")
                }
            }
            return components
        }

        private mutating func parseBracket() throws -> PathComponent {
            if consume("]") {
                return .iterate
            }
            if index < characters.count, characters[index] == "\"" {
                let key = try parseJSONString()
                guard consume("]") else {
                    throw JQError.invalid("quoted key must end with ']'.")
                }
                return .key(key)
            }

            let start = index
            while index < characters.count, characters[index].isNumber {
                index += 1
            }
            guard start < index, let value = Int(String(characters[start..<index])) else {
                throw JQError.invalid("array indexes must be non-negative integers.")
            }
            guard consume("]") else {
                throw JQError.invalid("array index must end with ']'.")
            }
            return .index(value)
        }

        private mutating func parseJSONString() throws -> String {
            let start = index
            index += 1
            var isEscaped = false
            while index < characters.count {
                let character = characters[index]
                index += 1
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    let source = String(characters[start..<index])
                    guard let data = source.data(using: .utf8),
                        let value = try? JSONDecoder().decode(String.self, from: data)
                    else {
                        throw JQError.invalid("quoted key is not valid JSON text.")
                    }
                    return value
                }
            }
            throw JQError.invalid("quoted key is unterminated.")
        }

        private mutating func parseIdentifier() -> String {
            let start = index
            index += 1
            while index < characters.count, Self.isIdentifierContinuation(characters[index]) {
                index += 1
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

        private static func isIdentifierStart(_ character: Character) -> Bool {
            character.isLetter || character == "_"
        }

        private static func isIdentifierContinuation(_ character: Character) -> Bool {
            isIdentifierStart(character) || character.isNumber
        }
    }

    private static func evaluate(_ stage: Stage, inputs: [Any]) throws -> [Any] {
        switch stage {
        case .path(let path):
            return try traverse(path, inputs: inputs)
        case .select(let path, let comparison, let literal):
            var selected: [Any] = []
            selected.reserveCapacity(inputs.count)
            for input in inputs {
                let candidates = try traverse(path, inputs: [input])
                if candidates.contains(where: { compare($0, comparison: comparison, to: literal) })
                {
                    selected.append(input)
                }
            }
            return selected
        }
    }

    private static func traverse(_ path: [PathComponent], inputs: [Any]) throws -> [Any] {
        var values = inputs
        for component in path {
            var next: [Any] = []
            next.reserveCapacity(min(maximumValueCount, values.count))
            for value in values {
                switch component {
                case .key(let key):
                    if let object = value as? [String: Any], let child = object[key] {
                        try append(child, to: &next)
                    }
                case .index(let index):
                    if let array = value as? [Any], array.indices.contains(index) {
                        try append(array[index], to: &next)
                    }
                case .iterate:
                    if let array = value as? [Any] {
                        for child in array {
                            try append(child, to: &next)
                        }
                    } else if let object = value as? [String: Any] {
                        for key in object.keys.sorted() {
                            if let child = object[key] {
                                try append(child, to: &next)
                            }
                        }
                    }
                }
            }
            values = next
        }
        return values
    }

    private static func append(_ value: Any, to values: inout [Any]) throws {
        guard values.count < maximumValueCount else {
            throw JQError.valueLimit
        }
        values.append(value)
    }

    private static func compare(
        _ value: Any,
        comparison: ComparisonOperator,
        to literal: Scalar
    ) -> Bool {
        guard let lhs = scalar(value) else {
            return false
        }
        switch comparison {
        case .equal:
            return equals(lhs, literal)
        case .notEqual:
            return !equals(lhs, literal)
        case .lessThan:
            return ordered(lhs, literal) == .orderedAscending
        case .lessThanOrEqual:
            let result = ordered(lhs, literal)
            return result == .orderedAscending || result == .orderedSame
        case .greaterThan:
            return ordered(lhs, literal) == .orderedDescending
        case .greaterThanOrEqual:
            let result = ordered(lhs, literal)
            return result == .orderedDescending || result == .orderedSame
        }
    }

    private static func scalar(_ value: Any) -> Scalar? {
        if value is NSNull {
            return .null
        }
        if let value = value as? String {
            return .string(value)
        }
        if let value = value as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            return .number(value.doubleValue)
        }
        return nil
    }

    private static func equals(_ lhs: Scalar, _ rhs: Scalar) -> Bool {
        switch (lhs, rhs) {
        case (.string(let lhs), .string(let rhs)):
            lhs == rhs
        case (.number(let lhs), .number(let rhs)):
            lhs == rhs
        case (.bool(let lhs), .bool(let rhs)):
            lhs == rhs
        case (.null, .null):
            true
        default:
            false
        }
    }

    private static func ordered(_ lhs: Scalar, _ rhs: Scalar) -> ComparisonResult? {
        switch (lhs, rhs) {
        case (.number(let lhs), .number(let rhs)):
            lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
        case (.string(let lhs), .string(let rhs)):
            lhs.compare(rhs, options: .literal)
        default:
            nil
        }
    }

    private static func render(_ values: [Any]) throws -> [String] {
        var result: [String] = []
        result.reserveCapacity(values.count)
        var renderedByteCount = 0
        for value in values {
            guard let rendered = render(value) else {
                continue
            }
            renderedByteCount += rendered.utf8.count
            if !result.isEmpty {
                renderedByteCount += 2
            }
            guard renderedByteCount <= maximumRenderedOutputByteCount else {
                throw JQError.renderedOutputLimit
            }
            result.append(rendered)
        }
        return result
    }

    private static func render(_ value: Any) -> String? {
        if value is String || value is NSNumber || value is NSNull {
            guard
                let wrapper = try? JSONSerialization.data(
                    withJSONObject: ["value": value],
                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                )
            else {
                return nil
            }
            let text = String(decoding: wrapper, as: UTF8.self)
            guard let start = text.firstIndex(of: ":"), let end = text.lastIndex(of: "\n") else {
                return nil
            }
            return text[text.index(after: start)..<end]
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard JSONSerialization.isValidJSONObject(value),
            let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
        else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}
