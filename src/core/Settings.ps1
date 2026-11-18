# Per-user preferences (theme, language): %APPDATA%\Tweaker\settings.json.

function Get-TwSettingsPath {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if ($env:TWEAKER_DATA_DIR) { return (Join-Path $env:TWEAKER_DATA_DIR 'settings.json') }
    return (Join-Path $env:APPDATA 'Tweaker\settings.json')
}

function Get-TwUserSetting {
    <#
    .SYNOPSIS
        Reads one saved preference ($null when missing or unreadable).
    .EXAMPLE
        Get-TwUserSetting -Name Theme
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('Theme', 'Language')][string]$Name)
    $path = Get-TwSettingsPath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $doc = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        return (Get-TwObjectProperty $doc $Name)
    } catch {
        return $null
    }
}

function Save-TwUserSetting {
    <#
    .SYNOPSIS
        Saves one preference.
    .EXAMPLE
        Save-TwUserSetting -Name Language -Value en
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][ValidateSet('Theme', 'Language')][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )
    $path = Get-TwSettingsPath
    $data = [ordered]@{}
    if (Test-Path -LiteralPath $path) {
        try {
            $doc = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            foreach ($p in $doc.PSObject.Properties) { $data[$p.Name] = $p.Value }
        } catch { Write-Verbose 'settings.json unreadable, recreating' }
    }
    $data[$Name] = $Value
    if ($PSCmdlet.ShouldProcess($path, "Save $Name")) {
        $dir = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
        [System.IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $data), (New-Object System.Text.UTF8Encoding($false)))
    }
}
