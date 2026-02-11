param(
    [Parameter(Mandatory = $true)]
    [string]$FolderPath
)

$logFile = Join-Path $env:TEMP "NuclearDelete.log"

function Write-Log {
    param([string]$Message)
    try {
        $line = "{0} | {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $Message
        Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
    } catch { }
}

function Wait-AndExit {
    param(
        [int]$Code = 0
    )
    Write-Host "Press any key to close..." -ForegroundColor DarkGray
    [Console]::ReadKey($true) | Out-Null
    exit $Code
}

try {
    if (-not (Test-Path -LiteralPath $FolderPath -PathType Container)) {
        Write-Host "Folder not found: $FolderPath" -ForegroundColor Red
        Write-Log "ERROR: Folder not found: $FolderPath"
        Wait-AndExit -Code 1
    }

    Write-Host ""
    Write-Host "NUCLEAR DELETE (PERMANENT)" -ForegroundColor Red
    Write-Host "Path: $FolderPath" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Press Enter to continue, or Esc to cancel." -ForegroundColor Red
    $key = [Console]::ReadKey($true).Key

    if ($key -eq [ConsoleKey]::Escape) {
        Write-Host "Cancelled (Esc)." -ForegroundColor Yellow
        Write-Log "CANCELLED: $FolderPath"
        Wait-AndExit -Code 0
    }

    if ($key -ne [ConsoleKey]::Enter) {
        Write-Host "Cancelled (only Enter proceeds)." -ForegroundColor Yellow
        Write-Log "CANCELLED: $FolderPath | Key=$key"
        Wait-AndExit -Code 0
    }

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Log "START: $FolderPath"
    Remove-Item -LiteralPath $FolderPath -Recurse -Force -ErrorAction Stop
    $timer.Stop()
    $elapsed = [Math]::Round($timer.Elapsed.TotalSeconds, 3)

    Write-Host "Deleted permanently: $FolderPath" -ForegroundColor Green
    Write-Host "Elapsed: $elapsed s" -ForegroundColor Cyan
    Write-Log "SUCCESS: $FolderPath | Elapsed=$elapsed s"
    Wait-AndExit -Code 0
}
catch {
    Write-Host "Delete failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Log "ERROR: $FolderPath | $($_.Exception.Message)"
    Write-Host "Log: $logFile" -ForegroundColor Yellow
    Wait-AndExit -Code 2
}
