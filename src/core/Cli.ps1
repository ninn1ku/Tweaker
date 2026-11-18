# Program entry logic shared by the dev entry point and the built single file:
# argument handling, elevation, CLI commands and exit codes.
#
# Exit codes:
#   0  success (also: nothing to do)
#   1  finished, but at least one tweak / restore step failed
#   2  invalid arguments (unknown tweak id, preset, file)
#   3  administrator rights required
#   4  environment not supported (no WPF / STA for the GUI)
#   5  unexpected error

function Write-TwConsole {
    <#
    .SYNOPSIS
        Console output for the CLI (suppressed by -Silent, except errors).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$Text = '',
        [Parameter(Position = 1)][ValidateSet('Info', 'Success', 'Warning', 'Error', 'Muted', 'Title')][string]$Kind = 'Info'
    )
    $ctx = Get-TwContext
    if ((Get-TwObjectProperty $ctx 'Silent' $false) -and $Kind -ne 'Error') { return }
    $color = switch ($Kind) {
        'Success' { 'Green' }
        'Warning' { 'Yellow' }
        'Error' { 'Red' }
        'Muted' { 'DarkGray' }
        'Title' { 'Cyan' }
        default { 'Gray' }
    }
    Write-Host $Text -ForegroundColor $color
}

function Split-TwListArgument {
    <#
    .SYNOPSIS
        Accepts "a,b", @('a','b') or @('a,b') and returns a clean string array.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowNull()][string[]]$Value)
    return @($Value | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Show-TwTweakList {
    [CmdletBinding()]
    param([string]$Category, [switch]$WithState)
    $tweaks = @(Get-TwTweak -Category $Category)
    if ($tweaks.Count -eq 0) { Write-TwConsole (Get-TwString 'cli.noTweaks') Warning; return }
    $order = @{}
    foreach ($c in (Get-TwJsonResource 'config/categories.json').categories) { $order[$c.id] = [int]$c.order }
    foreach ($group in ($tweaks | Group-Object category | Sort-Object { $order[$_.Name] })) {
        Write-TwConsole ''
        Write-TwConsole ('== {0} ==' -f (Get-TwString "category.$($group.Name)")) Title
        foreach ($t in $group.Group) {
            $flags = ''
            if (-not $t.verified) { $flags += ' ?' }
            if (-not (Test-TwTweakSupported -Tweak $t)) { $flags += ' -' }
            $name = Get-TwLocalizedText $t.name
            if ($WithState) {
                $state = Get-TwTweakState -Tweak $t
                $kind = switch ($state) { 'Applied' { 'Success' } 'Partial' { 'Warning' } 'Unsupported' { 'Muted' } default { 'Info' } }
                Write-TwConsole ('  {0,-16} {1,-42} {2}' -f (Get-TwString "state.$state"), $t.id, $name) $kind
            } else {
                $kind = switch ($t.risk) { 'advanced' { 'Warning' } 'moderate' { 'Info' } default { 'Info' } }
                Write-TwConsole ('  {0,-42} {1,-14} {2}{3}' -f $t.id, (Get-TwString "risk.$($t.risk)"), $name, $flags) $kind
            }
        }
    }
    Write-TwConsole ''
    Write-TwConsole (Get-TwString 'cli.listLegend') Muted
}

function Write-TwBatchReport {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)]$Report)
    foreach ($id in @($Report.Unknown)) { Write-TwConsole (Get-TwString 'cli.unknownId' $id) Error }
    if ($Report.RestorePoint -and -not $Report.RestorePoint.WhatIf) {
        if ($Report.RestorePoint.Success) { Write-TwConsole (Get-TwString 'cli.restorePointOk') Success }
        else { Write-TwConsole (Get-TwString 'cli.restorePointFailed' $Report.RestorePoint.Message) Warning }
    }
    $counts = @{ Success = 0; NoChange = 0; Skipped = 0; Failed = 0; WhatIf = 0 }
    foreach ($r in $Report.Results) {
        $counts[$r.Status]++
        $kind = switch ($r.Status) { 'Success' { 'Success' } 'Failed' { 'Error' } 'Skipped' { 'Warning' } default { 'Info' } }
        $action = Get-TwString "cli.action.$($r.Action)"
        $msg = ''
        if ($r.Message) {
            $msg = ' - ' + $(if ($r.Message -in 'ReadOnly', 'UnsupportedBuild') { Get-TwString "cli.reason.$($r.Message)" } else { $r.Message })
        }
        Write-TwConsole ('  [{0}] {1}: {2}{3}' -f (Get-TwString "status.$($r.Status)"), $action, $r.Name, $msg) $kind
    }
    Write-TwConsole ''
    Write-TwConsole (Get-TwString 'cli.summary' $counts.Success, $counts.NoChange, $counts.Skipped, $counts.Failed, $counts.WhatIf) Title
    if ($Report.WhatIf) { Write-TwConsole (Get-TwString 'cli.whatIfNote') Muted }
    if ($Report.ExplorerRestarted) { Write-TwConsole (Get-TwString 'cli.explorerRestarted') Info }
    if (@($Report.SignOutRequired).Count -gt 0) { Write-TwConsole (Get-TwString 'cli.signOutNeeded' (@($Report.SignOutRequired) -join ', ')) Warning }
    if (@($Report.RebootRequired).Count -gt 0) { Write-TwConsole (Get-TwString 'cli.rebootNeeded' (@($Report.RebootRequired) -join ', ')) Warning }
    if (@($Report.Unknown).Count -gt 0) { return 2 }
    if ($counts.Failed -gt 0) { return 1 }
    return 0
}

