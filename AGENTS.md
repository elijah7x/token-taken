# AGENTS.md: Token Taken agent workflow

## Source and public safety

- Treat the repository as public. Keep personal absolute paths, machine details, credentials, private reports, and raw usage data out of Git.
- Write repository documentation in English, except `README.zh-CN.md`. Localize app strings in English and Simplified Chinese with a String Catalog.
- Keep maintained source, release assets, contracts, and durable decisions in Git. Keep process artifacts outside the source tree; `.gitignore` is not an artifact filing system.
- `docs/product.md`, `docs/architecture.md`, `docs/decisions/`, and `docs/contracts/` record the engineering source of truth. Update the relevant contract when behavior changes and record consequential choices in an ADR.

## Worktrees

- Keep one long-lived checkout on `main`. Do not code in that checkout after the initial bootstrap; every coding task needs its own worktree.
- Create each task worktree under `token-taken-worktrees/<task>` in the artifact root, based on `main` or an explicitly agreed base.
- Keep unfinished work. Do not delete or reset another task's worktree. Ask before discarding a completed worktree.
- Generate the Xcode project from `project.yml` with XcodeGen. Do not hand-edit generated project files.

## Artifact root

- Resolve the physical Git common-dir to find the long-lived checkout. The checkout's parent is the default artifact root. Never derive shared storage from a task worktree's parent.
- `TOKEN_TAKEN_ARTIFACTS_ROOT` may override the artifact root with an absolute path outside the source tree.
- Use these folders in the artifact root:
  - `design-archive/`: design explorations, rejected candidates, and selection evidence.
  - `promo/`: promotional media and its source projects.
  - `private-artifacts/`: private reports, captures, reconciliation evidence, and release evidence. Keep raw usage samples in `private-artifacts/samples/`.
  - `local-packages/`: locally built packages.
  - `fork/`: read-only upstream reference clones. Do not modify, build, install dependencies for, or push them.
  - `token-taken-worktrees/`: task worktrees.
- Raw samples stay outside Git. Commit only synthetic or sanitized fixtures that contain no personal data or machine details.

## Project boundaries

- `TokenTakenKit` contains shared models, store, sync, and contracts. It depends on nothing in the app target.
- `TokenTaken` contains the main window and menu bar extra. `TokenTakenCLI` builds the `token-taken` tool. Both depend on `TokenTakenKit`; the CLI never depends on app UI.
- Use native SwiftUI Liquid Glass APIs on macOS 26 and later. Do not substitute web or CSS imitations.
- Pin the selected usage engine and keep its adapter thin. Engine selection remains open in `docs/decisions/0003-usage-engine.md`; do not claim accuracy or coverage before the reconciliation spike verifies it.
- Read agent logs read-only. Sync is opt-in, aggregate-only, and contains no prompts, responses, paths, project names, credentials, or cost. Costs are estimates from a versioned price table.
