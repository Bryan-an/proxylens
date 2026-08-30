import Foundation

/// A local resource the forward listener answers itself instead of proxying.
public enum CertificateDistributionResource: Equatable, Hashable, Sendable {
    case setupPage
    case derCertificate
    case pemCertificate
}

/// Routing for the on-device certificate setup page.
///
/// A device reaches these two ways: directly, before it is proxying, with an origin-form
/// request to the listener (`GET /ssl`); or through the proxy once it is configured, with an
/// absolute-form request to the reserved host. Nothing else is intercepted, so a real
/// request for `http://example.com/ssl` is still forwarded upstream.
public enum CertificateDistribution {
    /// The host a configured device uses to reach the setup page through the proxy.
    public static let reservedHost = "proxy.lens"

    public static let setupPagePath = "/ssl"
    public static let derCertificatePath = "/proxylens.crt"
    public static let pemCertificatePath = "/proxylens.pem"

    private static let certificateArmourHeader = "-----BEGIN CERTIFICATE-----"
    private static let certificateArmourFooter = "-----END CERTIFICATE-----"

    /// Returns the resource a request targets, or `nil` when the request must be proxied.
    ///
    /// - Parameters:
    ///   - requestTarget: The raw request target, in origin or absolute form.
    ///   - isTunnelled: Whether the request arrived inside an established CONNECT tunnel.
    ///     Tunnelled requests belong to the tunnelled host, never to ProxyLens.
    ///   - isReverseProxyListener: Whether the request arrived on a reverse-proxy listener,
    ///     whose whole purpose is a fixed upstream.
    public static func resource(
        requestTarget: String,
        isTunnelled: Bool,
        isReverseProxyListener: Bool
    ) -> CertificateDistributionResource? {
        guard !isTunnelled, !isReverseProxyListener else {
            return nil
        }

        let trimmed = requestTarget.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return nil
        }

        if trimmed.hasPrefix("/") {
            return resource(path: normalizedPath(trimmed))
        }

        guard
            let components = URLComponents(string: trimmed),
            components.scheme?.lowercased() == "http",
            let host = components.host,
            NetworkAddress.normalizedHost(host) == reservedHost
        else {
            return nil
        }

        return resource(path: normalizedPath(components.percentEncodedPath))
    }

    /// Converts the PEM-encoded root certificate to DER for devices that expect `.crt`.
    ///
    /// Devices reject a private key or an arbitrary blob confusingly, so the armour is
    /// checked before decoding and only a DER SEQUENCE is accepted.
    public static func derEncodedCertificate(fromPEM pem: Data) throws -> Data {
        guard let text = String(data: pem, encoding: .utf8) else {
            throw ProxyLensError.unsupportedOperation("The root certificate is not UTF-8 PEM")
        }
        guard
            let headerRange = text.range(of: certificateArmourHeader),
            let footerRange = text.range(of: certificateArmourFooter),
            headerRange.upperBound <= footerRange.lowerBound
        else {
            throw ProxyLensError.unsupportedOperation(
                "The root certificate is not a PEM certificate"
            )
        }

        let base64 = String(text[headerRange.upperBound..<footerRange.lowerBound])
        guard
            let der = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
            der.first == 0x30
        else {
            throw ProxyLensError.unsupportedOperation(
                "The root certificate is not valid DER inside its PEM armour"
            )
        }

        return der
    }

    private static func resource(path: String) -> CertificateDistributionResource? {
        switch path {
        case "/", setupPagePath:
            .setupPage
        case derCertificatePath:
            .derCertificate
        case pemCertificatePath:
            .pemCertificate
        default:
            nil
        }
    }

    private static func normalizedPath(_ target: String) -> String {
        var path = target
        if let queryStart = path.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            path = String(path[path.startIndex..<queryStart])
        }
        path = path.lowercased()
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path.isEmpty ? "/" : path
    }
}

/// The HTML a device sees at the setup page.
public enum CertificateSetupPage {
    /// The URL to print and encode as a QR code for the device to open.
    public static func setupURL(proxyHost: String, proxyPort: UInt16) -> String {
        "http://\(proxyHost):\(proxyPort)\(CertificateDistribution.setupPagePath)"
    }

    /// A self-contained page: no external assets, no scripts, readable on a phone.
    public static func html(proxyHost: String, proxyPort: UInt16) -> String {
        let host = escaped(proxyHost)
        let port = String(proxyPort)

        return """
            <!DOCTYPE html>
            <html lang="en">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>ProxyLens certificate setup</title>
            <style>
            :root { color-scheme: light dark; }
            body { font: -apple-system-body, system-ui, sans-serif; margin: 0 auto;
              max-width: 34rem; padding: 2rem 1.25rem; line-height: 1.5; }
            h1 { font-size: 1.5rem; }
            h2 { font-size: 1.1rem; margin-top: 2rem; }
            code { background: rgba(127,127,127,0.18); border-radius: 4px; padding: 0 .3em; }
            .download { display: inline-block; margin: .35rem .5rem .35rem 0; padding: .6rem 1rem;
              border: 1px solid currentColor; border-radius: 8px; text-decoration: none; }
            ol { padding-left: 1.2rem; }
            </style>
            </head>
            <body>
            <h1>ProxyLens</h1>
            <p>This device is talking to ProxyLens at <code>\(host):\(port)</code>.</p>
            <h2>1. Set the proxy</h2>
            <p>In the device's Wi-Fi settings, set the HTTP proxy to host <code>\(host)</code>
            and port <code>\(port)</code>.</p>
            <h2>2. Download the certificate</h2>
            <p>
            <a class="download" href="\(CertificateDistribution.derCertificatePath)">Certificate
            (.crt)</a>
            <a class="download" href="\(CertificateDistribution.pemCertificatePath)">Certificate
            (.pem)</a>
            </p>
            <h2>3. Trust it</h2>
            <p><strong>iOS and iPadOS</strong></p>
            <ol>
            <li>Open the downloaded profile and install it in Settings.</li>
            <li>Go to Settings &rsaquo; General &rsaquo; About &rsaquo; Certificate Trust
            Settings.</li>
            <li>Turn on full trust for the ProxyLens certificate.</li>
            </ol>
            <p><strong>Android</strong></p>
            <ol>
            <li>Open Settings &rsaquo; Security &rsaquo; Encryption &amp; credentials.</li>
            <li>Choose Install a certificate, then CA certificate.</li>
            <li>Select the downloaded <code>.crt</code> file.</li>
            </ol>
            <p>Apps that pin certificates will still refuse to be inspected. Remove the
            certificate when you are done debugging.</p>
            </body>
            </html>
            """
    }

    private static func escaped(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&#39;"
            default: escaped.append(character)
            }
        }
        return escaped
    }
}
