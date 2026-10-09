param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Install', 'Uninstall')]
    [string]$Action,
    [Parameter(Mandatory = $true)]
    [string]$Package,
    [Parameter(Mandatory = $true)]
    [string]$PrimaryInterface,
    [hashtable]$SourceFiles = @{}
)

$ErrorActionPreference = 'Stop'

function Get-SectionBounds {
    param([System.Collections.Generic.List[string]]$Lines, [string]$Section)
    $start = -1
    $end = $Lines.Count
    for ($index = 0; $index -lt $Lines.Count; $index++) {
        if ($Lines[$index] -match '^\s*\[([^\]]+)\]') {
            if ($start -ge 0) { $end = $index; break }
            if ($Matches[1] -ieq $Section) { $start = $index }
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
        if ($Lines[$index] -match $pattern) { $indices += $index }
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
    $activePattern = '^\s*' + [regex]::Escape($Name) + '\s*='
    foreach ($index in $indices) {
        if ($Lines[$index] -match $activePattern) { return $Lines[$index] }
    }
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
    }
    else {
        $Lines.Insert($bounds.End, $replacement)
    }
}

function Remove-Option {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [string]$Section,
        [string]$Name
    )
    $indices = @(Get-OptionIndices -Lines $Lines -Section $Section -Name $Name)
    for ($index = $indices.Count - 1; $index -ge 0; $index--) {
        $Lines.RemoveAt($indices[$index])
    }
}

function Restore-OptionLine {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [string]$Section,
        [string]$Name,
        [AllowNull()][string]$OriginalLine
    )
    $indices = @(Get-OptionIndices -Lines $Lines -Section $Section -Name $Name)
    if ($null -eq $OriginalLine) {
        for ($index = $indices.Count - 1; $index -ge 0; $index--) {
            $Lines.RemoveAt($indices[$index])
        }
        return
    }
    if ($indices.Count -gt 0) {
        $Lines[$indices[0]] = $OriginalLine
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
        $Lines.Add($OriginalLine)
    }
    else {
        $Lines.Insert($bounds.End, $OriginalLine)
    }
}

function Get-ConfigLines {
    param([string]$Path)
    $lines = New-Object 'System.Collections.Generic.List[string]'
    if (Test-Path -LiteralPath $Path) {
        foreach ($line in [System.IO.File]::ReadAllLines($Path)) { $lines.Add($line) }
    }
    return ,$lines
}

function Write-ConfigLines {
    param([string]$Path, [System.Collections.Generic.List[string]]$Lines)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($Path, $Lines, $encoding)
}

function Set-VlcConfiguration {
    param([string]$Path)
    $lines = Get-ConfigLines -Path $Path
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
    Set-OptionLine -Lines $lines -Section 'lua' -Name 'lua-intf' `
        -Value $PrimaryInterface
    Write-ConfigLines -Path $Path -Lines $lines
}

function Restore-VlcConfiguration {
    param([string]$Path, $State)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $lines = Get-ConfigLines -Path $Path

    $luaLine = Get-OptionLine -Lines $lines -Section 'lua' -Name 'lua-intf'
    if ((Get-ActiveOptionValue -Line $luaLine -Name 'lua-intf') -ne $PrimaryInterface) {
        return
    }
    Restore-OptionLine -Lines $lines -Section 'lua' -Name 'lua-intf' `
        -OriginalLine $State.OriginalLuaIntf

    $extraLine = Get-OptionLine -Lines $lines -Section 'core' -Name 'extraintf'
    $extraValue = Get-ActiveOptionValue -Line $extraLine -Name 'extraintf'
    $interfaces = @($extraValue -split ',' | ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and $_ -ine 'luaintf' })
    $originalExtra = Get-ActiveOptionValue -Line $State.OriginalExtraIntf `
        -Name 'extraintf'
    $originalInterfaces = @($originalExtra -split ',' |
        ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ine 'luaintf' })
    $currentInterfaceSet = (@($interfaces | Sort-Object -Unique) -join ',')
    $originalInterfaceSet = (@($originalInterfaces | Sort-Object -Unique) -join ',')
    $sameInterfaces = $currentInterfaceSet -ceq $originalInterfaceSet
    if ($sameInterfaces) {
        Restore-OptionLine -Lines $lines -Section 'core' -Name 'extraintf' `
            -OriginalLine $State.OriginalExtraIntf
    }
    elseif (@($originalExtra -split ',' |
        Where-Object { $_.Trim() -ieq 'luaintf' }).Count -gt 0) {
        $interfaces += 'luaintf'
        Set-OptionLine -Lines $lines -Section 'core' -Name 'extraintf' `
            -Value (($interfaces | Select-Object -Unique) -join ',')
    }
    elseif ($interfaces.Count -gt 0) {
        Set-OptionLine -Lines $lines -Section 'core' -Name 'extraintf' `
            -Value (($interfaces | Select-Object -Unique) -join ',')
    }

    Write-ConfigLines -Path $Path -Lines $lines
}

