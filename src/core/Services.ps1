# Windows services: read startup type from the registry (exact, includes "delayed"),
# change it through sc.exe (the only built-in tool that sets delayed auto-start on 5.1).

function Invoke-TwNativeCommand {
    <#
    .SYNOPSIS
        Runs a native executable and returns its exit code and output.
    .DESCRIPTION
        Single choke point for external tools (sc.exe, powercfg.exe, ...): makes
        them mockable and honours -WhatIf.
    .EXAMPLE
        Invoke-TwNativeCommand -FilePath 'sc.exe' -ArgumentList 'qc', 'DiagTrack'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [switch]$ReadOnlyCommand
    )
    $display = "$FilePath $($ArgumentList -join ' ')"
    if ($ReadOnlyCommand -or $PSCmdlet.ShouldProcess($display, 'Run')) {
        $output = & $FilePath @ArgumentList 2>&1 | ForEach-Object { "$_" }
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join [Environment]::NewLine) }
    }
    return [pscustomobject]@{ ExitCode = 0; Output = '' ; WhatIf = $true }
}

function Get-TwServiceConfig {
    <#
    .SYNOPSIS
        Returns whether a service exists and its exact startup type.
    .OUTPUTS
        Object with Name, Exists, StartupType (Boot, System, Automatic,
        AutomaticDelayed, Manual, Disabled).
    .EXAMPLE
        Get-TwServiceConfig -Name DiagTrack
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $path = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    $start = Get-TwRegistryValue -Path $path -Name 'Start'
    $result = [pscustomobject]@{ Name = $Name; Exists = $false; StartupType = $null }
    if (-not $start.Exists) { return $result }
    $result.Exists = $true
    $map = @{ 0 = 'Boot'; 1 = 'System'; 2 = 'Automatic'; 3 = 'Manual'; 4 = 'Disabled' }
    $type = $map[[int]$start.Value]
    if ($type -eq 'Automatic') {
        $delayed = Get-TwRegistryValue -Path $path -Name 'DelayedAutostart'
        if ($delayed.Exists -and [int]$delayed.Value -eq 1) { $type = 'AutomaticDelayed' }
    }
    $result.StartupType = $type
    return $result
}

function Set-TwServiceStartup {
    <#
    .SYNOPSIS
        Changes a service startup type (optionally stopping or starting it).
    .PARAMETER Name
        Service name.
    .PARAMETER StartupType
        Automatic, AutomaticDelayed, Manual or Disabled.
    .PARAMETER Stop
        Stop the service now (used together with Disabled/Manual).
    .PARAMETER Start
        Start the service now (used when restoring an automatic service).
    .EXAMPLE
        Set-TwServiceStartup -Name DiagTrack -StartupType Disabled -Stop -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Automatic', 'AutomaticDelayed', 'Manual', 'Disabled', 'Boot', 'System')][string]$StartupType,
        [switch]$Stop,
        [switch]$Start
    )
    $scType = switch ($StartupType) {
        'Automatic' { 'auto' }
        'AutomaticDelayed' { 'delayed-auto' }
        'Manual' { 'demand' }
        'Disabled' { 'disabled' }
        'Boot' { 'boot' }
        'System' { 'system' }
    }
    if ($PSCmdlet.ShouldProcess("service $Name", "Set startup type $StartupType")) {
        $r = Invoke-TwNativeCommand -FilePath 'sc.exe' -ArgumentList @('config', $Name, 'start=', $scType)
        if ($r.ExitCode -ne 0) { throw "sc.exe config $Name failed ($($r.ExitCode)): $($r.Output)" }
        if ($Stop) {
            $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -ne 'Stopped') { Stop-Service -Name $Name -Force -ErrorAction Stop }
        }
        if ($Start) {
            $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -ne 'Running') { Start-Service -Name $Name -ErrorAction Stop }
        }
    }
}
