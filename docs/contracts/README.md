Status: Implemented v1 (2026-11-11)

# Project contracts

- A contract is a set of binding rules that the code MUST satisfy. It outranks code: an implementation that disagrees with an approved contract is incorrect until the contract is deliberately changed.
- Changing a contract requires owner approval. The same change MUST update the contract and add an entry to [CHANGELOG.md](../../CHANGELOG.md); code-only changes MUST NOT silently alter contracted behavior.
- Contracts apply to the `TokenTaken` app, `TokenTakenKit`, the `TokenTakenCLI` target, and the `token-taken` command unless a rule names a narrower scope.

## Index

| File | Scope | Status |
| --- | --- | --- |
| [README.md](README.md) | Contract authority and change process | Implemented v1 |
| [statistics.md](statistics.md) | Usage semantics, identity, time, models, cost, reconciliation | Implemented v1 |
| [cli.md](cli.md) | Command-line behavior, JSON schema, stability, exit codes | Implemented v1 |
| [sync.md](sync.md) | Multi-device storage, sync protocol, merge and deletion rules | Implemented v1 |
| [privacy.md](privacy.md) | Read-only collection, network, credentials, fixtures | Implemented v1 |
| [upstream.md](upstream.md) | Engine pinning, adapter isolation, upgrades, licensing | Implemented v1 |
| [themes.md](themes.md) | Theme tokens, accessibility, visual acceptance | Implemented v1 |
| [mobile-report.md](mobile-report.md) | iPhone report layout, writer and reader rules, privacy, versioning | Accepted |

## Contracts and ADRs

- Architecture decision records (ADRs) record why an approach was chosen, its context, alternatives, and consequences. Contracts record what MUST hold in the product.
- An ADR can motivate a contract, but implementation MUST follow the current contract. When an ADR changes contracted behavior, update both documents and the changelog in the same approved change.
- Current decision context: [native macOS app](../decisions/0001-native-macos-app.md), [iCloud Drive sync](../decisions/0002-icloud-drive-sync.md), [usage engine](../decisions/0003-usage-engine.md), [Developer ID distribution](../decisions/0004-distribution.md), [collection granularity](../decisions/0005-collection-granularity.md), and [incremental collection](../decisions/0006-incremental-collection.md), with the accepted [mobile report](../decisions/0011-mobile-report.md) and [Apple silicon only](../decisions/0012-apple-silicon-only.md).
- Product goals and system structure are described in [product.md](../product.md) and [architecture.md](../architecture.md); neither may quietly redefine these contracts.

## Open questions

- None.
