# "Is this tweak applied right now?" - always computed from the live system.

function Test-TwTweakSupported {
    <#
    .SYNOPSIS
        True when the tweak's minBuild/maxBuild range includes the running build.
    .PARAMETER Tweak
        Tweak definition.
    .PARAMETER Build
        Build number to test against (defaults to the running OS).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Tweak, [int]$Build)
    if (-not $Build) { $Build = (Get-TwOsInfo).Build }
    $min = Get-TwObjectProperty $Tweak 'minBuild'
    $max = Get-TwObjectProperty $Tweak 'maxBuild'
    if ($null -ne $min -and $Build -lt [int]$min) { return $false }
    if ($null -ne $max -and $Build -gt [int]$max) { return $false }
    return $true
}

function Get-TwTweakCheck {
    <#
    .SYNOPSIS
        Evaluates each detectable action of a tweak.
    .OUTPUTS
        Objects with Target, Expected, Actual, Match ($true/$false; $null = not applicable).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Tweak)
    $ctx = Get-TwContext
    foreach ($r in @(Get-TwObjectProperty $Tweak 'registry' @())) {
        $cur = Get-TwRegistryValue -Path $r.path -Name $r.name -UserSid $ctx.TargetUserSid
        $expected = ConvertTo-TwComparableRegistryValue -Type $r.type -Value $r.value
        $actual = if ($cur.Exists) { ConvertTo-TwComparableRegistryValue -Type $r.type -Value $cur.Value } else { '<absent>' }
        [pscustomobject]@{ Kind = 'registry'; Target = "$($r.path)\$($r.name)"; Expected = $expected; Actual = $actual; Match = ($cur.Exists -and $expected -eq $actual) }
    }
    foreach ($s in @(Get-TwObjectProperty $Tweak 'services' @())) {
        $cur = Get-TwServiceConfig -Name $s.name
        $match = $null
        if ($cur.Exists) { $match = ($cur.StartupType -eq $s.startupType) }
        [pscustomobject]@{ Kind = 'service'; Target = $s.name; Expected = $s.startupType; Actual = $cur.StartupType; Match = $match }
    }
    foreach ($t in @(Get-TwObjectProperty $Tweak 'scheduledTasks' @())) {
        $state = Get-TwTaskState -Path $t.path
        $match = $null
        if ($state -ne 'Missing') { $match = ($state -eq $t.state) }
        [pscustomobject]@{ Kind = 'task'; Target = $t.path; Expected = $t.state; Actual = $state; Match = $match }
    }
    foreach ($f in @(Get-TwObjectProperty $Tweak 'optionalFeatures' @())) {
        $state = Get-TwOptionalFeatureState -Name $f.name
        $match = $null
        if (@('Enabled', 'Disabled') -contains $state) { $match = ($state -eq $f.state) }
        [pscustomobject]@{ Kind = 'feature'; Target = $f.name; Expected = $f.state; Actual = $state; Match = $match }
    }
    foreach ($c in @(Get-TwObjectProperty $Tweak 'commands' @())) {
        $match = $null
        try { $match = Invoke-TwCommandAction -Name $c.name -Action Detect -Arguments (Get-TwObjectProperty $c 'args') } catch { $match = $null }
        [pscustomobject]@{ Kind = 'command'; Target = $c.name; Expected = 'applied'; Actual = $match; Match = $match }
    }
}

function Get-TwTweakState {
    <#
    .SYNOPSIS
        Returns Applied, NotApplied, Partial, Unsupported or Unknown.
    .DESCRIPTION
        detect.mode "all" (default): every applicable check must match.
        detect.mode "any": one matching check is enough.
        Checks that do not apply (missing service/task) are ignored.
    .EXAMPLE
        Get-TwTweak -Id privacy.disable-telemetry | Get-TwTweakState
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, ValueFromPipeline)]$Tweak)
    process {
        if (-not (Test-TwTweakSupported -Tweak $Tweak)) { return 'Unsupported' }
        foreach ($f in @(Get-TwObjectProperty $Tweak 'optionalFeatures' @())) {
            if ((Get-TwOptionalFeatureState -Name $f.name) -eq 'Missing') { return 'Unsupported' }
        }
        try {
            $checks = @(Get-TwTweakCheck -Tweak $Tweak | Where-Object { $null -ne $_.Match })
        } catch {
            Write-TwLog -Level Debug -Message "Detection failed for $($Tweak.id): $($_.Exception.Message)"
            return 'Unknown'
        }
        if ($checks.Count -eq 0) { return 'Unknown' }
        $matched = @($checks | Where-Object { $_.Match }).Count
        $mode = Get-TwObjectProperty (Get-TwObjectProperty $Tweak 'detect') 'mode' 'all'
        if ($mode -eq 'any') {
            if ($matched -gt 0) { return 'Applied' }
            return 'NotApplied'
        }
        if ($matched -eq $checks.Count) { return 'Applied' }
        if ($matched -eq 0) { return 'NotApplied' }
        return 'Partial'
    }
}
