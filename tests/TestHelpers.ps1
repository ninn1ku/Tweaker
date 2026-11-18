# Shared test setup. Dot-source from BeforeAll:  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
# Loads every engine file and points the context at a throw-away data folder.
# Nothing here touches the real system: Use-TwFakeSystem replaces every primitive
# that reads or writes system state with an in-memory model, and Use-TwTripwire makes
# any accidental call to a real state-changing cmdlet fail the test.

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:TwDevRoot = $script:RepoRoot
$script:TwEmbedded = $null
foreach ($dir in 'core', 'ui') {
    $path = Join-Path $script:RepoRoot "src\$dir"
    if (Test-Path $path) {
        foreach ($file in Get-ChildItem -Path $path -Filter '*.ps1' -File | Sort-Object Name) { . $file.FullName }
    }
}

function New-TwTestContext {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'In-memory only')]
    param([string]$Language = 'ru')
    $dataRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('tweaker-test-' + [guid]::NewGuid().ToString('N'))
    $null = Initialize-TwContext -Language $Language -DataRoot $dataRoot
    return $dataRoot
}

function Use-TwTripwire {
    # Real state-changing cmdlets must never run in tests.
    foreach ($cmd in 'New-ItemProperty', 'Set-ItemProperty', 'Remove-ItemProperty', 'Stop-Service', 'Start-Service',
        'Set-Service', 'Disable-ScheduledTask', 'Enable-ScheduledTask', 'Checkpoint-Computer', 'Enable-ComputerRestore',
        'Enable-WindowsOptionalFeature', 'Disable-WindowsOptionalFeature', 'Remove-AppxPackage', 'Remove-AppxProvisionedPackage',
        'Stop-Process', 'Clear-RecycleBin', 'Set-DnsClientServerAddress') {
        Mock $cmd { throw "Tripwire: real system call '$($MyInvocation.MyCommand.Name)' attempted in a test" }
    }
    Mock Invoke-TwNativeCommand { throw "Tripwire: native command $FilePath $($ArgumentList -join ' ') attempted in a test" }
}

