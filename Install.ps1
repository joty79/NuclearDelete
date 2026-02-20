#requires -version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Install', 'Update', 'Uninstall', 'OpenInstallDirectory', 'LaunchDeleteTune', 'Exit', 'InstallGitHub', 'UpdateGitHub')]
    [string]$Action = '',
    [string]$InstallPath = [System.IO.Path]::Combine($env:LOCALAPPDATA, 'NuclearDeleteContext'),
    [string]$SourcePath = $PSScriptRoot,
    [ValidateSet('Local', 'GitHub')]
    [string]$PackageSource = 'Local',
    [string]$GitHubRepo = 'joty79/NuclearDelete',
    [string]$GitHubRef = 'master',
    [string]$GitHubZipUrl = '',
    [switch]$Force,
    [switch]$NoExplorerRestart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-NormalizedPath {
    param([Parameter(Mandatory)][string]$Path)
    [System.IO.Path]::GetFullPath($Path.Trim())
}

$script:InstallerVersion = '1.1.0'
$InstallPath = Resolve-NormalizedPath -Path $InstallPath
$SourcePath = Resolve-NormalizedPath -Path $SourcePath
$script:HasCliArgs = $MyInvocation.BoundParameters.Count -gt 0
$script:TempPackageRoots = [System.Collections.Generic.List[string]]::new()

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

function Test-IsProcessElevated {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        if (-not $identity) { return $false }
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Invoke-SelfElevatedAction {
    param([Parameter(Mandatory)][string]$TargetAction)

    $selfPath = $PSCommandPath
    if ([string]::IsNullOrWhiteSpace($selfPath) -and $MyInvocation.MyCommand) {
        $selfPath = $MyInvocation.MyCommand.Definition
    }
    if ([string]::IsNullOrWhiteSpace($selfPath) -or -not (Test-Path -LiteralPath $selfPath)) {
        throw 'Cannot locate installer script path for elevation.'
    }

    $pwshCmd = Get-Command -Name 'pwsh.exe' -ErrorAction SilentlyContinue
    if (-not $pwshCmd) {
        throw 'pwsh.exe is required for elevated install actions.'
    }

    $argList = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $selfPath),
        '-Action', $TargetAction,
        '-InstallPath', ('"{0}"' -f $InstallPath),
        '-SourcePath', ('"{0}"' -f $SourcePath),
        '-PackageSource', $script:PackageSource,
        '-GitHubRepo', $script:GitHubRepo,
        '-GitHubRef', $script:GitHubRef,
        '-Force'
    )
    if (-not [string]::IsNullOrWhiteSpace($GitHubZipUrl)) {
        $argList += @('-GitHubZipUrl', ('"{0}"' -f $GitHubZipUrl))
    }
    if ($NoExplorerRestart) {
        $argList += '-NoExplorerRestart'
    }

    $argumentString = [string]::Join(' ', $argList)
    $process = Start-Process -FilePath $pwshCmd.Source -ArgumentList $argumentString -Verb RunAs -Wait -PassThru
    if ($null -eq $process) {
        throw 'Failed to start elevated installer process.'
    }
    return [int]$process.ExitCode
}

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Get-RequiredPackageEntries {
    @(
        'Install.ps1',
        'NuclearDeleteFolder.ps1',
        'NuclearDeleteFolder.vbs',
        'EmptyRecycleBinFast.ps1',
        'DeleteTune.ps1',
        'DeleteTune.json',
        'README.md'
    )
}

function Assert-RequiredPackageFiles {
    param([Parameter(Mandatory)][string]$Root)
    foreach ($entry in Get-RequiredPackageEntries) {
        $fullPath = Join-Path $Root $entry
        if (-not (Test-Path -LiteralPath $fullPath)) {
            throw "Package is missing required file: $entry"
        }
    }
}

