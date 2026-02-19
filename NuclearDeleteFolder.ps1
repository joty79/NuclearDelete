param(
    [Parameter(Mandatory = $true)]
    [string]$AnchorPath
)

$mutexName = "Global\MoveTo_NuclearDelete_Operation"
$stateRoot = Join-Path $env:LOCALAPPDATA "NuclearDeleteContext"
$configPath = Join-Path $stateRoot "DeleteTune.json"
$debugLogPath = Join-Path $stateRoot "NuclearDelete.debug.log"

$defaultTune = [ordered]@{
    debug_mode                       = $false
    accelerator_enabled              = $true
    accelerator_threshold            = 2000
    selection_retry_count            = 10
    selection_retry_delay_ms         = 45
    large_selection_trust_threshold  = 1000
    strategy_move_first              = $false
}

function Get-PropertyValue {
    param(
        [Parameter(Mandatory = $false)]
        $Object,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Get-BoolSetting {
    param(
        [Parameter(Mandatory = $false)]
        $Value,
        [Parameter(Mandatory = $true)]
        [bool]$Default
    )

    if ($null -eq $Value) { return $Default }
    if ($Value -is [bool]) { return [bool]$Value }

    if ($Value -is [string]) {
        $normalized = $Value.Trim().ToLowerInvariant()
        if ($normalized -in @("1", "true", "yes", "on")) { return $true }
        if ($normalized -in @("0", "false", "no", "off")) { return $false }
    }

    return $Default
}

function Get-IntSetting {
    param(
        [Parameter(Mandatory = $false)]
        $Value,
        [Parameter(Mandatory = $true)]
        [int]$Default,
        [Parameter(Mandatory = $true)]
        [int]$Min,
        [Parameter(Mandatory = $true)]
        [int]$Max
    )

    $parsed = $Default
    try {
        if ($null -ne $Value) {
            $parsed = [int]$Value
        }
    }
    catch {
        $parsed = $Default
    }

    if ($parsed -lt $Min) { $parsed = $Min }
    if ($parsed -gt $Max) { $parsed = $Max }
    return $parsed
}

function Save-TuneConfig {
    param([hashtable]$Config)

    try {
        $Config | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $configPath -Encoding UTF8
    }
    catch { }
}

function Ensure-TuneConfig {
    if (-not (Test-Path -LiteralPath $stateRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    }

    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        $repoTunePath = Join-Path $PSScriptRoot "DeleteTune.json"
        if (Test-Path -LiteralPath $repoTunePath -PathType Leaf) {
            try {
                Copy-Item -LiteralPath $repoTunePath -Destination $configPath -Force
            }
            catch {
                Save-TuneConfig -Config $defaultTune
            }
        }
        else {
            Save-TuneConfig -Config $defaultTune
        }
    }

    $rawConfig = $null
    try {
        $rawConfig = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        $rawConfig = $null
    }

    $resolved = [ordered]@{}
    $resolved.debug_mode = Get-BoolSetting (Get-PropertyValue -Object $rawConfig -Name "debug_mode") $defaultTune.debug_mode
    $resolved.accelerator_enabled = Get-BoolSetting (Get-PropertyValue -Object $rawConfig -Name "accelerator_enabled") $defaultTune.accelerator_enabled
    $resolved.accelerator_threshold = Get-IntSetting (Get-PropertyValue -Object $rawConfig -Name "accelerator_threshold") $defaultTune.accelerator_threshold 100 500000
    $resolved.selection_retry_count = Get-IntSetting (Get-PropertyValue -Object $rawConfig -Name "selection_retry_count") $defaultTune.selection_retry_count 1 50
    $resolved.selection_retry_delay_ms = Get-IntSetting (Get-PropertyValue -Object $rawConfig -Name "selection_retry_delay_ms") $defaultTune.selection_retry_delay_ms 0 1000
    $resolved.large_selection_trust_threshold = Get-IntSetting (Get-PropertyValue -Object $rawConfig -Name "large_selection_trust_threshold") $defaultTune.large_selection_trust_threshold 1 500000
    $resolved.strategy_move_first = Get-BoolSetting (Get-PropertyValue -Object $rawConfig -Name "strategy_move_first") $defaultTune.strategy_move_first

    if ($null -eq $rawConfig) {
        Save-TuneConfig -Config $resolved
    }
    return $resolved
}

$tuneConfig = Ensure-TuneConfig

$script:debugMode = $tuneConfig.debug_mode
$script:acceleratorEnabled = $tuneConfig.accelerator_enabled
$script:acceleratorThreshold = $tuneConfig.accelerator_threshold
$script:strategyMoveFirst = $tuneConfig.strategy_move_first
$selectionRetryCount = $tuneConfig.selection_retry_count
$selectionRetryDelayMs = $tuneConfig.selection_retry_delay_ms
$largeSelectionTrustThreshold = $tuneConfig.large_selection_trust_threshold

function Write-DebugLog {
    param([string]$Message)

    if (-not $script:debugMode) { return }

    try {
        $stamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
        Add-Content -LiteralPath $debugLogPath -Value "$stamp $Message" -Encoding UTF8
    }
    catch { }
}

function Get-ExplorerSelection {
    param([string]$AnySelectedPath)

    $parentPath = Split-Path -Path $AnySelectedPath -Parent
    if ([string]::IsNullOrWhiteSpace($parentPath)) { return @() }

    $anchorPath = if (-not [string]::IsNullOrEmpty($AnySelectedPath)) { $AnySelectedPath.Trim() } else { "" }

    $shell = $null
    try {
        $shell = New-Object -ComObject Shell.Application
        $windows = $shell.Windows()

        foreach ($win in $windows) {
            try {
                if ($null -eq $win -or $null -eq $win.Document) { continue }

                $folder = $win.Document.Folder
                if ($null -eq $folder -or $null -eq $folder.Self) { continue }

                if (-not [string]::Equals($folder.Self.Path, $parentPath, [StringComparison]::OrdinalIgnoreCase)) {
                    continue
                }

                $items = $win.Document.SelectedItems()
                if ($null -eq $items -or $items.Count -eq 0) { continue }

                $results = New-Object System.Collections.Generic.List[string]($items.Count)
                $anchorHit = $false

                foreach ($item in $items) {
                    $p = [string]$item.Path
                    if (-not [string]::IsNullOrEmpty($p)) {
                        $p = $p.Trim()
                        $results.Add($p)

                        if (-not $anchorHit -and [string]::Equals($p, $anchorPath, [StringComparison]::OrdinalIgnoreCase)) {
                            $anchorHit = $true
                        }
                    }
                }

                if ($anchorHit) {
                    return $results
                }
            }
            catch { }
        }
    }
    catch { }
    finally {
        if ($null -ne $shell) {
            try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null } catch { }
        }
    }

    return @()
}

function Resolve-Targets {
    param([string]$AnySelectedPath)

    $bestTargets = @()
    $lastCount = -1
    $stableHits = 0

    for ($attempt = 0; $attempt -lt $selectionRetryCount; $attempt++) {
        $rawTargets = Get-ExplorerSelection -AnySelectedPath $AnySelectedPath
        $count = $rawTargets.Count

        if ($count -gt 0) {
            if ($count -gt $bestTargets.Count) {
                $bestTargets = $rawTargets
            }

            if ($count -ge $largeSelectionTrustThreshold) {
                return $bestTargets
            }

            if ($count -eq $lastCount) {
                $stableHits++
            }
            else {
                $stableHits = 1
                $lastCount = $count
            }

            if ($stableHits -ge 2) {
                return $bestTargets
            }
        }

        Start-Sleep -Milliseconds $selectionRetryDelayMs
    }

    if ($bestTargets.Count -gt 0) {
        return $bestTargets
    }

    return @($AnySelectedPath)
}

function Convert-ToUniqueStringArray {
    param([string[]]$InputPaths)

    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $InputPaths) {
        if (-not [string]::IsNullOrWhiteSpace($p)) {
            [void]$set.Add($p.Trim())
        }
    }

    return [string[]]$set
}