$processes = @(Get-Process -Name 'vlc' -ErrorAction SilentlyContinue)
if ($processes.Count -gt 0) {
    throw "Close VLC completely before $($Action.ToLower())ing $Package, then run this script again."
}

$profileRoot = Join-Path $env:APPDATA 'vlc'
$interfaceDirectory = Join-Path $profileRoot 'lua\intf'
$configuration = Join-Path $profileRoot 'vlcrc'
$statePath = Join-Path $interfaceDirectory ($Package + '-install-state.json')
$backupSuffix = '.' + $Package + '-backup'

if ($Action -eq 'Install') {
    if ($SourceFiles.Count -eq 0) { throw 'No Lua source files were provided to the installer.' }
    foreach ($relativePath in $SourceFiles.Keys) {
        if (-not (Test-Path -LiteralPath $SourceFiles[$relativePath] -PathType Leaf)) {
            throw "Required source file was not found: $($SourceFiles[$relativePath])"
        }
    }
    New-Item -ItemType Directory -Path $interfaceDirectory -Force | Out-Null

    if (Test-Path -LiteralPath $statePath) {
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    }
    else {
        $lines = Get-ConfigLines -Path $configuration
        $state = [pscustomobject]@{
            OriginalLuaIntf = Get-OptionLine -Lines $lines -Section 'lua' -Name 'lua-intf'
            OriginalExtraIntf = Get-OptionLine -Lines $lines -Section 'core' -Name 'extraintf'
            Files = @()
        }
    }

    foreach ($relativePath in $SourceFiles.Keys) {
        $record = @($state.Files | Where-Object { $_.Path -eq $relativePath })
        if ($record.Count -eq 0) {
            $target = Join-Path $interfaceDirectory $relativePath
            $state.Files += [pscustomobject]@{
                Path = $relativePath
                HadPrevious = Test-Path -LiteralPath $target -PathType Leaf
            }
        }
    }
    $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath -Encoding UTF8

    foreach ($relativePath in $SourceFiles.Keys) {
        $target = Join-Path $interfaceDirectory $relativePath
        $targetDirectory = Split-Path -Parent $target
        New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
        $backup = $target + $backupSuffix
        if ((Test-Path -LiteralPath $target -PathType Leaf) -and
            -not (Test-Path -LiteralPath $backup -PathType Leaf)) {
            Copy-Item -LiteralPath $target -Destination $backup
        }
        Copy-Item -LiteralPath $SourceFiles[$relativePath] -Destination $target -Force
    }
    Set-VlcConfiguration -Path $configuration
    Write-Host "$Package was installed for this Windows user. Start VLC to load it."
}
else {
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        throw "$Package installer state was not found. No files or VLC settings were changed."
    }
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    Restore-VlcConfiguration -Path $configuration -State $state
    foreach ($file in $state.Files) {
        $target = Join-Path $interfaceDirectory $file.Path
        $backup = $target + $backupSuffix
        if ($file.HadPrevious -and (Test-Path -LiteralPath $backup -PathType Leaf)) {
            Move-Item -LiteralPath $backup -Destination $target -Force
        }
        elseif (Test-Path -LiteralPath $target -PathType Leaf) {
            Remove-Item -LiteralPath $target -Force
        }
        if (Test-Path -LiteralPath $backup -PathType Leaf) {
            Remove-Item -LiteralPath $backup -Force
        }
    }
    Remove-Item -LiteralPath $statePath -Force
    Write-Host "$Package was uninstalled. Other VLC extra interfaces were preserved."
}
