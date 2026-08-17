#!/bin/bash
# PostToolUse(Edit|Write): format the edited Swift file with the repository formatter.
#
# Mirrors the `pre-commit` gate (scripts/quality.sh staged) so lint failures surface
# at edit time instead of at commit time.

set -uo pipefail

REPO_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
CONFIG="$REPO_ROOT/.swift-format"

file_path="$(jq -r '.tool_input.file_path // empty')"

[[ -n "$file_path" && "$file_path" == *.swift && -f "$file_path" ]] || exit 0

case "$file_path" in
    */.build/*) exit 0 ;;
esac

[[ -f "$CONFIG" ]] || exit 0

select_swift_format() {
    if command -v swift-format >/dev/null 2>&1; then
        SWIFT_FORMAT=(swift-format)
        return 0
    fi

    local found
    found="$(xcrun --find swift-format 2>/dev/null || true)"
    if [[ -n "$found" && -x "$found" ]]; then
        SWIFT_FORMAT=("$found")
        return 0
    fi

    if command -v swift >/dev/null 2>&1 && swift format --help >/dev/null 2>&1; then
        SWIFT_FORMAT=(swift format)
        return 0
    fi

    return 1
}

select_swift_format || exit 0

"${SWIFT_FORMAT[@]}" format --in-place --configuration "$CONFIG" "$file_path" 2>/dev/null

# Report anything the formatter cannot fix (line length, naming) back to Claude.
lint_output="$("${SWIFT_FORMAT[@]}" lint --strict --configuration "$CONFIG" "$file_path" 2>&1)"
if [[ -n "$lint_output" ]]; then
    printf 'swift-format lint (--strict) on %s:\n%s\n' "$file_path" "$lint_output" >&2
    exit 2
fi

exit 0
