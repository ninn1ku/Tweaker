# Presets and user configuration export / import.

function Get-TwPreset {
    <#
    .SYNOPSIS
        Lists presets from config/presets/*.json, in display order.
    .EXAMPLE
        Get-TwPreset | Select-Object id
    #>
    [CmdletBinding()]
    param([string]$Name)
    $presets = foreach ($res in Get-TwResourceList -Folder 'config/presets') { Get-TwJsonResource -Path $res }
    $presets = @($presets | Sort-Object { [int](Get-TwObjectProperty $_ 'order' 99) })
    if ($Name) { return @($presets | Where-Object { $_.id -eq $Name }) }
    return $presets
}

function Resolve-TwPresetTweakId {
    <#
    .SYNOPSIS
        Returns the ids of tweaks a preset applies on this machine.
    .DESCRIPTION
        A tweak belongs to a preset when its "presets" array lists it. Unverified
        tweaks and tweaks outside the running build range are never included.
    .EXAMPLE
        Resolve-TwPresetTweakId -Name recommended
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Get-TwPreset -Name $Name)) { throw "Unknown preset: $Name" }
    return @(Import-TwTweakCatalog | Where-Object {
            $_.verified -and @($_.presets) -contains $Name -and (Test-TwTweakSupported -Tweak $_)
        } | ForEach-Object { $_.id })
}

function Export-TwUserConfig {
    <#
    .SYNOPSIS
        Saves the list of currently applied tweaks to a JSON file.
    .DESCRIPTION
        The file can be imported on another PC (or after reinstalling Windows) with
        -Import. Only tweak ids are stored, no machine data.
    .EXAMPLE
        Export-TwUserConfig -Path .\my-tweaks.json
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path)
    $applied = @(Import-TwTweakCatalog | Where-Object { (Get-TwTweakState -Tweak $_) -eq 'Applied' } | ForEach-Object { $_.id })
    $doc = [ordered]@{
        tool     = 'Tweaker'
        version  = 1
        exported = (Get-Date).ToString('o')
        tweaks   = $applied
    }
    # .NET resolves relative paths against the process directory, not the PowerShell location.
    $Path = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)
    if ($PSCmdlet.ShouldProcess($Path, "Export $($applied.Count) tweak id(s)")) {
        [System.IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $doc -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    }
    return $applied
}

function Import-TwUserConfig {
    <#
    .SYNOPSIS
        Reads a file written by Export-TwUserConfig and returns its tweak ids.
    .DESCRIPTION
        Unknown ids are reported and ignored. Nothing is applied by this function.
    .EXAMPLE
        Invoke-TwTweakBatch -Apply (Import-TwUserConfig -Path .\my-tweaks.json)
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Path)
    $doc = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if ((Get-TwObjectProperty $doc 'tool') -ne 'Tweaker') { throw "Not a Tweaker configuration file: $Path" }
    $known = @{}
    foreach ($t in Import-TwTweakCatalog) { $known[$t.id] = $true }
    $ids = @()
    foreach ($id in @(Get-TwObjectProperty $doc 'tweaks' @())) {
        if ($id -is [string] -and $known.ContainsKey($id)) { $ids += $id }
        else { Write-TwLog -Level Warning -Message "Import: unknown tweak id ignored: $id" }
    }
    return $ids
}
