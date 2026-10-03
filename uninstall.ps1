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

function Restore-OptionLine {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [string]$Section,
        [string]$Name,
        [AllowNull()][string]$OriginalLine
    )

    $indices = @(Get-OptionIndices -Lines $Lines -Section $Section -Name $Name)
    if ($indices.Count -eq 0) { return }

    if ($Name -eq 'lua-intf') {
        if ($Lines[$indices[0]] -notmatch '^\s*lua-intf\s*=\s*autoqueue\s*$') {
            return
        }
    }

    if ($Name -eq 'extraintf') {
        $activeIndex = -1
        $activeValue = ''
        for ($index = 0; $index -lt $indices.Count; $index++) {
            if ($Lines[$indices[$index]] -match '^\s*extraintf\s*=(.*)$') {
                $activeIndex = $indices[$index]
                $activeValue = $Matches[1].Trim()
                break
            }
        }
        if ($activeIndex -lt 0) { return }

        $otherInterfaces = @($activeValue -split ',' | ForEach-Object {
            $_.Trim()
        } | Where-Object { $_ -and $_ -ine 'luaintf' })
        if ($otherInterfaces.Count -gt 0) {
            $Lines[$activeIndex] = 'extraintf=' + ($otherInterfaces -join ',')
            for ($index = $indices.Count - 1; $index -ge 0; $index--) {
                if ($indices[$index] -ne $activeIndex) {
                    $Lines.RemoveAt($indices[$index])
                }
            }
            return
        }

        if ($null -eq $OriginalLine -or
            $OriginalLine -match '^\s*extraintf\s*=') {
            for ($index = $indices.Count - 1; $index -ge 0; $index--) {
                $Lines.RemoveAt($indices[$index])
            }
            return
        }
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
    throw 'Close VLC completely before uninstalling Queue-T, then run this script again.'
}

$profileRoot = Join-Path $env:APPDATA 'vlc'
$interfaceDirectory = Join-Path $profileRoot 'lua\intf'
$installedScript = Join-Path $interfaceDirectory 'autoqueue.lua'
$statePath = Join-Path $interfaceDirectory 'autoqueue-install-state.json'
$backupScript = Join-Path $interfaceDirectory 'autoqueue.lua.autoqueue-backup'
$configuration = Join-Path $profileRoot 'vlcrc'

if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    throw 'Queue-T installer state was not found. For a manual installation, remove autoqueue.lua from VLC lua\intf and revert the VLC Lua interface settings yourself.'
}

$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
if (Test-Path -LiteralPath $configuration) {
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in [System.IO.File]::ReadAllLines($configuration)) {
        $lines.Add($line)
    }

    Restore-OptionLine -Lines $lines -Section 'lua' -Name 'lua-intf' `
        -OriginalLine $state.OriginalLuaIntf
    Restore-OptionLine -Lines $lines -Section 'core' -Name 'extraintf' `
        -OriginalLine $state.OriginalExtraIntf

    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($configuration, $lines, $utf8WithoutBom)
}

if ($state.HadPreviousScript -and (Test-Path -LiteralPath $backupScript)) {
    Move-Item -LiteralPath $backupScript -Destination $installedScript -Force
}
elseif (Test-Path -LiteralPath $installedScript) {
    Remove-Item -LiteralPath $installedScript -Force
}

Remove-Item -LiteralPath $statePath -Force
if (Test-Path -LiteralPath $backupScript) {
    Remove-Item -LiteralPath $backupScript -Force
}

Write-Host 'Queue-T was uninstalled. Other VLC extra interfaces were preserved.'
