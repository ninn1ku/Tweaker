@{
    Severity     = @('Error', 'Warning')

    ExcludeRules = @(
        # The CLI prints coloured, human-readable status lines to the console host.
        # It never needs to be captured by a pipeline (machine output goes through
        # -Export / return objects), so Write-Host is the right tool there.
        'PSAvoidUsingWriteHost'

        # Engine "Invoke-*", "Restore-*" and UI helpers delegate ShouldProcess to the
        # primitive Set-/Remove- functions they call. The analyzer cannot see through
        # that delegation and reports false positives for the wrappers.
        'PSUseShouldProcessForStateChangingFunctions'
    )

    Rules        = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.4')
        }
    }
}
