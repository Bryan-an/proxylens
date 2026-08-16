import AppKit

enum InspectorSyntaxPalette {
    static let key = adaptive(
        name: "InspectorSyntax.Key",
        light: NSColor(srgbRed: 0.20, green: 0.38, blue: 0.45, alpha: 1),
        dark: NSColor(srgbRed: 0.56, green: 0.72, blue: 0.78, alpha: 1)
    )
    static let string = adaptive(
        name: "InspectorSyntax.String",
        light: NSColor(srgbRed: 0.46, green: 0.34, blue: 0.17, alpha: 1),
        dark: NSColor(srgbRed: 0.83, green: 0.71, blue: 0.55, alpha: 1)
    )
    static let number = adaptive(
        name: "InspectorSyntax.Number",
        light: NSColor(srgbRed: 0.43, green: 0.30, blue: 0.47, alpha: 1),
        dark: NSColor(srgbRed: 0.78, green: 0.63, blue: 0.81, alpha: 1)
    )
    static let literal = adaptive(
        name: "InspectorSyntax.Literal",
        light: NSColor(srgbRed: 0.52, green: 0.31, blue: 0.31, alpha: 1),
        dark: NSColor(srgbRed: 0.83, green: 0.60, blue: 0.60, alpha: 1)
    )

    private static func adaptive(
        name: String,
        light: NSColor,
        dark: NSColor
    ) -> NSColor {
        NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? dark
                : light
        }
    }
}

/// Produces presentation-only colors for inspector text without changing captured bytes.
enum InspectorSyntaxHighlighter {
    enum Language: Equatable {
        case plainText
        case httpHeaders
        case json
        case urlEncodedForm
        case xml
    }

    static func language(forContentType contentType: String?) -> Language {
        guard
            let mediaType = contentType?
                .split(separator: ";", maxSplits: 1)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        else {
            return .plainText
        }

        if mediaType == "application/x-www-form-urlencoded" {
            return .urlEncodedForm
        }
        if mediaType == "application/xml" || mediaType == "text/xml"
            || mediaType.hasSuffix("+xml")
        {
            return .xml
        }
        return .plainText
    }

    static func highlight(
        _ text: String,
        as language: Language,
        in highlightedRange: NSRange? = nil
    ) -> NSAttributedString {
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let syntaxRange = highlightedRange ?? fullRange
        let result = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.textColor
            ]
        )

        switch language {
        case .plainText:
            break
        case .httpHeaders:
            headerPattern.enumerateMatches(in: text, range: syntaxRange) { match, _, _ in
                guard let match, match.numberOfRanges == 3 else { return }
                result.addAttribute(
                    .foregroundColor,
                    value: InspectorSyntaxPalette.key,
                    range: match.range(at: 1)
                )
                result.addAttribute(
                    .foregroundColor,
                    value: NSColor.secondaryLabelColor,
                    range: match.range(at: 2)
                )
            }
        case .json:
            jsonPattern.enumerateMatches(in: text, range: syntaxRange) { match, _, _ in
                guard let match else { return }
                let color: NSColor
                switch match.range {
                case match.range(at: 1): color = InspectorSyntaxPalette.key
                case match.range(at: 2): color = InspectorSyntaxPalette.string
                case match.range(at: 3): color = InspectorSyntaxPalette.number
                default: color = InspectorSyntaxPalette.literal
                }
                result.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        case .urlEncodedForm:
            urlEncodedFormPattern.enumerateMatches(in: text, range: syntaxRange) {
                match, _, _ in
                guard let match, match.numberOfRanges == 3 else { return }
                result.addAttribute(
                    .foregroundColor,
                    value: InspectorSyntaxPalette.key,
                    range: match.range(at: 1)
                )
                result.addAttribute(
                    .foregroundColor,
                    value: InspectorSyntaxPalette.string,
                    range: match.range(at: 2)
                )
            }
        case .xml:
            xmlTagPattern.enumerateMatches(in: text, range: syntaxRange) { tag, _, _ in
                guard let tag else { return }
                if let element = xmlElementPattern.firstMatch(in: text, range: tag.range) {
                    result.addAttribute(
                        .foregroundColor,
                        value: InspectorSyntaxPalette.key,
                        range: element.range(at: 1)
                    )
                }
                xmlAttributePattern.enumerateMatches(in: text, range: tag.range) {
                    attribute, _, _ in
                    guard let attribute, attribute.numberOfRanges == 4 else { return }
                    result.addAttribute(
                        .foregroundColor,
                        value: InspectorSyntaxPalette.number,
                        range: attribute.range(at: 1)
                    )
                    result.addAttribute(
                        .foregroundColor,
                        value: InspectorSyntaxPalette.string,
                        range: attribute.range(at: 3)
                    )
                }
            }
            xmlEntityPattern.enumerateMatches(in: text, range: syntaxRange) { match, _, _ in
                guard let match else { return }
                result.addAttribute(
                    .foregroundColor,
                    value: InspectorSyntaxPalette.literal,
                    range: match.range
                )
            }
            xmlMarkupPattern.enumerateMatches(in: text, range: syntaxRange) { match, _, _ in
                guard let match else { return }
                result.addAttribute(
                    .foregroundColor,
                    value: InspectorSyntaxPalette.literal,
                    range: match.range
                )
            }
        }

        return result
    }

    private static let headerPattern = try! NSRegularExpression(
        pattern: #"(?m)^([^:\r\n]+)(:.*)$"#
    )

    // Capture groups distinguish keys, string values, numbers, and JSON literals.
    private static let jsonPattern = try! NSRegularExpression(
        pattern:
            #"("(?:\\.|[^"\\])*")(?=\s*:)|("(?:\\.|[^"\\])*")|(-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?)|\b(?:true|false|null)\b"#
    )

    private static let urlEncodedFormPattern = try! NSRegularExpression(
        pattern: #"([^=&\r\n]+)=([^&\r\n]*)"#
    )

    private static let xmlElementPattern = try! NSRegularExpression(
        pattern: #"</?\s*([A-Za-z_][A-Za-z0-9_.:-]*)"#
    )

    private static let xmlTagPattern = try! NSRegularExpression(
        pattern: #"<(?![!?])(?:[^"'<>]|"[^"]*"|'[^']*')+>"#
    )

    private static let xmlAttributePattern = try! NSRegularExpression(
        pattern: #"\s([A-Za-z_][A-Za-z0-9_.:-]*)(\s*=\s*)((?:"[^"]*")|(?:'[^']*'))"#
    )

    private static let xmlEntityPattern = try! NSRegularExpression(
        pattern: #"&(?:#[0-9]+|#x[0-9A-Fa-f]+|[A-Za-z_][A-Za-z0-9_.:-]*);"#
    )

    private static let xmlMarkupPattern = try! NSRegularExpression(
        pattern: #"<!--.*?-->|<!\[CDATA\[.*?\]\]>|<\?.*?\?>"#,
        options: [.dotMatchesLineSeparators]
    )
}
