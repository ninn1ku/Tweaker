# Minimal JSON Schema (draft-07 subset) validator. Windows PowerShell 5.1 has no
# Test-Json, and the tweaker must not depend on external modules at runtime.
# Supported keywords: type, enum, const, required, properties, additionalProperties
# (boolean or schema), items, minItems, maxItems, uniqueItems, minLength, pattern,
# minimum, maximum, oneOf, anyOf, $ref (local "#/definitions/<name>").

function Get-TwJsonType {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { return 'boolean' }
    if ($Value -is [string]) { return 'string' }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [byte] -or
        $Value -is [uint32] -or $Value -is [uint64] -or $Value -is [System.Numerics.BigInteger]) { return 'integer' }
    if ($Value -is [double] -or $Value -is [decimal] -or $Value -is [single]) {
        if ([math]::Floor([double]$Value) -eq [double]$Value) { return 'integer' }
        return 'number'
    }
    if ($Value -is [System.Collections.IDictionary] -or $Value -is [System.Management.Automation.PSCustomObject]) { return 'object' }
    if ($Value -is [System.Collections.IEnumerable]) { return 'array' }
    return 'object'
}

function Get-TwJsonMember {
    [CmdletBinding()]
    param($Object)
    if ($Object -is [System.Collections.IDictionary]) {
        return @($Object.Keys | ForEach-Object { [pscustomobject]@{ Name = [string]$_; Value = $Object[$_] } })
    }
    return @($Object.PSObject.Properties | Where-Object { $_.MemberType -eq 'NoteProperty' } |
            ForEach-Object { [pscustomobject]@{ Name = $_.Name; Value = $_.Value } })
}

