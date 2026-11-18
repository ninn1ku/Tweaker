# Backups of the real original state, written BEFORE every change.
# One file per session: %ProgramData%\Tweaker\backups\<yyyyMMdd-HHmmss>.json

function Start-TwBackupSession {
    <#
    .SYNOPSIS
        Starts a new backup session (the file is created with the first entry).
    .EXAMPLE
        Start-TwBackupSession
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $ctx = Get-TwContext
    $id = Get-Date -Format 'yyyyMMdd-HHmmss'
    $file = Join-Path $ctx.BackupDir "$id.json"
    $n = 1
    while (Test-Path -LiteralPath $file) { $n++; $file = Join-Path $ctx.BackupDir "$id-$n.json" }
    if ($n -gt 1) { $id = "$id-$n" }
    $ctx.Session = [pscustomobject]@{
        version  = 1
        id       = $id
        created  = (Get-Date).ToString('o')
        computer = $env:COMPUTERNAME
        user     = [Environment]::UserName
        tool     = $ctx.Version
        file     = $file
        entries  = (New-Object System.Collections.ArrayList)
    }
    return $ctx.Session
}

function Get-TwBackupTargetKey {
    <#
    .SYNOPSIS
        Identity of the thing an entry describes (used to de-duplicate entries).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Entry)
    $kind = Get-TwObjectProperty $Entry 'kind'
    switch ($kind) {
        'registry' { return ('registry|{0}|{1}' -f (Get-TwObjectProperty $Entry 'path'), (Get-TwObjectProperty $Entry 'name')).ToLowerInvariant() }
        'command' { return ('command|{0}|{1}' -f (Get-TwObjectProperty $Entry 'name'), (Get-TwObjectProperty $Entry 'tweakId')).ToLowerInvariant() }
        'task' { return ('task|{0}' -f (Get-TwObjectProperty $Entry 'path')).ToLowerInvariant() }
        default { return ('{0}|{1}' -f $kind, (Get-TwObjectProperty $Entry 'name')).ToLowerInvariant() }
    }
}

function Save-TwBackupSession {
    <#
    .SYNOPSIS
        Writes the current session to disk (atomically via a temp file).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $ctx = Get-TwContext
    $s = $ctx.Session
    if (-not $s) { return }
    if (-not (Test-Path -LiteralPath $ctx.BackupDir)) {
        $null = New-Item -ItemType Directory -Path $ctx.BackupDir -Force -WhatIf:$false -Confirm:$false
    }
    $doc = [ordered]@{
        version  = $s.version
        id       = $s.id
        created  = $s.created
        computer = $s.computer
        user     = $s.user
        tool     = $s.tool
        entries  = @($s.entries)
    }
    $json = ConvertTo-Json -InputObject $doc -Depth 12
    $tmp = $s.file + '.tmp'
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $s.file -Force -WhatIf:$false -Confirm:$false
}

function Add-TwBackupEntry {
    <#
    .SYNOPSIS
        Records the original state of one target before it is changed.
    .DESCRIPTION
        Only the first entry per target and tweak is kept in a session: that is the
        real original value. Nothing is written in -WhatIf mode.
    .PARAMETER Entry
        Hashtable with tweakId, kind and kind-specific fields.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Entry)
    if ($WhatIfPreference) { return }
    $ctx = Get-TwContext
    if (-not $ctx.Session) { $null = Start-TwBackupSession -WhatIf:$false }
    $key = Get-TwBackupTargetKey $Entry
    foreach ($e in $ctx.Session.entries) {
        if ((Get-TwBackupTargetKey $e) -eq $key -and (Get-TwObjectProperty $e 'tweakId') -eq $Entry['tweakId']) { return }
    }
    $Entry['time'] = (Get-Date).ToString('o')
    [void]$ctx.Session.entries.Add([pscustomobject]$Entry)
    Save-TwBackupSession -WhatIf:$false
}

