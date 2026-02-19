# NuclearDelete

Standalone Windows context-menu utility for permanent delete (no Recycle Bin).

This project exists because very large selections (thousands of files/folders) expose
real Explorer/context-menu edge cases that normal one-liner scripts do not handle well.

## What It Does

- Adds a custom context-menu entry:
  - `Delete to Oblivion` -> `Delete Permanently`
- Supports both:
  - files
  - folders
  - mixed selections
- Uses a guarded launch flow to avoid "clone storms" when Explorer invokes the verb many times.

## Why Multi-Select Is Hard (Important)

When you right-click a large multi-selection, Explorer does not always hand your script one clean list.
Depending on verb/model/context, it may:

- invoke once per selected item
- invoke with partial arguments
- invoke quickly in bursts
- temporarily return incomplete `SelectedItems()` after cancel/retry flows

This is the exact class of issue already seen in `MoveTo.exe` debugging.

## Current `main` Architecture (Reliable Multi-Select)

`main` branch uses a "single active worker + selection re-read" pattern:

1. Explorer calls `NuclearDeleteFolder.vbs` (often many times, one per item).
2. VBS creates a lock file (`worker.lock`) in `%LOCALAPPDATA%\NuclearDelete`.
   - only one VBS call acquires it and launches PowerShell
   - others exit immediately
3. `NuclearDeleteFolder.ps1` starts and also uses a named mutex:
   - `Global\MoveTo_NuclearDelete_Operation`
   - guarantees one active PowerShell worker
4. PowerShell re-reads full Explorer selection via `Shell.Application`:
   - finds the Explorer window by parent folder
   - reads `SelectedItems()`
   - uses tuned retries + stable-hit heuristics (`selectionRetryCount`, `selectionRetryDelayMs`, `selectionStableHits`)
   - trusts first large stable read (`largeSelectionTrustThreshold`) to reduce latency on huge selections
5. If selection cannot be read, fallback is the anchor path (`%1`) so operation still works.
6. Deletes targets with:
   - folder: `Remove-Item -Recurse -Force`
   - file: `Remove-Item -Force`

This design is slower than the absolute-minimal single-call script, but much more stable under large selections.

## Branches

- `main`
  
  - multi-select files+folders
  - lock + mutex + Explorer selection re-read
  - recommended for real usage

- `single`
  
  - minimal single-target mode
  - fastest/simple baseline
  - useful for isolated testing

- `explorer-mode`
  
  - original interactive variant kept for comparison/history
  - useful when you want visible flow and older behavior

## Files

- `NuclearDeleteFolder.reg`
  - context-menu registration (`AllFilesystemObjects`)
  - submenu + placement options
- `NuclearDeleteFolder.vbs`
  - launcher and first synchronization gate (lock file)
- `NuclearDeleteFolder.ps1`
  - core delete engine and selection logic
- `Backup_DialogBenchmark/`
  - previous dialog/benchmark variants kept as reference

## Install / Update

1. Update absolute paths in `.reg` / `.vbs` if your folder location differs.
2. Import registry:

```powershell
reg import "D:\Users\joty79\scripts\NuclearDelete\NuclearDeleteFolder.reg"
```

3. If Explorer caches old menu behavior:

```powershell
Stop-Process -Name explorer -Force
Start-Process explorer.exe
```

## Troubleshooting

### "Nothing happens"

Check:

- `.reg` command points to the correct `NuclearDeleteFolder.vbs` path
- `NuclearDeleteFolder.vbs` points to the correct `NuclearDeleteFolder.ps1` path
- `%LOCALAPPDATA%\MoveTo\NuclearDelete\worker.lock` is not stale

If needed, remove stale lock:

```powershell
Remove-Item "$env:LOCALAPPDATA\NuclearDelete\worker.lock" -ErrorAction SilentlyContinue
```

## DeleteTune (Runtime Tweaks)

`DeleteTune.ps1` controls runtime flags without editing `NuclearDeleteFolder.ps1` directly.

Config file:

```powershell
$env:LOCALAPPDATA\NuclearDelete\DeleteTune.json
```

Run:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "D:\Users\joty79\scripts\NuclearDelete\DeleteTune.ps1"
```

Main options:
- `debug_mode`: enables debug log at `%LOCALAPPDATA%\NuclearDelete\NuclearDelete.debug.log`
- `accelerator_enabled`: enables/disables C# accelerator path
- `accelerator_threshold`: minimum target count before C# accelerator is used
- `selection_retry_count`
- `selection_retry_delay_ms`
- `large_selection_trust_threshold`

### "Only one file deletes in large selection"

This usually means Explorer invocation model mismatch or incomplete selection read.
Use `main` branch behavior (lock + mutex + selection retries), not minimal single mode.

### "High CPU spike"

Some spike is normal during large permanent delete (filesystem + Defender + metadata churn).
If spike stays extreme, compare:

- `main` vs `single`
- same dataset on same drive
- with/without Defender real-time scan (for diagnostics only)

## Reuse Pattern For Future Context-Menu Projects

If a future tool must handle large multi-select reliably, reuse this order:

1. VBS lock gate (`wsh.Run ..., True` on the elected launcher)
2. Process-level named mutex in the core engine
3. Re-read Explorer `SelectedItems()` with retry/hysteresis
4. Fallback anchor path when selection API is empty
5. Keep old variants in separate branches for fast rollback

This pattern is the main lesson from both `MoveTo` and `NuclearDelete` work.
