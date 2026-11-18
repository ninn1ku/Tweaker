# Named engine commands. Tweak JSON can reference these by name ("commands": [{"name": ...}]);
# it can never contain code. Each command has four functions:
#   Detect  -> $true / $false / $null (unknown)
#   Backup  -> state object saved to the backup before the change
#   Apply   -> performs the change
#   Undo    -> restores the saved state (State may be $null: then Windows defaults)

function Get-TwCommandTable {
    <#
    .SYNOPSIS
        Returns the whitelist of commands tweak JSON may reference.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    return @{
        'power.ultimate-plan' = @{ Detect = 'Test-TwUltimatePlan'; Backup = 'Get-TwActivePowerScheme'; Apply = 'Enable-TwUltimatePlan'; Undo = 'Disable-TwUltimatePlan' }
        'power.hibernation'   = @{ Detect = 'Test-TwHibernationState'; Backup = 'Get-TwHibernationState'; Apply = 'Set-TwHibernationTarget'; Undo = 'Restore-TwHibernationState' }
        'updates.pause'       = @{ Detect = 'Test-TwUpdatePause'; Backup = 'Get-TwUpdatePauseState'; Apply = 'Enable-TwUpdatePause'; Undo = 'Restore-TwUpdatePauseState' }
    }
}

function Invoke-TwCommandAction {
    <#
    .SYNOPSIS
        Calls one of the four functions of a named command.
    .PARAMETER Name
        Command name from Get-TwCommandTable.
    .PARAMETER Action
        Detect, Backup, Apply or Undo.
    .PARAMETER Arguments
        The "args" object from tweak JSON.
    .PARAMETER State
        Backup state (Undo only).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Detect', 'Backup', 'Apply', 'Undo')][string]$Action,
        $Arguments,
        $State
    )
    $table = Get-TwCommandTable
    if (-not $table.ContainsKey($Name)) { throw "Unknown command: $Name" }
    $fn = $table[$Name][$Action]
    switch ($Action) {
        'Undo' { return (& $fn -Arguments $Arguments -State $State) }
        default { return (& $fn -Arguments $Arguments) }
    }
}

# --- power.ultimate-plan -----------------------------------------------------------
# Ultimate Performance (e9a42b02-...) is hidden on most editions. We duplicate it under
# a fixed GUID owned by Tweaker, so detection and removal are exact.

function Get-TwUltimatePlanGuid {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return '7d3a8b1e-5c2f-4e8a-9b6d-1f0e2c3a4b5d'
}

