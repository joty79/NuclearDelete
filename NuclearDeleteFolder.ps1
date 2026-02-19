param(
    [Parameter(Mandatory = $true)]
    [string]$AnchorPath
)

$mutexName = "Global\MoveTo_NuclearDelete_Operation"
$selectionRetryCount = 10
$selectionRetryDelayMs = 45
# If selection is huge, we trust it faster to avoid UI lag
$largeSelectionTrustThreshold = 1000 

function Get-ExplorerSelection {
    param([string]$AnySelectedPath)

    $parentPath = Split-Path -Path $AnySelectedPath -Parent
    if ([string]::IsNullOrWhiteSpace($parentPath)) { return @() }
    
    # Pre-trim anchor for comparison
    $anchorPath = if (-not [string]::IsNullOrEmpty($AnySelectedPath)) { $AnySelectedPath.Trim() } else { "" }

    $shell = $null
    try {
        $shell = New-Object -ComObject Shell.Application
        $windows = $shell.Windows()
        
        # Optimization: Use foreach instead of indexed for-loop to reduce COM overhead
        foreach ($win in $windows) {
            try {
                if ($null -eq $win -or $null -eq $win.Document) { continue }
                
                $folder = $win.Document.Folder
                if ($null -eq $folder -or $null -eq $folder.Self) { continue }

                # Fast string comparison
                if (-not [string]::Equals($folder.Self.Path, $parentPath, [StringComparison]::OrdinalIgnoreCase)) {
                    continue
                }

                $items = $win.Document.SelectedItems()
                if ($null -eq $items -or $items.Count -eq 0) { continue }

                # Use a specific list type for speed
                $results = New-Object System.Collections.Generic.List[string]($items.Count)
                $anchorHit = $false

                # CRITICAL PERFORMANCE SECTION
                # We iterate COM items as fast as possible
                foreach ($item in $items) {
                    $p = [string]$item.Path
                    if (-not [string]::IsNullOrEmpty($p)) {
                        $p = $p.Trim()
                        $results.Add($p)
                        
                        # Check anchor hit inside the loop to avoid second pass
                        if (-not $anchorHit -and [string]::Equals($p, $anchorPath, [StringComparison]::OrdinalIgnoreCase)) {
                            $anchorHit = $true
                        }
                    }
                }

                # If this window contains the file we right-clicked, it's the winner.
                if ($anchorHit) {
                    return $results
                }
            } catch { }
        }
    } catch { }
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
            # Always keep the largest set found
            if ($count -gt $bestTargets.Count) {
                $bestTargets = $rawTargets
            }

            # PERF: If we found > 1000 items, trust it immediately. 
            # Waiting for 9000 items to "stabilize" via repeated COM calls is too slow.
            if ($count -ge $largeSelectionTrustThreshold) {
                return $bestTargets
            }

            # Fast stability check (Count only, signature is too slow for 9000 items)
            if ($count -eq $lastCount) {
                $stableHits++
            } else {
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

    # Fallback
    return @($AnySelectedPath)
}

function Invoke-DeleteBatch {
    param([System.Collections.Generic.List[string]]$Targets)

    if ($null -eq $Targets -or $Targets.Count -eq 0) { return 1 }

    $hadError = $false

    # Cache attributes for bitwise operations
    $attrReadOnly = [System.IO.FileAttributes]::ReadOnly
    $attrHidden   = [System.IO.FileAttributes]::Hidden
    $attrSystem   = [System.IO.FileAttributes]::System
    $attrDir      = [System.IO.FileAttributes]::Directory
    $maskForce    = $attrReadOnly -bor $attrHidden -bor $attrSystem
    $maskInvert   = -bnot $maskForce

    foreach ($path in $Targets) {
        if ([string]::IsNullOrWhiteSpace($path)) {
            continue
        }

        try {
            # OPTIMIZATION: GetAttributes is the single source of truth.
            # It tells us 1) Does it exist? 2) Is it a Dir? 3) Is it ReadOnly?
            # This saves 2 syscalls per file compared to Test-Path + Get-Item.
            $attr = [System.IO.File]::GetAttributes($path)
            
            # 1. Strip ReadOnly/Hidden/System if present (Bitwise check is extremely fast)
            if (($attr -band $maskForce) -ne 0) {
                $attr = $attr -band $maskInvert
                [System.IO.File]::SetAttributes($path, $attr)
            }

            # 2. Delete based on Directory flag
            if (($attr -band $attrDir) -eq $attrDir) {
                [System.IO.Directory]::Delete($path, $true)
            } else {
                [System.IO.File]::Delete($path)
            }
        }
        catch {
            # Catch 'FileNotFound' specifically to ignore it (race condition during multiselect)
            if ($_.Exception -is [System.IO.FileNotFoundException] -or 
                $_.Exception -is [System.IO.DirectoryNotFoundException]) {
                continue
            }

            # Hard fallback for locked files/ACL issues
            try {
                if (Test-Path -LiteralPath $path -PathType Container) {
                    Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
                } elseif (Test-Path -LiteralPath $path -PathType Leaf) {
                    Remove-Item -LiteralPath $path -Force -ErrorAction Stop
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
    # Resolve targets returns a generic List, avoiding array copy overhead
    $targets = Resolve-Targets -AnySelectedPath $AnchorPath
    exit (Invoke-DeleteBatch -Targets $targets)
}
finally {
    try { $mutex.ReleaseMutex() | Out-Null } catch { }
    $mutex.Dispose()
}
