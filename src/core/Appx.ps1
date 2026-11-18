# Built-in (Appx/MSIX) apps: listing, protection rules and removal.
# Removal cannot be backed up: apps are reinstalled from Microsoft Store if needed.

function Get-TwAppxCatalog {
    [CmdletBinding()]
    param()
    return (Get-TwJsonResource -Path 'config/appx.json')
}

function Test-TwAppxProtected {
    <#
    .SYNOPSIS
        True when a package must never be removed (Store, WinGet, frameworks, shell, Edge...).
    .EXAMPLE
        Test-TwAppxProtected -Name 'Microsoft.WindowsStore'   # True
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [bool]$IsFramework,
        [bool]$NonRemovable
    )
    if ($IsFramework -or $NonRemovable) { return $true }
    foreach ($pattern in @((Get-TwAppxCatalog).protected)) {
        if ($Name -like $pattern) { return $true }
    }
    return $false
}

function Get-TwInstalledAppx {
    <#
    .SYNOPSIS
        Installed Appx packages with catalog info (title, risk, protected flag).
    .DESCRIPTION
        As administrator lists packages of all users; otherwise of the current user.
        Read-only.
    #>
    [CmdletBinding()]
    param()
    $catalog = Get-TwAppxCatalog
    $known = @{}
    foreach ($b in @($catalog.bloatware)) { $known[$b.name] = $b }
    $params = @{ ErrorAction = 'SilentlyContinue' }
    if (Test-TwAdministrator) { $params['AllUsers'] = $true }
    $packages = @(Get-AppxPackage @params | Where-Object { -not $_.IsFramework -and $_.SignatureKind -ne 'System' })
    foreach ($group in ($packages | Group-Object Name)) {
        $p = $group.Group[0]
        $info = $known[$p.Name]
        [pscustomobject]@{
            Name        = $p.Name
            Title       = if ($info) { Get-TwLocalizedText $info.title } else { $p.Name }
            Version     = [string]$p.Version
            Recommended = [bool]$info
            Risk        = if ($info) { $info.risk } else { 'moderate' }
            Protected   = Test-TwAppxProtected -Name $p.Name -IsFramework ([bool]$p.IsFramework) -NonRemovable ([bool]$p.NonRemovable)
        }
    }
}

function Remove-TwAppx {
    <#
    .SYNOPSIS
        Removes an app for all users and its provisioned copy (so new users do not get it).
    .DESCRIPTION
        Refuses protected packages. Returns an object with Name, Status and Message.
    .EXAMPLE
        Remove-TwAppx -Name Clipchamp.Clipchamp -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param([Parameter(Mandatory)][string]$Name)
    if (Test-TwAppxProtected -Name $Name) {
        Write-TwLog -Level Warning -Message "Appx $Name is protected and was not removed"
        return [pscustomobject]@{ Name = $Name; Status = 'Skipped'; Message = 'Protected' }
    }
    try {
        if ($PSCmdlet.ShouldProcess($Name, 'Remove app for all users and deprovision')) {
            foreach ($p in @(Get-AppxPackage -Name $Name -AllUsers -ErrorAction SilentlyContinue)) {
                Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop
            }
            foreach ($prov in @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $Name })) {
                $null = Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop
            }
            Write-TwLog -Level Success -Message "Removed app $Name (all users + provisioned)"
            return [pscustomobject]@{ Name = $Name; Status = 'Success'; Message = '' }
        }
        return [pscustomobject]@{ Name = $Name; Status = 'WhatIf'; Message = '' }
    } catch {
        Write-TwLog -Level Error -Message "Removing $Name failed: $($_.Exception.Message)"
        return [pscustomobject]@{ Name = $Name; Status = 'Failed'; Message = $_.Exception.Message }
    }
}

function Uninstall-TwOneDrive {
    <#
    .SYNOPSIS
        Uninstalls OneDrive (files stay in the OneDrive folder and in the cloud).
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param()
    $setup = @((Join-Path $env:SystemRoot 'System32\OneDriveSetup.exe'), (Join-Path $env:SystemRoot 'SysWOW64\OneDriveSetup.exe')) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (Test-TwWinget) {
        $r = Invoke-TwNativeCommand -FilePath 'winget.exe' -ArgumentList 'uninstall', '--id', 'Microsoft.OneDrive', '--exact', '--silent', '--accept-source-agreements', '--disable-interactivity'
    } elseif ($setup) {
        $r = Invoke-TwNativeCommand -FilePath $setup -ArgumentList '/uninstall'
    } else {
        throw 'OneDrive uninstaller not found'
    }
    Write-TwLog -Message "OneDrive uninstall finished with code $($r.ExitCode)"
    return $r
}
