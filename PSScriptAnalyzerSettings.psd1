@{
    Severity     = @('Error', 'Warning')

    ExcludeRules = @(
        # The CLI prints coloured, human-readable status lines to the console host.
        # It never needs to be captured by a pipeline (machine output goes through
        # -Export / return objects), so Write-Host is the right tool there.
        'PSAvoidUsingWriteHost'

        # Engine wrappers (Invoke-TwTweak, Restore-TwBackupSession, command handlers...)
        # declare SupportsShouldProcess only to accept -WhatIf/-Confirm and pass them on
        # through $WhatIfPreference: the actual ShouldProcess call happens once, in the
        # primitive that touches the system (Set-TwRegistryValue, Set-TwServiceStartup,
        # Invoke-TwNativeCommand, ...). Calling ShouldProcess in the wrapper as well
        # would hide the per-value "What if" lines, so this rule is a false positive here.
        'PSShouldProcess'
    )

    Rules        = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.4')
        }
    }
}
