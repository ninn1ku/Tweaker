# Windows optional features (DISM). Reading goes through CIM so it also works
# without administrator rights (read-only mode).

function Get-TwOptionalFeatureState {
    <#
    .SYNOPSIS
        Returns Enabled, Disabled, Missing (not offered by this edition) or Unknown.
    .EXAMPLE
        Get-TwOptionalFeatureState -Name 'Microsoft-Windows-Subsystem-Linux'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)
    try {
        $f = Get-CimInstance -ClassName Win32_OptionalFeature -Filter ("Name = '{0}'" -f $Name.Replace("'", "''")) -ErrorAction Stop
    } catch {
        return 'Unknown'
    }
    if (-not $f) { return 'Missing' }
    switch ([int]$f.InstallState) {
        1 { return 'Enabled' }
        2 { return 'Disabled' }
        3 { return 'Missing' }
        default { return 'Unknown' }
    }
}

function Set-TwOptionalFeatureState {
    <#
    .SYNOPSIS
        Enables or disables an optional feature without forcing a restart.
    .EXAMPLE
        Set-TwOptionalFeatureState -Name 'Containers-DisposableClientVM' -State Enabled -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Enabled', 'Disabled')][string]$State
    )
    if ($PSCmdlet.ShouldProcess("feature $Name", "Set $State")) {
        if ($State -eq 'Enabled') {
            $null = Enable-WindowsOptionalFeature -Online -FeatureName $Name -All -NoRestart -ErrorAction Stop
        } else {
            $null = Disable-WindowsOptionalFeature -Online -FeatureName $Name -NoRestart -ErrorAction Stop
        }
    }
}
