param(
    [Parameter(Mandatory = $true)]
    [string]$TargetPath
)

if (-not (Test-Path -LiteralPath $TargetPath)) {
    exit 1
}

try {
    if (Test-Path -LiteralPath $TargetPath -PathType Container) {
        Remove-Item -LiteralPath $TargetPath -Recurse -Force -ErrorAction Stop
    } else {
        Remove-Item -LiteralPath $TargetPath -Force -ErrorAction Stop
    }
    exit 0
} catch {
    exit 2
}