function Get-TwActivePowerScheme {
    <#
    .SYNOPSIS
        Returns @{ activeScheme = '<guid>' } for the active power plan.
    #>
    [CmdletBinding()]
    param($Arguments)
    $null = $Arguments
    $r = Invoke-TwNativeCommand -FilePath 'powercfg.exe' -ArgumentList '/getactivescheme' -ReadOnlyCommand
    $m = [regex]::Match($r.Output, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
    $guid = $null
    if ($m.Success) { $guid = $m.Value.ToLowerInvariant() }
    return @{ activeScheme = $guid }
}

function Test-TwUltimatePlan {
    [CmdletBinding()]
    [OutputType([bool])]
    param($Arguments)
    $active = (Get-TwActivePowerScheme -Arguments $Arguments).activeScheme
    return ($active -eq (Get-TwUltimatePlanGuid) -or $active -eq 'e9a42b02-d5df-448d-aa00-03f14749eb61')
}

function Enable-TwUltimatePlan {
    [CmdletBinding(SupportsShouldProcess)]
    param($Arguments)
    $null = $Arguments
    $guid = Get-TwUltimatePlanGuid
    $list = Invoke-TwNativeCommand -FilePath 'powercfg.exe' -ArgumentList '/list' -ReadOnlyCommand
    if ($list.Output -notmatch [regex]::Escape($guid)) {
        $r = Invoke-TwNativeCommand -FilePath 'powercfg.exe' -ArgumentList '/duplicatescheme', 'e9a42b02-d5df-448d-aa00-03f14749eb61', $guid
        if ($r.ExitCode -ne 0) { throw "powercfg /duplicatescheme failed: $($r.Output)" }
    }
    $r = Invoke-TwNativeCommand -FilePath 'powercfg.exe' -ArgumentList '/setactive', $guid
    if ($r.ExitCode -ne 0) { throw "powercfg /setactive failed: $($r.Output)" }
}

function Disable-TwUltimatePlan {
    [CmdletBinding(SupportsShouldProcess)]
    param($Arguments, $State)
    $null = $Arguments
    $target = Get-TwObjectProperty $State 'activeScheme'
    $guid = Get-TwUltimatePlanGuid
    if (-not $target -or $target -eq $guid) { $target = '381b4222-f694-41f0-9685-ff5bb260df2e' }  # Balanced
    $r = Invoke-TwNativeCommand -FilePath 'powercfg.exe' -ArgumentList '/setactive', $target
    if ($r.ExitCode -ne 0) { throw "powercfg /setactive failed: $($r.Output)" }
    $list = Invoke-TwNativeCommand -FilePath 'powercfg.exe' -ArgumentList '/list' -ReadOnlyCommand
    if ($list.Output -match [regex]::Escape($guid)) {
        $null = Invoke-TwNativeCommand -FilePath 'powercfg.exe' -ArgumentList '/delete', $guid
    }
}

# --- power.hibernation (args: { "enabled": false }) --------------------------------

function Get-TwHibernationState {
    [CmdletBinding()]
    param($Arguments)
    $null = $Arguments
    $v = Get-TwRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name 'HibernateEnabled'
    $enabled = $true
    if ($v.Exists) { $enabled = ([int]$v.Value -ne 0) }
    return @{ enabled = $enabled }
}

function Test-TwHibernationState {
    [CmdletBinding()]
    [OutputType([bool])]
    param($Arguments)
    $want = [bool](Get-TwObjectProperty $Arguments 'enabled' $false)
    return ((Get-TwHibernationState).enabled -eq $want)
}

function Set-TwHibernationTarget {
    [CmdletBinding(SupportsShouldProcess)]
    param($Arguments)
    $want = [bool](Get-TwObjectProperty $Arguments 'enabled' $false)
    $arg = if ($want) { 'on' } else { 'off' }
    $r = Invoke-TwNativeCommand -FilePath 'powercfg.exe' -ArgumentList '/hibernate', $arg
    if ($r.ExitCode -ne 0) { throw "powercfg /hibernate $arg failed: $($r.Output)" }
}

function Restore-TwHibernationState {
    [CmdletBinding(SupportsShouldProcess)]
    param($Arguments, $State)
    $null = $Arguments
    $enabled = $true
    if ($null -ne $State) { $enabled = [bool](Get-TwObjectProperty $State 'enabled' $true) }
    Set-TwHibernationTarget -Arguments @{ enabled = $enabled }
}

# --- updates.pause (args: { "days": 35 }) ------------------------------------------
# Writes the same values the Settings app writes when you press "Pause updates".

function Get-TwUpdatePauseValueName {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return @('PauseUpdatesStartTime', 'PauseUpdatesExpiryTime', 'PauseFeatureUpdatesStartTime', 'PauseFeatureUpdatesEndTime',
        'PauseQualityUpdatesStartTime', 'PauseQualityUpdatesEndTime', 'FlightSettingsMaxPauseDays')
}

function Get-TwUpdatePauseState {
    [CmdletBinding()]
    param($Arguments)
    $null = $Arguments
    $key = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
    $values = @{}
    foreach ($n in Get-TwUpdatePauseValueName) {
        $v = Get-TwRegistryValue -Path $key -Name $n
        if ($v.Exists) { $values[$n] = @{ type = $v.Type; value = $v.Value } }
    }
    return @{ values = $values }
}

function Test-TwUpdatePause {
    [CmdletBinding()]
    [OutputType([bool])]
    param($Arguments)
    $null = $Arguments
    $v = Get-TwRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -Name 'PauseUpdatesExpiryTime'
    if (-not $v.Exists) { return $false }
    $until = [datetime]::MinValue
    if ([datetime]::TryParse([string]$v.Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$until)) {
        return ($until -gt (Get-Date).ToUniversalTime())
    }
    return $false
}

function Enable-TwUpdatePause {
    [CmdletBinding(SupportsShouldProcess)]
    param($Arguments)
    $days = [int](Get-TwObjectProperty $Arguments 'days' 35)
    $key = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
    $now = (Get-Date).ToUniversalTime()
    $start = $now.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $end = $now.AddDays($days).ToString('yyyy-MM-ddTHH:mm:ssZ')
    if ($days -gt 35) { Set-TwRegistryValue -Path $key -Name 'FlightSettingsMaxPauseDays' -Type DWord -Value $days }
    Set-TwRegistryValue -Path $key -Name 'PauseUpdatesStartTime' -Type String -Value $start
    Set-TwRegistryValue -Path $key -Name 'PauseUpdatesExpiryTime' -Type String -Value $end
    Set-TwRegistryValue -Path $key -Name 'PauseFeatureUpdatesStartTime' -Type String -Value $start
    Set-TwRegistryValue -Path $key -Name 'PauseFeatureUpdatesEndTime' -Type String -Value $end
    Set-TwRegistryValue -Path $key -Name 'PauseQualityUpdatesStartTime' -Type String -Value $start
    Set-TwRegistryValue -Path $key -Name 'PauseQualityUpdatesEndTime' -Type String -Value $end
}

function Restore-TwUpdatePauseState {
    [CmdletBinding(SupportsShouldProcess)]
    param($Arguments, $State)
    $null = $Arguments
    $key = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
    $saved = Get-TwObjectProperty $State 'values'
    foreach ($n in Get-TwUpdatePauseValueName) {
        $item = Get-TwObjectProperty $saved $n
        if ($item) { Set-TwRegistryValue -Path $key -Name $n -Type $item.type -Value $item.value }
        else { Remove-TwRegistryValue -Path $key -Name $n }
    }
}
