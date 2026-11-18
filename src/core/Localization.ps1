# UI strings live in config/lang/<lang>.json. Tweak texts live in the tweak JSON.

function Import-TwLanguage {
    <#
    .SYNOPSIS
        Loads the UI string table for a language (with English as fallback).
    .PARAMETER Language
        ru or en.
    .EXAMPLE
        Import-TwLanguage -Language ru
    #>
    [CmdletBinding()]
    param([ValidateSet('ru', 'en')][string]$Language = 'ru')

    $ctx = Get-TwContext
    $ctx.Language = $Language
    $ctx.Strings = ConvertTo-TwStringTable (Get-TwJsonResource -Path "config/lang/$Language.json")
    if ($Language -ne 'en') {
        $ctx.StringsFallback = ConvertTo-TwStringTable (Get-TwJsonResource -Path 'config/lang/en.json')
    } else {
        $ctx.StringsFallback = $ctx.Strings
    }
}

function ConvertTo-TwStringTable {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)]$InputObject)
    $table = @{}
    foreach ($p in $InputObject.PSObject.Properties) { $table[$p.Name] = [string]$p.Value }
    return $table
}

function Get-TwString {
    <#
    .SYNOPSIS
        Returns a localized UI string, formatted with optional arguments.
    .PARAMETER Key
        String key, e.g. cli.applying.
    .PARAMETER Arguments
        Values for {0}, {1}, ... placeholders.
    .EXAMPLE
        Get-TwString -Key 'category.privacy'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Key,
        [Parameter(Position = 1)][object[]]$Arguments
    )
    $ctx = Get-TwContext
    if ($null -eq $ctx.Strings) {
        try { Import-TwLanguage -Language $ctx.Language } catch { Write-Verbose $_.Exception.Message }
    }
    $text = $null
    if ($ctx.Strings -and $ctx.Strings.ContainsKey($Key)) { $text = $ctx.Strings[$Key] }
    elseif ($ctx.StringsFallback -and $ctx.StringsFallback.ContainsKey($Key)) { $text = $ctx.StringsFallback[$Key] }
    else { $text = $Key }
    if ($Arguments -and $Arguments.Count -gt 0) {
        try { return ($text -f $Arguments) } catch { return $text }
    }
    return $text
}

function Get-TwLocalizedText {
    <#
    .SYNOPSIS
        Picks the current-language text from a {"ru": "...", "en": "..."} object.
    .EXAMPLE
        Get-TwLocalizedText -Value $tweak.name
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [string]) { return $Value }
    $lang = (Get-TwContext).Language
    $text = Get-TwObjectProperty -InputObject $Value -Name $lang
    if (-not $text) { $text = Get-TwObjectProperty -InputObject $Value -Name 'en' }
    if (-not $text) { $text = Get-TwObjectProperty -InputObject $Value -Name 'ru' }
    return [string]$text
}
