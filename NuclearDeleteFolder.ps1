param(
    [Parameter(Mandatory = $true)]
    [string]$AnchorPath
)

$mutexName = "Global\MoveTo_NuclearDelete_Operation"
$selectionRetryCount = 3
$selectionRetryDelayMs = 200

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

    $targets = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $parentPath = Split-Path -Path $AnySelectedPath -Parent
    if ([string]::IsNullOrWhiteSpace($parentPath)) {
        return @()
    }

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

                for ($j = 0; $j -lt $items.Count; $j++) {
                    try {
                        $itemPath = [string]$items.Item($j).Path
                        if (-not [string]::IsNullOrWhiteSpace($itemPath)) {
                            [void]$targets.Add($itemPath.Trim())
                        }
                    } catch { }
                }

                if ($targets.Count -gt 0) {
                    break
                }
            } catch { }
        }
    } catch { }
    finally {
        if ($null -ne $shell) {
            try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) } catch { }
        }
    }

    return @($targets)
}

function Resolve-Targets {
    param([string]$AnySelectedPath)

    $targets = @()
    for ($attempt = 0; $attempt -lt $selectionRetryCount; $attempt++) {
        $targets = Normalize-Targets -InputPaths (Get-ExplorerSelection -AnySelectedPath $AnySelectedPath)
        if ($targets.Count -gt 0) {
            return $targets
        }

        if ($attempt -lt ($selectionRetryCount - 1)) {
            Start-Sleep -Milliseconds $selectionRetryDelayMs
        }
    }

    # Fallback when Explorer selection cannot be read.
    return (Normalize-Targets -InputPaths @($AnySelectedPath))
}

function Invoke-DeleteBatch {
    param([string[]]$Targets)

    if ($Targets.Count -eq 0) {
        return 1
    }

    $hadError = $false
    foreach ($targetPath in $Targets) {
        if (-not (Test-Path -LiteralPath $targetPath)) {
            $hadError = $true
            continue
        }

        try {
            if (Test-Path -LiteralPath $targetPath -PathType Container) {
                Remove-Item -LiteralPath $targetPath -Recurse -Force -ErrorAction Stop
            } else {
                Remove-Item -LiteralPath $targetPath -Force -ErrorAction Stop
            }
        } catch {
            $hadError = $true
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
