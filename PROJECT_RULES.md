# PROJECT_RULES.md (MoveTo)

## Scope
- This file stores MoveTo-specific decisions, guardrails, and critical lessons.
- Keep entries concise and actionable.

## Non-Negotiable Rules
- For registry paths that include `*`, use `Registry::HKEY_CURRENT_USER\...` (not `HKCU:\...`).
- Do not run `Test-Path` or `Get-ChildItem` on `HKCU:\...*\...` paths.
- For dynamic context-menu destinations, use nested shell keys (`shell\dest_*`), not empty `SubCommands=""`.
- Keep `SyncMoveToMenu.ps1` as the source-of-truth sync step between `destinations\*.lnk` and registry entries.
- For RoboCopy engine, use adaptive `/MT` tuning by source/destination media path; do not hardcode one value globally.

## Current Stability Policy
- Treat the native engine (`MoveTo.vbs` + `MoveTo.exe`) as stable and high-risk to modify.
- Prefer side-by-side experiments (for example, RoboCopy-based flow) instead of replacing the native path directly.

## Decision Log
### 2026-02-11 - Adaptive RoboCopy thread rule
- Problem: Fixed `/MT:32` is fast on NVMe but can underperform on HDD or same-drive copies.
- Root cause: Storage bottlenecks vary by media type and path topology.
- Guardrail: Choose `/MT` adaptively (`8` for HDD/network/same-physical-disk, `32` for SSD->SSD, `16` fallback).
- Files affected: `Robocopy/rcp.ps1`, `Robocopy/README.md`.
- Validation/tests: Use `__mtprobe` mode with representative source/destination paths.

### 2026-02-11 - RoboCopy benchmark and tuning controls
- Problem: Needed real-time speed visibility and manual MT tuning per partition route.
- Root cause: Performance depends on source/destination topology and workload shape.
- Guardrail: Use explicit `benchmark_mode` toggle; when ON keep paste window open with hotkey to `RoboTune.ps1`, when OFF close normally.
- Files affected: `Robocopy/rcp.ps1`, `Robocopy/RoboTune.ps1`, `Robocopy/README.md`.
- Validation/tests: Parse check + `__mtprobe` + interactive config load.

### 2026-02-10 - Registry wildcard path fix
- Problem: Context menu scripts could hang/fail when using registry paths with `*` under `HKCU:\`.
- Root cause: `*` interpreted as wildcard by PowerShell provider.
- Guardrail: Always use `Registry::HKEY_CURRENT_USER\...` for these paths.
- Files affected historically: `SyncMoveToMenu.ps1`, `MoveTo.reg`, `AddMoveToDestination.ps1`.

### 2026-02-11 - Conda shell initialization note
- Problem: `conda` command may be unavailable in some PowerShell sessions.
- Root cause: Shell PATH/profile may not load Conda shims in every terminal context.
- Guardrail: Use `E:\Compilers\miniconda\condabin\conda.bat` when plain `conda` is not recognized.
- Files affected: `AGENTS.md` (environment note).
- Validation/tests: `conda env list` succeeded via explicit `conda.bat` path.

### 2026-02-11 - RoboDelete baseline strategy
- Problem: Need fast permanent-delete tests for large folder workloads.
- Root cause: Explorer + Recycle Bin path is too slow for high file-count delete scenarios.
- Guardrail: Keep imported `robodelete.bat` as reference, and use `robodelete_fast.bat` as baseline test runner with summary/log.
- Files affected: `Robocopy/robodelete_fast.bat`, `Robocopy/README.md`.
- Validation/tests: Batch parse/read verification in workspace.

### 2026-02-11 - RoboDelete folder context menu
- Problem: Need one-click folder test entry from Explorer for permanent delete speed checks.
- Root cause: Manual drag/drop batch flow is slower to trigger repeatedly during benchmarks.
- Guardrail: Use folder-only context menu entry pointing to `robodelete_fast.bat` via VBS wrapper.
- Files affected: `Robocopy/RoboDelete_Folder.vbs`, `Robocopy/RoboDelete_Folder.reg`, `Robocopy/README.md`.
- Validation/tests: VBS syntax check (`cscript //nologo`) + file content verification.