function Use-TwFakeSystem {
    <#
        In-memory registry / services / tasks / features. Returns the state object so
        tests can seed and inspect it.
    #>
    param([int]$Build = 26100, [switch]$RealRestorePoint)
    $state = @{
        Reg      = @{}     # 'provider|name' -> @{ Type; Value }
        Keys     = @{}     # provider path -> $true
        Services = @{}     # name -> startup type
        Tasks    = @{}     # path -> Enabled/Disabled
        Features = @{}     # name -> Enabled/Disabled
        Calls    = New-Object System.Collections.ArrayList
    }
    $script:Fake = $state

    Use-TwTripwire

    $script:FakeBuild = $Build
    Mock Get-TwOsInfo { [pscustomobject]@{ Build = $script:FakeBuild; Ubr = 1; DisplayVersion = 'test'; Edition = 'Professional'; ProductName = 'Windows 11 Pro'; IsWindows11 = $true; IsServer = $false; Supported = $true } }

    Mock Get-TwRegistryValue {
        $p = ConvertTo-TwRegistryProviderPath -Path $Path -UserSid $UserSid
        $k = "$p|$Name".ToLowerInvariant()
        $r = [pscustomobject]@{ Path = $p; Name = $Name; KeyExists = $script:Fake.Keys.ContainsKey($p.ToLowerInvariant()); Exists = $false; Type = $null; Value = $null }
        if ($script:Fake.Reg.ContainsKey($k)) { $r.Exists = $true; $r.KeyExists = $true; $r.Type = $script:Fake.Reg[$k].Type; $r.Value = $script:Fake.Reg[$k].Value }
        $r
    }
    Mock Get-TwMissingKeyRoot {
        if ($script:Fake.Keys.ContainsKey($ProviderPath.ToLowerInvariant())) { return $null }
        $ProviderPath
    }
    Mock Set-TwRegistryValue {
        if ($WhatIfPreference) { [void]$script:Fake.Calls.Add("WHATIF set $Path|$Name"); return }
        $p = ConvertTo-TwRegistryProviderPath -Path $Path -UserSid $UserSid
        $script:Fake.Keys[$p.ToLowerInvariant()] = $true
        $script:Fake.Reg["$p|$Name".ToLowerInvariant()] = @{ Type = $Type; Value = $Value }
        [void]$script:Fake.Calls.Add("set $p|$Name=$Value")
    }
    Mock Remove-TwRegistryValue {
        if ($WhatIfPreference) { [void]$script:Fake.Calls.Add("WHATIF remove $Path|$Name"); return }
        $p = ConvertTo-TwRegistryProviderPath -Path $Path -UserSid $UserSid
        $script:Fake.Reg.Remove("$p|$Name".ToLowerInvariant())
        [void]$script:Fake.Calls.Add("remove $p|$Name")
    }
    Mock Remove-TwRegistryKey {
        if ($WhatIfPreference) { [void]$script:Fake.Calls.Add("WHATIF removekey $Path"); return }
        $p = (ConvertTo-TwRegistryProviderPath -Path $Path -UserSid $UserSid).ToLowerInvariant()
        foreach ($k in @($script:Fake.Keys.Keys)) { if ($k -eq $p -or $k.StartsWith("$p\")) { $script:Fake.Keys.Remove($k) } }
        foreach ($k in @($script:Fake.Reg.Keys)) { if ($k.StartsWith("$p|") -or $k.StartsWith("$p\")) { $script:Fake.Reg.Remove($k) } }
        [void]$script:Fake.Calls.Add("removekey $p")
    }
    Mock Get-TwServiceConfig {
        if ($script:Fake.Services.ContainsKey($Name)) { return [pscustomobject]@{ Name = $Name; Exists = $true; StartupType = $script:Fake.Services[$Name] } }
        [pscustomobject]@{ Name = $Name; Exists = $false; StartupType = $null }
    }
    Mock Set-TwServiceStartup {
        if ($WhatIfPreference) { [void]$script:Fake.Calls.Add("WHATIF service $Name"); return }
        $script:Fake.Services[$Name] = $StartupType
        [void]$script:Fake.Calls.Add("service $Name=$StartupType")
    }
    Mock Get-Service { [pscustomobject]@{ Name = $Name; Status = 'Running' } }
    Mock Get-TwTaskState {
        if ($script:Fake.Tasks.ContainsKey($Path)) { return $script:Fake.Tasks[$Path] }
        'Missing'
    }
    Mock Set-TwTaskState {
        if ($WhatIfPreference) { [void]$script:Fake.Calls.Add("WHATIF task $Path"); return }
        $script:Fake.Tasks[$Path] = $State
        [void]$script:Fake.Calls.Add("task $Path=$State")
    }
    Mock Get-TwOptionalFeatureState {
        if ($script:Fake.Features.ContainsKey($Name)) { return $script:Fake.Features[$Name] }
        'Missing'
    }
    Mock Set-TwOptionalFeatureState {
        if ($WhatIfPreference) { [void]$script:Fake.Calls.Add("WHATIF feature $Name"); return }
        $script:Fake.Features[$Name] = $State
        [void]$script:Fake.Calls.Add("feature $Name=$State")
    }
    if (-not $RealRestorePoint) { Mock New-TwRestorePoint { [pscustomobject]@{ Success = $true; WhatIf = $false; Message = '' } } }
    Mock Restart-TwExplorer { [void]$script:Fake.Calls.Add('explorer restart') }
    return $state
}

function Set-TwFakeRegistry {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'In-memory only')]
    param([string]$Path, [string]$Name, [string]$Type, $Value)
    $p = ConvertTo-TwRegistryProviderPath -Path $Path
    $script:Fake.Keys[$p.ToLowerInvariant()] = $true
    $script:Fake.Reg["$p|$Name".ToLowerInvariant()] = @{ Type = $Type; Value = $Value }
}

function Get-TwFakeRegistry {
    param([string]$Path, [string]$Name)
    $p = ConvertTo-TwRegistryProviderPath -Path $Path
    $k = "$p|$Name".ToLowerInvariant()
    if ($script:Fake.Reg.ContainsKey($k)) { return $script:Fake.Reg[$k] }
    return $null
}

function New-TwTestTweak {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'In-memory only')]
    param([hashtable]$Overrides = @{})
    $base = [ordered]@{
        id                      = 'privacy.test-tweak'
        category                = 'privacy'
        name                    = @{ ru = 'Test'; en = 'Test' }
        description             = @{ ru = 'Test'; en = 'Test' }
        risk                    = 'safe'
        minBuild                = 19045
        requiresReboot          = $false
        requiresExplorerRestart = $false
        requiresSignOut         = $false
        presets                 = @()
        verified                = $true
        source                  = 'https://learn.microsoft.com/'
        registry                = @()
        services                = @()
        scheduledTasks          = @()
        optionalFeatures        = @()
        commands                = @()
        undo                    = @{}
    }
    foreach ($k in $Overrides.Keys) { $base[$k] = $Overrides[$k] }
    # Round-trip through JSON so the object looks exactly like catalog data.
    return ($base | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
}
