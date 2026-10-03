$ErrorActionPreference = 'Stop'

function Get-SectionBounds {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [string]$Section
    )

    $start = -1
    $end = $Lines.Count
    for ($index = 0; $index -lt $Lines.Count; $index++) {
        if ($Lines[$index] -match '^\s*\[([^\]]+)\]') {
            if ($start -ge 0) {
                $end = $index
                break
            }
            if ($Matches[1] -ieq $Section) {
                $start = $index
            }
        }
    }

    return @{ Start = $start; End = $end }
}

function Get-OptionIndices {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [string]$Section,
        [string]$Name
    )

    $bounds = Get-SectionBounds -Lines $Lines -Section $Section
    if ($bounds.Start -lt 0) { return @() }

    $indices = @()
    $pattern = '^\s*#?\s*' + [regex]::Escape($Name) + '\s*='
    for ($index = $bounds.Start + 1; $index -lt $bounds.End; $index++) {
        if ($Lines[$index] -match $pattern) {
            $indices += $index
        }
    }
    return $indices
}

function Get-OptionLine {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [string]$Section,
        [string]$Name
    )

    $indices = @(Get-OptionIndices -Lines $Lines -Section $Section -Name $Name)
    if ($indices.Count -eq 0) { return $null }
    return $Lines[$indices[0]]
}

function Get-ActiveOptionValue {
    param([string]$Line, [string]$Name)

    if ($Line -and $Line -match ('^\s*' + [regex]::Escape($Name) + '\s*=(.*)$')) {
        return $Matches[1].Trim()
    }
    return ''
}

function Set-OptionLine {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [string]$Section,
        [string]$Name,
        [string]$Value
    )

    $replacement = $Name + '=' + $Value
    $indices = @(Get-OptionIndices -Lines $Lines -Section $Section -Name $Name)
    if ($indices.Count -gt 0) {
        $Lines[$indices[0]] = $replacement
        for ($index = $indices.Count - 1; $index -ge 1; $index--) {
            $Lines.RemoveAt($indices[$index])
        }
        return
    }

    $bounds = Get-SectionBounds -Lines $Lines -Section $Section
    if ($bounds.Start -lt 0) {
        if ($Lines.Count -gt 0 -and $Lines[$Lines.Count - 1] -ne '') {
            $Lines.Add('')
        }
        $Lines.Add('[' + $Section + ']')
        $Lines.Add($replacement)
        return
    }

    $Lines.Insert($bounds.End, $replacement)
}

function Restore-OptionLine {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [string]$Section,
        [string]$Name,
        [AllowNull()][string]$OriginalLine
    )

    $indices = @(Get-OptionIndices -Lines $Lines -Section $Section -Name $Name)
    if ($indices.Count -eq 0) {
        if ($null -ne $OriginalLine) {
            Set-OptionLine -Lines $Lines -Section $Section -Name $Name `
                -Value (Get-ActiveOptionValue -Line $OriginalLine -Name $Name)
        }
        return
    }

    if ($null -ne $OriginalLine) {
        $Lines[$indices[0]] = $OriginalLine
        for ($index = $indices.Count - 1; $index -ge 1; $index--) {
            $Lines.RemoveAt($indices[$index])
        }
    }
    else {
        for ($index = $indices.Count - 1; $index -ge 0; $index--) {
            $Lines.RemoveAt($indices[$index])
        }
    }
}

$processes = @(Get-Process -Name 'vlc' -ErrorAction SilentlyContinue)
if ($processes.Count -gt 0) {
    throw 'Close VLC completely before installing Queue-T, then run this installer again.'
}

$source = Join-Path $PSScriptRoot 'autoqueue.lua'
if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
    throw 'autoqueue.lua was not found beside install.ps1. Extract the complete project before installing.'
}

$profileRoot = Join-Path $env:APPDATA 'vlc'
$interfaceDirectory = Join-Path $profileRoot 'lua\intf'
$installedScript = Join-Path $interfaceDirectory 'autoqueue.lua'
$statePath = Join-Path $interfaceDirectory 'autoqueue-install-state.json'
$backupScript = Join-Path $interfaceDirectory 'autoqueue.lua.autoqueue-backup'
$configuration = Join-Path $profileRoot 'vlcrc'

New-Item -ItemType Directory -Path $interfaceDirectory -Force | Out-Null

if (Test-Path -LiteralPath $statePath) {
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
}
else {
    $lines = New-Object 'System.Collections.Generic.List[string]'
    if (Test-Path -LiteralPath $configuration) {
        foreach ($line in [System.IO.File]::ReadAllLines($configuration)) {
            $lines.Add($line)
        }
    }

    $originalLuaLine = Get-OptionLine -Lines $lines -Section 'lua' -Name 'lua-intf'
    if ((Get-ActiveOptionValue -Line $originalLuaLine -Name 'lua-intf') -eq 'autoqueue') {
        $originalLuaLine = $null
    }

    $originalExtraLine = Get-OptionLine -Lines $lines -Section 'core' -Name 'extraintf'
    $extraValue = Get-ActiveOptionValue -Line $originalExtraLine -Name 'extraintf'
    if ($extraValue) {
        $otherInterfaces = @($extraValue -split ',' | ForEach-Object {
            $_.Trim()
        } | Where-Object { $_ -and $_ -ine 'luaintf' })
        if ($otherInterfaces.Count -ne @($extraValue -split ',' | Where-Object {
            $_.Trim()
        }).Count) {
            $originalExtraLine = if ($otherInterfaces.Count -gt 0) {
                'extraintf=' + ($otherInterfaces -join ',')
            }
            else {
                $null
            }
        }
    }

    $hadPreviousScript = Test-Path -LiteralPath $installedScript -PathType Leaf
    if ($hadPreviousScript -and -not (Test-Path -LiteralPath $backupScript)) {
        Copy-Item -LiteralPath $installedScript -Destination $backupScript
    }

    $state = [pscustomobject]@{
        OriginalLuaIntf = $originalLuaLine
        OriginalExtraIntf = $originalExtraLine
        HadPreviousScript = $hadPreviousScript
    }
    $state | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
}

Copy-Item -LiteralPath $source -Destination $installedScript -Force

$lines = New-Object 'System.Collections.Generic.List[string]'
if (Test-Path -LiteralPath $configuration) {
    foreach ($line in [System.IO.File]::ReadAllLines($configuration)) {
        $lines.Add($line)
    }
}

$extraValue = Get-ActiveOptionValue `
    -Line (Get-OptionLine -Lines $lines -Section 'core' -Name 'extraintf') `
    -Name 'extraintf'
$interfaces = @($extraValue -split ',' | ForEach-Object { $_.Trim() } |
    Where-Object { $_ })
if (@($interfaces | Where-Object { $_ -ieq 'luaintf' }).Count -eq 0) {
    $interfaces += 'luaintf'
}

Set-OptionLine -Lines $lines -Section 'core' -Name 'extraintf' `
    -Value ($interfaces -join ',')
Set-OptionLine -Lines $lines -Section 'lua' -Name 'lua-intf' -Value 'autoqueue'

$utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllLines($configuration, $lines, $utf8WithoutBom)

Write-Host 'Queue-T was installed for this Windows user.'
Write-Host 'Start VLC to load it. Open an episode to queue later matching episodes.'
