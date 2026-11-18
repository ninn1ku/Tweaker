# Logging to %ProgramData%\Tweaker\logs and to an optional live sink (GUI log panel).

function Write-TwLog {
    <#
    .SYNOPSIS
        Writes a log entry to the log file and the live sink.
    .DESCRIPTION
        Entries are plain text lines: timestamp, level, message. Messages should say
        what changed, from which value to which value, and the result.
    .PARAMETER Message
        Text of the entry.
    .PARAMETER Level
        Info, Success, Warning, Error or Debug.
    .EXAMPLE
        Write-TwLog -Level Success -Message 'HKLM:\...\AllowTelemetry: 3 -> 0'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Message,
        [ValidateSet('Info', 'Success', 'Warning', 'Error', 'Debug')]
        [string]$Level = 'Info'
    )

    $ctx = Get-TwContext
    $time = Get-Date
    $line = '{0} [{1,-7}] {2}' -f $time.ToString('yyyy-MM-dd HH:mm:ss'), $Level.ToUpperInvariant(), $Message

    if ($Level -ne 'Debug' -or $VerbosePreference -ne 'SilentlyContinue') {
        try {
            if (-not (Test-Path -LiteralPath $ctx.LogDir)) {
                $null = New-Item -ItemType Directory -Path $ctx.LogDir -Force -WhatIf:$false -Confirm:$false
            }
            [System.IO.File]::AppendAllText($ctx.LogFile, $line + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
        } catch {
            Write-Verbose "Log file is not writable: $($_.Exception.Message)"
        }
    }

    Write-Verbose $line
    if ($ctx.LogSink -is [scriptblock]) {
        try {
            & $ctx.LogSink ([pscustomobject]@{ Time = $time; Level = $Level; Message = $Message })
        } catch {
            Write-Verbose "Log sink failed: $($_.Exception.Message)"
        }
    }
}
