# Configuration, runtime context and embedded/disk resources.

function Initialize-TwContext {
    <#
    .SYNOPSIS
        Creates the shared runtime context ($script:Tw).
    .DESCRIPTION
        The context holds paths, language, flags and caches used by every other
        engine function. Data lives under %ProgramData%\Tweaker unless the
        TWEAKER_DATA_DIR environment variable or -DataRoot overrides it (tests use this).
    .PARAMETER Language
        UI language: ru or en.
    .PARAMETER DataRoot
        Root folder for logs and backups.
    .PARAMETER ReadOnly
        Open in view-only mode: nothing may be applied.
    .EXAMPLE
        Initialize-TwContext -Language en -ReadOnly
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('ru', 'en')]
        [string]$Language = 'ru',
        [string]$DataRoot,
        [switch]$ReadOnly
    )

    if (-not $DataRoot) {
        if ($env:TWEAKER_DATA_DIR) { $DataRoot = $env:TWEAKER_DATA_DIR }
        else { $DataRoot = Join-Path $env:ProgramData 'Tweaker' }
    }

    $version = '0.0.0'
    $versionVar = Get-Variable -Name TwVersion -Scope Script -ErrorAction SilentlyContinue
    if ($versionVar) { $version = $versionVar.Value }

    $script:Tw = @{
        Version       = $version
        Language      = $Language
        ReadOnly      = [bool]$ReadOnly
        DataDir       = $DataRoot
        BackupDir     = Join-Path $DataRoot 'backups'
        LogDir        = Join-Path $DataRoot 'logs'
        LogFile       = Join-Path (Join-Path $DataRoot 'logs') ('tweaker-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
        LogSink       = $null
        Strings       = $null
        StringsFallback = $null
        Tweaks        = $null
        Session       = $null
        TargetUserSid = $null
        IncludeDefaultUser = $false
        RestorePointDone = $false
        Os            = $null
    }
    return $script:Tw
}

function Get-TwContext {
    <#
    .SYNOPSIS
        Returns the runtime context, creating a default one when missing.
    #>
    [CmdletBinding()]
    param()
    $ctx = Get-Variable -Name Tw -Scope Script -ErrorAction SilentlyContinue
    if (-not $ctx -or $null -eq $ctx.Value) { return (Initialize-TwContext) }
    return $ctx.Value
}

function Get-TwResourceRoot {
    <#
    .SYNOPSIS
        Returns the repository root used to read resources in development mode.
    #>
    [CmdletBinding()]
    param()
    $var = Get-Variable -Name TwDevRoot -Scope Script -ErrorAction SilentlyContinue
    if ($var -and $var.Value) { return $var.Value }
    return $null
}

function Get-TwEmbeddedTable {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $var = Get-Variable -Name TwEmbedded -Scope Script -ErrorAction SilentlyContinue
    if ($var -and $var.Value -is [hashtable]) { return $var.Value }
    return $null
}

function Get-TwResourceText {
    <#
    .SYNOPSIS
        Reads a text resource (JSON, XAML) as UTF-8.
    .DESCRIPTION
        In the built single-file script resources are Base64 strings embedded by
        build/Build.ps1; in development they are read from the repository.
    .PARAMETER Path
        Repository-relative path with forward slashes, e.g. config/lang/ru.json.
    .EXAMPLE
        Get-TwResourceText -Path 'config/lang/ru.json'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    $key = $Path.Replace('\', '/')
    $embedded = Get-TwEmbeddedTable
    if ($embedded) {
        if (-not $embedded.ContainsKey($key)) { throw "Resource not found: $key" }
        $bytes = [Convert]::FromBase64String($embedded[$key])
        return [System.Text.Encoding]::UTF8.GetString($bytes)
    }

    $root = Get-TwResourceRoot
    if (-not $root) { throw "Resource root is not set; cannot read $key" }
    $full = Join-Path $root ($key.Replace('/', '\'))
    if (-not (Test-Path -LiteralPath $full)) { throw "Resource not found: $key" }
    $text = [System.IO.File]::ReadAllText($full, [System.Text.Encoding]::UTF8)
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    return $text
}

function Get-TwJsonResource {
    <#
    .SYNOPSIS
        Reads and parses a JSON resource.
    .EXAMPLE
        Get-TwJsonResource -Path 'config/categories.json'
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    return (Get-TwResourceText -Path $Path | ConvertFrom-Json)
}

function Get-TwResourceList {
    <#
    .SYNOPSIS
        Lists resource paths inside a folder (non-recursive), sorted.
    .EXAMPLE
        Get-TwResourceList -Folder 'config/tweaks' -Extension '.json'
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$Folder,
        [string]$Extension = '.json'
    )
    $prefix = $Folder.Replace('\', '/').TrimEnd('/') + '/'
    $embedded = Get-TwEmbeddedTable
    if ($embedded) {
        return @($embedded.Keys | Where-Object {
                $_.StartsWith($prefix) -and $_.Substring($prefix.Length) -notmatch '/' -and $_.EndsWith($Extension)
            } | Sort-Object)
    }
    $root = Get-TwResourceRoot
    $dir = Join-Path $root ($prefix.Replace('/', '\'))
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    return @(Get-ChildItem -LiteralPath $dir -File -Filter ('*' + $Extension) | Sort-Object Name |
            ForEach-Object { $prefix + $_.Name })
}

function Get-TwObjectProperty {
    <#
    .SYNOPSIS
        Safe property read for PSCustomObject/hashtable values (StrictMode friendly).
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()]$Default = $null
    )
    if ($null -eq $InputObject) { return $Default }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $Default
    }
    $prop = $InputObject.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $Default
}