function Write-TwRestoreReport {
    [CmdletBinding()]
    [OutputType([int])]
    param([object[]]$Results)
    $failed = 0
    foreach ($r in @($Results)) {
        $kind = switch ($r.Status) { 'Success' { 'Success' } 'Failed' { 'Error' } default { 'Info' } }
        if ($r.Status -eq 'Failed') { $failed++ }
        Write-TwConsole ('  [{0}] {1} {2}' -f (Get-TwString "status.$($r.Status)"), $r.TweakId, $r.Target) $kind
    }
    Write-TwConsole (Get-TwString 'cli.restoreSummary' @($Results).Count, $failed) Title
    if ($failed -gt 0) { return 1 }
    return 0
}

function Initialize-TwUserTarget {
    <#
    .SYNOPSIS
        Detects "elevated as a different user" and redirects HKCU accordingly.
    #>
    [CmdletBinding()]
    param()
    $ctx = Get-TwContext
    $u = Resolve-TwTargetUser
    if (-not $u.Mismatch) { return $u }
    if ($u.TargetSid) {
        $ctx.TargetUserSid = $u.TargetSid
        Write-TwLog -Level Warning -Message "Elevated as a different account; HKCU tweaks go to HKEY_USERS\$($u.TargetSid)"
        Write-TwConsole (Get-TwString 'cli.hkcuRedirect') Warning
    } else {
        Write-TwLog -Level Warning -Message 'Elevated as a different account and the signed-in user hive is not loaded'
        Write-TwConsole (Get-TwString 'cli.hkcuMismatch') Warning
    }
    return $u
}