function Get-NuclearAcceleratorSource {
@"
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Threading.Tasks;

public static class NuclearAccelerator {
    private static string BuildUniqueDestination(string dropZonePath, string sourcePath) {
        var name = Path.GetFileName(sourcePath);
        if (string.IsNullOrWhiteSpace(name)) {
            name = Guid.NewGuid().ToString("N");
        }

        var destination = Path.Combine(dropZonePath, name);
        if (!File.Exists(destination) && !Directory.Exists(destination)) {
            return destination;
        }

        return Path.Combine(dropZonePath, Guid.NewGuid().ToString("N") + "_" + name);
    }

    public static string[] Nuke(string[] paths) {
        var failed = new ConcurrentBag<string>();
        var dirs = new ConcurrentBag<string>();

        Parallel.ForEach(paths, path => {
            if (string.IsNullOrWhiteSpace(path)) return;
            try {
                var attr = File.GetAttributes(path);
                var forceMask = FileAttributes.ReadOnly | FileAttributes.Hidden | FileAttributes.System;

                if ((attr & forceMask) != 0) {
                    File.SetAttributes(path, attr & ~forceMask);
                    attr = File.GetAttributes(path);
                }

                if ((attr & FileAttributes.Directory) == FileAttributes.Directory) {
                    dirs.Add(path);
                }
                else {
                    File.Delete(path);
                }
            }
            catch (FileNotFoundException) { }
            catch (DirectoryNotFoundException) { }
            catch {
                failed.Add(path);
            }
        });

        var seenDirs = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var dir in dirs) {
            if (string.IsNullOrWhiteSpace(dir)) continue;
            if (!seenDirs.Add(dir)) continue;

            try {
                if (!Directory.Exists(dir)) continue;

                var attr = File.GetAttributes(dir);
                var forceMask = FileAttributes.ReadOnly | FileAttributes.Hidden | FileAttributes.System;
                if ((attr & forceMask) != 0) {
                    File.SetAttributes(dir, attr & ~forceMask);
                }

                Directory.Delete(dir, true);
            }
            catch (FileNotFoundException) { }
            catch (DirectoryNotFoundException) { }
            catch {
                failed.Add(dir);
            }
        }

        return failed.ToArray();
    }

    public static string[] ScoopAndNuke(string[] paths, string dropZonePath) {
        if (paths == null || paths.Length == 0 || string.IsNullOrWhiteSpace(dropZonePath)) {
            return Array.Empty<string>();
        }

        var failed = new ConcurrentBag<string>();
        var dirs = new List<string>();
        var dirsLock = new object();

        try {
            Directory.CreateDirectory(dropZonePath);
            var dzAttr = File.GetAttributes(dropZonePath);
            if ((dzAttr & FileAttributes.Hidden) == 0) {
                File.SetAttributes(dropZonePath, dzAttr | FileAttributes.Hidden);
            }
        }
        catch {
            return Nuke(paths);
        }

        Parallel.ForEach(paths, path => {
            if (string.IsNullOrWhiteSpace(path)) return;

            try {
                var attr = File.GetAttributes(path);
                var forceMask = FileAttributes.ReadOnly | FileAttributes.Hidden | FileAttributes.System;
                if ((attr & forceMask) != 0) {
                    File.SetAttributes(path, attr & ~forceMask);
                    attr = File.GetAttributes(path);
                }

                if ((attr & FileAttributes.Directory) == FileAttributes.Directory) {
                    lock (dirsLock) {
                        dirs.Add(path);
                    }
                }
                else {
                    var destination = BuildUniqueDestination(dropZonePath, path);
                    File.Move(path, destination);
                }
            }
            catch (FileNotFoundException) { }
            catch (DirectoryNotFoundException) { }
            catch {
                failed.Add(path);
            }
        });

        dirs.Sort((left, right) => right.Length.CompareTo(left.Length));
        foreach (var dir in dirs) {
            try {
                if (!Directory.Exists(dir)) continue;

                var attr = File.GetAttributes(dir);
                var forceMask = FileAttributes.ReadOnly | FileAttributes.Hidden | FileAttributes.System;
                if ((attr & forceMask) != 0) {
                    File.SetAttributes(dir, attr & ~forceMask);
                }

                var destination = BuildUniqueDestination(dropZonePath, dir);
                Directory.Move(dir, destination);
            }
            catch (FileNotFoundException) { }
            catch (DirectoryNotFoundException) { }
            catch {
                failed.Add(dir);
            }
        }

        try {
            Directory.Delete(dropZonePath, true);
        }
        catch {
            failed.Add(dropZonePath);
        }

        return failed.ToArray();
    }
}
"@
}

