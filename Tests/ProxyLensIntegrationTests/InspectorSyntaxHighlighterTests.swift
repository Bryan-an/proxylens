import AppKit
import XCTest

@testable import ProxyLens

@MainActor
final class InspectorSyntaxHighlighterTests: XCTestCase {
    func testHighlightsJSONTokensWithoutChangingContent() {
        let json = #"{"name":"ProxyLens","count":42,"enabled":true,"missing":null}"#
        let highlighted = InspectorSyntaxHighlighter.highlight(json, as: .json)

        XCTAssertEqual(highlighted.string, json)
        XCTAssertEqual(
            foregroundColor(at: json.range(of: #""name""#)!, in: highlighted), .systemBlue)
        XCTAssertEqual(
            foregroundColor(at: json.range(of: #""ProxyLens""#)!, in: highlighted),
            .systemRed
        )
        XCTAssertEqual(foregroundColor(at: json.range(of: "42")!, in: highlighted), .systemPurple)
        XCTAssertEqual(foregroundColor(at: json.range(of: "true")!, in: highlighted), .systemOrange)
        XCTAssertEqual(foregroundColor(at: json.range(of: "null")!, in: highlighted), .systemOrange)
    }

    func testHighlightsHTTPHeaderNamesAndValues() {
        let headers = "Content-Type: application/json\r\nX-Request-ID: 123"
        let highlighted = InspectorSyntaxHighlighter.highlight(headers, as: .httpHeaders)

        XCTAssertEqual(highlighted.string, headers)
        XCTAssertEqual(
            foregroundColor(at: headers.range(of: "Content-Type")!, in: highlighted),
            .systemBlue
        )
        XCTAssertEqual(
            foregroundColor(at: headers.range(of: "application/json")!, in: highlighted),
            .secondaryLabelColor
        )
    }

    func testRestrictsJSONHighlightingToTheDerivedPayload() {
        let metadata = "42 B • application/json"
        let json = #"{"count":42}"#
        let text = "\(metadata)\n\n\(json)"
        let payloadRange = NSRange(
            location: (metadata + "\n\n").utf16.count,
            length: json.utf16.count
        )

        let highlighted = InspectorSyntaxHighlighter.highlight(
            text,
            as: .json,
            in: payloadRange
        )

        XCTAssertEqual(highlighted.string, text)
        XCTAssertEqual(
            foregroundColor(at: text.range(of: "42")!, in: highlighted),
            .textColor
        )
        XCTAssertEqual(
            foregroundColor(at: text.range(of: #""count""#)!, in: highlighted),
            .systemBlue
        )
    }

    private func foregroundColor(
        at range: Range<String.Index>,
        in value: NSAttributedString
    ) -> NSColor? {
        value.attribute(
            .foregroundColor,
            at: NSRange(range, in: value.string).location,
            effectiveRange: nil
        ) as? NSColor
    }
}
