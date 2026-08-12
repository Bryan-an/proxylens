#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FORMAT_CONFIG="$REPO_ROOT/.swift-format"

PACKAGE_PATHS=(
    "Packages/ProxyLensCore"
    "Packages/ProxyLensApplication"
    "Packages/ProxyLensCapture"
    "Packages/ProxyLensPersistence"
    "Packages/ProxyLensPlatform"
)

SWIFT_FORMAT_COMMAND=()

usage() {
    cat <<'EOF'
Usage: scripts/quality.sh <mode>

Modes:
  staged       Check staged whitespace and staged Swift files.
  full         Check the worktree, project generation, packages, and app tests.
  ci           Like full, but check committed whitespace instead of the worktree.
  format       Format all Swift source files in place.
  ui           Run the macOS UI test target explicitly.
EOF
}

fail() {
    printf 'quality: error: %s\n' "$*" >&2
    exit 1
}

step() {
    printf '\n==> %s\n' "$*"
}

select_swift_format() {
    if ((${#SWIFT_FORMAT_COMMAND[@]} > 0)); then
        return
    fi

    if command -v swift-format >/dev/null 2>&1; then
        SWIFT_FORMAT_COMMAND=(swift-format)
    elif command -v xcrun >/dev/null 2>&1; then
        local swift_format_path
        swift_format_path="$(xcrun --find swift-format 2>/dev/null || true)"
        if [[ -n "$swift_format_path" && -x "$swift_format_path" ]]; then
            SWIFT_FORMAT_COMMAND=("$swift_format_path")
        fi
    fi

    if ((${#SWIFT_FORMAT_COMMAND[@]} == 0)) && command -v swift >/dev/null 2>&1; then
        if swift format --help >/dev/null 2>&1; then
            SWIFT_FORMAT_COMMAND=(swift format)
        fi
    fi

    ((${#SWIFT_FORMAT_COMMAND[@]} > 0)) || fail "swift-format is unavailable; install/select an Xcode Swift 6 toolchain"
    [[ -f "$FORMAT_CONFIG" ]] || fail "missing formatter configuration: $FORMAT_CONFIG"
}

check_staged_whitespace() {
    step "Checking staged whitespace"
    git diff --cached --check
}

check_worktree_whitespace() {
    step "Checking worktree whitespace"
    git diff --check HEAD
}

check_ci_whitespace() {
    step "Checking committed whitespace"
    git diff-tree --check --no-commit-id -r HEAD
}

lint_staged_swift() {
    select_swift_format

    local file
    local found_swift=0
    local failed=0

    while IFS= read -r -d '' file; do
        found_swift=1
        printf 'Checking %s\n' "$file"

        if ! git show ":$file" | "${SWIFT_FORMAT_COMMAND[@]}" lint \
            --strict \
            --configuration "$FORMAT_CONFIG" \
            --assume-filename "$file" \
            -; then
            failed=1
        fi
    done < <(git diff --cached --name-only -z --diff-filter=ACMR -- '*.swift')

    if ((found_swift == 0)); then
        printf 'No staged Swift files to lint.\n'
    fi

    ((failed == 0)) || fail "staged Swift formatting/lint checks failed"
}

lint_all_swift() {
    select_swift_format

    step "Linting all Swift sources"
    "${SWIFT_FORMAT_COMMAND[@]}" lint \
        --strict \
        --parallel \
        --configuration "$FORMAT_CONFIG" \
        --recursive \
        ProxyLensApp Packages Tests
}

format_all_swift() {
    select_swift_format

    step "Formatting all Swift sources"
    "${SWIFT_FORMAT_COMMAND[@]}" format \
        --in-place \
        --configuration "$FORMAT_CONFIG" \
        --recursive \
        ProxyLensApp Packages Tests
}

run_package_tests() {
    command -v swift >/dev/null 2>&1 || fail "Swift is unavailable"

    local package_path
    for package_path in "${PACKAGE_PATHS[@]}"; do
        step "Testing $package_path"
        (
            cd "$REPO_ROOT/$package_path"
            swift test --parallel
        )
    done
}

run_app_tests() {
    command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild is unavailable"

    step "Building the ProxyLens Xcode scheme"
    xcodebuild \
        -project "$REPO_ROOT/ProxyLens.xcodeproj" \
        -scheme ProxyLens \
        -configuration Debug \
        -sdk macosx \
        -derivedDataPath "$REPO_ROOT/.build/DerivedData" \
        CODE_SIGNING_ALLOWED=NO \
        build

    step "Testing the ProxyLens integration test target"
    xcodebuild \
        -project "$REPO_ROOT/ProxyLens.xcodeproj" \
        -scheme ProxyLens \
        -destination 'platform=macOS' \
        -only-testing:ProxyLensIntegrationTests \
        -derivedDataPath "$REPO_ROOT/.build/DerivedData" \
        CODE_SIGNING_ALLOWED=NO \
        test
}

run_ui_tests() {
    command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild is unavailable"

    step "Testing the ProxyLens UI test target"
    xcodebuild \
        -project "$REPO_ROOT/ProxyLens.xcodeproj" \
        -scheme ProxyLens \
        -destination 'platform=macOS' \
        -only-testing:ProxyLensUITests \
        -derivedDataPath "$REPO_ROOT/.build/DerivedDataUI" \
        CODE_SIGNING_ALLOWED=YES \
        CODE_SIGN_IDENTITY=- \
        test
}

check_xcodegen_sync() {
    command -v xcodegen >/dev/null 2>&1 || fail "xcodegen is unavailable; install XcodeGen before running full quality checks"

    local temporary_directory
    temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/proxylens-xcodegen.XXXXXX")"

    step "Checking generated Xcode project synchronization"
    cp "$REPO_ROOT/project.yml" "$temporary_directory/project.yml"
    cp -R "$REPO_ROOT/ProxyLensApp" "$temporary_directory/ProxyLensApp"
    cp -R "$REPO_ROOT/Tests" "$temporary_directory/Tests"
    mkdir -p "$temporary_directory/Packages"

    local package_path
    local package_name
    for package_path in "${PACKAGE_PATHS[@]}"; do
        package_name="${package_path##*/}"
        mkdir -p "$temporary_directory/Packages/$package_name"
        cp "$REPO_ROOT/$package_path/Package.swift" "$temporary_directory/Packages/$package_name/Package.swift"
    done

    if ! (
        cd "$temporary_directory"
        xcodegen generate --quiet
    ); then
        rm -rf -- "$temporary_directory"
        fail "XcodeGen could not regenerate the project"
    fi

    if ! diff -ruN \
        --exclude=.DS_Store \
        --exclude=xcuserdata \
        --exclude=swiftpm \
        --exclude='*.xcuserstate' \
        "$REPO_ROOT/ProxyLens.xcodeproj" \
        "$temporary_directory/ProxyLens.xcodeproj"; then
        rm -rf -- "$temporary_directory"
        fail "ProxyLens.xcodeproj is out of sync with project.yml"
    fi

    rm -rf -- "$temporary_directory"
    printf 'Generated Xcode project is synchronized.\n'
}

run_staged_checks() {
    check_staged_whitespace
    lint_staged_swift
}

run_full_checks() {
    check_worktree_whitespace
    lint_all_swift
    check_xcodegen_sync
    run_package_tests
    run_app_tests
}

run_ci_checks() {
    check_ci_whitespace
    lint_all_swift
    check_xcodegen_sync
    run_package_tests
    run_app_tests
}

cd "$REPO_ROOT"

case "${1:-}" in
    staged)
        run_staged_checks
        ;;
    full)
        run_full_checks
        ;;
    ci)
        run_ci_checks
        ;;
    format)
        format_all_swift
        ;;
    ui)
        run_ui_tests
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
