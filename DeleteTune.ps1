param(
    [switch]$ShowPathOnly
)

[Console]::InputEncoding = [Text.UTF8Encoding]::UTF8
[Console]::OutputEncoding = [Text.UTF8Encoding]::UTF8

$stateRoot = Join-Path $env:LOCALAPPDATA "NuclearDeleteContext"
$configPath = Join-Path $stateRoot "DeleteTune.json"
$repoDefaultPath = Join-Path $PSScriptRoot "DeleteTune.json"

function New-DefaultTuneConfig {
    return [ordered]@{
        debug_mode                      = $false
        accelerator_enabled             = $true
        accelerator_threshold           = 2000
        selection_retry_count           = 10
        selection_retry_delay_ms        = 45
        large_selection_trust_threshold = 1000
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

function Read-LineWithEscape {
    param(
        [string]$PromptText,
        [ConsoleColor]$PromptColor = [ConsoleColor]::Gray
    )

    Write-Host -NoNewline ($PromptText + ": ") -ForegroundColor $PromptColor
    $buffer = New-Object System.Text.StringBuilder
    while ($true) {
        $keyInfo = [Console]::ReadKey($true)
        switch ($keyInfo.Key) {
            "Escape" {
                Write-Host ""
                return [pscustomobject]@{
                    Cancelled = $true
                    Text      = [string]$buffer.ToString()
                }
            }
            "Enter" {
                Write-Host ""
                return [pscustomobject]@{
                    Cancelled = $false
                    Text      = [string]$buffer.ToString()
                }
            }
            "Backspace" {
                if ($buffer.Length -gt 0) {
                    [void]$buffer.Remove($buffer.Length - 1, 1)
                    Write-Host "`b `b" -NoNewline
                }
            }
            default {
                if ($keyInfo.KeyChar -ne [char]0) {
                    [void]$buffer.Append($keyInfo.KeyChar)
                    Write-Host $keyInfo.KeyChar -NoNewline
                }
            }
        }
    }
}

function Read-IntegerWithEscape {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PromptText,
        [Parameter(Mandatory = $true)]
        [int]$CurrentValue,
        [Parameter(Mandatory = $true)]
        [int]$Min,
        [Parameter(Mandatory = $true)]
        [int]$Max
    )

    while ($true) {
        $line = Read-LineWithEscape -PromptText ("{0} [{1}] (blank=keep, ESC=back)" -f $PromptText, $CurrentValue)
        if ($line.Cancelled) {
            return [pscustomobject]@{
                Cancelled = $true
                Value     = $CurrentValue
            }
        }

        $text = $line.Text
        if ([string]::IsNullOrWhiteSpace($text)) {
            return [pscustomobject]@{
                Cancelled = $false
                Value     = $CurrentValue
            }
        }

        $parsed = 0
        if (-not [int]::TryParse($text, [ref]$parsed)) {
            Write-Host "Invalid integer. Use $Min..$Max." -ForegroundColor Red
            Start-Sleep -Milliseconds 700
            continue
        }

        if ($parsed -lt $Min -or $parsed -gt $Max) {
            Write-Host "Out of range ($Min-$Max)." -ForegroundColor Red
            Start-Sleep -Milliseconds 700
            continue
        }

        return [pscustomobject]@{
            Cancelled = $false
            Value     = $parsed
        }
    }
}

function Write-StatePair {
    param(
        [string]$Name,
        [bool]$Value,
        [switch]$First
    )

    if (-not $First) { Write-Host " | " -NoNewline -ForegroundColor Yellow }
    Write-Host -NoNewline ($Name + "=") -ForegroundColor Cyan
    if ($Value) {
        Write-Host -NoNewline "True" -ForegroundColor Green
    }
    else {
        Write-Host -NoNewline "False" -ForegroundColor Red
    }
}

function Write-TunePair {
    param(
        [string]$Name,
        [int]$Value,
        [switch]$First
    )

    if (-not $First) { Write-Host " | " -NoNewline -ForegroundColor Yellow }
    Write-Host -NoNewline ($Name + "=") -ForegroundColor Cyan
    Write-Host -NoNewline ([string]$Value) -ForegroundColor Green
}

function Write-MenuLine {
    param(
        [string]$Number,
        [string]$Prefix,
        [string]$Highlight,
        [string]$Suffix,
        [ConsoleColor]$HighlightColor = [ConsoleColor]::Cyan
    )

    Write-Host ($Number + ". ") -NoNewline -ForegroundColor Gray
    if ($Prefix) { Write-Host $Prefix -NoNewline -ForegroundColor Gray }
    Write-Host $Highlight -NoNewline -ForegroundColor $HighlightColor
    if ($Suffix) { Write-Host $Suffix -ForegroundColor Gray } else { Write-Host "" }
}

function Show-HowToUse {
    Write-Host ""
    Write-Host "=== How To Use ===" -ForegroundColor Cyan
    Write-Host "1. Toggle debug mode" -ForegroundColor Gray
    Write-Host "   - Writes runtime trace to NuclearDelete.debug.log." -ForegroundColor Gray
    Write-Host "2. Toggle accelerator mode" -ForegroundColor Gray
    Write-Host "   - Enables/disables C# delete accelerator path." -ForegroundColor Gray
    Write-Host "3. Set accelerator threshold" -ForegroundColor Gray
    Write-Host "   - Minimum target count before C# accelerator starts." -ForegroundColor Gray
    Write-Host "4. Set selection retry count" -ForegroundColor Gray
    Write-Host "   - Number of selection polling attempts." -ForegroundColor Gray
    Write-Host "5. Set selection retry delay (ms)" -ForegroundColor Gray
    Write-Host "   - Delay between selection attempts." -ForegroundColor Gray
    Write-Host "6. Set large selection trust threshold" -ForegroundColor Gray
    Write-Host "   - Early accept target count for large selections." -ForegroundColor Gray
    Write-Host "7. Open state directory" -ForegroundColor Gray
    Write-Host "8. Install / Update NuclearDelete" -ForegroundColor Gray
    Write-Host "9. Show installation/state paths" -ForegroundColor Gray
    Write-Host "0. Reset defaults" -ForegroundColor Gray
    Write-Host "H. How to use" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Global: every change is saved immediately." -ForegroundColor Green
    Write-Host "Press any key to return..." -ForegroundColor DarkCyan
    [Console]::ReadKey($true) | Out-Null
}

function Launch-Installer {
    $installerPath = Join-Path $PSScriptRoot 'Install.ps1'
    if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
        Write-Host "Install.ps1 not found: $installerPath" -ForegroundColor Red
        Start-Sleep -Milliseconds 900
        return
    }

    Start-Process pwsh.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installerPath)
}

