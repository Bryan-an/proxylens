#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENTITLEMENTS="$REPO_ROOT/ProxyLensApp/Resources/ProxyLens.entitlements"
DIST_DIR="$REPO_ROOT/dist"
APP_PATH="$DIST_DIR/ProxyLens.app"

usage() {
    cat <<'EOF'
Usage: scripts/notarize.sh

Re-sign dist/ProxyLens.app with Developer ID, submit it to Apple notarization,
staple the ticket, and rewrite the versioned zip plus SHA-256 checksum.

Requires a paid Apple Developer Program membership, a Developer ID Application
certificate in the keychain, and notary credentials in the environment or .env:

  APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD, and APPLE_TEAM_ID
    or
  APPLE_API_KEY_PATH, APPLE_API_KEY_ID, and APPLE_API_ISSUER

Optional:

  PROXYLENS_SIGN_IDENTITY   Developer ID Application identity to use when more
                            than one is installed

A free Apple ID cannot notarize. See docs/DISTRIBUTION.md.
EOF
}

fail() {
    printf 'notarize: error: %s\n' "$*" >&2
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

developer_program_required() {
    cat <<'EOF' >&2
notarize: error: Developer ID signing and Apple notarization require a paid Apple Developer Program membership. A free Apple ID cannot create a Developer ID Application certificate or submit builds to notarytool.

EOF
    if (($# > 0)); then
        printf 'Missing:\n' >&2
        local item
        for item in "$@"; do
            printf '  - %s\n' "$item" >&2
        done
        printf '\n' >&2
    fi
    printf 'See docs/DISTRIBUTION.md.\n' >&2
    exit 1
}

list_developer_id_identities() {
    security find-identity -v -p codesigning \
        | sed -n 's/.*"\(Developer ID Application: .*\)".*/\1/p'
}

resolve_sign_identity() {
    local configured="${PROXYLENS_SIGN_IDENTITY:-}"
    local identities
    local identity
    local match_count=0
    local selected=""

    if [[ -n "$configured" ]]; then
        if [[ "$configured" != "Developer ID Application:"* ]]; then
            printf '%s' ""
            return 1
        fi
        printf '%s' "$configured"
        return 0
    fi

    identities="$(list_developer_id_identities || true)"
    if [[ -z "$identities" ]]; then
        printf '%s' ""
        return 1
    fi

    while IFS= read -r identity; do
        [[ -n "$identity" ]] || continue
        match_count=$((match_count + 1))
        selected="$identity"
    done <<<"$identities"

    if ((match_count > 1)); then
        fail "multiple Developer ID Application identities found; set PROXYLENS_SIGN_IDENTITY to one of them"
    fi

    printf '%s' "$selected"
    return 0
}

has_app_specific_password_credentials() {
    [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]
}

has_api_key_credentials() {
    [[ -n "${APPLE_API_KEY_PATH:-}" && -n "${APPLE_API_KEY_ID:-}" && -n "${APPLE_API_ISSUER:-}" ]]
}

collect_missing_requirements() {
    local missing=()

    if has_api_key_credentials; then
        :
    elif has_app_specific_password_credentials; then
        if [[ -z "${APPLE_TEAM_ID:-}" ]]; then
            missing+=("APPLE_TEAM_ID")
        fi
    else
        missing+=("APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD, and APPLE_TEAM_ID, or APPLE_API_KEY_PATH, APPLE_API_KEY_ID, and APPLE_API_ISSUER")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        printf '%s\n' "${missing[@]}"
    fi
}

cd "$REPO_ROOT"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

[[ "${1:-}" == "" ]] || fail "unexpected argument: $1"

command -v codesign >/dev/null 2>&1 || fail "codesign is unavailable"
command -v xcrun >/dev/null 2>&1 || fail "xcrun is unavailable"
[[ -f "$ENTITLEMENTS" ]] || fail "missing entitlements: $ENTITLEMENTS"
[[ -d "$APP_PATH" ]] || fail "missing $APP_PATH; run ./scripts/package.sh first"

load_env

missing_args=()
SIGN_IDENTITY=""
if ! SIGN_IDENTITY="$(resolve_sign_identity)"; then
    if [[ -n "${PROXYLENS_SIGN_IDENTITY:-}" ]]; then
        missing_args+=("PROXYLENS_SIGN_IDENTITY must be a Developer ID Application identity")
    else
        missing_args+=("Developer ID Application certificate in the keychain")
    fi
fi

MISSING_CREDENTIALS="$(collect_missing_requirements || true)"
if [[ -n "$MISSING_CREDENTIALS" ]]; then
    while IFS= read -r item; do
        [[ -n "$item" ]] || continue
        missing_args+=("$item")
    done <<<"$MISSING_CREDENTIALS"
fi

if ((${#missing_args[@]} > 0)); then
    developer_program_required "${missing_args[@]}"
fi

if has_api_key_credentials; then
    [[ -f "$APPLE_API_KEY_PATH" ]] || fail "APPLE_API_KEY_PATH does not exist"
fi

step "Signing ProxyLens.app with Developer ID"
codesign \
    --force \
    --sign "$SIGN_IDENTITY" \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --generate-entitlement-der \
    --timestamp \
    "$APP_PATH"
codesign --verify --verbose=2 "$APP_PATH"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
[[ -n "$VERSION" ]] || fail "could not read CFBundleShortVersionString"

ZIP_PATH="$DIST_DIR/ProxyLens-$VERSION.zip"
CHECKSUM_PATH="$ZIP_PATH.sha256"

step "Writing $ZIP_PATH for notarization"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

step "Submitting to notarytool"
if has_api_key_credentials; then
    xcrun notarytool submit "$ZIP_PATH" \
        --key "$APPLE_API_KEY_PATH" \
        --key-id "$APPLE_API_KEY_ID" \
        --issuer "$APPLE_API_ISSUER" \
        --wait
else
    xcrun notarytool submit "$ZIP_PATH" \
        --apple-id "$APPLE_ID" \
        --team-id "$APPLE_TEAM_ID" \
        --password "$APPLE_APP_SPECIFIC_PASSWORD" \
        --wait
fi

step "Stapling the notarization ticket"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

step "Rewriting $ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
(
    cd "$DIST_DIR"
    shasum -a 256 "ProxyLens-$VERSION.zip"
) >"$CHECKSUM_PATH"

printf '\nNotarized %s\n' "$ZIP_PATH"
printf 'Checksum %s\n' "$CHECKSUM_PATH"
