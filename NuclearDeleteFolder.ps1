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
    strategy_robocopy_combo          = $false
    robocopy_combo_threshold         = 5000
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
    $resolved.strategy_robocopy_combo = Get-BoolSetting (Get-PropertyValue -Object $rawConfig -Name "strategy_robocopy_combo") $defaultTune.strategy_robocopy_combo
    $resolved.robocopy_combo_threshold = Get-IntSetting (Get-PropertyValue -Object $rawConfig -Name "robocopy_combo_threshold") $defaultTune.robocopy_combo_threshold 100 500000

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
$script:strategyRobocopyCombo = $tuneConfig.strategy_robocopy_combo
$script:robocopyComboThreshold = $tuneConfig.robocopy_combo_threshold
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

function New-BulkResult {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Used,
        [Parameter(Mandatory = $true)]
        [bool]$Success,
        [Parameter(Mandatory = $false)]
        [string]$DropZone,
        [Parameter(Mandatory = $true)]
        [string]$Reason
    )

    return [pscustomobject]@{
        Used     = $Used
        Success  = $Success
        DropZone = $DropZone
        Reason   = $Reason
    }
}

function Get-ExplorerSelectionContext {
    param([string]$AnySelectedPath)

    $parentPath = Split-Path -Path $AnySelectedPath -Parent
    if ([string]::IsNullOrWhiteSpace($parentPath)) {
        return [pscustomobject]@{
            Found  = $false
            Reason = "NoParentPath"
            Shell  = $null
        }
    }

    $anchorPath = if (-not [string]::IsNullOrEmpty($AnySelectedPath)) { $AnySelectedPath.Trim() } else { "" }
    $shell = $null
    try {
        $shell = New-Object -ComObject Shell.Application
        $windows = $shell.Windows()
        $context = $null

        foreach ($win in $windows) {
            try {
                if ($null -eq $win -or $null -eq $win.Document) { continue }

                $folder = $win.Document.Folder
                if ($null -eq $folder -or $null -eq $folder.Self) { continue }
                if (-not [string]::Equals($folder.Self.Path, $parentPath, [StringComparison]::OrdinalIgnoreCase)) { continue }

                $items = $win.Document.SelectedItems()
                if ($null -eq $items -or $items.Count -eq 0) { continue }

                if ($null -eq $context) {
                    $context = [pscustomobject]@{
                        Window = $win
                        Items  = $items
                    }
                }

                $focusedPath = ""
                try { $focusedPath = [string]$win.Document.FocusedItem.Path } catch { }
                if (-not [string]::IsNullOrWhiteSpace($focusedPath)) { $focusedPath = $focusedPath.Trim() }

                if (-not [string]::IsNullOrWhiteSpace($anchorPath) -and
                    [string]::Equals($focusedPath, $anchorPath, [StringComparison]::OrdinalIgnoreCase)) {
                    $context = [pscustomobject]@{
                        Window = $win
                        Items  = $items
                    }
                    break
                }
            }
            catch { }
        }

        if ($null -eq $context) {
            if ($null -ne $shell) {
                try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null } catch { }
            }

            return [pscustomobject]@{
                Found  = $false
                Reason = "NoMatchingExplorerWindow"
                Shell  = $null
            }
        }

        $items = $context.Items
        $itemCount = [int]$items.Count
        if ($itemCount -le 0) {
            if ($null -ne $shell) {
                try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null } catch { }
            }

            return [pscustomobject]@{
                Found  = $false
                Reason = "EmptySelection"
                Shell  = $null
            }
        }

        $firstPath = [string]$items.Item(0).Path
        if ([string]::IsNullOrWhiteSpace($firstPath)) {
            if ($null -ne $shell) {
                try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null } catch { }
            }

            return [pscustomobject]@{
                Found  = $false
                Reason = "FirstItemPathMissing"
                Shell  = $null
            }
        }
        $firstPath = $firstPath.Trim()

        $samplePaths = New-Object System.Collections.Generic.List[string]
        $sampleCount = [Math]::Min(8, $itemCount)
        for ($sampleIndex = 0; $sampleIndex -lt $sampleCount; $sampleIndex++) {
            try {
                $samplePath = [string]$items.Item($sampleIndex).Path
                if (-not [string]::IsNullOrWhiteSpace($samplePath)) {
                    [void]$samplePaths.Add($samplePath.Trim())
                }
            }
            catch { }
        }

        return [pscustomobject]@{
            Found      = $true
            Reason     = "OK"
            Shell      = $shell
            Window     = $context.Window
            Items      = $items
            ItemCount  = $itemCount
            ParentPath = $parentPath
            AnchorPath = $anchorPath
            FirstPath  = $firstPath
            SamplePaths = [string[]]$samplePaths.ToArray()
        }
    }
    catch {
        if ($null -ne $shell) {
            try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null } catch { }
        }

        return [pscustomobject]@{
            Found  = $false
            Reason = "SelectionContextException"
            Shell  = $null
        }
    }
}