if ($ShowPathOnly) {
    $null = Load-Config
    Write-Output $configPath
    exit 0
}

$config = Load-Config

while ($true) {
    Clear-Host
    $debugMode = [bool]$config.debug_mode
    $acceleratorEnabled = [bool]$config.accelerator_enabled
    $acceleratorThreshold = [int]$config.accelerator_threshold
    $retryCount = [int]$config.selection_retry_count
    $retryDelay = [int]$config.selection_retry_delay_ms
    $trustThreshold = [int]$config.large_selection_trust_threshold

    Write-Host ""
    Write-Host "=== DeleteTune Menu ===" -ForegroundColor Green
    Write-Host "MODES : [ " -NoNewline -ForegroundColor Yellow
    Write-StatePair -Name "debug" -Value $debugMode -First
    Write-StatePair -Name "accelerator" -Value $acceleratorEnabled
    Write-Host " ]" -ForegroundColor Yellow
    Write-Host "TUNE  : [ " -NoNewline -ForegroundColor Yellow
    Write-TunePair -Name "threshold" -Value $acceleratorThreshold -First
    Write-TunePair -Name "retry_count" -Value $retryCount
    Write-TunePair -Name "retry_delay_ms" -Value $retryDelay
    Write-TunePair -Name "trust_threshold" -Value $trustThreshold
    Write-Host " ]" -ForegroundColor Yellow
    Write-Host "PATH  : " -NoNewline -ForegroundColor Yellow
    Write-Host $configPath -ForegroundColor Green

    Write-MenuLine -Number "1" -Prefix "Toggle " -Highlight "debug" -Suffix " mode" -HighlightColor Red
    Write-MenuLine -Number "2" -Prefix "Toggle " -Highlight "accelerator" -Suffix " mode" -HighlightColor Green
    Write-MenuLine -Number "3" -Prefix "Set accelerator " -Highlight "threshold" -Suffix "" -HighlightColor Green
    Write-MenuLine -Number "4" -Prefix "Set selection retry " -Highlight "count" -Suffix "" -HighlightColor Green
    Write-MenuLine -Number "5" -Prefix "Set selection retry " -Highlight "delay_ms" -Suffix "" -HighlightColor Green
    Write-MenuLine -Number "6" -Prefix "Set large selection trust " -Highlight "threshold" -Suffix "" -HighlightColor Green
    Write-MenuLine -Number "7" -Prefix "" -Highlight "Open state directory" -Suffix "" -HighlightColor Cyan
    Write-MenuLine -Number "8" -Prefix "Install / Update " -Highlight "NuclearDelete" -Suffix "" -HighlightColor Cyan
    Write-MenuLine -Number "9" -Prefix "Show install/state " -Highlight "paths" -Suffix "" -HighlightColor Cyan
    Write-MenuLine -Number "0" -Prefix "" -Highlight "Reset defaults" -Suffix "" -HighlightColor Yellow
    Write-Host "[H] " -NoNewline -ForegroundColor Yellow
    Write-Host "How to use" -ForegroundColor Cyan
    Write-Host "[Esc] " -NoNewline -ForegroundColor Yellow
    Write-Host "Exit" -ForegroundColor Red

    Write-Host -NoNewline "Select option: "
    $keyInfo = [Console]::ReadKey($true)
    Write-Host ""

    $choice = $null
    switch ($keyInfo.Key) {
        "D0" { $choice = "0" }
        "NumPad0" { $choice = "0" }
        "D1" { $choice = "1" }
        "NumPad1" { $choice = "1" }
        "D2" { $choice = "2" }
        "NumPad2" { $choice = "2" }
        "D3" { $choice = "3" }
        "NumPad3" { $choice = "3" }
        "D4" { $choice = "4" }
        "NumPad4" { $choice = "4" }
        "D5" { $choice = "5" }
        "NumPad5" { $choice = "5" }
        "D6" { $choice = "6" }
        "NumPad6" { $choice = "6" }
        "D7" { $choice = "7" }
        "NumPad7" { $choice = "7" }
        "D8" { $choice = "8" }
        "NumPad8" { $choice = "8" }
        "D9" { $choice = "9" }
        "NumPad9" { $choice = "9" }
        "H" { $choice = "H" }
        "Escape" {
            Write-Host "Exit." -ForegroundColor Yellow
            return
        }
        default {
            Write-Host "Invalid option." -ForegroundColor Red
            Start-Sleep -Milliseconds 700
            continue
        }
    }

    switch ($choice) {
        "1" {
            $config.debug_mode = -not [bool]$config.debug_mode
            Save-Config -Config $config
        }
        "2" {
            $config.accelerator_enabled = -not [bool]$config.accelerator_enabled
            Save-Config -Config $config
        }
        "3" {
            $result = Read-IntegerWithEscape -PromptText "accelerator_threshold" -CurrentValue ([int]$config.accelerator_threshold) -Min 100 -Max 500000
            if (-not $result.Cancelled) {
                $config.accelerator_threshold = [int]$result.Value
                Save-Config -Config $config
            }
        }
        "4" {
            $result = Read-IntegerWithEscape -PromptText "selection_retry_count" -CurrentValue ([int]$config.selection_retry_count) -Min 1 -Max 50
            if (-not $result.Cancelled) {
                $config.selection_retry_count = [int]$result.Value
                Save-Config -Config $config
            }
        }
        "5" {
            $result = Read-IntegerWithEscape -PromptText "selection_retry_delay_ms" -CurrentValue ([int]$config.selection_retry_delay_ms) -Min 0 -Max 1000
            if (-not $result.Cancelled) {
                $config.selection_retry_delay_ms = [int]$result.Value
                Save-Config -Config $config
            }
        }
        "6" {
            $result = Read-IntegerWithEscape -PromptText "large_selection_trust_threshold" -CurrentValue ([int]$config.large_selection_trust_threshold) -Min 1 -Max 500000
            if (-not $result.Cancelled) {
                $config.large_selection_trust_threshold = [int]$result.Value
                Save-Config -Config $config
            }
        }
        "7" {
            if (-not (Test-Path -LiteralPath $stateRoot -PathType Container)) {
                New-Item -Path $stateRoot -ItemType Directory -Force | Out-Null
            }
            Start-Process explorer.exe $stateRoot
        }
        "8" {
            Launch-Installer
        }
        "9" {
            Write-Host ""
            Write-Host "Install directory : $PSScriptRoot" -ForegroundColor Gray
            Write-Host "State directory   : $stateRoot" -ForegroundColor Gray
            Write-Host "Config path       : $configPath" -ForegroundColor Gray
            Write-Host ""
            Write-Host "Press any key to return..." -ForegroundColor DarkCyan
            [Console]::ReadKey($true) | Out-Null
        }
        "H" {
            Show-HowToUse
        }
        "0" {
            $config = New-DefaultTuneConfig
            Save-Config -Config $config
            Write-Host "Defaults restored." -ForegroundColor Green
            Start-Sleep -Milliseconds 700
        }
    }
}
