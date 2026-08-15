import Darwin
import Foundation
import ProxyLensCore
@preconcurrency import Security
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
    func testRootPrivateKeyAllowsCurrentApplicationToSignWithoutPrompt() async throws {
        let provider = makeProvider()

        do {
            _ = try await provider.rootCertificate()
            let trustsCurrentApplication =
                try await provider.rootPrivateKeyTrustsCurrentApplicationForTesting()
            XCTAssertTrue(trustsCurrentApplication)
            _ = try await provider.leafCertificate(for: "localhost")
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

    func testRootCertificateRoundTripsAcrossProviderInstances() async throws {
        let namespace = "com.proxylens.tests.\(UUID().uuidString)"
        let first = KeychainCertificateProvider(
            configuration: .init(keychainNamespace: namespace)
        )
        let second = KeychainCertificateProvider(
            configuration: .init(keychainNamespace: namespace)
        )

        do {
            let pem = try await first.rootCertificate()
            let reloaded = try await second.rootCertificate()
            XCTAssertEqual(pem, reloaded)
        } catch {
            try? await first.removeCertificateAuthority()
            throw error
        }

        try await first.removeCertificateAuthority()
    }

    func testTrustStoreReportsNotGeneratedThenUntrustedAndExportsPEM() async throws {
        let provider = makeProvider()
        let store = SystemCertificateTrustStore(certificateProvider: provider)
        let exportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxylens-root-\(UUID().uuidString).pem")

        do {
            let initial = try await store.trustState()
            XCTAssertEqual(initial, .notGenerated)

            try await store.exportRootCertificate(to: exportURL)
            let attributes = try FileManager.default.attributesOfItem(atPath: exportURL.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.uint16Value, 0o644)

            let pem = try String(contentsOf: exportURL, encoding: .utf8)
            XCTAssertTrue(pem.contains("BEGIN CERTIFICATE"))
            _ = try Certificate(pemEncoded: pem)

            let afterExport = try await store.trustState()
            XCTAssertEqual(afterExport, .untrusted)
        } catch {
            try? await provider.removeCertificateAuthority()
            try? FileManager.default.removeItem(at: exportURL)
            throw error
        }

        try? FileManager.default.removeItem(at: exportURL)
        try await provider.removeCertificateAuthority()
    }
    func testTrustStateRecognizesOnlyUnrestrictedRootTrustSettings() {
        XCTAssertTrue(SystemCertificateTrustStore.trustSettingsGrantUnrestrictedRootTrust([]))
        XCTAssertTrue(
            SystemCertificateTrustStore.trustSettingsGrantUnrestrictedRootTrust([[:]])
        )
        XCTAssertTrue(
            SystemCertificateTrustStore.trustSettingsGrantUnrestrictedRootTrust([
                [
                    kSecTrustSettingsResult: NSNumber(
                        value: SecTrustSettingsResult.trustRoot.rawValue
                    )
                ]
            ])
        )
        XCTAssertFalse(
            SystemCertificateTrustStore.trustSettingsGrantUnrestrictedRootTrust([
                [
                    kSecTrustSettingsResult: NSNumber(
                        value: SecTrustSettingsResult.deny.rawValue
                    )
                ]
            ])
        )
        XCTAssertFalse(
            SystemCertificateTrustStore.trustSettingsGrantUnrestrictedRootTrust([
                [
                    kSecTrustSettingsPolicy: "ssl",
                    kSecTrustSettingsResult: NSNumber(
                        value: SecTrustSettingsResult.trustRoot.rawValue
                    )
                ]
            ])
        )
    }

    func testSystemProxyRecoveryIsNoOpWithoutSnapshot() async throws {
        let snapshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyLensSystemProxyTests-\(UUID().uuidString)")
            .appendingPathComponent("PreviousConfiguration.plist")
        let controller = MacOSSystemProxyController(snapshotURL: snapshotURL)

        try await controller.recoverInterruptedConfiguration()

        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path))
    }
    func testSystemProxyControllerCachesAuthorizationForItsLifetime() async throws {
        let snapshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyLensSystemProxyTests-\(UUID().uuidString)")
            .appendingPathComponent("PreviousConfiguration.plist")
        let controller = MacOSSystemProxyController(snapshotURL: snapshotURL)

        let authorizationIsCached = try await controller.authorizationIsCachedForTesting()
        XCTAssertTrue(authorizationIsCached)
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

    func testApplicationSourceResolverUsesSocketOwnerMetadataAndPreservesClientAddress() async {
        let application = FlowApplication(
            name: "Safari",
            bundleIdentifier: "com.apple.Safari",
            bundlePath: "/System/Applications/Safari.app",
            executablePath: "/System/Applications/Safari.app/Contents/MacOS/Safari",
            processIdentifier: 501
        )
        let resolver = MacOSFlowSourceResolver(
            socketLocator: FixedProcessSocketLocator(processIdentifier: 501),
            applicationInspector: FixedProcessApplicationInspector(application: application)
        )

        let source = await resolver.resolveSource(
            clientEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 54_321),
            proxyEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 9_090)
        )

        XCTAssertEqual(source.kind, .desktopProxy)
        XCTAssertEqual(source.label, "Safari")
        XCTAssertEqual(source.clientAddress, "127.0.0.1:54321")
        XCTAssertEqual(source.application, application)
    }

    func testApplicationSourceResolverFallsBackWhenTheSocketOwnerIsUnavailable() async {
        let resolver = MacOSFlowSourceResolver(
            socketLocator: FixedProcessSocketLocator(processIdentifier: nil),
            applicationInspector: FixedProcessApplicationInspector(application: nil)
        )

        let source = await resolver.resolveSource(
            clientEndpoint: NetworkEndpoint(host: "::1", port: 54_321),
            proxyEndpoint: NetworkEndpoint(host: "::1", port: 9_090)
        )

        XCTAssertEqual(source.kind, .desktopProxy)
        XCTAssertEqual(source.label, "Desktop proxy")
        XCTAssertEqual(source.clientAddress, "[::1]:54321")
        XCTAssertNil(source.application)
    }

    func testLibprocSocketLocatorFindsTheCurrentProcessLocalConnection() throws {
        let connection = try LocalTCPConnection()
        defer { connection.close() }

        let processIdentifier = LibprocProcessSocketLocator().processIdentifier(
            clientPort: connection.clientPort,
            proxyPort: connection.serverPort
        )

        XCTAssertEqual(processIdentifier, getpid())
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

private struct FixedProcessSocketLocator: ProcessSocketLocating {
    let processIdentifier: pid_t?

    func processIdentifier(clientPort _: UInt16, proxyPort _: UInt16) -> pid_t? {
        processIdentifier
    }
}

private struct FixedProcessApplicationInspector: ProcessApplicationInspecting {
    let application: FlowApplication?

    func application(processIdentifier _: pid_t) -> FlowApplication? {
        application
    }
}

private final class LocalTCPConnection {
    let clientPort: UInt16
    let serverPort: UInt16

    private let listener: Int32
    private let client: Int32
    private let accepted: Int32

    init() throws {
        let listenerDescriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard listenerDescriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenerDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(listenerDescriptor, 1) == 0 else {
            Darwin.close(listenerDescriptor)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listenerDescriptor, $0, &addressLength)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(listenerDescriptor)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        let resolvedServerPort = UInt16(bigEndian: address.sin_port)

        let clientDescriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard clientDescriptor >= 0 else {
            Darwin.close(listenerDescriptor)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        let connectResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(clientDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else {
            Darwin.close(clientDescriptor)
            Darwin.close(listenerDescriptor)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        let acceptedDescriptor = Darwin.accept(listenerDescriptor, nil, nil)
        guard acceptedDescriptor >= 0 else {
            Darwin.close(clientDescriptor)
            Darwin.close(listenerDescriptor)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        var clientAddress = sockaddr_in()
        addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let clientNameResult = withUnsafeMutablePointer(to: &clientAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(clientDescriptor, $0, &addressLength)
            }
        }
        guard clientNameResult == 0 else {
            Darwin.close(acceptedDescriptor)
            Darwin.close(clientDescriptor)
            Darwin.close(listenerDescriptor)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        listener = listenerDescriptor
        client = clientDescriptor
        accepted = acceptedDescriptor
        serverPort = resolvedServerPort
        clientPort = UInt16(bigEndian: clientAddress.sin_port)
    }

    func close() {
        Darwin.close(accepted)
        Darwin.close(client)
        Darwin.close(listener)
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
