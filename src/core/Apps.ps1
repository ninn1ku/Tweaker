# Program installation through WinGet (the only network access besides Windows itself).

function Test-TwWinget {
    <#
    .SYNOPSIS
        True when winget.exe (App Installer) is available.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return [bool](Get-Command -Name winget.exe -ErrorAction SilentlyContinue)
}

function Get-TwAppCatalog {
    <#
    .SYNOPSIS
        Program catalog from config/apps.json, flattened.
    #>
    [CmdletBinding()]
    param()
    foreach ($g in @((Get-TwJsonResource -Path 'config/apps.json').groups)) {
        foreach ($a in @($g.apps)) {
            [pscustomobject]@{ Group = $g.id; GroupName = Get-TwLocalizedText $g.name; Id = $a.id; Name = $a.name }
        }
    }
}

function Install-TwWingetPackage {
    <#
    .SYNOPSIS
        Installs one package silently with winget.
    .EXAMPLE
        Install-TwWingetPackage -Id 7zip.7zip -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9.+_-]*$')][string]$Id)
    if (-not (Test-TwWinget)) { throw 'winget is not installed' }
    $r = Invoke-TwNativeCommand -FilePath 'winget.exe' -ArgumentList 'install', '--id', $Id, '--exact', '--silent',
        '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity'
    # 0 = installed; -1978335189 (0x8A15002B) = already installed / no applicable upgrade.
    $ok = $r.ExitCode -in 0, -1978335189
    $level = if ($ok) { 'Success' } else { 'Error' }
    Write-TwLog -Level $level -Message "winget install $Id -> exit code $($r.ExitCode)"
    return [pscustomobject]@{ Id = $Id; Status = $(if ($ok) { 'Success' } else { 'Failed' }); ExitCode = $r.ExitCode }
}

function Update-TwWingetAll {
    <#
    .SYNOPSIS
        winget upgrade --all (updates every program winget knows).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (-not (Test-TwWinget)) { throw 'winget is not installed' }
    $r = Invoke-TwNativeCommand -FilePath 'winget.exe' -ArgumentList 'upgrade', '--all', '--silent', '--include-unknown',
        '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity'
    Write-TwLog -Message "winget upgrade --all -> exit code $($r.ExitCode)"
    return $r
}