function Remove-KeepRootMarkerFast {
    param([string]$MarkerPath)

    if ([string]::IsNullOrWhiteSpace($MarkerPath)) { return $true }

    # Keep runtime impact near-zero: immediate try first, then tiny retries only on failure.
    $retryDelaysMs = @(0, 15, 35, 75)
    foreach ($delayMs in $retryDelaysMs) {
        if ($delayMs -gt 0) {
            Start-Sleep -Milliseconds $delayMs
        }

        try {
            if (-not [System.IO.File]::Exists($MarkerPath)) {
                return $true
            }
            [System.IO.File]::Delete($MarkerPath)
            if (-not [System.IO.File]::Exists($MarkerPath)) {
                return $true
            }
        }
        catch { }
    }

    return (-not [System.IO.File]::Exists($MarkerPath))
}

function Try-DeleteFileTinyRetry {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $true }

    $retryDelaysMs = @(0, 20, 60, 120)
    foreach ($delayMs in $retryDelaysMs) {
        if ($delayMs -gt 0) {
            Start-Sleep -Milliseconds $delayMs
        }

        try {
            if (-not [System.IO.File]::Exists($Path)) {
                return $true
            }

            try {
                [System.IO.File]::SetAttributes($Path, [System.IO.FileAttributes]::Normal)
            }
            catch { }

            [System.IO.File]::Delete($Path)
            if (-not [System.IO.File]::Exists($Path)) {
                return $true
            }
        }
        catch { }
    }

    return (-not [System.IO.File]::Exists($Path))
}

