# Repair and maintenance tools.

function Invoke-TwSystemFileCheck {
    <#
    .SYNOPSIS
        sfc /scannow (checks and repairs protected system files).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $r = Invoke-TwNativeCommand -FilePath 'sfc.exe' -ArgumentList '/scannow'
    # sfc writes UTF-16 with NUL characters into redirected output.
    $text = ($r.Output -replace "`0", '').Trim()
    Write-TwLog -Message "sfc /scannow -> exit code $($r.ExitCode)"
    return [pscustomobject]@{ ExitCode = $r.ExitCode; Output = $text }
}

function Invoke-TwDismRestoreHealth {
    <#
    .SYNOPSIS
        DISM /Online /Cleanup-Image /RestoreHealth (repairs the component store).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $r = Invoke-TwNativeCommand -FilePath 'dism.exe' -ArgumentList '/Online', '/Cleanup-Image', '/RestoreHealth'
    Write-TwLog -Message "DISM RestoreHealth -> exit code $($r.ExitCode)"
    return $r
}

function Reset-TwWindowsUpdate {
    <#
    .SYNOPSIS
        Resets Windows Update components (classic Microsoft procedure).
    .DESCRIPTION
        Stops wuauserv, bits, cryptsvc and msiserver, renames SoftwareDistribution
        and catroot2 to *.bak-<timestamp> (nothing is deleted) and starts the
        services again. Update history in Settings becomes empty.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param()
    $services = 'wuauserv', 'bits', 'cryptsvc', 'msiserver'
    if (-not $PSCmdlet.ShouldProcess('Windows Update components', 'Reset')) { return }
    foreach ($s in $services) { Stop-Service -Name $s -Force -ErrorAction SilentlyContinue }
    $stamp = Get-Date -Format 'yyyyMMddHHmmss'
    foreach ($dir in (Join-Path $env:SystemRoot 'SoftwareDistribution'), (Join-Path $env:SystemRoot 'System32\catroot2')) {
        if (Test-Path -LiteralPath $dir) {
            try { Rename-Item -LiteralPath $dir -NewName ((Split-Path $dir -Leaf) + ".bak-$stamp") -ErrorAction Stop }
            catch { Write-TwLog -Level Warning -Message "Could not rename ${dir}: $($_.Exception.Message)" }
        }
    }
    foreach ($s in $services) { Start-Service -Name $s -ErrorAction SilentlyContinue }
    Write-TwLog -Level Success -Message 'Windows Update components reset'
}

function Get-TwClassicPanel {
    <#
    .SYNOPSIS
        Classic control panels Tweaker can open. Names come from config/lang (panel.<id>).
    #>
    [CmdletBinding()]
    param()
    @(
        [pscustomobject]@{ Id = 'control'; File = 'control.exe'; Arguments = @() }
        [pscustomobject]@{ Id = 'appwiz'; File = 'control.exe'; Arguments = @('appwiz.cpl') }
        [pscustomobject]@{ Id = 'sysdm'; File = 'SystemPropertiesAdvanced.exe'; Arguments = @() }
        [pscustomobject]@{ Id = 'ncpa'; File = 'control.exe'; Arguments = @('ncpa.cpl') }
        [pscustomobject]@{ Id = 'powercfg'; File = 'control.exe'; Arguments = @('powercfg.cpl') }
        [pscustomobject]@{ Id = 'sound'; File = 'control.exe'; Arguments = @('mmsys.cpl') }
        [pscustomobject]@{ Id = 'devmgmt'; File = 'devmgmt.msc'; Arguments = @() }
        [pscustomobject]@{ Id = 'services'; File = 'services.msc'; Arguments = @() }
        [pscustomobject]@{ Id = 'taskschd'; File = 'taskschd.msc'; Arguments = @() }
        [pscustomobject]@{ Id = 'eventvwr'; File = 'eventvwr.msc'; Arguments = @() }
        [pscustomobject]@{ Id = 'diskmgmt'; File = 'diskmgmt.msc'; Arguments = @() }
        [pscustomobject]@{ Id = 'restore'; File = 'rstrui.exe'; Arguments = @() }
    )
}

function Open-TwClassicPanel {
    <#
    .SYNOPSIS
        Opens a classic control panel by id.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Id)
    $p = Get-TwClassicPanel | Where-Object Id -eq $Id
    if (-not $p) { throw "Unknown panel: $Id" }
    if ($PSCmdlet.ShouldProcess($p.File, 'Open')) {
        if ($p.Arguments.Count -gt 0) { Start-Process -FilePath $p.File -ArgumentList $p.Arguments }
        else { Start-Process -FilePath $p.File }
    }
}
