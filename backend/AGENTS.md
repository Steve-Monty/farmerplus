# Backend and Administration

The FastAPI API and administration project. Source composition: app.py. Python runtime: .venv/Scripts/python.exe. Tests: .venv/Scripts/python.exe -m pytest tests -q. Local configuration is .env; do not print secrets.

## Project locations and working from any folder

- Farmer PWA: `C:/Farmer PWA`
- Backend / Administration: `C:/Farmer Backend`
- Integration / Shared Contracts: `C:/Farmer Integration`
- Independent eLearning: `C:/e-learning`
- Original Android reference: `C:/Farmer App`

A Codex task can start in any of these folders. Determine the owning project from the requested behavior; use an explicit working directory for each command. Do not recreate projects as subfolders of Farmer App. Read the destination project's AGENTS.md before cross-project edits.

For an API, authentication, sync, identifier, event or learning-interface change: identify consumers in all three applications, update the contract in Integration, change affected consumers, and run the compatibility tests from Integration. Its docs/feature-inventory.md and docs/dependency-matrix.md describe feature ownership and current interface evidence. A passing local test does not prove production deployment, physical-device GPS quality, or live OAuth sign-in.

## CodeGraph first

Where `.codegraph/` exists, use CodeGraph before text search or file reads to understand/locate code. Prefer the available `codegraph_explore` MCP tool. CLI fallback on this machine:

```powershell
& 'C:/Users/SteveMonty/AppData/Local/codegraph/current/bin/codegraph.cmd' explore 'concrete file or symbol and the question'
```

Run from the owning project root. Each index has its own scope. Query affected projects again after restructuring; shared-contract tests, not a single graph, check cross-project compatibility. If an unindexed project is encountered, do not silently index it without user authorization.

## Current product and environment decisions

- This is a test architecture using fresh email-based accounts and clean local databases; no old test data migration is required.
- Weather is OFF on a fresh installation. When disabled, hide weather and do not request location or network data for weather. Farm mapping location remains independent.
- Offline farm/field edits, walking-boundary drafts and queued changes must survive restart/reconnection. Downloaded content stays until explicit removal, subject to browser storage clearing/eviction. Clearly distinguish offline outlines from offline basemaps.
- Show GPS accuracy, reject invalid/stale/poor fixes and unsafe geometry, and explain foreground/browser suspension limits. Never claim survey-grade accuracy.
- Never put SMTP/OAuth secrets in browser code, logs, docs or commits. Backend .env is local and ignored. Test authentication mail goes to the configured test recipient while the account retains its intended email. Production must reject test mail override.
- Do not publish/deploy public services without explicit authorization. Local loopback previews and checks are authorized by a build request.
- Do not use the Impeccable skill for this work.

## Local previews

From `C:/Farmer PWA`, `npm run build` then `npm run dev` starts PWA `http://127.0.0.1:5173`, administration `http://127.0.0.1:8088/admin`, and API `http://127.0.0.1:8088`. The backend uses its own `.local-development` database. Keep the exact host consistent; localhost and 127.0.0.1 have separate browser storage.

From any project, invoke the same commands with an explicit `Set-Location`/tool workdir. Backend tests use its `.venv`; integration tests use `npm test` in Integration. Read PWA docs/LOCAL-DEVELOPMENT.md and the owning project README for setup and current limitations.

## Starting Codex here

Open this folder as a Codex project and start a task, or run `codex` in a terminal whose current directory is this folder. From another directory, use `codex -C "C:\Farmer PWA" "your prompt"` (substitute the desired project path).

For a CLI task that needs to edit sibling projects under workspace-write permissions, explicitly add only the affected roots with `--add-dir`, for example:

```powershell
codex -C 'C:\Farmer PWA' --add-dir 'C:\Farmer Backend' --add-dir 'C:\Farmer Integration' 'Implement this change and verify the affected contracts'
```

Do not disable sandboxing to work across projects. Read each affected root's AGENTS.md and run commands in its own working directory. When using `codex exec` in these non-Git development folders, the CLI requires `--skip-git-repo-check` unless a repository has subsequently been initialized.