function Invoke-DeleteBatch {
    param([string[]]$Targets)

    if ($null -eq $Targets -or $Targets.Count -eq 0) { return 1 }

    $targetsArray = Convert-ToUniqueStringArray -InputPaths $Targets
    if ($targetsArray.Count -eq 0) { return 1 }

    $useAccelerator = $false
    $failedItems = @()

    if ($script:acceleratorEnabled -and $targetsArray.Count -ge $script:acceleratorThreshold) {
        if ([System.Management.Automation.PSTypeName]"NuclearAccelerator".Type) {
            $useAccelerator = $true
        }
        else {
            try {
                Add-Type -TypeDefinition (Get-NuclearAcceleratorSource) -Language CSharp -ErrorAction Stop | Out-Null
                $useAccelerator = $true
            }
            catch {
                $useAccelerator = $false
                Write-DebugLog "CSharp compile failed: $($_.Exception.Message)"
            }
        }
    }

    if ($useAccelerator) {
        try {
            if ($script:strategyMoveFirst) {
                $dropBase = Split-Path -Path $targetsArray[0] -Parent
                if ([string]::IsNullOrWhiteSpace($dropBase)) {
                    $dropBase = [System.IO.Path]::GetPathRoot($targetsArray[0])
                }
                if ([string]::IsNullOrWhiteSpace($dropBase)) {
                    $dropBase = $env:TEMP
                }

                $dropZone = Join-Path $dropBase ("._NuclearDrop_" + [Guid]::NewGuid().ToString("N"))
                Write-DebugLog "Delete path: CSharp ScoopAndNuke (count=$($targetsArray.Count), dropZone='$dropZone')"
                $failedItems = [NuclearAccelerator]::ScoopAndNuke([string[]]$targetsArray, [string]$dropZone)
            }
            else {
                Write-DebugLog "Delete path: CSharp accelerator (count=$($targetsArray.Count))"
                $failedItems = [NuclearAccelerator]::Nuke([string[]]$targetsArray)
            }
        }
        catch {
            $useAccelerator = $false
            $failedItems = @()
            Write-DebugLog "CSharp execution failed: $($_.Exception.Message)"
        }
    }

    if (-not $useAccelerator) {
        Write-DebugLog "Delete path: PowerShell baseline (count=$($targetsArray.Count))"
        $attrReadOnly = [System.IO.FileAttributes]::ReadOnly
        $attrHidden = [System.IO.FileAttributes]::Hidden
        $attrSystem = [System.IO.FileAttributes]::System
        $attrDir = [System.IO.FileAttributes]::Directory
        $maskForce = $attrReadOnly -bor $attrHidden -bor $attrSystem
        $maskInvert = -bnot $maskForce

        $localFailed = New-Object System.Collections.Generic.List[string]

        foreach ($path in $targetsArray) {
            if ([string]::IsNullOrWhiteSpace($path)) { continue }

            try {
                $attr = [System.IO.File]::GetAttributes($path)
                if (($attr -band $maskForce) -ne 0) {
                    $attr = $attr -band $maskInvert
                    [System.IO.File]::SetAttributes($path, $attr)
                }

                if (($attr -band $attrDir) -eq $attrDir) {
                    [System.IO.Directory]::Delete($path, $true)
                }
                else {
                    [System.IO.File]::Delete($path)
                }
            }
            catch {
                if ($_.Exception -is [System.IO.FileNotFoundException] -or
                    $_.Exception -is [System.IO.DirectoryNotFoundException]) {
                    continue
                }
                [void]$localFailed.Add($path)
            }
        }

        $failedItems = $localFailed.ToArray()
    }

    if ($null -ne $failedItems -and $failedItems.Count -gt 0) {
        Write-DebugLog "Fallback cleanup count=$($failedItems.Count)"
        $hadError = $false

        $uniqueFailed = Convert-ToUniqueStringArray -InputPaths $failedItems
        foreach ($path in $uniqueFailed) {
            try {
                if (Test-Path -LiteralPath $path -PathType Container) {
                    Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
                }
                elseif (Test-Path -LiteralPath $path -PathType Leaf) {
                    Remove-Item -LiteralPath $path -Force -ErrorAction Stop
                }
            }
            catch {
                $hadError = $true
                Write-DebugLog "Fallback failed for '$path': $($_.Exception.Message)"
            }
        }

        if ($hadError) { return 2 }
    }

    return 0
}

$createdNew = $false
$mutex = [System.Threading.Mutex]::new($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) {
    $mutex.Dispose()
    exit 0
}

try {
    Write-DebugLog "Start anchor='$AnchorPath' threshold=$script:acceleratorThreshold accel=$script:acceleratorEnabled move_first=$script:strategyMoveFirst"
    $targets = Resolve-Targets -AnySelectedPath $AnchorPath
    Write-DebugLog "Resolved targets count=$($targets.Count)"
    $exitCode = Invoke-DeleteBatch -Targets $targets
    Write-DebugLog "End exitCode=$exitCode"
    exit $exitCode
}
finally {
    try { $mutex.ReleaseMutex() | Out-Null } catch { }
    $mutex.Dispose()
}