### 2026-02-11 - RoboDelete MT and speed profile
- Problem: Needed explicit robocopy multi-thread tuning for delete benchmarks.
- Root cause: Baseline batch lacked `/MT` control.
- Guardrail: Default `robodelete_fast.bat` folder profile uses `/MT:64` plus `/R:0 /W:0 /NFL /NDL /NJH /NJS /NP /XJ`; allow override via `ROBODELETE_MT`.
- Files affected: `Robocopy/robodelete_fast.bat`, `Robocopy/README.md`.
- Validation/tests: Local temp-folder run with `ROBODELETE_MT=64` and summary/log verification.

### 2026-02-11 - RoboDelete low-overhead testing mode
- Problem: Benchmark view/progress output can distort delete-speed measurements.
- Root cause: Console progress rendering (`/ETA` and verbose output) adds non-trivial overhead in some workloads.
- Guardrail: Add `ROBODELETE_TEST` mode; default `1` sets silent fast profile + hold window for summary, with elapsed time as primary metric and minimal summary fields.
- Files affected: `Robocopy/robodelete_fast.bat`, `Robocopy/README.md`.
- Validation/tests: Batch parse/flow verification and config echo/log field checks for `TEST/VISUAL/HOLD`.

### 2026-02-11 - Nuclear delete hold-on-exit for testing
- Problem: Nuclear delete window could close too quickly after completion during benchmark checks.
- Root cause: Script exited immediately after success/cancel/not-found paths.
- Guardrail: Keep console open on all outcomes until key press, so elapsed/result is always visible.
- Files affected: `NuclearDelete/NuclearDeleteFolder.ps1`.
- Validation/tests: Script flow review for success/cancel/error branches using common `Wait-AndExit`.

### 2026-02-11 - Deletion strategy simplified (Nuclear only)
- Problem: RoboDelete (`robocopy /MIR` delete flow) was significantly slower than direct Nuclear delete in real tests.
- Root cause: Mirror/delete workflow requires extra enumeration and comparison overhead.
- Guardrail: Keep only `NuclearDelete` for permanent folder delete workflows; deprecate/remove RoboDelete scripts and menu entries.
- Files affected: `Robocopy/README.md`, `Robocopy/robodelete_fast.bat` (removed), `Robocopy/robodelete.bat` (removed), `Robocopy/RoboDelete_Folder.vbs` (removed), `Robocopy/RoboDelete_Folder.reg` (removed), `NuclearDelete/Remove_RoboDelete_ContextMenu.reg` (new).
- Validation/tests: Workspace file cleanup verification + grep for remaining RoboDelete references in active docs.

### 2026-02-11 - Nuclear delete menu placement for muscle memory
- Problem: Direct one-click delete entry risks misclick and should be near built-in Delete position.
- Root cause: Flat custom menu items are easier to trigger accidentally and can appear far from native delete block.
- Guardrail: Use submenu pattern `Delete to Oblivion -> Delete Permanently` with `Position=Bottom` and `SeparatorBefore` on `Directory\shell`.
- Files affected: `NuclearDelete/NuclearDeleteFolder.reg`.
- Validation/tests: Registry structure review (`shell\run`) + key ordering key-name prefix (`z_10_`).

### 2026-02-11 - Reliable cascade menu wiring for Explorer
- Problem: Parent menu appeared but did not open submenu; click produced app-association error.
- Root cause: Nested `shell` cascade under the parent key was not being resolved reliably by Explorer in this setup.
- Guardrail: Use `ExtendedSubCommandsKey` on parent menu and define actions under `HKCU\Software\Classes\Directory\ContextMenus\...`.
- Files affected: `NuclearDelete/NuclearDeleteFolder.reg`.
- Validation/tests: Registry content review for `ExtendedSubCommandsKey` and `ContextMenus\...\shell\run\command`.

