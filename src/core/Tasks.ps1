# Scheduled tasks.

function Split-TwTaskPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $index = $Path.LastIndexOf('\')
    return [pscustomobject]@{
        TaskPath = $Path.Substring(0, $index + 1)
        TaskName = $Path.Substring($index + 1)
    }
}

function Get-TwTaskState {
    <#
    .SYNOPSIS
        Returns Enabled, Disabled or Missing for a scheduled task.
    .PARAMETER Path
        Full task path, e.g. \Microsoft\Windows\Customer Experience Improvement Program\Consolidator
    .EXAMPLE
        Get-TwTaskState '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)
    $parts = Split-TwTaskPath $Path
    $task = Get-ScheduledTask -TaskPath $parts.TaskPath -TaskName $parts.TaskName -ErrorAction SilentlyContinue
    if (-not $task) { return 'Missing' }
    if ([string]$task.State -eq 'Disabled') { return 'Disabled' }
    return 'Enabled'
}

function Set-TwTaskState {
    <#
    .SYNOPSIS
        Enables or disables a scheduled task.
    .EXAMPLE
        Set-TwTaskState '\Microsoft\Windows\Feedback\Siuf\DmClient' Disabled -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [Parameter(Mandatory, Position = 1)][ValidateSet('Enabled', 'Disabled')][string]$State
    )
    $parts = Split-TwTaskPath $Path
    if ($PSCmdlet.ShouldProcess("task $Path", "Set $State")) {
        if ($State -eq 'Disabled') {
            $null = Disable-ScheduledTask -TaskPath $parts.TaskPath -TaskName $parts.TaskName -ErrorAction Stop
        } else {
            $null = Enable-ScheduledTask -TaskPath $parts.TaskPath -TaskName $parts.TaskName -ErrorAction Stop
        }
    }
}
