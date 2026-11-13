# ADR-0012: Apple silicon only

## Status

Accepted

## Date

2026-11-13

## Context

- macOS 26 is the last macOS release that runs on Intel Macs. Token Taken targets macOS 26.0, so an Intel build only ever serves the final Intel-only release train.
- The owner does not want to carry Intel-specific code, packaging, or verification work for that single release train.
- A universal build roughly doubles every bundled executable. The pinned tokscale 4.21.0 engine alone is about 41 MB as a universal binary, and the app, `TokenTakenKit.framework`, and `token-taken` each pay the same cost.
- `scripts/fetch-engine.sh` assembled the engine with `lipo -create` from two npm architecture packages, and `ARCHS="arm64 x86_64"` in `scripts/release.sh` built every target twice. `TokscaleCollector.locateExecutable` also ordered its module-search candidates by build architecture.

## Decision

- Token Taken ships for Apple silicon (arm64) only. Debug and Release build `ARCHS=arm64` for the app, `TokenTakenKit.framework`, `token-taken`, and the tests.
- `engine/engine.lock.json` pins only `@tokscale/cli-darwin-arm64`. `scripts/fetch-engine.sh` verifies that archive's SHA-256 and installs its `bin/tokscale` directly, with no `lipo -create` step.
- `scripts/release.sh` fails the release when the app's main binary, `TokenTakenKit`, `token-taken`, or tokscale reports any architecture other than `arm64` (`lipo -archs`), so an Intel slice cannot return unnoticed.
- `TokscaleCollector.locateExecutable` looks only for `@tokscale/cli-darwin-arm64` when falling back to an npm-installed engine.
- The iOS app in `ios/` is unaffected; this decision covers the macOS targets.

## Consequences

- Intel Macs running macOS 26 cannot run the app.
- The DMG is smaller: the bundled engine loses its x86_64 slice, and the app binaries and framework are roughly half their universal size.
- The release check enforces arm64, so reintroducing a second architecture requires changing `project.yml`, the lock file, the fetch script, and this ADR together.
- `THIRD_PARTY_NOTICES.md` describes the bundled component as the unmodified `bin/tokscale` from `@tokscale/cli-darwin-arm64` 4.21.0, and the dependency set as the `aarch64-apple-darwin` build.

## Alternatives rejected

- **Keep universal binaries until macOS 27:** rejected. It keeps the doubled engine and app size for users who, at the current deployment target, are already outside Intel support.
- **Ship x86_64 only through Rosetta on Apple silicon:** rejected. It slows every Apple silicon user and still needs the Intel build.
- **Keep `lipo -create` but build one slice per configuration:** rejected as more moving parts for no benefit; the release check already guarantees arm64.