function Show-InteractiveMenu {
    while ($true) {
        Write-Banner
        Write-Host ('Source : {0}' -f $SourcePath) -ForegroundColor DarkGray
        Write-Host ('Install: {0}' -f $InstallPath) -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '[1] Install' -ForegroundColor Green
        Write-Host '[2] Update' -ForegroundColor Yellow
        Write-Host '[3] Uninstall' -ForegroundColor Red
        Write-Host '[4] Open install directory' -ForegroundColor Cyan
        Write-Host '[5] Launch DeleteTune' -ForegroundColor Cyan
        Write-Host '[0] Exit' -ForegroundColor Gray
        Write-Host ''
        $choice = (Read-Host 'Select option').Trim()
        switch ($choice) {
            '1' { return 'Install' }
            '2' { return 'Update' }
            '3' { return 'Uninstall' }
            '4' { return 'OpenInstallDirectory' }
            '5' { return 'LaunchDeleteTune' }
            '0' { return 'Exit' }
            default {
                Write-Host 'Invalid option. Press any key...' -ForegroundColor Red
                [void][System.Console]::ReadKey($true)
            }
        }
    }
}

function Confirm-Action {
    param([Parameter(Mandatory)][string]$Prompt)
    if ($Force) { return $true }
    $answer = (Read-Host "$Prompt [y/N]").Trim().ToLowerInvariant()
    return ($answer -eq 'y')
}

