# Direct-download packaging

ProxyLens is distributed as a signed, notarized macOS app downloaded directly — not through the App Store. Hardened Runtime is on; the app is not sandboxed, because capture needs a local listener, Keychain-backed CA material, and system proxy changes.

A **paid Apple Developer Program membership** is required to produce a Gatekeeper-trusted download. A free Apple ID can build and run ProxyLens locally. It cannot create a Developer ID Application certificate or submit builds to Apple notarization.

GitHub Releases are deferred until that membership exists.

## Local package

```sh
./scripts/package.sh
```

The script regenerates the Xcode project, builds the `ProxyLens` scheme in Release, signs the app, and writes:

```text
dist/ProxyLens.app
dist/ProxyLens-0.1.0.zip
dist/ProxyLens-0.1.0.zip.sha256
```

Signing identity:

- Default is **ad-hoc** (`-`). The zip is not notarized. Gatekeeper will block copies downloaded from the internet.
- Set `PROXYLENS_SIGN_IDENTITY` to a `Developer ID Application: …` identity after enrollment. Do not use an `Apple Development` identity for the zip; that signature is for local runs only.

`dist/` is gitignored. Packaging is not part of `./scripts/quality.sh` or the Quality GitHub Action.

## Gatekeeper without notarization

An ad-hoc or unsigned download is expected to show “unidentified developer”. Until a Developer ID signature is notarized, the only ways to open it are:

- Finder: Control-click the app, choose Open, then confirm.
- Terminal: `xattr -d com.apple.quarantine /path/to/ProxyLens.app`

Do not disable Gatekeeper globally. Prefer running a Debug build from Xcode for day-to-day work.

## Notarization after enrollment

1. Enroll in the [Apple Developer Program](https://developer.apple.com/programs/).
2. Create a **Developer ID Application** certificate and install it in the keychain.
3. Copy [`.env.example`](../.env.example) to `.env` and fill in either:
   - `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, and `APPLE_TEAM_ID`, or
   - `APPLE_API_KEY_PATH`, `APPLE_API_KEY_ID`, and `APPLE_API_ISSUER` (`notarytool` infers the team from the key)
4. Optionally set `PROXYLENS_SIGN_IDENTITY` when more than one Developer ID is installed.
5. Package, then notarize:

```sh
./scripts/package.sh
./scripts/notarize.sh
```

`scripts/notarize.sh` re-signs `dist/ProxyLens.app` with Developer ID, submits the zip with `notarytool`, staples the ticket, and rewrites the zip and checksum. Without a Developer ID identity or notary credentials it exits and prints what is missing. It does not log secret values.

`.env` is gitignored. Never commit certificates, `.p12` files, or app-specific passwords.

## After notarization

The remaining distribution step is a GitHub Release that publishes the notarized zip and its SHA-256 checksum. That workflow is intentionally not in the repository until Developer ID signing is available.