function Get-TwBackupSession {
    <#
    .SYNOPSIS
        Lists backup sessions, newest first.
    .PARAMETER Id
        Return only this session.
    .EXAMPLE
        Get-TwBackupSession | Select-Object id, created, @{n='count';e={$_.entries.Count}}
    #>
    [CmdletBinding()]
    param([string]$Id)
    $ctx = Get-TwContext
    if (-not (Test-Path -LiteralPath $ctx.BackupDir)) { return @() }
    $sessions = foreach ($file in Get-ChildItem -LiteralPath $ctx.BackupDir -Filter '*.json' -File) {
        try {
            $doc = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            $doc | Add-Member -NotePropertyName file -NotePropertyValue $file.FullName -Force
            if ($null -eq (Get-TwObjectProperty $doc 'entries')) { $doc | Add-Member -NotePropertyName entries -NotePropertyValue @() -Force }
            $doc
        } catch {
            Write-TwLog -Level Warning -Message "Unreadable backup file $($file.Name): $($_.Exception.Message)"
        }
    }
    $sessions = @($sessions | Sort-Object { [string]$_.id } -Descending)
    if ($Id) { return @($sessions | Where-Object { $_.id -eq $Id }) }
    return $sessions
}

function Remove-TwBackupSession {
    <#
    .SYNOPSIS
        Deletes a backup session file.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Id)
    foreach ($s in Get-TwBackupSession -Id $Id) {
        if ($PSCmdlet.ShouldProcess($s.file, 'Delete backup')) { Remove-Item -LiteralPath $s.file -Force }
    }
}

function Test-TwEntryMatchesDesired {
    <#
    .SYNOPSIS
        True when a backup entry already holds the value the tweak would set.
    .DESCRIPTION
        Such entries were recorded while the tweak was already applied, so they do
        not describe the original state and are skipped when looking for it.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Entry, $Tweak)
    if (-not $Tweak) { return $false }
    switch ($Entry.kind) {
        'registry' {
            if (-not $Entry.existed) { return $false }
            foreach ($r in @(Get-TwObjectProperty $Tweak 'registry' @())) {
                $p = ConvertTo-TwRegistryProviderPath -Path $r.path -UserSid (Get-TwObjectProperty $Entry 'userSid')
                if ($p -eq $Entry.path -and $r.name -eq $Entry.name) {
                    return ((ConvertTo-TwComparableRegistryValue $r.type $r.value) -eq (ConvertTo-TwComparableRegistryValue $r.type $Entry.value))
                }
            }
        }
        'service' {
            foreach ($s in @(Get-TwObjectProperty $Tweak 'services' @())) {
                if ($s.name -eq $Entry.name) { return ($s.startupType -eq $Entry.startupType) }
            }
        }
        'task' {
            foreach ($t in @(Get-TwObjectProperty $Tweak 'scheduledTasks' @())) {
                if ($t.path -eq $Entry.path) { return ($t.state -eq $Entry.state) }
            }
        }
        'feature' {
            foreach ($f in @(Get-TwObjectProperty $Tweak 'optionalFeatures' @())) {
                if ($f.name -eq $Entry.name) { return ($f.state -eq $Entry.state) }
            }
        }
    }
    return $false
}

