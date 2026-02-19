#requires -version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Install', 'Update', 'Uninstall', 'OpenInstallDirectory', 'LaunchDeleteTune', 'Exit')]
    [string]$Action = '',
    [string]$InstallPath = [System.IO.Path]::Combine($env:LOCALAPPDATA, 'NuclearDeleteContext'),
    [string]$SourcePath = $PSScriptRoot,
    [switch]$NoExplorerRestart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:InstallerVersion = '1.0.0'
$InstallPath = [System.IO.Path]::GetFullPath($InstallPath)
$SourcePath = [System.IO.Path]::GetFullPath($SourcePath)

function Write-Banner {
    param([string]$Title = 'NuclearDelete Installer')
    try { Clear-Host } catch { }
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ('  {0}  v{1}' -f $Title, $script:InstallerVersion) -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
}

function Write-Step {
    param(
        [Parameter(Mandatory)][string]$Text,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )
    Write-Host ('[>] {0}' -f $Text) -ForegroundColor $Color
}

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Invoke-RegCommand {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$IgnoreNotFound
    )

    $output = & reg.exe @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $text = ($output | Out-String).Trim()
        if ($IgnoreNotFound -and $text -match 'unable to find the specified registry key or value') {
            return $null
        }
        throw "reg.exe failed (exit $exitCode): reg $($Arguments -join ' ')`n$text"
    }
    return $output
}

function Add-RegStringValue {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )
    $safeValue = if ($Value -eq '') { '""' } else { $Value }
    Invoke-RegCommand -Arguments @('add', $Key, '/v', $Name, '/t', 'REG_SZ', '/d', $safeValue, '/f') | Out-Null
}

function Add-RegDefaultValue {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )
    $safeValue = if ($Value -eq '') { '""' } else { $Value }
    Invoke-RegCommand -Arguments @('add', $Key, '/ve', '/t', 'REG_SZ', '/d', $safeValue, '/f') | Out-Null
}

function Remove-RegTree {
    param([Parameter(Mandatory)][string]$Key)
    Invoke-RegCommand -Arguments @('delete', $Key, '/f') -IgnoreNotFound | Out-Null
}

function Get-RequiredPackageEntries {
    @(
        'Install.ps1',
        'NuclearDeleteFolder.ps1',
        'NuclearDeleteFolder.vbs',
        'DeleteTune.ps1',
        'DeleteTune.json',
        'README.md'
    )
}

function Get-RegistryCleanupPaths {
    @(
        'HKCU\Software\Classes\AllFilesystemObjects\shell\z_10_DeleteToOblivion',
        'HKCU\Software\Classes\AllFilesystemObjects\ContextMenus\DeleteToOblivion',
        'HKCU\Software\Classes\Directory\shell\z_10_DeleteToOblivion',
        'HKCU\Software\Classes\Directory\ContextMenus\DeleteToOblivion',
        'HKCU\Software\Classes\Directory\shell\NuclearDeleteFolder',
        'HKCR\AllFilesystemObjects\shell\z_10_DeleteToOblivion',
        'HKCR\AllFilesystemObjects\ContextMenus\DeleteToOblivion',
        'HKCR\Directory\shell\z_10_DeleteToOblivion',
        'HKCR\Directory\ContextMenus\DeleteToOblivion',
        'HKCR\Directory\shell\NuclearDeleteFolder'
    )
}

function Remove-NuclearRegistryKeys {
    Write-Step -Text 'Cleaning existing context-menu keys...' -Color Cyan
    foreach ($key in Get-RegistryCleanupPaths) {
        try { Remove-RegTree -Key $key } catch { }
    }
}