### 2026-02-11 - Nuclear production mode (silent minimal) + backup variant
- Problem: Interactive prompts/timing/logging add friction for day-to-day delete workflow.
- Root cause: Existing Nuclear script still contained benchmark and confirmation UI logic.
- Guardrail: Keep active `NuclearDelete` path minimal and silent (no prompt, no elapsed/log output); store interactive/benchmark variant in dedicated backup folder.
- Files affected: `NuclearDelete/NuclearDeleteFolder.ps1`, `NuclearDelete/NuclearDeleteFolder.vbs`, `NuclearDelete/Backup_DialogBenchmark/NuclearDeleteFolder.interactive.ps1`, `NuclearDelete/Backup_DialogBenchmark/NuclearDeleteFolder.visible.vbs`, `NuclearDelete/Backup_DialogBenchmark/NuclearDeleteFolder.menu.reg`, `NuclearDelete/Backup_DialogBenchmark/README.md`.
- Validation/tests: PowerShell parse check for active script + VBS launch mode review (`shell.Run ... , 0, False`).

### 2026-02-11 - Nuclear launcher set visible for multi-select validation
- Problem: Need to confirm runtime behavior (single vs multiple `pwsh` instances) during multi-select delete tests.
- Root cause: Hidden launcher made process behavior hard to observe.
- Guardrail: Use visible VBS launch mode (`shell.Run ... , 1, False`) while validating behavior.
- Files affected: `NuclearDelete/NuclearDeleteFolder.vbs`.
- Validation/tests: VBS syntax check via `cscript //nologo`.

### 2026-02-11 - Nuclear multi-select invocation fix
- Problem: Selecting many folders triggered multiple PowerShell windows/processes.
- Root cause: Command used single-target `%1`, so Explorer invoked the verb per item.
- Guardrail: Use `%*` with `MultiSelectModel=Player`; make launcher/script accept multiple paths in one run.
- Files affected: `NuclearDelete/NuclearDeleteFolder.reg`, `NuclearDelete/NuclearDeleteFolder.vbs`, `NuclearDelete/NuclearDeleteFolder.ps1`.
- Validation/tests: PowerShell parse check + VBS syntax check + registry content review (`%*`, `MultiSelectModel`).

### 2026-02-11 - Nuclear queue/worker model for true single-process multi-select
- Problem: `%*` cascade invocation proved unreliable and produced no action in Explorer.
- Root cause: Explorer argument expansion behavior for this submenu path was inconsistent.
- Guardrail: Use per-item enqueue (`%1`) with hidden launcher and a mutex-protected queue; spawn one visible worker process to drain queue and delete all targets in one run.
- Files affected: `NuclearDelete/NuclearDeleteFolder.ps1`, `NuclearDelete/NuclearDeleteFolder.vbs`, `NuclearDelete/NuclearDeleteFolder.reg`.
- Validation/tests: PowerShell parse check + VBS syntax check + registry command review (`"%1"` enqueue path).

### 2026-02-11 - Nuclear worker race hardening
- Problem: Multi-select could still spawn multiple visible workers in fast successive invokes.
- Root cause: Queue worker lifetime/settle timing could end before all Explorer invokes had enqueued.
- Guardrail: Add dedicated worker mutex singleton and increase queue settle window before each batch run.
- Files affected: `NuclearDelete/NuclearDeleteFolder.ps1`.
- Validation/tests: PowerShell parse check + source check for singleton lock (`workerMutexName`) and settle loop (`idleRounds -lt 12`).

### 2026-02-11 - Nuclear startup race fix (PID-first worker detection)
- Problem: Multiple workers still appeared when several enqueue calls happened during worker startup.
- Root cause: Worker-running check preferred mutex state; before worker acquired mutex, next enqueue could start another worker.
- Guardrail: In worker detection, check live PID file/process first, then fallback to mutex check; keep settle window moderate (`idleRounds -lt 6`) to reduce close delay.
- Files affected: `NuclearDelete/NuclearDeleteFolder.ps1`.
- Validation/tests: PowerShell parse check + source check for PID-first `Test-WorkerRunning` and updated settle loop.

### 2026-02-11 - Nuclear in-process worker election (no spawned worker windows)
- Problem: Spawning a separate worker process from each enqueue path still caused multiple visible windows under multi-select.
- Root cause: Explorer invokes per item, and startup races around spawned workers were hard to eliminate completely.
- Guardrail: Remove spawned worker startup; each enqueue appends to queue, and exactly one enqueue process becomes worker via mutex (`WaitOne(0)`) and drains the queue in-process.
- Files affected: `NuclearDelete/NuclearDeleteFolder.ps1`.
- Validation/tests: PowerShell parse check + local 3-target concurrent invoke test (`Remaining=0`).

