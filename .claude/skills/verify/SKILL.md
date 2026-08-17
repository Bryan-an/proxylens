---
name: verify
description: Use when verifying a ProxyLens change before claiming it works, before committing, or before pushing — picks the narrowest correct test command for what actually changed instead of running the whole gate or nothing.
disable-model-invocation: true
---

# Verify

Pick the narrowest command that would actually catch a regression in what you changed, run it, and read the output. Verification here spans four different command shapes; the cost between them is a minute versus fifteen.

## Ladder

Run the lowest rung that covers the change. Climb only when the change reaches further.

| What changed | Command |
|---|---|
| One package's sources or tests | `cd Packages/<Package> && swift test --parallel` |
| One case in a package | `cd Packages/<Package> && swift test --filter <testName>` |
| `ProxyLensApp/` or `Tests/ProxyLensIntegrationTests/` | integration target (below) |
| One integration test | `-only-testing:` with the full test path (below) |
| Anything, before pushing | `./scripts/quality.sh full` |

Integration target:

```sh
xcodebuild -project ProxyLens.xcodeproj -scheme ProxyLens -destination 'platform=macOS' \
  -only-testing:ProxyLensIntegrationTests \
  -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO test
```

Single integration test — append the class and method:

```sh
  -only-testing:ProxyLensIntegrationTests/ProxyLensIntegrationTests/testYourTestName
```

`xcodebuild` output is enormous. Filter it, or you will burn context on build logs:

```sh
... test 2>&1 | grep -E "^Test Case|XCTAssert.*failed|error:|\*\* TEST"
```

## Before running

**Added, renamed, or deleted a file under `ProxyLensApp/` or `Tests/`?** Run `xcodegen generate` first and commit the regenerated `ProxyLens.xcodeproj`. The pbxproj lists sources individually; without this the file is invisible to the build and `quality.sh full` fails its sync check.

**Only touched a package?** `swift test` from that package directory does not need the Xcode project at all — prefer it.

## Rules

- A test you did not watch fail before the fix proves nothing about the fix. For a bug, write the failing assertion first.
- Report what the command printed. "Tests pass" without having read the output is a guess.
- If the test target does not compile, say so and name the symbols — do not report the subset that did run as if it were the suite.
- Never claim the full gate passed unless you ran `./scripts/quality.sh full` (worktree lint, XcodeGen sync, all five package suites, app build, integration tests) to completion.

## Gate modes

| Command | Runs |
|---|---|
| `./scripts/quality.sh staged` | staged whitespace + staged `swift-format lint --strict` (the `pre-commit` hook) |
| `./scripts/quality.sh full` | worktree lint, XcodeGen sync, all package tests, app build + integration tests (the `pre-push` hook) |
| `./scripts/quality.sh ci` | same as full, with committed-whitespace checking — what GitHub Actions runs |
| `./scripts/quality.sh ui` | `ProxyLensUITests` only; not part of the default gate |

CI is `workflow_dispatch:` only — nothing runs automatically on push or PR. The local gate is the real gate.