function Convert-ToRegEscapedPath {
    param([Parameter(Mandatory)][string]$Path)
    $Path.Replace('\', '\\')
}

function Write-InstalledVbs {
    param(
        [Parameter(Mandatory)][string]$SourceVbsPath,
        [Parameter(Mandatory)][string]$DestinationVbsPath,
        [Parameter(Mandatory)][string]$InstalledScriptPath
    )

    $content = Get-Content -LiteralPath $SourceVbsPath -Raw -Encoding UTF8
    $escapedScript = $InstalledScriptPath.Replace('"', '""')

    $pattern = '(?m)^scriptPath = ".*"$'
    $replacement = ('scriptPath = "{0}"' -f $escapedScript)
    if ($content -match $pattern) {
        $content = [System.Text.RegularExpressions.Regex]::Replace($content, $pattern, $replacement)
    }
    else {
        throw 'Could not locate scriptPath assignment in NuclearDeleteFolder.vbs.'
    }

    Set-Content -LiteralPath $DestinationVbsPath -Value $content -Encoding ASCII
}

function Register-NuclearContextMenu {
    param([Parameter(Mandatory)][string]$InstalledVbsPath)

    $vbsEscaped = Convert-ToRegEscapedPath -Path $InstalledVbsPath
    $commandValue = ('wscript.exe "{0}" "%1"' -f $vbsEscaped)

    $parentKey = 'HKCU\Software\Classes\AllFilesystemObjects\shell\z_10_DeleteToOblivion'
    $childKey = 'HKCU\Software\Classes\AllFilesystemObjects\ContextMenus\DeleteToOblivion\shell\run'
    $commandKey = 'HKCU\Software\Classes\AllFilesystemObjects\ContextMenus\DeleteToOblivion\shell\run\command'

    Add-RegStringValue -Key $parentKey -Name 'MUIVerb' -Value 'Delete to Oblivion'
    Add-RegStringValue -Key $parentKey -Name 'Icon' -Value 'imageres.dll,-94'
    Add-RegStringValue -Key $parentKey -Name 'Position' -Value 'Bottom'
    Add-RegStringValue -Key $parentKey -Name 'SeparatorBefore' -Value ''
    Add-RegStringValue -Key $parentKey -Name 'ExtendedSubCommandsKey' -Value 'AllFilesystemObjects\ContextMenus\DeleteToOblivion'

    Add-RegStringValue -Key $childKey -Name 'MUIVerb' -Value 'Delete Permanently'
    Add-RegStringValue -Key $childKey -Name 'Icon' -Value 'imageres.dll,-94'
    Add-RegStringValue -Key $childKey -Name 'MultiSelectModel' -Value 'Document'

    Add-RegDefaultValue -Key $commandKey -Value $commandValue
}

function Install-NuclearDelete {
    Write-Step -Text 'Installing NuclearDelete context menu...' -Color Cyan
    Ensure-Directory -Path $InstallPath

    $required = Get-RequiredPackageEntries
    foreach ($entry in $required) {
        $src = Join-Path $SourcePath $entry
        if (-not (Test-Path -LiteralPath $src)) {
            throw "Missing required file: $src"
        }
    }

    foreach ($entry in $required) {
        if ($entry -eq 'NuclearDeleteFolder.vbs') { continue }
        $src = Join-Path $SourcePath $entry
        $dst = Join-Path $InstallPath $entry
        $dstDir = Split-Path -Path $dst -Parent
        Ensure-Directory -Path $dstDir
        Copy-Item -LiteralPath $src -Destination $dst -Force
    }

    $installedPs1 = Join-Path $InstallPath 'NuclearDeleteFolder.ps1'
    $installedVbs = Join-Path $InstallPath 'NuclearDeleteFolder.vbs'
    Write-InstalledVbs -SourceVbsPath (Join-Path $SourcePath 'NuclearDeleteFolder.vbs') -DestinationVbsPath $installedVbs -InstalledScriptPath $installedPs1

    Remove-NuclearRegistryKeys
    Register-NuclearContextMenu -InstalledVbsPath $installedVbs

    Write-Step -Text ("Install completed at: {0}" -f $InstallPath) -Color Green
}

function Uninstall-NuclearDelete {
    Write-Step -Text 'Uninstalling NuclearDelete context menu...' -Color Yellow
    Remove-NuclearRegistryKeys

    if (Test-Path -LiteralPath $InstallPath -PathType Container) {
        $preserve = @('Install.ps1', 'DeleteTune.ps1', 'DeleteTune.json')
        Get-ChildItem -LiteralPath $InstallPath -Force | ForEach-Object {
            if ($preserve -contains $_.Name) { return }
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Step -Text 'Uninstall completed (installer + DeleteTune preserved).' -Color Green
}

function Restart-Explorer {
    if ($NoExplorerRestart) { return }
    Write-Step -Text 'Restarting Explorer...' -Color DarkYellow
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 600
    Start-Process explorer.exe
}

function Show-InteractiveMenu {
    while ($true) {
        Write-Banner
        Write-Host ('Source : {0}' -f $SourcePath) -ForegroundColor DarkGray
        Write-Host ('Install: {0}' -f $InstallPath) -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '[1] Install / Update' -ForegroundColor Green
        Write-Host '[2] Uninstall' -ForegroundColor Yellow
        Write-Host '[3] Open install directory' -ForegroundColor Cyan
        Write-Host '[4] Launch DeleteTune' -ForegroundColor Cyan
        Write-Host '[0] Exit' -ForegroundColor Gray
        Write-Host ''
        $choice = (Read-Host 'Select option').Trim()
        switch ($choice) {
            '1' { return 'Install' }
            '2' { return 'Uninstall' }
            '3' { return 'OpenInstallDirectory' }
            '4' { return 'LaunchDeleteTune' }
            '0' { return 'Exit' }
            default {
                Write-Host 'Invalid option. Press any key...' -ForegroundColor Red
                [void][System.Console]::ReadKey($true)
            }
        }
    }
}

function Open-InstallDirectory {
    Ensure-Directory -Path $InstallPath
    Start-Process explorer.exe -ArgumentList $InstallPath
}

function Launch-DeleteTune {
    $tuneScript = Join-Path $InstallPath 'DeleteTune.ps1'
    if (-not (Test-Path -LiteralPath $tuneScript -PathType Leaf)) {
        Write-Step -Text "DeleteTune not found in install path. Install first." -Color Yellow
        return
    }
    Start-Process pwsh.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $tuneScript)
}

if ([string]::IsNullOrWhiteSpace($Action)) {
    $Action = Show-InteractiveMenu
}

switch ($Action) {
    'Install' {
        Install-NuclearDelete
        Restart-Explorer
    }
    'Update' {
        Install-NuclearDelete
        Restart-Explorer
    }
    'Uninstall' {
        Uninstall-NuclearDelete
        Restart-Explorer
    }
    'OpenInstallDirectory' {
        Open-InstallDirectory
    }
    'LaunchDeleteTune' {
        Launch-DeleteTune
    }
    'Exit' { }
    default {
        throw "Unsupported action: $Action"
    }
}
