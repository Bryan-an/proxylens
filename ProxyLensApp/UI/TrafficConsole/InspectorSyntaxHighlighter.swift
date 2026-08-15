import AppKit

/// Produces presentation-only colors for inspector text without changing captured bytes.
enum InspectorSyntaxHighlighter {
    enum Language {
        case plainText
        case httpHeaders
        case json
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
                    .foregroundColor, value: NSColor.systemBlue, range: match.range(at: 1))
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
                case match.range(at: 1): color = .systemBlue
                case match.range(at: 2): color = .systemRed
                case match.range(at: 3): color = .systemPurple
                default: color = .systemOrange
                }
                result.addAttribute(.foregroundColor, value: color, range: match.range)
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
}