### 2026-02-11 - Nuclear mixed selection support (files + folders)
- Problem: Delete action needed to support mixed file/folder selections, not only folder paths.
- Root cause: Batch delete logic treated all targets as containers.
- Guardrail: Handle both path types: `Container` with `-Recurse -Force`, `Leaf` with `-Force`; register menu under `AllFilesystemObjects` for broad selection coverage.
- Files affected: `NuclearDelete/NuclearDeleteFolder.ps1`, `NuclearDelete/NuclearDeleteFolder.reg`.
- Validation/tests: PowerShell parse check + registry content review (`AllFilesystemObjects` keys and command path).

### 2026-02-11 - Explorer multi-select behavior for files (Document model)
- Problem: In large file-only selections, action could run for only one item.
- Root cause: Verb under `AllFilesystemObjects` without explicit multi-select model may default to single-item behavior.
- Guardrail: Set `MultiSelectModel=Document` on the run verb and keep queue/worker aggregation in script.
- Files affected: `NuclearDelete/NuclearDeleteFolder.reg`.
- Validation/tests: Registry review of `MultiSelectModel` and follow-up user test on large file-only selection.

### 2026-02-11 - Nuclear VBS-first synchronization to reduce CPU clone storms
- Problem: Per-item multi-select invocations still caused high CPU spikes due to many short-lived PowerShell enqueue processes.
- Root cause: Enqueue logic lived in PowerShell, so each selected item spawned another `pwsh` instance.
- Guardrail: Move enqueue + lock election to VBS; use one lock file worker (`worker.lock`), synchronous worker run, and stale lock cleanup (5 minutes).
- Files affected: `NuclearDelete/NuclearDeleteFolder.vbs`, `NuclearDelete/NuclearDeleteFolder.ps1`.
- Validation/tests: PowerShell parse check + VBS syntax run; registry command remains VBS `%1`.

### 2026-02-11 - Pending-file queue to remove enqueue lock contention
- Problem: Burst multi-select still produced heavy CPU spikes due to contention on one shared queue file.
- Root cause: Many parallel VBS invokes attempted repeated append/open retries against `queue.txt`.
- Guardrail: Replace single shared queue file with per-invoke pending files (`pending\*.txt`); worker atomically moves pending files into per-batch folder for processing.
- Files affected: `NuclearDelete/NuclearDeleteFolder.vbs`, `NuclearDelete/NuclearDeleteFolder.ps1`.
- Validation/tests: PowerShell parse check + VBS syntax run.

### 2026-02-11 - Recovery from legacy queue state + COM-safe enqueue filename
- Problem: Delete action could appear to do nothing due to incompatible leftover queue files and COM dependency in VBS filename generation.
- Root cause: Worker only read `*.txt` while old pending files had no extension; VBS used `Scriptlet.TypeLib` which may be blocked on some systems.
- Guardrail: Worker reads all pending files plus legacy `queue.txt`; VBS uses `FileSystemObject.GetTempName` for pending filenames (no Scriptlet COM dependency).
- Files affected: `NuclearDelete/NuclearDeleteFolder.ps1`, `NuclearDelete/NuclearDeleteFolder.vbs`.
- Validation/tests: PowerShell parse check + probe delete via VBS (`probe_deleted`) + state folder verification.

### 2026-02-11 - Adopt MoveTo-style single-instance selection model for NuclearDelete
- Problem: Queue-based multi-select handling remained fragile under large selections and could degenerate to single-item behavior.
- Root cause: Explorer per-item invocation timing plus queue/lock choreography created edge cases and overhead.
- Guardrail: Follow `MoveTo.cs` pattern: VBS lock allows one worker launch, PowerShell uses named mutex (`Global\MoveTo_NuclearDelete_Operation`), reads full Explorer selection from the parent folder with retries, and falls back to anchor path.
- Files affected: `NuclearDelete/NuclearDeleteFolder.ps1`, `NuclearDelete/NuclearDeleteFolder.vbs`.
- Validation/tests: PowerShell parse check + direct delete test (`direct_deleted`) + VBS launch probe (`pwsh_started`, `file_deleted`).

## Entry Template
### YYYY-MM-DD - Short decision title
- Problem:
- Root cause:
- Guardrail/rule:
- Files affected:
- Validation/tests:
