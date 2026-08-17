import Foundation
import ProxyLensCore
import XCTest

@testable import ProxyLensCapture

final class ServerSentEventStreamDecoderTests: XCTestCase {
    func testDecodesFragmentedGzipAndXGzipStreamsIncrementally() throws {
        let eventStream = Data("data: first\n\ndata: second\n\n".utf8)
        let compressed = try HTTPContentCoding.encode(
            eventStream,
            contentEncoding: "gzip"
        )

        for contentEncoding in ["gzip", "x-gzip"] {
            let decoded = try decode(
                compressed,
                contentEncoding: contentEncoding,
                fragmentSize: 3
            )
            XCTAssertEqual(decoded, eventStream)
        }
    }

    func testDecodesFragmentedDeflateStreamIncrementally() throws {
        let eventStream = Data("event: update\ndata: ready\n\n".utf8)
        let zlibWrapped = try HTTPContentCoding.encode(
            eventStream,
            contentEncoding: "deflate"
        )
        let rawDeflate = Data(zlibWrapped.dropFirst(2).dropLast(4))

        for compressed in [zlibWrapped, rawDeflate] {
            let decoded = try decode(
                compressed,
                contentEncoding: "deflate",
                fragmentSize: 1
            )
            XCTAssertEqual(decoded, eventStream)
        }
    }

    func testRejectsDecodedOutputAboveTheLifetimeLimit() throws {
        let compressed = try HTTPContentCoding.encode(
            Data(repeating: 0x41, count: 4_096),
            contentEncoding: "gzip"
        )
        let decoder = try ServerSentEventStreamDecoder(
            contentEncoding: "gzip",
            maximumDecodedByteCount: 1_024
        )

        XCTAssertThrowsError(try decoder.append(compressed)) { error in
            XCTAssertEqual(
                error as? ServerSentEventStreamDecoder.DecodingError,
                .exceedsLimit
            )
        }
    }

    func testRejectsCorruptAndTruncatedCompressedStreams() throws {
        let corruptDecoder = try ServerSentEventStreamDecoder(
            contentEncoding: "gzip",
            maximumDecodedByteCount: 1_024
        )
        XCTAssertThrowsError(try corruptDecoder.append(Data("not gzip".utf8)))

        let eventStream = Data("data: incomplete\n\n".utf8)
        let compressed = try HTTPContentCoding.encode(
            eventStream,
            contentEncoding: "gzip"
        )
        let truncatedDecoder = try ServerSentEventStreamDecoder(
            contentEncoding: "gzip",
            maximumDecodedByteCount: 1_024
        )
        _ = try truncatedDecoder.append(compressed.dropLast(4))

        XCTAssertThrowsError(try truncatedDecoder.finish()) { error in
            XCTAssertEqual(
                error as? ServerSentEventStreamDecoder.DecodingError,
                .truncatedStream
            )
        }
    }

    func testRejectsUnsupportedOrStackedContentCodings() {
        for contentEncoding in ["br", "gzip, deflate"] {
            XCTAssertThrowsError(
                try ServerSentEventStreamDecoder(
                    contentEncoding: contentEncoding,
                    maximumDecodedByteCount: 1_024
                )
            ) { error in
                XCTAssertEqual(
                    error as? ServerSentEventStreamDecoder.DecodingError,
                    .unsupportedContentEncoding(contentEncoding)
                )
            }
        }
    }

    private func decode(
        _ compressed: Data,
        contentEncoding: String,
        fragmentSize: Int
    ) throws -> Data {
        let decoder = try ServerSentEventStreamDecoder(
            contentEncoding: contentEncoding,
            maximumDecodedByteCount: 1_024 * 1_024
        )
        var output = Data()
        var offset = 0
        while offset < compressed.count {
            let end = min(offset + fragmentSize, compressed.count)
            output.append(try decoder.append(compressed[offset..<end]))
            offset = end
        }
        output.append(try decoder.finish())
        return output
    }
}
