param(
    [Parameter(Mandatory = $true)]
    [string]$AnchorPath
)

$mutexName = "Global\MoveTo_NuclearDelete_Operation"
$selectionRetryCount = 10
$selectionRetryDelayMs = 45
$selectionStableHits = 2
$largeSelectionTrustThreshold = 1000

function Normalize-Targets {
    param([string[]]$InputPaths)
    @(
        $InputPaths |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.Trim() } |
        Select-Object -Unique
    )
}

function Get-ExplorerSelection {
    param([string]$AnySelectedPath)

    $parentPath = Split-Path -Path $AnySelectedPath -Parent
    if ([string]::IsNullOrWhiteSpace($parentPath)) {
        return @()
    }
    $anchorPath = if ([string]::IsNullOrWhiteSpace($AnySelectedPath)) { "" } else { $AnySelectedPath.Trim() }

    $bestTargets = New-Object System.Collections.Generic.List[string]
    $shell = $null
    try {
        $shell = New-Object -ComObject Shell.Application
        $windows = $shell.Windows()
        for ($i = 0; $i -lt $windows.Count; $i++) {
            try {
                $win = $windows.Item($i)
                if ($null -eq $win -or $null -eq $win.Document) { continue }

                $folder = $win.Document.Folder
                if ($null -eq $folder -or $null -eq $folder.Self) { continue }

                $windowPath = [string]$folder.Self.Path
                if (-not [string]::Equals($windowPath, $parentPath, [StringComparison]::OrdinalIgnoreCase)) {
                    continue
                }

                $items = $win.Document.SelectedItems()
                if ($null -eq $items) { continue }
                if ($items.Count -le 0) { continue }

                $windowTargets = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                $anchorHit = $false

                for ($j = 0; $j -lt $items.Count; $j++) {
                    try {
                        $itemPath = [string]$items.Item($j).Path
                        if (-not [string]::IsNullOrWhiteSpace($itemPath)) {
                            $itemPath = $itemPath.Trim()
                            [void]$windowTargets.Add($itemPath)
                            if (-not [string]::IsNullOrWhiteSpace($anchorPath) -and
                                [string]::Equals($itemPath, $anchorPath, [StringComparison]::OrdinalIgnoreCase)) {
                                $anchorHit = $true
                            }
                        }
                    } catch { }
                }

                if ($windowTargets.Count -eq 0) { continue }

                $candidate = [string[]]@($windowTargets)
                if ($anchorHit) {
                    return $candidate
                }
                if ($candidate.Count -gt $bestTargets.Count) {
                    $bestTargets.Clear()
                    foreach ($candidatePath in $candidate) {
                        [void]$bestTargets.Add($candidatePath)
                    }
                }
            } catch { }
        }
    } catch { }
    finally {
        if ($null -ne $shell) {
            try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) } catch { }
        }
    }

    return [string[]]@($bestTargets)
}

function Resolve-Targets {
    param([string]$AnySelectedPath)

    $bestTargets = @()
    $lastSignature = $null
    $stableHits = 0

    for ($attempt = 0; $attempt -lt $selectionRetryCount; $attempt++) {
        $targets = Normalize-Targets -InputPaths (Get-ExplorerSelection -AnySelectedPath $AnySelectedPath)
        if ($targets.Count -gt 0) {
            if ($targets.Count -gt $bestTargets.Count) {
                $bestTargets = @($targets)
            }

            if ($targets.Count -ge $largeSelectionTrustThreshold) {
                return $targets
            }

            if ($targets.Count -eq 1 -and
                [string]::Equals($targets[0], $AnySelectedPath, [StringComparison]::OrdinalIgnoreCase)) {
                return $targets
            }

            $signature = "{0}|{1}|{2}" -f $targets.Count, $targets[0], $targets[$targets.Count - 1]
            if ($signature -eq $lastSignature) {
                $stableHits++
            }
            else {
                $stableHits = 1
                $lastSignature = $signature
            }

            if ($stableHits -ge $selectionStableHits) {
                return $targets
            }
        }

        if ($attempt -lt ($selectionRetryCount - 1)) {
            Start-Sleep -Milliseconds $selectionRetryDelayMs
        }
    }

    if ($bestTargets.Count -gt 0) {
        return @($bestTargets)
    }

    # Fallback when Explorer selection cannot be read.
    return (Normalize-Targets -InputPaths @($AnySelectedPath))
}

function Clear-ForceAttributes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $attrs = [System.IO.File]::GetAttributes($Path)
    $clearMask = [System.IO.FileAttributes]::ReadOnly `
        -bor [System.IO.FileAttributes]::Hidden `
        -bor [System.IO.FileAttributes]::System

    if (($attrs -band $clearMask) -ne 0) {
        $newAttrs = $attrs -band (-bnot $clearMask)
        [System.IO.File]::SetAttributes($Path, $newAttrs)
        $attrs = $newAttrs
    }

    return $attrs
}

function Invoke-DeleteBatch {
    param([string[]]$Targets)

    if ($Targets.Count -eq 0) {
        return 1
    }

    $hadError = $false

    foreach ($targetPath in $Targets) {
        $isFile = [System.IO.File]::Exists($targetPath)
        $isDir = [System.IO.Directory]::Exists($targetPath)

        if (-not $isFile -and -not $isDir) {
            continue
        }

        try {
            $attrs = Clear-ForceAttributes -Path $targetPath
            $isDirectoryAttr = (($attrs -band [System.IO.FileAttributes]::Directory) -ne 0)

            if ($isDir -or $isDirectoryAttr) {
                [System.IO.Directory]::Delete($targetPath, $true)
            }
            else {
                [System.IO.File]::Delete($targetPath)
            }
        }
        catch {
            try {
                if (Test-Path -LiteralPath $targetPath -PathType Container) {
                    Remove-Item -LiteralPath $targetPath -Recurse -Force -ErrorAction Stop
                }
                else {
                    Remove-Item -LiteralPath $targetPath -Force -ErrorAction Stop
                }
            }
            catch {
                $hadError = $true
            }
        }
    }

    if ($hadError) { return 2 }
    return 0
}

$createdNew = $false
$mutex = [System.Threading.Mutex]::new($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) {
    $mutex.Dispose()
    exit 0
}

try {
    $targets = Resolve-Targets -AnySelectedPath $AnchorPath
    exit (Invoke-DeleteBatch -Targets $targets)
}
finally {
    try { $mutex.ReleaseMutex() | Out-Null } catch { }
    $mutex.Dispose()
}
