# Registry primitives. Every write goes through Set-TwRegistryValue /
# Remove-TwRegistryValue / Remove-TwRegistryKey (SupportsShouldProcess), which
# makes them easy to mock in tests and honours -WhatIf everywhere.

function ConvertTo-TwRegistryProviderPath {
    <#
    .SYNOPSIS
        Converts HKLM:\ / HKCU:\ paths into Registry:: provider paths.
    .DESCRIPTION
        HKCU paths are redirected to HKEY_USERS\<sid> when a target user SID is
        given (elevated as a different account, or the Default user hive).
    .PARAMETER Path
        Path as written in tweak JSON: HKLM:\..., HKCU:\... (HKU:\ also accepted).
    .PARAMETER UserSid
        Optional SID (or mounted hive name) to use instead of HKEY_CURRENT_USER.
    .EXAMPLE
        ConvertTo-TwRegistryProviderPath 'HKCU:\Software\Foo' -UserSid 'S-1-5-21-1'
        # Registry::HKEY_USERS\S-1-5-21-1\Software\Foo
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [string]$UserSid
    )
    if ($Path -like 'Registry::*') { return $Path }
    if ($Path -notmatch '^(?<hive>HKLM|HKCU|HKU|HKCR|HKEY_LOCAL_MACHINE|HKEY_CURRENT_USER|HKEY_USERS):?\\?(?<rest>.*)$') {
        throw "Unsupported registry path: $Path"
    }
    $rest = $Matches['rest'].TrimEnd('\')
    switch -Regex ($Matches['hive']) {
        '^(HKLM|HKEY_LOCAL_MACHINE)$' { $root = 'HKEY_LOCAL_MACHINE' }
        '^(HKU|HKEY_USERS)$' { $root = 'HKEY_USERS' }
        '^HKCR$' { $root = 'HKEY_CLASSES_ROOT' }
        default {
            if ($UserSid) { $root = "HKEY_USERS\$UserSid" } else { $root = 'HKEY_CURRENT_USER' }
        }
    }
    if ($rest) { return "Registry::$root\$rest" }
    return "Registry::$root"
}

function ConvertTo-TwRegistryData {
    <#
    .SYNOPSIS
        Converts a JSON value into the .NET value expected for a registry type.
    .DESCRIPTION
        DWORD values above 0x7FFFFFFF are converted to their signed Int32 bit pattern
        (that is what the registry API expects); Binary accepts an array of bytes or a
        hex string; MultiString accepts an array of strings.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('String', 'ExpandString', 'DWord', 'QWord', 'Binary', 'MultiString')][string]$Type,
        [AllowNull()]$Value
    )
    switch ($Type) {
        'DWord' {
            $n = [int64]$Value
            if ($n -lt [int32]::MinValue -or $n -gt [uint32]::MaxValue) { throw "DWORD value out of range: $Value" }
            if ($n -gt [int32]::MaxValue) { return [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]$n), 0) }
            return [int32]$n
        }
        'QWord' {
            $d = [decimal]$Value
            if ($d -gt [decimal][int64]::MaxValue) { return [BitConverter]::ToInt64([BitConverter]::GetBytes([uint64]$d), 0) }
            return [int64]$d
        }
        'Binary' {
            if ($Value -is [string]) {
                $hex = $Value -replace '[^0-9A-Fa-f]', ''
                $bytes = New-Object byte[] ($hex.Length / 2)
                for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [Convert]::ToByte($hex.Substring($i * 2, 2), 16) }
                return , $bytes
            }
            return , ([byte[]]@($Value))
        }
        'MultiString' { return , ([string[]]@($Value)) }
        default { return [string]$Value }
    }
}

function ConvertTo-TwComparableRegistryValue {
    <#
    .SYNOPSIS
        Normalises a registry value to a string for equality checks.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Type, [AllowNull()]$Value)
    if ($null -eq $Value) { return '<null>' }
    switch ($Type) {
        'DWord' { return ([uint32]([BitConverter]::ToUInt32([BitConverter]::GetBytes([int32](ConvertTo-TwRegistryData -Type DWord -Value $Value)), 0))).ToString() }
        'QWord' { return ([BitConverter]::ToUInt64([BitConverter]::GetBytes([int64](ConvertTo-TwRegistryData -Type QWord -Value $Value)), 0)).ToString() }
        'Binary' { return ((ConvertTo-TwRegistryData -Type Binary -Value $Value) | ForEach-Object { $_.ToString('X2') }) -join '' }
        'MultiString' { return (@($Value) -join "`n") }
        default { return [string]$Value }
    }
}

