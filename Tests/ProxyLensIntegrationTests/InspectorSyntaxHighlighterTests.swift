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
            foregroundColor(at: json.range(of: #""name""#)!, in: highlighted),
            InspectorSyntaxPalette.key
        )
        XCTAssertEqual(
            foregroundColor(at: json.range(of: #""ProxyLens""#)!, in: highlighted),
            InspectorSyntaxPalette.string
        )
        XCTAssertEqual(
            foregroundColor(at: json.range(of: "42")!, in: highlighted),
            InspectorSyntaxPalette.number
        )
        XCTAssertEqual(
            foregroundColor(at: json.range(of: "true")!, in: highlighted),
            InspectorSyntaxPalette.literal
        )
        XCTAssertEqual(
            foregroundColor(at: json.range(of: "null")!, in: highlighted),
            InspectorSyntaxPalette.literal
        )
    }

    func testHighlightsHTTPHeaderNamesAndValues() {
        let headers = "Content-Type: application/json\r\nX-Request-ID: 123"
        let highlighted = InspectorSyntaxHighlighter.highlight(headers, as: .httpHeaders)

        XCTAssertEqual(highlighted.string, headers)
        XCTAssertEqual(
            foregroundColor(at: headers.range(of: "Content-Type")!, in: highlighted),
            InspectorSyntaxPalette.key
        )
        XCTAssertEqual(
            foregroundColor(at: headers.range(of: "application/json")!, in: highlighted),
            .secondaryLabelColor
        )
    }

    func testHighlightsXMLTokensWithoutChangingContent() {
        let xml = #"<!-- note --><root id="42"><child enabled='true'>&amp;</child></root>"#
        let highlighted = InspectorSyntaxHighlighter.highlight(xml, as: .xml)

        XCTAssertEqual(highlighted.string, xml)
        XCTAssertEqual(
            foregroundColor(at: xml.range(of: "root")!, in: highlighted),
            InspectorSyntaxPalette.key
        )
        XCTAssertEqual(
            foregroundColor(at: xml.range(of: "id")!, in: highlighted),
            InspectorSyntaxPalette.number
        )
        XCTAssertEqual(
            foregroundColor(at: xml.range(of: #""42""#)!, in: highlighted),
            InspectorSyntaxPalette.string
        )
        XCTAssertEqual(
            foregroundColor(at: xml.range(of: "<!-- note -->")!, in: highlighted),
            InspectorSyntaxPalette.literal
        )
        XCTAssertEqual(
            foregroundColor(at: xml.range(of: "&amp;")!, in: highlighted),
            InspectorSyntaxPalette.literal
        )
    }

    func testDoesNotHighlightXMLAttributeLikeTextOutsideTags() {
        let xml = #"<root>message id="42"</root>"#
        let highlighted = InspectorSyntaxHighlighter.highlight(xml, as: .xml)

        XCTAssertEqual(
            foregroundColor(at: xml.range(of: "id")!, in: highlighted),
            .textColor
        )
        XCTAssertEqual(
            foregroundColor(at: xml.range(of: #""42""#)!, in: highlighted),
            .textColor
        )
    }

    func testHighlightsURLEncodedFormKeysAndValuesWithoutChangingContent() {
        let form = "name=ProxyLens+App&enabled=true&empty="
        let highlighted = InspectorSyntaxHighlighter.highlight(form, as: .urlEncodedForm)

        XCTAssertEqual(highlighted.string, form)
        XCTAssertEqual(
            foregroundColor(at: form.range(of: "name")!, in: highlighted),
            InspectorSyntaxPalette.key
        )
        XCTAssertEqual(
            foregroundColor(at: form.range(of: "ProxyLens+App")!, in: highlighted),
            InspectorSyntaxPalette.string
        )
        XCTAssertEqual(
            foregroundColor(at: form.range(of: "enabled")!, in: highlighted),
            InspectorSyntaxPalette.key
        )
        XCTAssertEqual(
            foregroundColor(at: form.range(of: "true")!, in: highlighted),
            InspectorSyntaxPalette.string
        )
        XCTAssertEqual(
            foregroundColor(at: form.range(of: "empty")!, in: highlighted),
            InspectorSyntaxPalette.key
        )
    }

    func testSelectsBodyLanguageFromContentType() {
        XCTAssertEqual(
            InspectorSyntaxHighlighter.language(forContentType: "application/xml; charset=utf-8"),
            .xml
        )
        XCTAssertEqual(
            InspectorSyntaxHighlighter.language(forContentType: "text/xml"),
            .xml
        )
        XCTAssertEqual(
            InspectorSyntaxHighlighter.language(forContentType: "application/problem+xml"),
            .xml
        )
        XCTAssertEqual(
            InspectorSyntaxHighlighter.language(
                forContentType: "application/x-www-form-urlencoded; charset=utf-8"
            ),
            .urlEncodedForm
        )
        XCTAssertEqual(
            InspectorSyntaxHighlighter.language(
                forContentType: "multipart/form-data; boundary=test"),
            .plainText
        )
        XCTAssertEqual(
            InspectorSyntaxHighlighter.language(forContentType: "text/plain"),
            .plainText
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
            InspectorSyntaxPalette.key
        )
    }

    func testUsesMutedColorsInsteadOfTheSaturatedSystemPalette() {
        XCTAssertNotEqual(InspectorSyntaxPalette.key, .systemBlue)
        XCTAssertNotEqual(InspectorSyntaxPalette.string, .systemRed)
        XCTAssertNotEqual(InspectorSyntaxPalette.number, .systemPurple)
        XCTAssertNotEqual(InspectorSyntaxPalette.literal, .systemOrange)
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