function Start-TwMain {
    <#
    .SYNOPSIS
        Entry point: parses options, handles elevation and runs the CLI or the GUI.
    .OUTPUTS
        Exit code (see the table at the top of this file).
    .PARAMETER Options
        $PSBoundParameters of the entry script.
    .PARAMETER ScriptPath
        $PSCommandPath of the entry script (empty when run through irm | iex).
    .PARAMETER ScriptText
        Source text of the program (used to relaunch elevated after irm | iex).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Options,
        [string]$ScriptPath,
        [string]$ScriptText
    )
    $opt = @{}
    foreach ($k in $Options.Keys) { $opt[$k] = $Options[$k] }
    foreach ($k in 'Apply', 'Undo') { if ($opt.ContainsKey($k)) { $opt[$k] = Split-TwListArgument $opt[$k] } }
    $lang = 'ru'
    if ($opt['Lang']) { $lang = $opt['Lang'] }

    $isAdmin = Test-TwAdministrator
    $writeAction = [bool]($opt['Preset'] -or $opt['Apply'] -or $opt['Undo'] -or $opt['Import'])
    $readAction = [bool]($opt['List'] -or $opt['Status'] -or $opt['Export'])
    $cli = $writeAction -or $readAction
    $readOnly = [bool]$opt['ReadOnly']
    if (-not $cli -and -not $isAdmin -and $opt['NoElevate']) { $readOnly = $true }

    $ctx = Initialize-TwContext -Language $lang -ReadOnly:$readOnly
    $ctx['Silent'] = [bool]$opt['Silent']
    $ctx.IncludeDefaultUser = [bool]$opt['DefaultUser']
    Import-TwLanguage -Language $lang
    Write-TwLog -Level Debug -Message ("Start: version {0}, admin={1}, args={2}" -f $ctx.Version, $isAdmin, (($opt.Keys | Sort-Object) -join ','))

    $os = Get-TwOsInfo
    if (-not $os.Supported -and -not $opt['Silent']) { Write-TwConsole (Get-TwString 'cli.osUnsupported' $os.Build) Warning }

    # ---------------- GUI ----------------
    if (-not $cli) {
        if (-not $isAdmin -and -not $readOnly) {
            Write-TwConsole (Get-TwString 'cli.elevating') Info
            $fwd = @{}
            foreach ($k in $Options.Keys) { $fwd[$k] = $Options[$k] }
            try {
                Start-TwElevated -ScriptPath $ScriptPath -ScriptText $ScriptText -Parameters $fwd -Minimized
                return 0
            } catch {
                # UAC declined or unavailable: still open the window, in view-only mode.
                Write-TwConsole (Get-TwString 'cli.elevationFailed' $_.Exception.Message) Warning
                $readOnly = $true
                $ctx.ReadOnly = $true
            }
        }
        if (-not (Test-TwStaThread)) {
            $fwd = @{}
            foreach ($k in $Options.Keys) { $fwd[$k] = $Options[$k] }
            Start-TwElevated -ScriptPath $ScriptPath -ScriptText $ScriptText -Parameters $fwd -NoElevate
            return 0
        }
        if (-not (Get-Command -Name Show-TwMainWindow -ErrorAction SilentlyContinue)) {
            Write-TwConsole (Get-TwString 'cli.guiUnavailable') Error
            return 4
        }
        if ($isAdmin) { $null = Initialize-TwUserTarget }
        return (Show-TwMainWindow)
    }

    # ---------------- CLI ----------------
    if ($writeAction -and -not $isAdmin -and -not $WhatIfPreference) {
        Write-TwConsole (Get-TwString 'cli.needAdmin') Error
        return 3
    }
    if ($isAdmin) { $null = Initialize-TwUserTarget }
    if ($readOnly -and $writeAction) { Write-TwConsole (Get-TwString 'cli.readOnlyMode') Warning }

    if ($opt['List']) { Show-TwTweakList -Category $opt['Category']; return 0 }
    if ($opt['Status']) { Show-TwTweakList -Category $opt['Category'] -WithState; return 0 }
    if ($opt['Export']) {
        $ids = Export-TwUserConfig -Path $opt['Export'] -WhatIf:$false
        Write-TwConsole (Get-TwString 'cli.exported' @($ids).Count, $opt['Export']) Success
        return 0
    }

    $applyIds = @()
    $undoIds = @()
    if ($opt['Preset']) {
        if (-not (Get-TwPreset -Name $opt['Preset'])) {
            Write-TwConsole (Get-TwString 'cli.unknownPreset' $opt['Preset'], ((Get-TwPreset | ForEach-Object { $_.id }) -join ', ')) Error
            return 2
        }
        $applyIds += Resolve-TwPresetTweakId -Name $opt['Preset']
    }
    if ($opt['Import']) {
        if (-not (Test-Path -LiteralPath $opt['Import'])) { Write-TwConsole (Get-TwString 'cli.fileNotFound' $opt['Import']) Error; return 2 }
        try { $applyIds += Import-TwUserConfig -Path $opt['Import'] } catch { Write-TwConsole $_.Exception.Message Error; return 2 }
    }
    if ($opt['Apply']) { $applyIds += $opt['Apply'] }

    $exit = 0
    if ($opt['Undo']) {
        $special = @($opt['Undo'] | Where-Object { $_ -in 'All', 'Last' })
        if ($special.Count -gt 0) {
            if ($ctx.ReadOnly) { Write-TwConsole (Get-TwString 'cli.readOnlyMode') Warning; return 0 }
            $sessions = @(Get-TwBackupSession)
            if ($sessions.Count -eq 0) { Write-TwConsole (Get-TwString 'cli.noBackups') Warning }
            elseif ($special -contains 'All') {
                Write-TwConsole (Get-TwString 'cli.undoAll') Title
                $exit = [math]::Max($exit, (Write-TwRestoreReport (Restore-TwFullBackup)))
            } else {
                Write-TwConsole (Get-TwString 'cli.undoLast' $sessions[0].id) Title
                $exit = [math]::Max($exit, (Write-TwRestoreReport (Restore-TwBackupSession -Id $sessions[0].id)))
            }
        }
        $undoIds = @($opt['Undo'] | Where-Object { $_ -notin 'All', 'Last' })
    }

    if ($applyIds.Count -gt 0 -or $undoIds.Count -gt 0) {
        $progress = {
            param($i, $n, $t, $action)
            Write-TwConsole ('[{0}/{1}] {2}: {3}' -f $i, $n, (Get-TwString "cli.action.$action"), (Get-TwLocalizedText $t.name)) Muted
        }
        $report = Invoke-TwTweakBatch -Apply $applyIds -Undo $undoIds -NoRestorePoint:([bool]$opt['NoRestorePoint']) -OnProgress $progress
        $exit = [math]::Max($exit, (Write-TwBatchReport $report))
    } elseif (-not $opt['Undo']) {
        Write-TwConsole (Get-TwString 'cli.nothingToDo') Info
    }
    return [int]$exit
}
