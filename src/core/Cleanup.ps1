# Disk cleanup: estimate first, clean, report the space actually freed.

function Get-TwCleanupTarget {
    <#
    .SYNOPSIS
        Cleanup targets with their folders. Names come from config/lang (cleanup.<id>).
    #>
    [CmdletBinding()]
    param()
    $win = $env:SystemRoot
    @(
        [pscustomobject]@{ Id = 'temp'; Risk = 'safe'; Paths = @($env:TEMP, (Join-Path $win 'Temp')); Measurable = $true }
        [pscustomobject]@{ Id = 'wucache'; Risk = 'safe'; Paths = @((Join-Path $win 'SoftwareDistribution\Download')); Measurable = $true }
        [pscustomobject]@{ Id = 'docache'; Risk = 'safe'; Paths = @((Join-Path $win 'ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache')); Measurable = $true }
        [pscustomobject]@{ Id = 'thumbcache'; Risk = 'safe'; Paths = @((Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer')); Measurable = $true }
        [pscustomobject]@{ Id = 'recyclebin'; Risk = 'moderate'; Paths = @(); Measurable = $true }
        [pscustomobject]@{ Id = 'dism'; Risk = 'safe'; Paths = @(); Measurable = $false }
        [pscustomobject]@{ Id = 'dismresetbase'; Risk = 'advanced'; Paths = @(); Measurable = $false }
    )
}

function Get-TwCleanupFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Target)
    $cutoff = (Get-Date).AddHours(-24)
    foreach ($p in $Target.Paths) {
        if (-not $p -or -not (Test-Path -LiteralPath $p)) { continue }
        if ($Target.Id -eq 'thumbcache') {
            Get-ChildItem -LiteralPath $p -Filter 'thumbcache_*.db' -File -Force -ErrorAction SilentlyContinue
            Get-ChildItem -LiteralPath $p -Filter 'iconcache_*.db' -File -Force -ErrorAction SilentlyContinue
        } elseif ($Target.Id -eq 'temp') {
            # Files younger than a day may belong to running installers: leave them.
            Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cutoff }
        } else {
            Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue
        }
    }
}

function Measure-TwCleanupTarget {
    <#
    .SYNOPSIS
        Estimated bytes that cleaning a target would free ($null = cannot estimate).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id)
    $t = Get-TwCleanupTarget | Where-Object Id -eq $Id
    if (-not $t -or -not $t.Measurable) { return $null }
    if ($Id -eq 'recyclebin') {
        $total = [int64]0
        try {
            $shell = New-Object -ComObject Shell.Application
            foreach ($item in @($shell.Namespace(10).Items())) { $total += [int64]$item.Size }
        } catch { return $null }
        return $total
    }
    $sum = (Get-TwCleanupFile -Target $t | Measure-Object -Property Length -Sum).Sum
    if (-not $sum) { return [int64]0 }
    return [int64]$sum
}

function Invoke-TwCleanup {
    <#
    .SYNOPSIS
        Cleans one target and returns bytes freed (measured before and after).
    .EXAMPLE
        Invoke-TwCleanup -Id temp -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param([Parameter(Mandatory)][ValidateSet('temp', 'wucache', 'docache', 'thumbcache', 'recyclebin', 'dism', 'dismresetbase')][string]$Id)
    $t = Get-TwCleanupTarget | Where-Object Id -eq $Id
    $before = Measure-TwCleanupTarget -Id $Id
    $freeBefore = (Get-PSDrive -Name $env:SystemDrive.TrimEnd(':')).Free
    if (-not $PSCmdlet.ShouldProcess("cleanup $Id", 'Delete files')) {
        return [pscustomobject]@{ Id = $Id; Status = 'WhatIf'; Estimated = $before; Freed = 0; Message = '' }
    }
    $failedFiles = 0
    switch ($Id) {
        'recyclebin' { Clear-RecycleBin -Force -ErrorAction SilentlyContinue }
        'docache' {
            if (Get-Command -Name Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) {
                Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue
            }
        }
        'dism' { $null = Invoke-TwNativeCommand -FilePath 'dism.exe' -ArgumentList '/Online', '/Cleanup-Image', '/StartComponentCleanup' }
        'dismresetbase' { $null = Invoke-TwNativeCommand -FilePath 'dism.exe' -ArgumentList '/Online', '/Cleanup-Image', '/StartComponentCleanup', '/ResetBase' }
        'wucache' {
            $stopped = @()
            foreach ($svc in 'wuauserv', 'bits') {
                $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
                if ($s -and $s.Status -eq 'Running') { Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue; $stopped += $svc }
            }
            try {
                foreach ($f in Get-TwCleanupFile -Target $t) { try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop } catch { $failedFiles++ } }
            } finally {
                foreach ($svc in $stopped) { Start-Service -Name $svc -ErrorAction SilentlyContinue }
            }
        }
        default {
            foreach ($f in Get-TwCleanupFile -Target $t) { try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop } catch { $failedFiles++ } }
        }
    }
    $freed = [int64]((Get-PSDrive -Name $env:SystemDrive.TrimEnd(':')).Free - $freeBefore)
    if ($freed -lt 0) { $freed = 0 }
    $msg = ''
    if ($failedFiles -gt 0) { $msg = "$failedFiles file(s) in use were skipped" }
    Write-TwLog -Level Success -Message ("Cleanup {0}: freed {1:N1} MB {2}" -f $Id, ($freed / 1MB), $msg)
    return [pscustomobject]@{ Id = $Id; Status = 'Success'; Estimated = $before; Freed = $freed; Message = $msg }
}

function Format-TwSize {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()]$Bytes)
    if ($null -eq $Bytes) { return '?' }
    $b = [double]$Bytes
    if ($b -ge 1GB) { return '{0:N1} GB' -f ($b / 1GB) }
    if ($b -ge 1MB) { return '{0:N1} MB' -f ($b / 1MB) }
    if ($b -ge 1KB) { return '{0:N0} KB' -f ($b / 1KB) }
    return '{0:N0} B' -f $b
}