function Get-TwOriginalEntry {
    <#
    .SYNOPSIS
        Finds, per target, the backup entry that holds the real original state.
    .DESCRIPTION
        Sessions are scanned newest to oldest; the first entry whose value differs
        from what the tweak sets is the original. If every entry equals the tweak's
        value, the oldest one is used.
    .PARAMETER TweakId
        Only entries recorded for this tweak.
    .PARAMETER Tweak
        Tweak definition (used to skip entries that equal the tweak's own values).
    .PARAMETER SessionId
        Limit to one session.
    #>
    [CmdletBinding()]
    param(
        [string]$TweakId,
        $Tweak,
        [string]$SessionId
    )
    $sessions = if ($SessionId) { Get-TwBackupSession -Id $SessionId } else { Get-TwBackupSession }
    $chosen = [ordered]@{}
    $fallback = [ordered]@{}
    foreach ($s in $sessions) {
        $entries = @($s.entries)
        [array]::Reverse($entries)
        foreach ($e in $entries) {
            if ($TweakId -and $e.tweakId -ne $TweakId) { continue }
            $key = Get-TwBackupTargetKey $e
            $fallback[$key] = $e
            if ($chosen.Contains($key)) { continue }
            if (-not (Test-TwEntryMatchesDesired -Entry $e -Tweak $Tweak)) { $chosen[$key] = $e }
        }
    }
    foreach ($key in $fallback.Keys) {
        if (-not $chosen.Contains($key)) { $chosen[$key] = $fallback[$key] }
    }
    return @($chosen.Values)
}

function Restore-TwBackupEntry {
    <#
    .SYNOPSIS
        Puts one target back into the state recorded in a backup entry.
    .EXAMPLE
        Get-TwOriginalEntry -TweakId privacy.disable-telemetry | ForEach-Object { Restore-TwBackupEntry $_ -WhatIf }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory, Position = 0)]$Entry)
    switch ($Entry.kind) {
        'registry' {
            if ($Entry.existed) {
                Set-TwRegistryValue -Path $Entry.path -Name $Entry.name -Type $Entry.type -Value $Entry.value
                Write-TwLog -Level Success -Message ("Restored {0}\{1} = {2}" -f $Entry.path, $Entry.name, (ConvertTo-TwComparableRegistryValue $Entry.type $Entry.value))
            } else {
                Remove-TwRegistryValue -Path $Entry.path -Name $Entry.name
                $created = Get-TwObjectProperty $Entry 'createdKey'
                if ($created) { Remove-TwRegistryKey -Path $created }
                Write-TwLog -Level Success -Message ("Restored {0}\{1}: removed (it did not exist)" -f $Entry.path, $Entry.name)
            }
        }
        'service' {
            if ($Entry.existed -and $Entry.startupType) {
                $start = @('Automatic', 'AutomaticDelayed') -contains $Entry.startupType -and [bool](Get-TwObjectProperty $Entry 'wasRunning' $false)
                Set-TwServiceStartup -Name $Entry.name -StartupType $Entry.startupType -Start:$start
                Write-TwLog -Level Success -Message "Restored service $($Entry.name) startup = $($Entry.startupType)"
            }
        }
        'task' {
            if ($Entry.state -ne 'Missing') {
                Set-TwTaskState -Path $Entry.path -State $Entry.state
                Write-TwLog -Level Success -Message "Restored task $($Entry.path) = $($Entry.state)"
            }
        }
        'feature' {
            if (@('Enabled', 'Disabled') -contains $Entry.state) {
                Set-TwOptionalFeatureState -Name $Entry.name -State $Entry.state
                Write-TwLog -Level Success -Message "Restored feature $($Entry.name) = $($Entry.state)"
            }
        }
        'dns' {
            Restore-TwDnsServer -Entry $Entry
            Write-TwLog -Level Success -Message "Restored DNS servers of adapter $($Entry.name)"
        }
        'command' {
            Invoke-TwCommandAction -Name $Entry.name -Action Undo -State (Get-TwObjectProperty $Entry 'data')
            Write-TwLog -Level Success -Message "Restored command $($Entry.name)"
        }
        default { throw "Unknown backup entry kind: $($Entry.kind)" }
    }
}

function Restore-TwBackupSession {
    <#
    .SYNOPSIS
        Rolls back every change recorded in one session (newest change first).
    .EXAMPLE
        Restore-TwBackupSession -Id 20261118-120000 -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Id)
    $session = Get-TwBackupSession -Id $Id | Select-Object -First 1
    if (-not $session) { throw "Backup session not found: $Id" }
    $entries = @($session.entries)
    [array]::Reverse($entries)
    $results = foreach ($e in $entries) { Invoke-TwRestoreStep -Entry $e }
    return @($results)
}

function Restore-TwFullBackup {
    <#
    .SYNOPSIS
        Returns every target ever changed by Tweaker to its oldest recorded state.
    .EXAMPLE
        Restore-TwFullBackup -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $oldest = [ordered]@{}
    foreach ($s in Get-TwBackupSession) {
        foreach ($e in @($s.entries)) { $oldest[(Get-TwBackupTargetKey $e)] = $e }  # sessions are newest first
    }
    $entries = @($oldest.Values)
    [array]::Reverse($entries)
    $results = foreach ($e in $entries) { Invoke-TwRestoreStep -Entry $e }
    return @($results)
}

function Invoke-TwRestoreStep {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$Entry)
    $target = Get-TwBackupTargetKey $Entry
    try {
        Restore-TwBackupEntry -Entry $Entry
        $status = 'Success'
        if ($WhatIfPreference) { $status = 'WhatIf' }
        return [pscustomobject]@{ Target = $target; TweakId = $Entry.tweakId; Status = $status; Message = '' }
    } catch {
        Write-TwLog -Level Error -Message "Restore failed for ${target}: $($_.Exception.Message)"
        return [pscustomobject]@{ Target = $target; TweakId = $Entry.tweakId; Status = 'Failed'; Message = $_.Exception.Message }
    }
}