function Test-TwJsonSchema {
    <#
    .SYNOPSIS
        Validates a parsed JSON value against a JSON Schema subset.
    .OUTPUTS
        Error messages (strings). No output means the value is valid.
    .PARAMETER InputObject
        Parsed JSON value (ConvertFrom-Json output).
    .PARAMETER Schema
        Parsed schema.
    .PARAMETER Root
        Root schema for $ref resolution (defaults to -Schema).
    .PARAMETER Path
        JSON pointer-like location used in messages.
    .EXAMPLE
        Test-TwJsonSchema -InputObject $doc -Schema $schema
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory)]$Schema,
        $Root,
        [string]$Path = '$'
    )
    if ($null -eq $Root) { $Root = $Schema }
    if ($Schema -is [bool]) {
        if (-not $Schema) { "${Path}: value is not allowed" }
        return
    }

    $ref = Get-TwObjectProperty $Schema '$ref'
    if ($ref) {
        if ($ref -notmatch '^#/definitions/(.+)$') { "${Path}: unsupported `$ref '$ref'"; return }
        $target = Get-TwObjectProperty (Get-TwObjectProperty $Root 'definitions') $Matches[1]
        if ($null -eq $target) { "${Path}: unresolved `$ref '$ref'"; return }
        Test-TwJsonSchema -InputObject $InputObject -Schema $target -Root $Root -Path $Path
        return
    }

    $actual = Get-TwJsonType $InputObject

    $type = Get-TwObjectProperty $Schema 'type'
    if ($null -ne $type) {
        $allowed = @($type)
        $ok = ($allowed -contains $actual) -or ($actual -eq 'integer' -and $allowed -contains 'number')
        if (-not $ok) { "${Path}: expected type $($allowed -join '|'), got $actual"; return }
    }

    $enum = Get-TwObjectProperty $Schema 'enum'
    if ($null -ne $enum) {
        $match = $false
        foreach ($e in @($enum)) {
            if ($null -eq $e -and $null -eq $InputObject) { $match = $true; break }
            if ($null -ne $e -and $null -ne $InputObject -and (Get-TwJsonType $e) -eq $actual -and $e -ceq $InputObject) { $match = $true; break }
        }
        if (-not $match) { "${Path}: value '$InputObject' is not one of: $(@($enum) -join ', ')" }
    }

    if ($Schema.PSObject.Properties['const']) {
        if (-not ($Schema.const -ceq $InputObject)) { "${Path}: value must be '$($Schema.const)'" }
    }

    foreach ($kw in 'oneOf', 'anyOf') {
        $variants = Get-TwObjectProperty $Schema $kw
        if ($null -eq $variants) { continue }
        $passed = 0
        foreach ($variant in @($variants)) {
            $errs = @(Test-TwJsonSchema -InputObject $InputObject -Schema $variant -Root $Root -Path $Path)
            if ($errs.Count -eq 0) { $passed++ }
        }
        if ($kw -eq 'oneOf' -and $passed -ne 1) { "${Path}: must match exactly one schema in oneOf (matched $passed)" }
        if ($kw -eq 'anyOf' -and $passed -lt 1) { "${Path}: must match at least one schema in anyOf" }
    }

    switch ($actual) {
        'string' {
            $minLength = Get-TwObjectProperty $Schema 'minLength'
            if ($null -ne $minLength -and $InputObject.Length -lt $minLength) { "${Path}: string shorter than $minLength" }
            $pattern = Get-TwObjectProperty $Schema 'pattern'
            if ($pattern -and $InputObject -cnotmatch $pattern) { "${Path}: '$InputObject' does not match pattern $pattern" }
        }
        { $_ -in 'integer', 'number' } {
            $min = Get-TwObjectProperty $Schema 'minimum'
            if ($null -ne $min -and [double]$InputObject -lt [double]$min) { "${Path}: $InputObject is less than $min" }
            $max = Get-TwObjectProperty $Schema 'maximum'
            if ($null -ne $max -and [double]$InputObject -gt [double]$max) { "${Path}: $InputObject is greater than $max" }
        }
        'array' {
            $items = @($InputObject)
            $minItems = Get-TwObjectProperty $Schema 'minItems'
            if ($null -ne $minItems -and $items.Count -lt $minItems) { "${Path}: expected at least $minItems item(s)" }
            $maxItems = Get-TwObjectProperty $Schema 'maxItems'
            if ($null -ne $maxItems -and $items.Count -gt $maxItems) { "${Path}: expected at most $maxItems item(s)" }
            if (Get-TwObjectProperty $Schema 'uniqueItems' $false) {
                $seen = @{}
                foreach ($i in $items) {
                    $k = ($i | ConvertTo-Json -Compress -Depth 20)
                    if ($seen.ContainsKey($k)) { "${Path}: duplicate item $k" }
                    $seen[$k] = $true
                }
            }
            $itemSchema = Get-TwObjectProperty $Schema 'items'
            if ($null -ne $itemSchema) {
                for ($n = 0; $n -lt $items.Count; $n++) {
                    Test-TwJsonSchema -InputObject $items[$n] -Schema $itemSchema -Root $Root -Path "$Path[$n]"
                }
            }
        }
        'object' {
            $members = Get-TwJsonMember $InputObject
            $names = @($members | ForEach-Object { $_.Name })
            foreach ($req in @(Get-TwObjectProperty $Schema 'required' @())) {
                if ($names -notcontains $req) { "${Path}: missing required property '$req'" }
            }
            $props = Get-TwObjectProperty $Schema 'properties'
            $additional = Get-TwObjectProperty $Schema 'additionalProperties' $true
            foreach ($m in $members) {
                $propSchema = Get-TwObjectProperty $props $m.Name
                if ($null -ne $propSchema) {
                    Test-TwJsonSchema -InputObject $m.Value -Schema $propSchema -Root $Root -Path "$Path.$($m.Name)"
                } elseif ($additional -is [bool]) {
                    if (-not $additional) { "${Path}: unknown property '$($m.Name)'" }
                } else {
                    Test-TwJsonSchema -InputObject $m.Value -Schema $additional -Root $Root -Path "$Path.$($m.Name)"
                }
            }
        }
    }
}
