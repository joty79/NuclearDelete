param(
    [switch]$ShowPathOnly
)

$stateRoot = Join-Path $env:LOCALAPPDATA "NuclearDelete"
$configPath = Join-Path $stateRoot "DeleteTune.json"
$repoDefaultPath = Join-Path $PSScriptRoot "DeleteTune.json"

function New-DefaultTuneConfig {
    return [ordered]@{
        debug_mode                       = $false
        accelerator_enabled              = $true
        accelerator_threshold            = 2000
        selection_retry_count            = 10
        selection_retry_delay_ms         = 45
        large_selection_trust_threshold  = 1000
    }
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

function Save-Config {
    param([hashtable]$Config)

    if (-not (Test-Path -LiteralPath $stateRoot -PathType Container)) {
        New-Item -Path $stateRoot -ItemType Directory -Force | Out-Null
    }

    $Config | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $configPath -Encoding UTF8
}

function Load-Config {
    $defaults = New-DefaultTuneConfig

    if (-not (Test-Path -LiteralPath $stateRoot -PathType Container)) {
        New-Item -Path $stateRoot -ItemType Directory -Force | Out-Null
    }

    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        if (Test-Path -LiteralPath $repoDefaultPath -PathType Leaf) {
            Copy-Item -LiteralPath $repoDefaultPath -Destination $configPath -Force
        }
        else {
            Save-Config -Config $defaults
        }
    }

    $raw = $null
    try {
        $raw = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        $raw = $null
    }

    $resolved = [ordered]@{}
    $resolved.debug_mode = Get-BoolSetting (Get-PropertyValue -Object $raw -Name "debug_mode") $defaults.debug_mode
    $resolved.accelerator_enabled = Get-BoolSetting (Get-PropertyValue -Object $raw -Name "accelerator_enabled") $defaults.accelerator_enabled
    $resolved.accelerator_threshold = Get-IntSetting (Get-PropertyValue -Object $raw -Name "accelerator_threshold") $defaults.accelerator_threshold 100 500000
    $resolved.selection_retry_count = Get-IntSetting (Get-PropertyValue -Object $raw -Name "selection_retry_count") $defaults.selection_retry_count 1 50
    $resolved.selection_retry_delay_ms = Get-IntSetting (Get-PropertyValue -Object $raw -Name "selection_retry_delay_ms") $defaults.selection_retry_delay_ms 0 1000
    $resolved.large_selection_trust_threshold = Get-IntSetting (Get-PropertyValue -Object $raw -Name "large_selection_trust_threshold") $defaults.large_selection_trust_threshold 1 500000

    Save-Config -Config $resolved
    return $resolved
}

function Show-Config {
    param([hashtable]$Config)

    Clear-Host
    Write-Host "DeleteTune"
    Write-Host "=========="
    Write-Host "1. Toggle debug_mode                       : $($Config.debug_mode)"
    Write-Host "2. Toggle accelerator_enabled              : $($Config.accelerator_enabled)"
    Write-Host "3. Set accelerator_threshold               : $($Config.accelerator_threshold)"
    Write-Host "4. Set selection_retry_count               : $($Config.selection_retry_count)"
    Write-Host "5. Set selection_retry_delay_ms            : $($Config.selection_retry_delay_ms)"
    Write-Host "6. Set large_selection_trust_threshold     : $($Config.large_selection_trust_threshold)"
    Write-Host "7. Open state directory"
    Write-Host "8. Show install/state paths"
    Write-Host "9. Reset defaults"
    Write-Host "0. Exit"
    Write-Host ""
    Write-Host "Config: $configPath"
    Write-Host ""
}

function Read-IntegerInRange {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,
        [Parameter(Mandatory = $true)]
        [int]$Current,
        [Parameter(Mandatory = $true)]
        [int]$Min,
        [Parameter(Mandatory = $true)]
        [int]$Max
    )

    $value = Read-Host "$Prompt [$Current]"
    if ([string]::IsNullOrWhiteSpace($value)) { return $Current }

    $parsed = 0
    if (-not [int]::TryParse($value, [ref]$parsed)) {
        Write-Host "Invalid integer. Press Enter."
        [void](Read-Host)
        return $null
    }

    if ($parsed -lt $Min -or $parsed -gt $Max) {
        Write-Host "Out of range ($Min-$Max). Press Enter."
        [void](Read-Host)
        return $null
    }

    return $parsed
}

if ($ShowPathOnly) {
    $null = Load-Config
    Write-Output $configPath
    exit 0
}

$config = Load-Config

while ($true) {
    Show-Config -Config $config
    $choice = Read-Host "Select option"

    switch ($choice) {
        "1" {
            $config.debug_mode = -not $config.debug_mode
            Save-Config -Config $config
        }
        "2" {
            $config.accelerator_enabled = -not $config.accelerator_enabled
            Save-Config -Config $config
        }
        "3" {
            $newValue = Read-IntegerInRange -Prompt "accelerator_threshold" -Current $config.accelerator_threshold -Min 100 -Max 500000
            if ($null -ne $newValue) {
                $config.accelerator_threshold = $newValue
                Save-Config -Config $config
            }
        }
        "4" {
            $newValue = Read-IntegerInRange -Prompt "selection_retry_count" -Current $config.selection_retry_count -Min 1 -Max 50
            if ($null -ne $newValue) {
                $config.selection_retry_count = $newValue
                Save-Config -Config $config
            }
        }
        "5" {
            $newValue = Read-IntegerInRange -Prompt "selection_retry_delay_ms" -Current $config.selection_retry_delay_ms -Min 0 -Max 1000
            if ($null -ne $newValue) {
                $config.selection_retry_delay_ms = $newValue
                Save-Config -Config $config
            }
        }
        "6" {
            $newValue = Read-IntegerInRange -Prompt "large_selection_trust_threshold" -Current $config.large_selection_trust_threshold -Min 1 -Max 500000
            if ($null -ne $newValue) {
                $config.large_selection_trust_threshold = $newValue
                Save-Config -Config $config
            }
        }
        "7" {
            Start-Process explorer.exe $stateRoot
        }
        "8" {
            Write-Host ""
            Write-Host "Install directory : $PSScriptRoot"
            Write-Host "State directory   : $stateRoot"
            Write-Host "Config path       : $configPath"
            Write-Host ""
            Write-Host "Press Enter."
            [void](Read-Host)
        }
        "9" {
            $config = New-DefaultTuneConfig
            Save-Config -Config $config
        }
        "0" {
            break
        }
        default {
            Write-Host "Unknown option. Press Enter."
            [void](Read-Host)
        }
    }
}
