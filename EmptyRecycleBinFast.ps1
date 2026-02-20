#requires -version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'

$drives = Get-PSDrive -PSProvider FileSystem | Where-Object {
    $_.Free -ne $null -and $_.Name -match '^[A-Za-z]$'
}

foreach ($drive in $drives) {
    $recyclePath = ('{0}:\$Recycle.Bin' -f $drive.Name.ToUpperInvariant())
    if (-not (Test-Path -LiteralPath $recyclePath -PathType Container)) {
        continue
    }

    & cmd.exe /c "rd /s /q `"$recyclePath`""
}
