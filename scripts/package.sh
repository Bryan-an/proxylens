#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENTITLEMENTS="$REPO_ROOT/ProxyLensApp/Resources/ProxyLens.entitlements"
DIST_DIR="$REPO_ROOT/dist"
DERIVED_DATA="$REPO_ROOT/.build/DerivedDataRelease"

usage() {
    cat <<'EOF'
Usage: scripts/package.sh

Build a Release ProxyLens.app, sign it, and write a versioned zip plus SHA-256
checksum under dist/.

Signing:
  Default identity is ad-hoc (-). Set PROXYLENS_SIGN_IDENTITY to a Developer ID
  Application identity after enrolling in the Apple Developer Program. Apple
  Development identities are rejected; they are for local runs, not distribution.

The zip is not notarized. Run scripts/notarize.sh after Developer ID signing.
EOF
}

fail() {
    printf 'package: error: %s\n' "$*" >&2
    exit 1
}

step() {
    printf '\n==> %s\n' "$*"
}

load_env() {
    local env_file="$REPO_ROOT/.env"
    if [[ -f "$env_file" ]]; then
        set -a
        # shellcheck disable=SC1090
        source "$env_file"
        set +a
    fi
}

is_developer_id_identity() {
    local identity="$1"
    [[ "$identity" == "Developer ID Application:"* ]]
}

resolve_sign_identity() {
    local identity="${PROXYLENS_SIGN_IDENTITY:--}"

    if [[ "$identity" == *"Apple Development"* ]]; then
        fail "Apple Development identities are for local runs, not distribution. Use ad-hoc (-) or a Developer ID Application identity."
    fi

    if [[ "$identity" != "-" ]] && ! is_developer_id_identity "$identity"; then
        fail "PROXYLENS_SIGN_IDENTITY must be '-' or a Developer ID Application identity."
    fi

    printf '%s' "$identity"
}

cd "$REPO_ROOT"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

[[ "${1:-}" == "" ]] || fail "unexpected argument: $1"

command -v xcodegen >/dev/null 2>&1 || fail "xcodegen is unavailable; install XcodeGen before packaging"
command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild is unavailable"
[[ -f "$ENTITLEMENTS" ]] || fail "missing entitlements: $ENTITLEMENTS"

load_env
SIGN_IDENTITY="$(resolve_sign_identity)"

step "Generating the Xcode project"
xcodegen generate --quiet

mkdir -p "$DIST_DIR"
rm -rf "$DIST_DIR/ProxyLens.app" "$DIST_DIR"/ProxyLens-*.zip "$DIST_DIR"/ProxyLens-*.zip.sha256

step "Building Release"
xcodebuild \
    -project "$REPO_ROOT/ProxyLens.xcodeproj" \
    -scheme ProxyLens \
    -configuration Release \
    -sdk macosx \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=YES \
    ENABLE_HARDENED_RUNTIME=YES \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    build

BUILT_APP="$DERIVED_DATA/Build/Products/Release/ProxyLens.app"
[[ -d "$BUILT_APP" ]] || fail "Release build did not produce ProxyLens.app"

step "Copying the app into dist/"
ditto "$BUILT_APP" "$DIST_DIR/ProxyLens.app"

CODESIGN_ARGS=(
    --force
    --sign "$SIGN_IDENTITY"
    --options runtime
    --entitlements "$ENTITLEMENTS"
    --generate-entitlement-der
)
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    CODESIGN_ARGS+=(--timestamp=none)
else
    CODESIGN_ARGS+=(--timestamp)
fi

step "Signing ProxyLens.app with $SIGN_IDENTITY"
codesign "${CODESIGN_ARGS[@]}" "$DIST_DIR/ProxyLens.app"
codesign --verify --verbose=2 "$DIST_DIR/ProxyLens.app"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DIST_DIR/ProxyLens.app/Contents/Info.plist")"
[[ -n "$VERSION" ]] || fail "could not read CFBundleShortVersionString"

ZIP_PATH="$DIST_DIR/ProxyLens-$VERSION.zip"
CHECKSUM_PATH="$ZIP_PATH.sha256"

step "Writing $ZIP_PATH"
ditto -c -k --keepParent "$DIST_DIR/ProxyLens.app" "$ZIP_PATH"
(
    cd "$DIST_DIR"
    shasum -a 256 "ProxyLens-$VERSION.zip"
) >"$CHECKSUM_PATH"

printf '\nPackaged %s\n' "$ZIP_PATH"
printf 'Checksum %s\n' "$CHECKSUM_PATH"

if is_developer_id_identity "$SIGN_IDENTITY"; then
    printf 'Signed with Developer ID. The zip is not notarized; run ./scripts/notarize.sh.\n'
else
    printf 'Ad-hoc signed and not notarized. Gatekeeper will block downloaded copies until a Developer ID signature is notarized.\n'
fi
