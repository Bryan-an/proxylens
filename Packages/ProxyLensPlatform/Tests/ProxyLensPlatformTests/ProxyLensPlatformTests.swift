import Foundation
import ProxyLensCore
import X509
import XCTest

@testable import ProxyLensPlatform

final class ProxyLensPlatformTests: XCTestCase {
    func testKeychainProviderKeepsRootStableAndNonExtractable() async throws {
        let provider = makeProvider()

        do {
            let first = try await provider.rootCertificate()
            let second = try await provider.rootCertificate()
            let rootPrivateKeyIsExtractable =
                try await provider.rootPrivateKeyIsExtractableForTesting()

            XCTAssertEqual(first, second)
            XCTAssertFalse(rootPrivateKeyIsExtractable)

            let certificate = try parseCertificate(first)
            XCTAssertEqual(certificate.subject, certificate.issuer)
            XCTAssertEqual(
                try XCTUnwrap(try certificate.extensions.basicConstraints),
                .isCertificateAuthority(maxPathLength: 0)
            )
        } catch {
            try? await provider.removeCertificateAuthority()
            throw error
        }

        try await provider.removeCertificateAuthority()
    }

    func testLeafCertificateIsCachedAndSignedByRoot() async throws {
        let provider = makeProvider()

        do {
            let root = try parseCertificate(try await provider.rootCertificate())
            let first = try await provider.leafCertificate(for: "LOCALHOST.")
            let second = try await provider.leafCertificate(for: "localhost")

            XCTAssertEqual(first, second)
            XCTAssertFalse(first.privateKeyData.isEmpty)

            let leaf = try parseCertificate(first.certificateData)
            XCTAssertEqual(leaf.issuer, root.subject)
            XCTAssertTrue(root.publicKey.isValidSignature(leaf.signature, for: leaf))
            XCTAssertEqual(
                Array(try XCTUnwrap(try leaf.extensions.subjectAlternativeNames)),
                [.dnsName("localhost")]
            )
            XCTAssertEqual(
                Array(try XCTUnwrap(try leaf.extensions.extendedKeyUsage)),
                [.serverAuth]
            )
            XCTAssertNoThrow(
                try Certificate.PrivateKey(
                    pemEncoded: String(decoding: first.privateKeyData, as: UTF8.self)
                )
            )
        } catch {
            try? await provider.removeCertificateAuthority()
            throw error
        }

        try await provider.removeCertificateAuthority()
    }

    func testLeafCertificateRejectsInvalidHostname() async throws {
        let provider = makeProvider()

        await assertThrowsErrorAsync(try await provider.leafCertificate(for: "bad host")) {
            error in
            XCTAssertEqual(error as? CertificateProviderError, .invalidHostname("bad host"))
        }

        try await provider.removeCertificateAuthority()
    }

    func testSystemProxyRecoveryIsNoOpWithoutSnapshot() async throws {
        let snapshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyLensSystemProxyTests-\(UUID().uuidString)")
            .appendingPathComponent("PreviousConfiguration.plist")
        let controller = MacOSSystemProxyController(snapshotURL: snapshotURL)

        try await controller.recoverInterruptedConfiguration()

        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path))
    }

    func testSystemProxyRecoveryFailsClosedForCorruptSnapshot() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyLensSystemProxyTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let snapshotURL = rootURL.appendingPathComponent("PreviousConfiguration.plist")
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        try Data([0xFF]).write(to: snapshotURL)
        let controller = MacOSSystemProxyController(snapshotURL: snapshotURL)

        await assertThrowsErrorAsync(
            try await controller.recoverInterruptedConfiguration()
        ) { error in
            XCTAssertEqual(error as? SystemProxyControllerError, .invalidSnapshot)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path))
    }

    func testSystemProxyRestoreRequiresDurableSnapshot() async {
        let snapshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyLensSystemProxyTests-\(UUID().uuidString)")
            .appendingPathComponent("PreviousConfiguration.plist")
        let controller = MacOSSystemProxyController(snapshotURL: snapshotURL)

        await assertThrowsErrorAsync(
            try await controller.restorePreviousConfiguration()
        ) { error in
            XCTAssertEqual(error as? SystemProxyControllerError, .snapshotMissing)
        }
    }

    private func makeProvider() -> KeychainCertificateProvider {
        KeychainCertificateProvider(
            configuration: .init(
                keychainNamespace: "com.proxylens.tests.\(UUID().uuidString)",
                maximumCachedLeafCertificates: 2
            )
        )
    }

    private func parseCertificate(_ data: Data) throws -> Certificate {
        try Certificate(pemEncoded: String(decoding: data, as: UTF8.self))
    }
}

private func assertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
