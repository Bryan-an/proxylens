# Development quality workflow

ProxyLens uses native Git hooks backed by one repository-owned quality script. The hooks provide fast local feedback; GitHub Actions is the authoritative check before changes are merged.

## Initial setup

Run this once after cloning the repository:

```sh
./scripts/setup-hooks.sh
```

The script configures the local repository with:

```sh
git config --local core.hooksPath .githooks
```

The `core.hooksPath` setting belongs to the local clone and is not transferred through Git. Run the setup script again if the repository is cloned into a new directory.

## Quality commands

```sh
# Fast staged-content checks; normally run by pre-commit.
./scripts/quality.sh staged

# Full local checks; normally run by pre-push.
./scripts/quality.sh full

# Reproduce the GitHub Actions quality job.
./scripts/quality.sh ci

# Format Swift sources explicitly when needed.
./scripts/quality.sh format

# Run the macOS UI test target explicitly.
./scripts/quality.sh ui

# Build a Release zip under dist/ (ad-hoc signed by default).
./scripts/package.sh
```

Release packaging, Hardened Runtime, and notarization are documented in [DISTRIBUTION.md](DISTRIBUTION.md). A paid Apple Developer Program membership is required before `./scripts/notarize.sh` can succeed.

## HTTPS capture

HTTPS interception needs the local CA trusted in the user domain. In the app, open **Trust HTTPS Certificate…**, then **Install and Trust**, and enter the login password when macOS asks.

Verify from a terminal after capture is running:

```sh
curl -x http://127.0.0.1:9090 https://example.com/
```

`curl` uses the system trust store on macOS. If the CA is trusted, the request succeeds and the flow appears in the console. **Remove Trust** in the same sheet reverses the change.

The formatter configuration is stored in `.swift-format`. The project uses the Swift formatter from the active Xcode toolchain through `swift-format`, `xcrun`, or `swift format`.

## Hook responsibilities

- `pre-commit` checks staged whitespace and staged Swift source only. It does not rewrite files or run the full test suite.
- `pre-push` checks the worktree, validates XcodeGen output in a temporary directory, runs every local Swift package test target, and runs the app build plus integration tests.
- `.github/workflows/quality.yml` runs the CI mode on pushes, pull requests, and merge-queue groups.

The UI test target is available through `./scripts/quality.sh ui` but is not part of the default hook gate while the scaffold contains only a placeholder UI test. Add it to CI once the native traffic-console UI has meaningful coverage and the runner environment is stable.

The GitHub `main` branch should require the `Quality` status check after the repository is created. Local hooks can be bypassed, so branch protection and CI remain the merge gate.
