#!/bin/bash
# PostToolUse(Write): flag new Swift files that the generated project does not reference.
#
# The pbxproj lists sources individually, so a new file under ProxyLensApp/ or Tests/
# builds fine locally while `./scripts/quality.sh full` fails on the sync check.

set -uo pipefail

REPO_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
PBXPROJ="$REPO_ROOT/ProxyLens.xcodeproj/project.pbxproj"

file_path="$(jq -r '.tool_input.file_path // empty')"

[[ -n "$file_path" && "$file_path" == *.swift && -f "$PBXPROJ" ]] || exit 0

# Only the app and test targets are file-listed; the local packages build from Package.swift.
case "$file_path" in
    "$REPO_ROOT"/ProxyLensApp/*|"$REPO_ROOT"/Tests/*) ;;
    ProxyLensApp/*|Tests/*) ;;
    *) exit 0 ;;
esac

basename="${file_path##*/}"

if ! grep -q -- "$basename" "$PBXPROJ"; then
    printf '%s is not referenced by ProxyLens.xcodeproj.\n' "$basename" >&2
    printf 'Run `xcodegen generate` and commit the regenerated project, or `./scripts/quality.sh full` will fail the XcodeGen sync check.\n' >&2
    exit 2
fi

exit 0
