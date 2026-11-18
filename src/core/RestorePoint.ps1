# System Restore points.

function Test-TwSystemRestoreEnabled {
    <#
    .SYNOPSIS
        True when System Protection is enabled for the system drive.
    .DESCRIPTION
        The System Restore client registers protected volumes under
        HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SPP\Clients; an empty or
        missing value means protection is off.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $v = Get-TwRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SPP\Clients' -Name '{09F7EDC5-294E-4180-AF6A-FB0E6A0E9513}'
    if (-not $v.Exists) { return $false }
    # Any registered volume means protection is on for at least one drive; if the
    # system drive is not among them Checkpoint-Computer fails and we report it.
    return [bool]((@($v.Value) -join '').Trim())
}

function Enable-TwSystemRestore {
    <#
    .SYNOPSIS
        Turns on System Protection for the system drive (asks via ShouldProcess).
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param()
    $drive = $env:SystemDrive + '\'
    if ($PSCmdlet.ShouldProcess($drive, 'Enable System Protection')) {
        Enable-ComputerRestore -Drive $drive -ErrorAction Stop
        Write-TwLog -Level Success -Message "System Protection enabled for $drive"
    }
}

function New-TwRestorePoint {
    <#
    .SYNOPSIS
        Creates a restore point, bypassing the one-per-24-hours limit.
    .DESCRIPTION
        Windows silently skips Checkpoint-Computer when a restore point was created
        in the last 24 hours. SystemRestorePointCreationFrequency = 0 lifts that
        limit; the original value (or its absence) is put back afterwards.
        Returns an object with Success and Message; never fails silently.
    .PARAMETER Description
        Restore point name.
    .EXAMPLE
        New-TwRestorePoint -Description 'Tweaker' -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Description = 'Tweaker')
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $name = 'SystemRestorePointCreationFrequency'
    if (-not $PSCmdlet.ShouldProcess($env:SystemDrive, "Create restore point '$Description'")) {
        return [pscustomobject]@{ Success = $true; WhatIf = $true; Message = 'WhatIf' }
    }
    if (-not (Test-TwSystemRestoreEnabled)) {
        Write-TwLog -Level Warning -Message 'System Protection is disabled: restore point not created.'
        return [pscustomobject]@{ Success = $false; WhatIf = $false; Message = 'SystemProtectionDisabled' }
    }
    $original = Get-TwRegistryValue -Path $key -Name $name
    try {
        Set-TwRegistryValue -Path $key -Name $name -Type DWord -Value 0
        Checkpoint-Computer -Description $Description -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-TwLog -Level Success -Message "Restore point created: $Description"
        return [pscustomobject]@{ Success = $true; WhatIf = $false; Message = '' }
    } catch {
        Write-TwLog -Level Warning -Message "Restore point NOT created: $($_.Exception.Message)"
        return [pscustomobject]@{ Success = $false; WhatIf = $false; Message = $_.Exception.Message }
    } finally {
        try {
            if ($original.Exists) { Set-TwRegistryValue -Path $key -Name $name -Type DWord -Value $original.Value }
            else { Remove-TwRegistryValue -Path $key -Name $name }
        } catch {
            Write-TwLog -Level Warning -Message "Could not restore ${name}: $($_.Exception.Message)"
        }
    }
}

function Get-TwRestorePoint {
    <#
    .SYNOPSIS
        Lists existing restore points (requires administrator rights).
    #>
    [CmdletBinding()]
    param()
    try {
        return @(Get-ComputerRestorePoint -ErrorAction Stop | Sort-Object SequenceNumber -Descending |
                ForEach-Object {
                    [pscustomobject]@{
                        Sequence    = $_.SequenceNumber
                        Description = $_.Description
                        Created     = [Management.ManagementDateTimeConverter]::ToDateTime($_.CreationTime)
                    }
                })
    } catch {
        return @()
    }
}
