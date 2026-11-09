Status: Draft v0 (2026-11-09)

# Upstream engine contract

## References versus shipped engine

- Reference clones live outside the repository and are read-only research material. They MUST NOT be edited, vendored implicitly, or used as mutable build inputs.
- A reference clone's current branch or HEAD does not establish the version investigated, pinned, or shipped.
- The shipped engine is selected in [ADR-0003](../decisions/0003-usage-engine.md). Only that pinned engine is a product dependency; other references do not gain runtime or distribution roles by being studied.

## Pinning and adapter isolation

- An engine lock file MUST record the exact version, full commit, and distribution checksum. Its path is TBD after engine spike (ADR-0003).
- Release builds MUST resolve the locked artifact and verify its checksum. Mutable branches, floating tags, and unrecorded local overrides are prohibited.
- The thin adapter is the only product code allowed to know engine-specific output schemas, field meanings, invocation details, and quirks.
- `TokenTakenKit`, the app, and the CLI consume the normalized semantics in [statistics.md](statistics.md); they MUST NOT parse raw engine output independently.
- Engine limitations and unsupported fields MUST surface as explicit adapter states or warnings, never invented values.

## Patches

- Prefer the unmodified pinned engine and adapter-side normalization. Patches to upstream code MUST be avoided unless no conforming adapter solution exists.
- Every unavoidable patch MUST be minimal, reproducible, and recorded with its upstream source link, reason, affected locked version, and licensing impact.
- A patch MUST NOT be presented as upstream behavior during reconciliation; deviations follow the statistics contract.

## Upgrade checklist

- Read the upstream changelog and release notes for the exact old and new versions.
- Diff the engine's input and output schemas, category meanings, model aliases, source coverage, and price behavior.
- Re-run reconciliation on the same sanitized sample set against both the previous and candidate versions; record every deviation and reason.
- Update the adapter and engine lock together, including the new version, full commit, and checksum.
- Update [THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md) for every changed copied component or bundled binary and add a [CHANGELOG.md](../../CHANGELOG.md) entry.
- Do not ship an upgrade with unexplained reconciliation differences or unreviewed license changes.

## Licensing

- Verify the license of each copied source file, bundled binary, and asset independently; repository-level permission does not automatically cover separately licensed assets.
- Include applicable MIT copyright and license notices for copied MIT-licensed code or binaries in `THIRD_PARTY_NOTICES.md` and retain notices required by other licenses.
- TokenTracker's React Bits assets have a separate license and MUST NOT be copied into the product or repository.
- Reference-only code is not automatically approved for copying. Any copied code requires an explicit license review and notice update.

## Open questions

- Engine selection and packaging mechanism: TBD after engine spike (ADR-0003).
- Engine lock-file path and patch-record location: TBD after engine spike (ADR-0003).
