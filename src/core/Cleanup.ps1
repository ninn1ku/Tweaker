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

function Invoke-TwFolderSweep {
    <#
    .SYNOPSIS
        Walks a folder once and measures (or, with -Delete, deletes) its files.
    .DESCRIPTION
        Uses plain .NET calls instead of Get-ChildItem/Remove-Item per file: on folders with
        tens of thousands of files that is the difference between seconds and many minutes.
        Junctions and symbolic links are never followed, so nothing outside Path is touched.
        With -Delete, folders that end up empty are removed too (deepest first); the root
        folder itself always stays.
    .OUTPUTS
        Object with Bytes and Files (measured or actually deleted) and Failed (files in use
        or without access).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Include = @('*'),
        [switch]$NoRecurse,
        [Nullable[datetime]]$OlderThan,
        [switch]$Delete
    )
    $bytes = [int64]0
    $count = 0
    $failed = 0
    $root = New-Object System.IO.DirectoryInfo $Path
    if (-not $root.Exists) { return [pscustomobject]@{ Bytes = $bytes; Files = $count; Failed = $failed } }
    $reparse = [System.IO.FileAttributes]::ReparsePoint
    $stack = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $visited = New-Object 'System.Collections.Generic.List[System.IO.DirectoryInfo]'
    $stack.Push($root)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        if ($dir.FullName -ne $root.FullName) { $visited.Add($dir) }
        foreach ($pattern in $Include) {
            try { $files = $dir.GetFiles($pattern) } catch { $failed++; continue }
            foreach ($f in $files) {
                if ($OlderThan -and $f.LastWriteTime -ge $OlderThan) { continue }
                # Read the size first: clearing ReadOnly drops FileInfo's cached state.
                $len = $f.Length
                if ($Delete) {
                    try {
                        if ($f.IsReadOnly) { $f.IsReadOnly = $false }
                        $f.Delete()
                    } catch { $failed++; continue }
                }
                $bytes += $len
                $count++
            }
        }
        if ($NoRecurse) { continue }
        try { $subs = $dir.GetDirectories() } catch { continue }
        foreach ($s in $subs) {
            if (($s.Attributes -band $reparse) -eq 0) { $stack.Push($s) }
        }
    }
    if ($Delete) {
        # Pre-order walk: a parent is always listed before its children, so walking the
        # list backwards empties children first. Delete($false) refuses non-empty folders.
        for ($i = $visited.Count - 1; $i -ge 0; $i--) {
            $d = $visited[$i]
            if ($OlderThan -and $d.LastWriteTime -ge $OlderThan) { continue }
            try { $d.Delete($false) } catch { $null = $_ }
        }
    }
    [pscustomobject]@{ Bytes = $bytes; Files = $count; Failed = $failed }
}

function Invoke-TwCleanupSweep {
    <#
    .SYNOPSIS
        Measures or cleans all folders of a cleanup target in a single pass per folder.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Target, [switch]$Delete)
    $bytes = [int64]0
    $count = 0
    $failed = 0
    foreach ($p in $Target.Paths) {
        if (-not $p) { continue }
        $sweep = @{ Path = $p; Delete = $Delete }
        if ($Target.Id -eq 'thumbcache') {
            $sweep.Include = @('thumbcache_*.db', 'iconcache_*.db')
            $sweep.NoRecurse = $true
        } elseif ($Target.Id -eq 'temp') {
            # Files younger than a day may belong to running installers: leave them.
            $sweep.OlderThan = (Get-Date).AddHours(-24)
        }
        $r = Invoke-TwFolderSweep @sweep
        $bytes += $r.Bytes
        $count += $r.Files
        $failed += $r.Failed
    }
    [pscustomobject]@{ Bytes = $bytes; Files = $count; Failed = $failed }
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
    return [int64](Invoke-TwCleanupSweep -Target $t).Bytes
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
    if (-not $PSCmdlet.ShouldProcess("cleanup $Id", 'Delete files')) {
        $estimate = Measure-TwCleanupTarget -Id $Id
        return [pscustomobject]@{ Id = $Id; Status = 'WhatIf'; Estimated = $estimate; Freed = 0; Message = '' }
    }
    # No separate measuring pass before cleaning: file targets count the bytes they
    # actually delete; the rest compare free space on the system drive.
    $freeBefore = (Get-PSDrive -Name $env:SystemDrive.TrimEnd(':')).Free
    $failedFiles = 0
    $deletedBytes = $null
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
                $r = Invoke-TwCleanupSweep -Target $t -Delete
                $failedFiles = $r.Failed
                $deletedBytes = $r.Bytes
            } finally {
                foreach ($svc in $stopped) { Start-Service -Name $svc -ErrorAction SilentlyContinue }
            }
        }
        default {
            $r = Invoke-TwCleanupSweep -Target $t -Delete
            $failedFiles = $r.Failed
            $deletedBytes = $r.Bytes
        }
    }
    if ($null -ne $deletedBytes) {
        $freed = [int64]$deletedBytes
    } else {
        $freed = [int64]((Get-PSDrive -Name $env:SystemDrive.TrimEnd(':')).Free - $freeBefore)
    }
    if ($freed -lt 0) { $freed = 0 }
    $msg = ''
    if ($failedFiles -gt 0) { $msg = "$failedFiles file(s) in use were skipped" }
    Write-TwLog -Level Success -Message ("Cleanup {0}: freed {1:N1} MB {2}" -f $Id, ($freed / 1MB), $msg)
    return [pscustomobject]@{ Id = $Id; Status = 'Success'; Estimated = $null; Freed = $freed; Message = $msg }
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
