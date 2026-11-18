# Tweak catalog loading, apply / undo of single tweaks and batches.

function Import-TwTweakCatalog {
    <#
    .SYNOPSIS
        Loads and validates config/tweaks/*.json.
    .DESCRIPTION
        Every file is validated against config/schema/tweaks.schema.json. Invalid
        tweaks and duplicate ids are logged and skipped, never applied.
    .PARAMETER Force
        Reload even if the catalog is cached.
    .EXAMPLE
        Import-TwTweakCatalog | Measure-Object
    #>
    [CmdletBinding()]
    param([switch]$Force)
    $ctx = Get-TwContext
    if ($ctx.Tweaks -and -not $Force) { return $ctx.Tweaks }
    $schema = Get-TwJsonResource -Path 'config/schema/tweaks.schema.json'
    $list = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($res in Get-TwResourceList -Folder 'config/tweaks') {
        try { $doc = Get-TwJsonResource -Path $res } catch {
            Write-TwLog -Level Error -Message "Cannot parse ${res}: $($_.Exception.Message)"
            continue
        }
        $tweakSchema = Get-TwObjectProperty (Get-TwObjectProperty $schema 'definitions') 'tweak'
        foreach ($t in @(Get-TwObjectProperty $doc 'tweaks' @())) {
            $errors = @(Test-TwJsonSchema -InputObject $t -Schema $tweakSchema -Root $schema -Path "$res#$(Get-TwObjectProperty $t 'id')")
            if ($errors.Count -gt 0) {
                Write-TwLog -Level Error -Message ("Invalid tweak skipped: " + ($errors -join '; '))
                continue
            }
            if ($seen.ContainsKey($t.id)) {
                Write-TwLog -Level Error -Message "Duplicate tweak id skipped: $($t.id) in $res"
                continue
            }
            $seen[$t.id] = $true
            [void]$list.Add($t)
        }
    }
    $ctx.Tweaks = $list.ToArray()
    return $ctx.Tweaks
}

function Get-TwTweak {
    <#
    .SYNOPSIS
        Returns tweaks from the catalog.
    .PARAMETER Id
        One or more ids (wildcards allowed).
    .PARAMETER Category
        Category id filter.
    .PARAMETER SupportedOnly
        Hide tweaks that do not apply to the running build.
    .EXAMPLE
        Get-TwTweak -Category privacy
    #>
    [CmdletBinding()]
    param(
        [string[]]$Id,
        [string]$Category,
        [switch]$SupportedOnly
    )
    $all = @(Import-TwTweakCatalog)
    if ($Id) {
        $all = @($all | Where-Object { $t = $_; @($Id | Where-Object { $t.id -like $_ }).Count -gt 0 })
    }
    if ($Category) { $all = @($all | Where-Object { $_.category -eq $Category }) }
    if ($SupportedOnly) { $all = @($all | Where-Object { Test-TwTweakSupported -Tweak $_ }) }
    return $all
}

function New-TwResult {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'In-memory only')]
    param($Tweak, [string]$Action, [string]$Status, [string]$Message = '', [int]$Changes = 0)
    return [pscustomobject]@{
        Id                      = $Tweak.id
        Name                    = (Get-TwLocalizedText $Tweak.name)
        Action                  = $Action
        Status                  = $Status
        Message                 = $Message
        Changes                 = $Changes
        RequiresReboot          = [bool](Get-TwObjectProperty $Tweak 'requiresReboot' $false)
        RequiresExplorerRestart = [bool](Get-TwObjectProperty $Tweak 'requiresExplorerRestart' $false)
        RequiresSignOut         = [bool](Get-TwObjectProperty $Tweak 'requiresSignOut' $false)
    }
}

function Get-TwRegistryUserSidList {
    <#
    .SYNOPSIS
        User hives an HKCU action is written to: the target user, plus the Default
        profile when that option is on.
    #>
    [CmdletBinding()]
    param([string]$Path)
    $ctx = Get-TwContext
    $list = @($ctx.TargetUserSid)
    if ($Path -match '^HKCU:' -and $ctx.IncludeDefaultUser) { $list += 'TweakerDefaultUser' }
    return $list
}

function Invoke-TwTweakApply {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$Tweak)
    $changes = 0
    $id = $Tweak.id

    foreach ($r in @(Get-TwObjectProperty $Tweak 'registry' @())) {
        foreach ($sid in Get-TwRegistryUserSidList -Path $r.path) {
            $provider = ConvertTo-TwRegistryProviderPath -Path $r.path -UserSid $sid
            $cur = Get-TwRegistryValue -Path $provider -Name $r.name
            $want = ConvertTo-TwComparableRegistryValue -Type $r.type -Value $r.value
            $have = if ($cur.Exists) { ConvertTo-TwComparableRegistryValue -Type $r.type -Value $cur.Value } else { '<absent>' }
            if ($cur.Exists -and $cur.Type -eq $r.type -and $want -eq $have) { continue }
            Add-TwBackupEntry -Entry @{
                tweakId = $id; kind = 'registry'; path = $provider; name = $r.name; userSid = $sid
                existed = $cur.Exists; type = $(if ($cur.Exists) { $cur.Type } else { $r.type }); value = $cur.Value
                createdKey = (Get-TwMissingKeyRoot -ProviderPath $provider)
            }
            Set-TwRegistryValue -Path $provider -Name $r.name -Type $r.type -Value $r.value
            Write-TwLog -Message ("[{0}] {1}\{2}: {3} -> {4}" -f $id, $provider, $r.name, $have, $want)
            $changes++
        }
    }

    foreach ($s in @(Get-TwObjectProperty $Tweak 'services' @())) {
        $cur = Get-TwServiceConfig -Name $s.name
        if (-not $cur.Exists) { Write-TwLog -Level Debug -Message "[$id] service $($s.name) not present, skipped"; continue }
        if ($cur.StartupType -eq $s.startupType) { continue }
        $running = $false
        $svc = Get-Service -Name $s.name -ErrorAction SilentlyContinue
        if ($svc) { $running = ([string]$svc.Status -eq 'Running') }
        Add-TwBackupEntry -Entry @{ tweakId = $id; kind = 'service'; name = $s.name; existed = $true; startupType = $cur.StartupType; wasRunning = $running }
        $stop = [bool](Get-TwObjectProperty $s 'stop' $false) -and @('Disabled', 'Manual') -contains $s.startupType
        Set-TwServiceStartup -Name $s.name -StartupType $s.startupType -Stop:$stop
        Write-TwLog -Message ("[{0}] service {1}: {2} -> {3}" -f $id, $s.name, $cur.StartupType, $s.startupType)
        $changes++
    }

    foreach ($t in @(Get-TwObjectProperty $Tweak 'scheduledTasks' @())) {
        $state = Get-TwTaskState -Path $t.path
        if ($state -eq 'Missing') { Write-TwLog -Level Debug -Message "[$id] task $($t.path) not present, skipped"; continue }
        if ($state -eq $t.state) { continue }
        Add-TwBackupEntry -Entry @{ tweakId = $id; kind = 'task'; path = $t.path; state = $state }
        Set-TwTaskState -Path $t.path -State $t.state
        Write-TwLog -Message ("[{0}] task {1}: {2} -> {3}" -f $id, $t.path, $state, $t.state)
        $changes++
    }

    foreach ($f in @(Get-TwObjectProperty $Tweak 'optionalFeatures' @())) {
        $state = Get-TwOptionalFeatureState -Name $f.name
        if (@('Enabled', 'Disabled') -notcontains $state) { throw "Optional feature $($f.name) is not available ($state)" }
        if ($state -eq $f.state) { continue }
        Add-TwBackupEntry -Entry @{ tweakId = $id; kind = 'feature'; name = $f.name; state = $state }
        Set-TwOptionalFeatureState -Name $f.name -State $f.state
        Write-TwLog -Message ("[{0}] feature {1}: {2} -> {3}" -f $id, $f.name, $state, $f.state)
        $changes++
    }

    foreach ($c in @(Get-TwObjectProperty $Tweak 'commands' @())) {
        $cmdArgs = Get-TwObjectProperty $c 'args'
        if (Invoke-TwCommandAction -Name $c.name -Action Detect -Arguments $cmdArgs) { continue }
        $state = Invoke-TwCommandAction -Name $c.name -Action Backup -Arguments $cmdArgs
        Add-TwBackupEntry -Entry @{ tweakId = $id; kind = 'command'; name = $c.name; data = $state }
        Invoke-TwCommandAction -Name $c.name -Action Apply -Arguments $cmdArgs
        Write-TwLog -Message ("[{0}] command {1} applied" -f $id, $c.name)
        $changes++
    }
    return $changes
}

function Invoke-TwTweakUndo {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$Tweak)
    $changes = 0
    $id = $Tweak.id
    $covered = @{}

    # 1. Real original values from backups.
    foreach ($e in Get-TwOriginalEntry -TweakId $id -Tweak $Tweak) {
        Restore-TwBackupEntry -Entry $e
        $covered[(Get-TwBackupTargetKey $e)] = $true
        $changes++
    }

    # 2. No backup for a target: fall back to the documented Windows default ("undo").
    $undo = Get-TwObjectProperty $Tweak 'undo'
    foreach ($r in @(Get-TwObjectProperty $undo 'registry' @())) {
        foreach ($sid in Get-TwRegistryUserSidList -Path $r.path) {
            $provider = ConvertTo-TwRegistryProviderPath -Path $r.path -UserSid $sid
            if ($covered.ContainsKey((Get-TwBackupTargetKey @{ kind = 'registry'; path = $provider; name = $r.name }))) { continue }
            $cur = Get-TwRegistryValue -Path $provider -Name $r.name
            if ([bool](Get-TwObjectProperty $r 'delete' $false)) {
                if (-not $cur.Exists) { continue }
                Remove-TwRegistryValue -Path $provider -Name $r.name
                Write-TwLog -Message ("[{0}] {1}\{2}: deleted (default)" -f $id, $provider, $r.name)
            } else {
                $want = ConvertTo-TwComparableRegistryValue -Type $r.type -Value $r.value
                if ($cur.Exists -and $want -eq (ConvertTo-TwComparableRegistryValue -Type $r.type -Value $cur.Value)) { continue }
                Set-TwRegistryValue -Path $provider -Name $r.name -Type $r.type -Value $r.value
                Write-TwLog -Message ("[{0}] {1}\{2}: -> {3} (default)" -f $id, $provider, $r.name, $want)
            }
            $changes++
        }
    }
    foreach ($k in @(Get-TwObjectProperty $undo 'deleteKeys' @())) {
        foreach ($sid in Get-TwRegistryUserSidList -Path $k) {
            $provider = ConvertTo-TwRegistryProviderPath -Path $k -UserSid $sid
            if (-not (Test-Path -LiteralPath $provider)) { continue }
            Remove-TwRegistryKey -Path $provider
            Write-TwLog -Message ("[{0}] key {1}: deleted (default)" -f $id, $provider)
            $changes++
        }
    }
    foreach ($s in @(Get-TwObjectProperty $undo 'services' @())) {
        if ($covered.ContainsKey(('service|' + $s.name).ToLowerInvariant())) { continue }
        $cur = Get-TwServiceConfig -Name $s.name
        if (-not $cur.Exists -or $cur.StartupType -eq $s.startupType) { continue }
        Set-TwServiceStartup -Name $s.name -StartupType $s.startupType
        Write-TwLog -Message ("[{0}] service {1}: {2} -> {3} (default)" -f $id, $s.name, $cur.StartupType, $s.startupType)
        $changes++
    }
    foreach ($t in @(Get-TwObjectProperty $undo 'scheduledTasks' @())) {
        if ($covered.ContainsKey(('task|' + $t.path).ToLowerInvariant())) { continue }
        $state = Get-TwTaskState -Path $t.path
        if ($state -eq 'Missing' -or $state -eq $t.state) { continue }
        Set-TwTaskState -Path $t.path -State $t.state
        Write-TwLog -Message ("[{0}] task {1}: {2} -> {3} (default)" -f $id, $t.path, $state, $t.state)
        $changes++
    }
    foreach ($f in @(Get-TwObjectProperty $undo 'optionalFeatures' @())) {
        if ($covered.ContainsKey(('feature|' + $f.name).ToLowerInvariant())) { continue }
        $state = Get-TwOptionalFeatureState -Name $f.name
        if (@('Enabled', 'Disabled') -notcontains $state -or $state -eq $f.state) { continue }
        Set-TwOptionalFeatureState -Name $f.name -State $f.state
        Write-TwLog -Message ("[{0}] feature {1}: {2} -> {3} (default)" -f $id, $f.name, $state, $f.state)
        $changes++
    }
    foreach ($c in @(Get-TwObjectProperty $Tweak 'commands' @())) {
        if ($covered.ContainsKey(('command|{0}|{1}' -f $c.name, $id).ToLowerInvariant())) { continue }
        $cmdArgs = Get-TwObjectProperty $c 'args'
        if (-not (Invoke-TwCommandAction -Name $c.name -Action Detect -Arguments $cmdArgs)) { continue }
        Invoke-TwCommandAction -Name $c.name -Action Undo -Arguments $cmdArgs -State $null
        Write-TwLog -Message ("[{0}] command {1} undone (default)" -f $id, $c.name)
        $changes++
    }
    return $changes
}

function Invoke-TwTweak {
    <#
    .SYNOPSIS
        Applies or undoes one tweak and returns a result object.
    .DESCRIPTION
        Never throws: errors become a result with Status = Failed so that one bad
        tweak does not stop a batch. Supports -WhatIf (nothing is changed and no
        backup is written).
    .PARAMETER Tweak
        Tweak definition.
    .PARAMETER Action
        Apply or Undo.
    .EXAMPLE
        Get-TwTweak -Id privacy.disable-telemetry | Invoke-TwTweak -Action Apply -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]$Tweak,
        [ValidateSet('Apply', 'Undo')][string]$Action = 'Apply'
    )
    process {
        $ctx = Get-TwContext
        if ($ctx.ReadOnly) { return (New-TwResult $Tweak $Action 'Skipped' 'ReadOnly') }
        if (-not (Test-TwTweakSupported -Tweak $Tweak)) {
            Write-TwLog -Level Warning -Message "[$($Tweak.id)] skipped: not supported on build $((Get-TwOsInfo).Build)"
            return (New-TwResult $Tweak $Action 'Skipped' 'UnsupportedBuild')
        }
        try {
            if ($Action -eq 'Apply') { $n = Invoke-TwTweakApply -Tweak $Tweak } else { $n = Invoke-TwTweakUndo -Tweak $Tweak }
            $status = 'Success'
            if ($n -eq 0) { $status = 'NoChange' }
            elseif ($WhatIfPreference) { $status = 'WhatIf' }
            if ($status -eq 'Success') { Write-TwLog -Level Success -Message "[$($Tweak.id)] $Action OK ($n change(s))" }
            return (New-TwResult $Tweak $Action $status '' $n)
        } catch {
            Write-TwLog -Level Error -Message "[$($Tweak.id)] $Action failed: $($_.Exception.Message)"
            return (New-TwResult $Tweak $Action 'Failed' $_.Exception.Message)
        }
    }
}

function Restart-TwExplorer {
    <#
    .SYNOPSIS
        Restarts Explorer once so shell tweaks take effect.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if ($PSCmdlet.ShouldProcess('explorer.exe', 'Restart')) {
        Get-Process -Name explorer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process -FilePath 'explorer.exe' }
        Write-TwLog -Level Success -Message 'Explorer restarted'
    }
}

function Invoke-TwTweakBatch {
    <#
    .SYNOPSIS
        Applies and undoes a set of tweaks as one session.
    .DESCRIPTION
        1. Restore point before the first change of the app session (unless disabled).
        2. New backup session.
        3. Undo list first, then apply list; tweaks of the same exclusiveGroup that are
           currently applied are undone before a sibling is applied.
        4. One Explorer restart at the end if any tweak needs it.
        Returns a report with per-tweak results and what needs a reboot / sign-out.
    .PARAMETER Apply
        Tweak ids to apply.
    .PARAMETER Undo
        Tweak ids to undo.
    .PARAMETER NoRestorePoint
        Skip the restore point.
    .PARAMETER NoExplorerRestart
        Do not restart Explorer even if needed.
    .PARAMETER OnProgress
        Script block called with (index, total, tweak, action) before each tweak.
    .EXAMPLE
        Invoke-TwTweakBatch -Apply privacy.disable-telemetry -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string[]]$Apply = @(),
        [string[]]$Undo = @(),
        [switch]$NoRestorePoint,
        [switch]$NoExplorerRestart,
        [scriptblock]$OnProgress
    )
    $ctx = Get-TwContext
    $catalog = @(Import-TwTweakCatalog)
    $byId = @{}
    foreach ($t in $catalog) { $byId[$t.id] = $t }

    $unknown = @(@($Apply) + @($Undo) | Where-Object { $_ -and -not $byId.ContainsKey($_) })
    $applyList = @($Apply | Where-Object { $byId.ContainsKey($_) } | Select-Object -Unique | ForEach-Object { $byId[$_] })
    $undoIds = New-Object System.Collections.Generic.List[string]
    foreach ($u in $Undo) { if ($byId.ContainsKey($u) -and -not $undoIds.Contains($u)) { $undoIds.Add($u) } }

    # Mutually exclusive groups (e.g. Windows Update modes).
    foreach ($t in $applyList) {
        $group = Get-TwObjectProperty $t 'exclusiveGroup'
        if (-not $group) { continue }
        foreach ($other in $catalog) {
            if ($other.id -eq $t.id -or (Get-TwObjectProperty $other 'exclusiveGroup') -ne $group) { continue }
            if ($Apply -contains $other.id -or $undoIds.Contains($other.id)) { continue }
            if (@('Applied', 'Partial') -contains (Get-TwTweakState -Tweak $other)) { $undoIds.Add($other.id) }
        }
    }
    $undoList = @($undoIds | ForEach-Object { $byId[$_] })

    $report = [pscustomobject]@{
        Results           = New-Object System.Collections.ArrayList
        Unknown           = $unknown
        RestorePoint      = $null
        BackupSession     = $null
        ExplorerRestarted = $false
        RebootRequired    = @()
        SignOutRequired   = @()
        WhatIf            = [bool]$WhatIfPreference
    }
    $total = $undoList.Count + $applyList.Count
    if ($total -eq 0) { return $report }
    if ($ctx.ReadOnly) {
        foreach ($t in $undoList) { [void]$report.Results.Add((New-TwResult $t 'Undo' 'Skipped' 'ReadOnly')) }
        foreach ($t in $applyList) { [void]$report.Results.Add((New-TwResult $t 'Apply' 'Skipped' 'ReadOnly')) }
        return $report
    }

    if (-not $WhatIfPreference) {
        if (-not $NoRestorePoint -and -not $ctx.RestorePointDone) {
            $report.RestorePoint = New-TwRestorePoint -Description ("Tweaker {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm'))
            if ($report.RestorePoint.Success) { $ctx.RestorePointDone = $true }
        }
        $report.BackupSession = (Start-TwBackupSession).id
    }

    $mounted = $false
    if ($ctx.IncludeDefaultUser -and -not $WhatIfPreference) { $mounted = Mount-TwDefaultUserHive }
    try {
        $steps = New-Object System.Collections.Generic.List[object]
        foreach ($t in $undoList) { $steps.Add([pscustomobject]@{ Tweak = $t; Action = 'Undo' }) }
        foreach ($t in $applyList) { $steps.Add([pscustomobject]@{ Tweak = $t; Action = 'Apply' }) }
        $i = 0
        foreach ($step in $steps) {
            $i++
            if ($OnProgress) { & $OnProgress $i $total $step.Tweak $step.Action }
            [void]$report.Results.Add((Invoke-TwTweak -Tweak $step.Tweak -Action $step.Action))
        }
    } finally {
        if ($mounted) { Dismount-TwDefaultUserHive }
    }

    $done = @($report.Results | Where-Object { $_.Status -eq 'Success' })
    if (-not $NoExplorerRestart -and @($done | Where-Object { $_.RequiresExplorerRestart }).Count -gt 0) {
        Restart-TwExplorer
        $report.ExplorerRestarted = $true
    }
    $report.RebootRequired = @($done | Where-Object { $_.RequiresReboot } | ForEach-Object { $_.Name })
    $report.SignOutRequired = @($done | Where-Object { $_.RequiresSignOut } | ForEach-Object { $_.Name })
    return $report
}

function Mount-TwDefaultUserHive {
    <#
    .SYNOPSIS
        Loads C:\Users\Default\NTUSER.DAT as HKEY_USERS\TweakerDefaultUser.
    .DESCRIPTION
        Lets HKCU tweaks also be written to the profile template used for new users.
        Returns $true when the hive was mounted by this call.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param()
    if (Test-Path -LiteralPath 'Registry::HKEY_USERS\TweakerDefaultUser') { return $false }
    $hive = Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT'
    if (-not (Test-Path -LiteralPath $hive)) { return $false }
    if ($PSCmdlet.ShouldProcess($hive, 'Load hive')) {
        $r = Invoke-TwNativeCommand -FilePath 'reg.exe' -ArgumentList 'load', 'HKU\TweakerDefaultUser', $hive
        if ($r.ExitCode -ne 0) { Write-TwLog -Level Warning -Message "Default user hive not loaded: $($r.Output)"; return $false }
        return $true
    }
    return $false
}

function Dismount-TwDefaultUserHive {
    <#
    .SYNOPSIS
        Unloads the Default user hive mounted by Mount-TwDefaultUserHive.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    if ($PSCmdlet.ShouldProcess('HKU\TweakerDefaultUser', 'Unload hive')) {
        $r = Invoke-TwNativeCommand -FilePath 'reg.exe' -ArgumentList 'unload', 'HKU\TweakerDefaultUser'
        if ($r.ExitCode -ne 0) { Write-TwLog -Level Warning -Message "Default user hive not unloaded: $($r.Output)" }
    }
}