function Get-GitHubBranchNames {
    param([Parameter(Mandatory)][string]$Repo)

    $apiUrl = "https://api.github.com/repos/$Repo/branches?per_page=100"
    try {
        $resp = Invoke-RestMethod -Uri $apiUrl -Headers @{ 'User-Agent' = 'NuclearDeleteInstaller/1.1' } -Method Get
        if (-not $resp) { return @() }
        $names = @($resp | ForEach-Object { [string]$_.name } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        return @($names | Select-Object -Unique)
    }
    catch {
        Write-Host ("[!] Could not fetch branch list: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        return @()
    }
}

function Read-GitHubRefInteractive {
    param(
        [string]$DefaultRef = 'master',
        [string]$Repo = 'joty79/NuclearDelete'
    )

    $normalizedDefault = if ([string]::IsNullOrWhiteSpace($DefaultRef)) { 'master' } else { $DefaultRef.Trim() }
    $branches = @(Get-GitHubBranchNames -Repo $Repo)

    if ($branches.Count -gt 0) {
        if ($branches -notcontains $normalizedDefault) {
            $branches = @($normalizedDefault) + @($branches)
        }
        else {
            $branches = @($normalizedDefault) + @($branches | Where-Object { $_ -ne $normalizedDefault })
        }
        $branches = @($branches | Select-Object -Unique)

        Write-Host ''
        Write-Host ("Available branches for {0}:" -f $Repo) -ForegroundColor Cyan
        for ($i = 0; $i -lt $branches.Count; $i++) {
            $n = $i + 1
            $name = $branches[$i]
            $suffix = if ($name -eq $normalizedDefault) { ' (default)' } else { '' }
            Write-Host ("[{0}] {1}{2}" -f $n, $name, $suffix) -ForegroundColor Gray
        }
        Write-Host '[M] Manual branch/ref input' -ForegroundColor Gray
        Write-Host '[Enter] Use default' -ForegroundColor Gray

        while ($true) {
            $choice = (Read-Host ("Select branch number (blank = {0})" -f $normalizedDefault)).Trim()
            if ([string]::IsNullOrWhiteSpace($choice)) { return $normalizedDefault }
            if ($choice.Equals('m', [System.StringComparison]::OrdinalIgnoreCase)) { break }
            if ($choice -match '^\d+$') {
                $index = [int]$choice
                if ($index -ge 1 -and $index -le $branches.Count) {
                    return $branches[$index - 1]
                }
            }
            Write-Host 'Invalid selection. Choose a number, M, or Enter.' -ForegroundColor Yellow
        }
    }

    while ($true) {
        $raw = Read-Host ("GitHub branch/ref (blank = {0})" -f $normalizedDefault)
        $candidate = if ($null -eq $raw) { '' } else { $raw.Trim() }
        if ([string]::IsNullOrWhiteSpace($candidate)) { return $normalizedDefault }
        if ($candidate.StartsWith('refs/heads/', [System.StringComparison]::OrdinalIgnoreCase)) {
            $candidate = $candidate.Substring('refs/heads/'.Length)
        }
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            Write-Host 'Invalid branch/ref. Try again.' -ForegroundColor Yellow
            continue
        }
        return $candidate
    }
}

function Get-GitHubZipUrlResolved {
    if (-not [string]::IsNullOrWhiteSpace($GitHubZipUrl)) {
        return $GitHubZipUrl.Trim()
    }
    return ("https://codeload.github.com/{0}/zip/refs/heads/{1}" -f $GitHubRepo, $GitHubRef)
}

function Resolve-PackageSourceRoot {
    if ($PackageSource -eq 'Local') {
        Assert-RequiredPackageFiles -Root $SourcePath
        return $SourcePath
    }

    $tmpId = [Guid]::NewGuid().ToString('N')
    $zipPath = Join-Path $env:TEMP ("nucleardelete-package-{0}.zip" -f $tmpId)
    $extractPath = Join-Path $env:TEMP ("nucleardelete-package-{0}" -f $tmpId)
    Ensure-Directory -Path $extractPath

    $url = Get-GitHubZipUrlResolved
    Write-Step -Text ("Downloading package: {0}" -f $url) -Color Cyan
    Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing

    Write-Step -Text 'Extracting package...' -Color Cyan
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue

    $script:TempPackageRoots.Add($extractPath) | Out-Null

    $candidateRoots = @($extractPath) + @(Get-ChildItem -LiteralPath $extractPath -Directory -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    foreach ($candidate in $candidateRoots | Select-Object -Unique) {
        if ((Test-Path -LiteralPath (Join-Path $candidate 'Install.ps1')) -and
            (Test-Path -LiteralPath (Join-Path $candidate 'NuclearDeleteFolder.ps1'))) {
            Assert-RequiredPackageFiles -Root $candidate
            return $candidate
        }
    }

    throw 'Downloaded package root is invalid or incomplete.'
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
    $recycleScriptPath = Join-Path $InstallPath 'EmptyRecycleBinFast.ps1'
    $recycleScriptEscaped = Convert-ToRegEscapedPath -Path $recycleScriptPath
    $recycleCommandValue = ('pwsh.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $recycleScriptEscaped)

    $parentKey = 'HKCU\Software\Classes\AllFilesystemObjects\shell\z_10_DeleteToOblivion'
    $recycleChildKey = 'HKCU\Software\Classes\AllFilesystemObjects\ContextMenus\DeleteToOblivion\shell\a_00_EmptyRecycleBin'
    $recycleCommandKey = 'HKCU\Software\Classes\AllFilesystemObjects\ContextMenus\DeleteToOblivion\shell\a_00_EmptyRecycleBin\command'
    $childKey = 'HKCU\Software\Classes\AllFilesystemObjects\ContextMenus\DeleteToOblivion\shell\run'
    $commandKey = 'HKCU\Software\Classes\AllFilesystemObjects\ContextMenus\DeleteToOblivion\shell\run\command'

    Add-RegStringValue -Key $parentKey -Name 'MUIVerb' -Value 'Delete to Oblivion'
    Add-RegStringValue -Key $parentKey -Name 'Icon' -Value 'imageres.dll,-94'
    Add-RegStringValue -Key $parentKey -Name 'Position' -Value 'Bottom'
    Add-RegStringValue -Key $parentKey -Name 'SeparatorBefore' -Value ''
    Add-RegStringValue -Key $parentKey -Name 'ExtendedSubCommandsKey' -Value 'AllFilesystemObjects\ContextMenus\DeleteToOblivion'
    Add-RegStringValue -Key $recycleChildKey -Name 'MUIVerb' -Value 'Empty Recycle Bin (All Volumes)'
    Add-RegStringValue -Key $recycleChildKey -Name 'Icon' -Value 'shell32.dll,-31'
    Add-RegDefaultValue -Key $recycleCommandKey -Value $recycleCommandValue
    Add-RegStringValue -Key $childKey -Name 'MUIVerb' -Value 'Delete Permanently'
    Add-RegStringValue -Key $childKey -Name 'Icon' -Value 'imageres.dll,-94'
    Add-RegStringValue -Key $childKey -Name 'MultiSelectModel' -Value 'Document'
    Add-RegDefaultValue -Key $commandKey -Value $commandValue
}

function Deploy-PackageFiles {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$InstallRoot
    )

    $required = Get-RequiredPackageEntries
    foreach ($entry in $required) {
        if ($entry -eq 'NuclearDeleteFolder.vbs') { continue }
        $src = Join-Path $SourceRoot $entry
        $dst = Join-Path $InstallRoot $entry
        Ensure-Directory -Path (Split-Path -Path $dst -Parent)
        Copy-Item -LiteralPath $src -Destination $dst -Force
    }

    $installedPs1 = Join-Path $InstallRoot 'NuclearDeleteFolder.ps1'
    $installedVbs = Join-Path $InstallRoot 'NuclearDeleteFolder.vbs'
    Write-InstalledVbs -SourceVbsPath (Join-Path $SourceRoot 'NuclearDeleteFolder.vbs') -DestinationVbsPath $installedVbs -InstalledScriptPath $installedPs1
}

function Install-NuclearDelete {
    param([ValidateSet('Install', 'Update')][string]$Mode)

    Write-Step -Text ("{0} NuclearDelete context menu..." -f $Mode) -Color Cyan
    Write-Step -Text ("Package source: {0}" -f $script:PackageSource) -Color DarkCyan
    if ($script:PackageSource -eq 'GitHub') {
        Write-Step -Text ("GitHub ref: {0}" -f $script:GitHubRef) -Color DarkCyan
    }

    Ensure-Directory -Path $InstallPath
    $sourceRoot = $null
    try {
        $sourceRoot = Resolve-PackageSourceRoot
        Deploy-PackageFiles -SourceRoot $sourceRoot -InstallRoot $InstallPath
    }
    finally {
        foreach ($temp in $script:TempPackageRoots) {
            try {
                if (Test-Path -LiteralPath $temp) {
                    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
            catch { }
        }
        $script:TempPackageRoots.Clear()
    }

    Remove-NuclearRegistryKeys
    Register-NuclearContextMenu -InstalledVbsPath (Join-Path $InstallPath 'NuclearDeleteFolder.vbs')

    Write-Step -Text ("{0} completed at: {1}" -f $Mode, $InstallPath) -Color Green
}

function Uninstall-NuclearDelete {
    Write-Step -Text 'Uninstalling NuclearDelete context menu...' -Color Yellow
    Remove-NuclearRegistryKeys

    if (Test-Path -LiteralPath $InstallPath -PathType Container) {
        $preserve = @('Install.ps1', 'DeleteTune.ps1', 'DeleteTune.json')
        foreach ($item in @(Get-ChildItem -LiteralPath $InstallPath -Force -ErrorAction SilentlyContinue)) {
            if ($preserve -contains $item.Name) { continue }
            Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Step -Text 'Uninstall completed (installer + DeleteTune preserved).' -Color Green
}

function Restart-ExplorerShell {
    if ($NoExplorerRestart) { return }

    if (-not $Force) {
        $answer = (Read-Host 'Restart Explorer now to refresh context menus? [Y/n]').Trim().ToLowerInvariant()
        if ($answer -in @('n', 'no')) {
            Write-Step -Text 'Explorer restart skipped by user.' -Color Yellow
            return
        }
    }

    Write-Step -Text 'Restarting Explorer...' -Color DarkYellow
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    Start-Process explorer.exe
}

function Open-InstallDirectory {
    Ensure-Directory -Path $InstallPath
    Start-Process explorer.exe -ArgumentList $InstallPath
    return 0
}

function Launch-DeleteTune {
    $tuneScript = Join-Path $InstallPath 'DeleteTune.ps1'
    if (-not (Test-Path -LiteralPath $tuneScript -PathType Leaf)) {
        Write-Step -Text "DeleteTune not found in install path. Install first." -Color Yellow
        return 1
    }
    Start-Process pwsh.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $tuneScript)
    return 0
}

function Invoke-Main {
    if (-not $script:HasCliArgs) {
        $menuAction = Show-InteractiveMenu
        if ($menuAction -eq 'Exit') { return 0 }
        $Action = $menuAction
    }

    switch ($Action) {
        'Install' {
            if (-not $script:HasCliArgs) {
                $script:PackageSource = 'GitHub'
                $script:GitHubRef = Read-GitHubRefInteractive -DefaultRef $script:GitHubRef -Repo $script:GitHubRepo
            }
            if (-not (Confirm-Action -Prompt "Install NuclearDelete to '$InstallPath'?")) {
                Write-Host 'Cancelled.' -ForegroundColor Yellow
                return 0
            }
            if (-not (Test-IsProcessElevated)) {
                Write-Step -Text 'Install requires elevation for reliable registry write-through. Requesting admin rights...' -Color Yellow
                return (Invoke-SelfElevatedAction -TargetAction 'Install')
            }
            Install-NuclearDelete -Mode 'Install'
            Restart-ExplorerShell
            return 0
        }
        'Update' {
            if (-not $script:HasCliArgs) {
                $script:PackageSource = 'GitHub'
                $script:GitHubRef = Read-GitHubRefInteractive -DefaultRef $script:GitHubRef -Repo $script:GitHubRepo
            }
            if (-not (Confirm-Action -Prompt "Update NuclearDelete at '$InstallPath'?")) {
                Write-Host 'Cancelled.' -ForegroundColor Yellow
                return 0
            }
            if (-not (Test-IsProcessElevated)) {
                Write-Step -Text 'Update requires elevation for reliable registry write-through. Requesting admin rights...' -Color Yellow
                return (Invoke-SelfElevatedAction -TargetAction 'Update')
            }
            Install-NuclearDelete -Mode 'Update'
            Restart-ExplorerShell
            return 0
        }
        'InstallGitHub' {
            $script:PackageSource = 'GitHub'
            if (-not (Confirm-Action -Prompt "Install NuclearDelete from GitHub '$GitHubRef' to '$InstallPath'?")) {
                Write-Host 'Cancelled.' -ForegroundColor Yellow
                return 0
            }
            if (-not (Test-IsProcessElevated)) {
                Write-Step -Text 'Install (GitHub) requires elevation for reliable registry write-through. Requesting admin rights...' -Color Yellow
                return (Invoke-SelfElevatedAction -TargetAction 'InstallGitHub')
            }
            Install-NuclearDelete -Mode 'Install'
            Restart-ExplorerShell
            return 0
        }
        'UpdateGitHub' {
            $script:PackageSource = 'GitHub'
            if (-not (Confirm-Action -Prompt "Update NuclearDelete from GitHub '$GitHubRef' at '$InstallPath'?")) {
                Write-Host 'Cancelled.' -ForegroundColor Yellow
                return 0
            }
            if (-not (Test-IsProcessElevated)) {
                Write-Step -Text 'Update (GitHub) requires elevation for reliable registry write-through. Requesting admin rights...' -Color Yellow
                return (Invoke-SelfElevatedAction -TargetAction 'UpdateGitHub')
            }
            Install-NuclearDelete -Mode 'Update'
            Restart-ExplorerShell
            return 0
        }
        'Uninstall' {
            if (-not (Confirm-Action -Prompt "Uninstall NuclearDelete from '$InstallPath'?")) {
                Write-Host 'Cancelled.' -ForegroundColor Yellow
                return 0
            }
            if (-not (Test-IsProcessElevated)) {
                Write-Step -Text 'Uninstall requires elevation for full registry cleanup. Requesting admin rights...' -Color Yellow
                return (Invoke-SelfElevatedAction -TargetAction 'Uninstall')
            }
            Uninstall-NuclearDelete
            Restart-ExplorerShell
            return 0
        }
        'OpenInstallDirectory' { return (Open-InstallDirectory) }
        'LaunchDeleteTune' { return (Launch-DeleteTune) }
        'Exit' { return 0 }
        default {
            Write-Host "Unknown action: $Action" -ForegroundColor Red
            return 1
        }
    }
}

exit (Invoke-Main)