function Resolve-RobocopyMoveRootLeftovers {
    param(
        [string]$SourceDirectory,
        [string]$DestinationDirectory
    )

    $stats = [pscustomobject]@{
        Checked  = 0
        Eligible = 0
        Cleaned  = 0
        Failed   = 0
        Skipped  = 0
    }

    if ([string]::IsNullOrWhiteSpace($SourceDirectory) -or [string]::IsNullOrWhiteSpace($DestinationDirectory)) {
        return $stats
    }
    if (-not [System.IO.Directory]::Exists($SourceDirectory)) {
        return $stats
    }
    if (-not [System.IO.Directory]::Exists($DestinationDirectory)) {
        return $stats
    }

    $failedSamples = New-Object System.Collections.Generic.List[string]
    $sourceFiles = @()
    try {
        $sourceFiles = @([System.IO.Directory]::EnumerateFiles($SourceDirectory, "*", [System.IO.SearchOption]::TopDirectoryOnly))
    }
    catch {
        return $stats
    }

    foreach ($sourcePath in $sourceFiles) {
        $name = [System.IO.Path]::GetFileName($sourcePath)
        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        if ($name.StartsWith("__rcwm_keep_root_", [System.StringComparison]::OrdinalIgnoreCase) -and
            $name.EndsWith(".tmp", [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        $stats.Checked++
        $destinationPath = Join-Path $DestinationDirectory $name
        if (-not [System.IO.File]::Exists($destinationPath)) {
            $stats.Skipped++
            continue
        }

        $sourceInfo = $null
        $destinationInfo = $null
        try {
            $sourceInfo = Get-Item -LiteralPath $sourcePath -Force -ErrorAction Stop
            $destinationInfo = Get-Item -LiteralPath $destinationPath -Force -ErrorAction Stop
        }
        catch {
            $stats.Skipped++
            continue
        }

        if ($sourceInfo.PSIsContainer -or $destinationInfo.PSIsContainer) {
            $stats.Skipped++
            continue
        }

        $sameLength = ([int64]$sourceInfo.Length -eq [int64]$destinationInfo.Length)
        $sameWriteUtc = ($sourceInfo.LastWriteTimeUtc -eq $destinationInfo.LastWriteTimeUtc)
        if (-not ($sameLength -and $sameWriteUtc)) {
            $stats.Skipped++
            continue
        }

        $stats.Eligible++
        if (Try-DeleteFileTinyRetry -Path $sourcePath) {
            $stats.Cleaned++
        }
        else {
            $stats.Failed++
            if ($failedSamples.Count -lt 3) {
                [void]$failedSamples.Add($sourcePath)
            }
        }
    }

    Write-DebugLog ("Robocopy combo root-cleanup source='{0}' dest='{1}' checked={2} eligible={3} cleaned={4} failed={5} skipped={6}" -f $SourceDirectory, $DestinationDirectory, $stats.Checked, $stats.Eligible, $stats.Cleaned, $stats.Failed, $stats.Skipped)
    if ($stats.Failed -gt 0) {
        $preview = if ($failedSamples.Count -gt 0) { [string]::Join(" | ", $failedSamples.ToArray()) } else { "" }
        Write-DebugLog ("Robocopy combo root-cleanup warning source='{0}' failed={1} samples='{2}'" -f $SourceDirectory, $stats.Failed, $preview)
    }

    return $stats
}

function Invoke-RobocopyMoveAllTopFiles {
    param(
        [string]$SourceDirectory,
        [string]$DestinationDirectory,
        [string]$KeepRootFileName
    )

    $robocopyArgs = @(
        $SourceDirectory,
        $DestinationDirectory,
        "*",
        "/MOV",
        "/IS",
        "/R:0",
        "/W:0",
        "/NP",
        "/NJH",
        "/NJS",
        "/NC",
        "/NS",
        "/NFL",
        "/NDL",
        "/MT:48"
    )

    if (-not [string]::IsNullOrWhiteSpace($KeepRootFileName)) {
        $robocopyArgs += @("/XF", $KeepRootFileName)
    }

    & C:\Windows\System32\robocopy.exe @robocopyArgs | Out-Null
    $exitCode = $LASTEXITCODE
    return [pscustomobject]@{
        ExitCode  = $exitCode
        Succeeded = ($exitCode -lt 8)
    }
}

function Try-RobocopyBulkScoopAndNuke {
    param([string]$AnySelectedPath)

    $comboTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $selectionStageMs = -1
    $transferStageMs = -1
    $rootCleanupStageMs = -1
    $dropzoneDeleteStageMs = -1
    $sampleVerifyStageMs = -1

    $dropZone = $null
    $stageStartMs = $comboTimer.ElapsedMilliseconds
    $selectionContext = Get-ExplorerSelectionContext -AnySelectedPath $AnySelectedPath
    $selectionStageMs = $comboTimer.ElapsedMilliseconds - $stageStartMs
    if (-not $selectionContext.Found) {
        Write-DebugLog ("Robocopy combo timing totalMs={0} selection_validate_ms={1} transfer_ms={2} root_cleanup_ms={3} dropzone_delete_ms={4} sample_verify_ms={5}" -f $comboTimer.ElapsedMilliseconds, $selectionStageMs, $transferStageMs, $rootCleanupStageMs, $dropzoneDeleteStageMs, $sampleVerifyStageMs)
        return (New-BulkResult -Used:$false -Success:$false -DropZone $null -Reason $selectionContext.Reason)
    }

    $shell = $selectionContext.Shell
    try {
        $itemCount = [int]$selectionContext.ItemCount
        $sourceDirectory = [string]$selectionContext.ParentPath
        $firstPath = [string]$selectionContext.FirstPath
        $window = $selectionContext.Window
        $samplePaths = @($selectionContext.SamplePaths)

        if ($itemCount -lt $script:robocopyComboThreshold) {
            return (New-BulkResult -Used:$false -Success:$false -DropZone $null -Reason "BelowComboThreshold")
        }
        if ([string]::IsNullOrWhiteSpace($sourceDirectory) -or -not [System.IO.Directory]::Exists($sourceDirectory)) {
            return (New-BulkResult -Used:$false -Success:$false -DropZone $null -Reason "SourceDirectoryMissing")
        }

        # Fast select-all hint (count-only) to avoid expensive per-item COM traversal.
        $folderItemCount = -1
        $stageStartMs = $comboTimer.ElapsedMilliseconds
        try {
            if ($null -ne $window -and $null -ne $window.Document -and $null -ne $window.Document.Folder) {
                $folderItemCount = [int]($window.Document.Folder.Items().Count)
            }
        }
        catch {
            $folderItemCount = -1
        }
        $countCheckStageMs = $comboTimer.ElapsedMilliseconds - $stageStartMs

        if ($folderItemCount -gt 0 -and $itemCount -ne $folderItemCount) {
            Write-DebugLog ("Robocopy combo skipped: count-mismatch selected={0} folderItems={1} count_check_ms={2}" -f $itemCount, $folderItemCount, $countCheckStageMs)
            return (New-BulkResult -Used:$false -Success:$false -DropZone $null -Reason "NotSelectAllCountMismatch")
        }
        Write-DebugLog ("Robocopy combo trust-mode selected={0} folderItems={1} count_check_ms={2}" -f $itemCount, $folderItemCount, $countCheckStageMs)

        $topLevelFileCount = @(
            Get-ChildItem -LiteralPath $sourceDirectory -File -Force -ErrorAction SilentlyContinue
        ).Count
        if ($topLevelFileCount -le 0 -or $itemCount -ne $topLevelFileCount) {
            Write-DebugLog ("Robocopy combo blocked: not full top-level file selection selected={0} topLevelFiles={1}" -f $itemCount, $topLevelFileCount)
            return (New-BulkResult -Used:$false -Success:$false -DropZone $null -Reason "NotFullTopLevelFileSelection")
        }

        $dropRoot = [System.IO.Path]::GetPathRoot($firstPath)
        if ([string]::IsNullOrWhiteSpace($dropRoot)) {
            $dropRoot = Split-Path -Path $firstPath -Parent
        }
        if ([string]::IsNullOrWhiteSpace($dropRoot)) {
            return (New-BulkResult -Used:$true -Success:$false -DropZone $null -Reason "DropRootMissing")
        }

        $dropZone = Join-Path $dropRoot ("._NuclearDrop_" + [Guid]::NewGuid().ToString("N"))
        [System.IO.Directory]::CreateDirectory($dropZone) | Out-Null
        try {
            $dropAttr = [System.IO.File]::GetAttributes($dropZone)
            if (($dropAttr -band [System.IO.FileAttributes]::Hidden) -eq 0) {
                [System.IO.File]::SetAttributes($dropZone, $dropAttr -bor [System.IO.FileAttributes]::Hidden)
            }
        }
        catch { }

        $markerName = $null
        $markerPath = $null
        $robocopyResult = $null
        try {
            $markerName = ("__rcwm_keep_root_{0}.tmp" -f ([Guid]::NewGuid().ToString("N")))
            $markerPath = Join-Path $sourceDirectory $markerName
            [System.IO.File]::WriteAllText($markerPath, "")
            Write-DebugLog "Robocopy combo move guard marker='$markerName'"
        }
        catch {
            $markerName = $null
            $markerPath = $null
            Write-DebugLog "Robocopy combo marker create warning source='$sourceDirectory' error='$($_.Exception.Message)'"
        }

        Write-DebugLog "Robocopy combo start (count=$itemCount source='$sourceDirectory' dropZone='$dropZone' threshold=$script:robocopyComboThreshold)"
        $stageStartMs = $comboTimer.ElapsedMilliseconds
        try {
            $robocopyResult = Invoke-RobocopyMoveAllTopFiles -SourceDirectory $sourceDirectory -DestinationDirectory $dropZone -KeepRootFileName $markerName
            Write-DebugLog "Robocopy combo transfer result exitCode=$($robocopyResult.ExitCode) succeeded=$($robocopyResult.Succeeded)"
        }
        finally {
            $transferStageMs = $comboTimer.ElapsedMilliseconds - $stageStartMs
            if (-not [string]::IsNullOrWhiteSpace($markerPath)) {
                $markerRemoved = Remove-KeepRootMarkerFast -MarkerPath $markerPath
                if (-not $markerRemoved) {
                    Write-DebugLog "Robocopy combo marker cleanup warning marker='$markerPath'"
                }
                else {
                    Write-DebugLog "Robocopy combo marker cleanup ok marker='$markerPath'"
                }
            }
        }

        if ($null -eq $robocopyResult -or -not $robocopyResult.Succeeded) {
            $reason = if ($null -eq $robocopyResult) { "RobocopyNoResult" } else { "RobocopyExitCode_$($robocopyResult.ExitCode)" }
            return (New-BulkResult -Used:$true -Success:$false -DropZone $dropZone -Reason $reason)
        }

        $stageStartMs = $comboTimer.ElapsedMilliseconds
        [void](Resolve-RobocopyMoveRootLeftovers -SourceDirectory $sourceDirectory -DestinationDirectory $dropZone)
        $rootCleanupStageMs = $comboTimer.ElapsedMilliseconds - $stageStartMs

        $stageStartMs = $comboTimer.ElapsedMilliseconds
        $cleanupExit = Invoke-DeleteBatch -Targets @($dropZone)
        $dropzoneDeleteStageMs = $comboTimer.ElapsedMilliseconds - $stageStartMs
        if ($cleanupExit -ne 0) {
            Write-DebugLog "Robocopy combo dropZone delete failed exitCode=$cleanupExit dropZone='$dropZone'"
            Write-DebugLog ("Robocopy combo timing totalMs={0} selection_validate_ms={1} transfer_ms={2} root_cleanup_ms={3} dropzone_delete_ms={4} sample_verify_ms={5}" -f $comboTimer.ElapsedMilliseconds, $selectionStageMs, $transferStageMs, $rootCleanupStageMs, $dropzoneDeleteStageMs, $sampleVerifyStageMs)
            return (New-BulkResult -Used:$true -Success:$false -DropZone $dropZone -Reason ("DropZoneDeleteFailed_{0}" -f $cleanupExit))
        }
        $dropZone = $null

        $remainingTopLevelFiles = @(
            Get-ChildItem -LiteralPath $sourceDirectory -File -Force -ErrorAction SilentlyContinue |
            Where-Object {
                -not (
                    $_.Name.StartsWith("__rcwm_keep_root_", [System.StringComparison]::OrdinalIgnoreCase) -and
                    $_.Name.EndsWith(".tmp", [System.StringComparison]::OrdinalIgnoreCase)
                )
            }
        ).Count
        if ($remainingTopLevelFiles -gt 0) {
            Write-DebugLog "Robocopy combo post-verify failed remainingTopLevelFiles=$remainingTopLevelFiles"
            Write-DebugLog ("Robocopy combo timing totalMs={0} selection_validate_ms={1} transfer_ms={2} root_cleanup_ms={3} dropzone_delete_ms={4} sample_verify_ms={5}" -f $comboTimer.ElapsedMilliseconds, $selectionStageMs, $transferStageMs, $rootCleanupStageMs, $dropzoneDeleteStageMs, $sampleVerifyStageMs)
            return (New-BulkResult -Used:$true -Success:$false -DropZone $null -Reason ("SourceStillHasTopLevelFiles_{0}" -f $remainingTopLevelFiles))
        }

        $stageStartMs = $comboTimer.ElapsedMilliseconds
        $remainingSamples = 0
        foreach ($samplePath in $samplePaths) {
            if ([string]::IsNullOrWhiteSpace($samplePath)) { continue }
            try {
                if (Test-Path -LiteralPath $samplePath) {
                    $remainingSamples++
                }
            }
            catch {
                $remainingSamples++
            }
        }
        $sampleVerifyStageMs = $comboTimer.ElapsedMilliseconds - $stageStartMs

        if ($remainingSamples -gt 0) {
            Write-DebugLog "Robocopy combo post-verify failed remainingSamples=$remainingSamples totalSamples=$($samplePaths.Count)"
            Write-DebugLog ("Robocopy combo timing totalMs={0} selection_validate_ms={1} transfer_ms={2} root_cleanup_ms={3} dropzone_delete_ms={4} sample_verify_ms={5}" -f $comboTimer.ElapsedMilliseconds, $selectionStageMs, $transferStageMs, $rootCleanupStageMs, $dropzoneDeleteStageMs, $sampleVerifyStageMs)
            return (New-BulkResult -Used:$true -Success:$false -DropZone $null -Reason "SourceStillHasSample")
        }

        Write-DebugLog "Robocopy combo success samples=$($samplePaths.Count)"
        Write-DebugLog ("Robocopy combo timing totalMs={0} selection_validate_ms={1} transfer_ms={2} root_cleanup_ms={3} dropzone_delete_ms={4} sample_verify_ms={5}" -f $comboTimer.ElapsedMilliseconds, $selectionStageMs, $transferStageMs, $rootCleanupStageMs, $dropzoneDeleteStageMs, $sampleVerifyStageMs)
        return (New-BulkResult -Used:$true -Success:$true -DropZone $null -Reason "OK")
    }
    catch {
        Write-DebugLog "Robocopy combo exception: $($_.Exception.Message)"
        Write-DebugLog ("Robocopy combo timing totalMs={0} selection_validate_ms={1} transfer_ms={2} root_cleanup_ms={3} dropzone_delete_ms={4} sample_verify_ms={5}" -f $comboTimer.ElapsedMilliseconds, $selectionStageMs, $transferStageMs, $rootCleanupStageMs, $dropzoneDeleteStageMs, $sampleVerifyStageMs)
        return (New-BulkResult -Used:$true -Success:$false -DropZone $dropZone -Reason "Exception")
    }
    finally {
        if ($null -ne $shell) {
            try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null } catch { }
        }
    }
}

function Try-ExplorerBulkScoopAndNuke {
    param([string]$AnySelectedPath)

    $parentPath = Split-Path -Path $AnySelectedPath -Parent
    if ([string]::IsNullOrWhiteSpace($parentPath)) {
        return [pscustomobject]@{
            Used    = $false
            Success = $false
            DropZone = $null
            Reason  = "NoParentPath"
        }
    }

    $anchorPath = if (-not [string]::IsNullOrEmpty($AnySelectedPath)) { $AnySelectedPath.Trim() } else { "" }
    $shell = $null
    $dropZone = $null

    try {
        $shell = New-Object -ComObject Shell.Application
        $windows = $shell.Windows()
        $context = $null

        foreach ($win in $windows) {
            try {
                if ($null -eq $win -or $null -eq $win.Document) { continue }

                $folder = $win.Document.Folder
                if ($null -eq $folder -or $null -eq $folder.Self) { continue }
                if (-not [string]::Equals($folder.Self.Path, $parentPath, [StringComparison]::OrdinalIgnoreCase)) { continue }

                $items = $win.Document.SelectedItems()
                if ($null -eq $items -or $items.Count -eq 0) { continue }

                if ($null -eq $context) {
                    $context = [pscustomobject]@{
                        Window = $win
                        Items  = $items
                    }
                }

                $focusedPath = ""
                try { $focusedPath = [string]$win.Document.FocusedItem.Path } catch { }
                if (-not [string]::IsNullOrWhiteSpace($focusedPath)) { $focusedPath = $focusedPath.Trim() }

                if (-not [string]::IsNullOrWhiteSpace($anchorPath) -and
                    [string]::Equals($focusedPath, $anchorPath, [StringComparison]::OrdinalIgnoreCase)) {
                    $context = [pscustomobject]@{
                        Window = $win
                        Items  = $items
                    }
                    break
                }
            }
            catch { }
        }

        if ($null -eq $context) {
            return [pscustomobject]@{
                Used    = $false
                Success = $false
                DropZone = $null
                Reason  = "NoMatchingExplorerWindow"
            }
        }

        $items = $context.Items
        $itemCount = [int]$items.Count
        if ($itemCount -le 0) {
            return [pscustomobject]@{
                Used    = $false
                Success = $false
                DropZone = $null
                Reason  = "EmptySelection"
            }
        }

        $firstPath = [string]$items.Item(0).Path
        if ([string]::IsNullOrWhiteSpace($firstPath)) {
            return [pscustomobject]@{
                Used    = $true
                Success = $false
                DropZone = $null
                Reason  = "FirstItemPathMissing"
            }
        }
        $firstPath = $firstPath.Trim()

        # Small verification sample to avoid false-success from async/shell quirks.
        $samplePaths = New-Object System.Collections.Generic.List[string]
        $sampleCount = [Math]::Min(8, $itemCount)
        for ($sampleIndex = 0; $sampleIndex -lt $sampleCount; $sampleIndex++) {
            try {
                $samplePath = [string]$items.Item($sampleIndex).Path
                if (-not [string]::IsNullOrWhiteSpace($samplePath)) {
                    [void]$samplePaths.Add($samplePath.Trim())
                }
            }
            catch { }
        }

        $dropRoot = [System.IO.Path]::GetPathRoot($firstPath)
        if ([string]::IsNullOrWhiteSpace($dropRoot)) {
            $dropRoot = Split-Path -Path $firstPath -Parent
        }
        if ([string]::IsNullOrWhiteSpace($dropRoot)) {
            return [pscustomobject]@{
                Used    = $true
                Success = $false
                DropZone = $null
                Reason  = "DropRootMissing"
            }
        }

        $dropZone = Join-Path $dropRoot ("._NuclearDrop_" + [Guid]::NewGuid().ToString("N"))
        [System.IO.Directory]::CreateDirectory($dropZone) | Out-Null

        try {
            $dropAttr = [System.IO.File]::GetAttributes($dropZone)
            if (($dropAttr -band [System.IO.FileAttributes]::Hidden) -eq 0) {
                [System.IO.File]::SetAttributes($dropZone, $dropAttr -bor [System.IO.FileAttributes]::Hidden)
            }
        }
        catch { }

        $destFolder = $shell.NameSpace($dropZone)
        if ($null -eq $destFolder) {
            return [pscustomobject]@{
                Used    = $true
                Success = $false
                DropZone = $dropZone
                Reason  = "DestinationNamespaceMissing"
            }
        }

        # FOF_SILENT + FOF_NOCONFIRMATION + FOF_NOCONFIRMMKDIR + FOF_NOERRORUI
        $moveFlags = 0x0004 -bor 0x0010 -bor 0x0200 -bor 0x0400
        Write-DebugLog "Explorer bulk move start (count=$itemCount, dropZone='$dropZone')"
        $destFolder.MoveHere($items, $moveFlags)

        # MoveHere is asynchronous. Wait for completion, not only first evidence.
        $completionStableHits = 0
        $completionReached = $false
        for ($attempt = 0; $attempt -lt 1200; $attempt++) {
            $remainingSamples = 0
            foreach ($samplePath in $samplePaths) {
                try {
                    if (Test-Path -LiteralPath $samplePath) {
                        $remainingSamples++
                    }
                }
                catch {
                    $remainingSamples++
                }
            }

            $selectionRemaining = -1
            try {
                $selectionRemaining = [int]$context.Window.Document.SelectedItems().Count
            }
            catch { }

            $completionSignal = ($remainingSamples -eq 0) -and (($selectionRemaining -eq 0) -or ($selectionRemaining -eq -1))
            if ($completionSignal) {
                $completionStableHits++
                if ($completionStableHits -ge 6) {
                    $completionReached = $true
                    Write-DebugLog "Explorer bulk move completion confirmed (attempt=$attempt stableHits=$completionStableHits selectionRemaining=$selectionRemaining)"
                    break
                }
            }
            else {
                $completionStableHits = 0
            }

            if (($attempt % 20) -eq 0) {
                Write-DebugLog "Explorer bulk move progress (attempt=$attempt remainingSamples=$remainingSamples selectionRemaining=$selectionRemaining)"
            }

            Start-Sleep -Milliseconds 50
        }

        if (-not $completionReached) {
            return [pscustomobject]@{
                Used    = $true
                Success = $false
                DropZone = $dropZone
                Reason  = "MoveNotCompleted"
            }
        }

        for ($attempt = 0; $attempt -lt 400; $attempt++) {
            try {
                [System.IO.Directory]::Delete($dropZone, $true)

                $remainingSamples = 0
                foreach ($samplePath in $samplePaths) {
                    try {
                        if (Test-Path -LiteralPath $samplePath) {
                            $remainingSamples++
                        }
                    }
                    catch {
                        $remainingSamples++
                    }
                }

                if ($remainingSamples -gt 0) {
                    Write-DebugLog "Explorer bulk post-verify failed (remainingSamples=$remainingSamples totalSamples=$($samplePaths.Count))"
                    return [pscustomobject]@{
                        Used    = $true
                        Success = $false
                        DropZone = $null
                        Reason  = "SourceStillHasSample"
                    }
                }

                Write-DebugLog "Explorer bulk move+delete success (attempt=$attempt samples=$($samplePaths.Count))"
                return [pscustomobject]@{
                    Used    = $true
                    Success = $true
                    DropZone = $null
                    Reason  = "OK"
                }
            }
            catch {
                Start-Sleep -Milliseconds 100
            }
        }

        return [pscustomobject]@{
            Used    = $true
            Success = $false
            DropZone = $dropZone
            Reason  = "DropZoneDeleteTimeout"
        }
    }
    catch {
        Write-DebugLog "Explorer bulk move exception: $($_.Exception.Message)"
        return [pscustomobject]@{
            Used    = $false
            Success = $false
            DropZone = $dropZone
            Reason  = "Exception"
        }
    }
    finally {
        if ($null -ne $shell) {
            try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null } catch { }
        }
    }
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
            Write-DebugLog "Delete path: CSharp accelerator (count=$($targetsArray.Count))"
            $failedItems = [NuclearAccelerator]::Nuke([string[]]$targetsArray)
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

function Write-MainTimingSummary {
    param(
        [int]$ExitCode,
        [string]$PathName,
        [long]$TotalMs,
        [long]$RobocopyComboMs,
        [long]$ExplorerMoveFirstMs,
        [long]$ResolveTargetsMs,
        [long]$DeleteBatchMs
    )

    Write-DebugLog ("Main timing exitCode={0} path='{1}' totalMs={2} robocopy_combo_ms={3} explorer_move_first_ms={4} resolve_targets_ms={5} delete_batch_ms={6}" -f $ExitCode, $PathName, $TotalMs, $RobocopyComboMs, $ExplorerMoveFirstMs, $ResolveTargetsMs, $DeleteBatchMs)
}

$createdNew = $false
$mutex = [System.Threading.Mutex]::new($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) {
    $mutex.Dispose()
    exit 0
}

try {
    $mainTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $robocopyComboMs = -1
    $explorerMoveFirstMs = -1
    $resolveTargetsMs = -1
    $deleteBatchMs = -1

    Write-DebugLog "Start anchor='$AnchorPath' threshold=$script:acceleratorThreshold accel=$script:acceleratorEnabled move_first=$script:strategyMoveFirst robocopy_combo=$script:strategyRobocopyCombo robocopy_combo_threshold=$script:robocopyComboThreshold"

    if ($script:strategyRobocopyCombo) {
        $stageStartMs = $mainTimer.ElapsedMilliseconds
        $roboResult = Try-RobocopyBulkScoopAndNuke -AnySelectedPath $AnchorPath
        $robocopyComboMs = $mainTimer.ElapsedMilliseconds - $stageStartMs
        Write-DebugLog "Robocopy combo result used=$($roboResult.Used) success=$($roboResult.Success) reason=$($roboResult.Reason)"

        if ($roboResult.Used -and $roboResult.Success) {
            Write-MainTimingSummary -ExitCode 0 -PathName "Robocopy combo path" -TotalMs $mainTimer.ElapsedMilliseconds -RobocopyComboMs $robocopyComboMs -ExplorerMoveFirstMs $explorerMoveFirstMs -ResolveTargetsMs $resolveTargetsMs -DeleteBatchMs $deleteBatchMs
            Write-DebugLog "End exitCode=0 (Robocopy combo path)"
            exit 0
        }

        if ($roboResult.Used -and -not $roboResult.Success -and -not [string]::IsNullOrWhiteSpace([string]$roboResult.DropZone)) {
            Write-DebugLog "Robocopy combo cleanup fallback for dropZone='$([string]$roboResult.DropZone)'"
            $cleanupExit = Invoke-DeleteBatch -Targets @([string]$roboResult.DropZone)
            if ($cleanupExit -eq 0) {
                Write-DebugLog "Robocopy combo dropZone cleanup succeeded"
                Write-DebugLog "Robocopy combo cleanup done; continuing with standard resolve/delete for remaining source items"
            }
            else {
                Write-DebugLog "Robocopy combo dropZone cleanup failed exitCode=$cleanupExit"
            }
        }
    }

    if ($script:strategyMoveFirst) {
        $stageStartMs = $mainTimer.ElapsedMilliseconds
        $bulkResult = Try-ExplorerBulkScoopAndNuke -AnySelectedPath $AnchorPath
        $explorerMoveFirstMs = $mainTimer.ElapsedMilliseconds - $stageStartMs
        Write-DebugLog "Explorer bulk result used=$($bulkResult.Used) success=$($bulkResult.Success) reason=$($bulkResult.Reason)"

        if ($bulkResult.Used -and $bulkResult.Success) {
            Write-MainTimingSummary -ExitCode 0 -PathName "Explorer bulk path" -TotalMs $mainTimer.ElapsedMilliseconds -RobocopyComboMs $robocopyComboMs -ExplorerMoveFirstMs $explorerMoveFirstMs -ResolveTargetsMs $resolveTargetsMs -DeleteBatchMs $deleteBatchMs
            Write-DebugLog "End exitCode=0 (Explorer bulk path)"
            exit 0
        }

        if ($bulkResult.Used -and -not $bulkResult.Success -and -not [string]::IsNullOrWhiteSpace([string]$bulkResult.DropZone)) {
            Write-DebugLog "Explorer bulk cleanup fallback for dropZone='$([string]$bulkResult.DropZone)'"
            $cleanupExit = Invoke-DeleteBatch -Targets @([string]$bulkResult.DropZone)
            if ($cleanupExit -eq 0) {
                Write-DebugLog "Explorer dropZone cleanup succeeded"
                Write-DebugLog "Explorer dropZone cleanup done; continuing with standard resolve/delete for remaining source items"
            }
            else {
                Write-DebugLog "Explorer dropZone cleanup failed exitCode=$cleanupExit"
            }
        }
    }

    $stageStartMs = $mainTimer.ElapsedMilliseconds
    $targets = Resolve-Targets -AnySelectedPath $AnchorPath
    $resolveTargetsMs = $mainTimer.ElapsedMilliseconds - $stageStartMs
    Write-DebugLog "Resolved targets count=$($targets.Count)"

    $stageStartMs = $mainTimer.ElapsedMilliseconds
    $exitCode = Invoke-DeleteBatch -Targets $targets
    $deleteBatchMs = $mainTimer.ElapsedMilliseconds - $stageStartMs
    Write-MainTimingSummary -ExitCode $exitCode -PathName "Standard resolve/delete path" -TotalMs $mainTimer.ElapsedMilliseconds -RobocopyComboMs $robocopyComboMs -ExplorerMoveFirstMs $explorerMoveFirstMs -ResolveTargetsMs $resolveTargetsMs -DeleteBatchMs $deleteBatchMs
    Write-DebugLog "End exitCode=$exitCode"
    exit $exitCode
}
finally {
    try { $mutex.ReleaseMutex() | Out-Null } catch { }
    $mutex.Dispose()
}