function Get-TwRegistryValue {
    <#
    .SYNOPSIS
        Reads a registry value without changing anything.
    .OUTPUTS
        Object with KeyExists, Exists, Type and Value.
    .PARAMETER Path
        HKLM:\ / HKCU:\ path or a Registry:: provider path.
    .PARAMETER Name
        Value name; empty string or '(Default)' for the default value.
    .PARAMETER UserSid
        Redirect HKCU to HKEY_USERS\<sid>.
    .EXAMPLE
        Get-TwRegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Name,
        [string]$UserSid
    )
    $provider = ConvertTo-TwRegistryProviderPath -Path $Path -UserSid $UserSid
    if ($Name -eq '(Default)') { $Name = '' }
    $result = [pscustomobject]@{ Path = $provider; Name = $Name; KeyExists = $false; Exists = $false; Type = $null; Value = $null }
    $key = Get-Item -LiteralPath $provider -ErrorAction SilentlyContinue
    if (-not $key) { return $result }
    $result.KeyExists = $true
    try {
        if ($key.GetValueNames() -notcontains $Name) { return $result }
        $kind = $key.GetValueKind($Name)
        $raw = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $result.Exists = $true
        $result.Type = [string]$kind
        if ($kind -eq [Microsoft.Win32.RegistryValueKind]::DWord) { $raw = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int32]$raw), 0) }
        if ($kind -eq [Microsoft.Win32.RegistryValueKind]::Binary) { $raw = @($raw | ForEach-Object { [int]$_ }) }
        if ($kind -eq [Microsoft.Win32.RegistryValueKind]::MultiString) { $raw = @($raw) }
        $result.Value = $raw
    } finally {
        $key.Close()
    }
    return $result
}

function Get-TwMissingKeyRoot {
    <#
    .SYNOPSIS
        Returns the top-most ancestor of a key that does not exist yet (or $null).
    .DESCRIPTION
        Used by the backup: when a tweak creates a new key branch, undo removes the
        whole branch it created and nothing else.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$ProviderPath)
    if (Test-Path -LiteralPath $ProviderPath) { return $null }
    $missing = $ProviderPath
    $parent = Split-Path -Path $ProviderPath -Parent
    while ($parent -and $parent -notmatch '^Registry::[^\\]+$' -and -not (Test-Path -LiteralPath $parent)) {
        $missing = $parent
        $parent = Split-Path -Path $parent -Parent
    }
    return $missing
}

function Set-TwRegistryValue {
    <#
    .SYNOPSIS
        Creates or updates a registry value (creating the key if needed).
    .PARAMETER Path
        HKLM:\ / HKCU:\ path or Registry:: provider path.
    .PARAMETER Name
        Value name ('' for the default value).
    .PARAMETER Type
        String, ExpandString, DWord, QWord, Binary, MultiString.
    .PARAMETER Value
        Data, converted with ConvertTo-TwRegistryData.
    .PARAMETER UserSid
        Redirect HKCU to HKEY_USERS\<sid>.
    .EXAMPLE
        Set-TwRegistryValue 'HKCU:\Software\Foo' 'Bar' DWord 1 -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Name,
        [Parameter(Mandatory, Position = 2)][ValidateSet('String', 'ExpandString', 'DWord', 'QWord', 'Binary', 'MultiString')][string]$Type,
        [Parameter(Position = 3)][AllowNull()][AllowEmptyString()]$Value,
        [string]$UserSid
    )
    $provider = ConvertTo-TwRegistryProviderPath -Path $Path -UserSid $UserSid
    if ($Name -eq '(Default)') { $Name = '' }
    $data = ConvertTo-TwRegistryData -Type $Type -Value $Value
    $display = if ($Name) { $Name } else { '(Default)' }
    if ($PSCmdlet.ShouldProcess("$provider\$display", "Set $Type = $(ConvertTo-TwComparableRegistryValue -Type $Type -Value $Value)")) {
        if (-not (Test-Path -LiteralPath $provider)) {
            $null = New-Item -Path $provider -Force -ErrorAction Stop
        }
        if ($Name -eq '') {
            Set-ItemProperty -LiteralPath $provider -Name '(default)' -Value $data -Type $Type -Force -ErrorAction Stop
        } else {
            $null = New-ItemProperty -LiteralPath $provider -Name $Name -PropertyType $Type -Value $data -Force -ErrorAction Stop
        }
    }
}

function Remove-TwRegistryValue {
    <#
    .SYNOPSIS
        Deletes a registry value if it exists.
    .EXAMPLE
        Remove-TwRegistryValue 'HKCU:\Software\Foo' 'Bar' -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Name,
        [string]$UserSid
    )
    $provider = ConvertTo-TwRegistryProviderPath -Path $Path -UserSid $UserSid
    if ($Name -eq '(Default)') { $Name = '' }
    $current = Get-TwRegistryValue -Path $provider -Name $Name
    if (-not $current.Exists) { return }
    $display = if ($Name) { $Name } else { '(Default)' }
    if ($PSCmdlet.ShouldProcess("$provider\$display", 'Delete value')) {
        Remove-ItemProperty -LiteralPath $provider -Name $Name -Force -ErrorAction Stop
    }
}

function Remove-TwRegistryKey {
    <#
    .SYNOPSIS
        Deletes a registry key with all subkeys (used to undo keys a tweak created).
    .EXAMPLE
        Remove-TwRegistryKey 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}' -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [string]$UserSid
    )
    $provider = ConvertTo-TwRegistryProviderPath -Path $Path -UserSid $UserSid
    if (-not (Test-Path -LiteralPath $provider)) { return }
    if ($provider -match '^Registry::[^\\]+(\\[^\\]+)?$' -or $provider -match '^Registry::HKEY_LOCAL_MACHINE\\(SOFTWARE|SYSTEM)$') {
        throw "Refusing to delete a top-level key: $provider"
    }
    if ($PSCmdlet.ShouldProcess($provider, 'Delete key')) {
        Remove-Item -LiteralPath $provider -Recurse -Force -ErrorAction Stop
    }
}
