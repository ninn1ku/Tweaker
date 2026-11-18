BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'Registry helpers (pure functions)' {
    It 'maps HKCU to HKEY_USERS\<sid> when a target SID is given' {
        ConvertTo-TwRegistryProviderPath 'HKCU:\Software\Foo' -UserSid 'S-1-5-21-1' | Should -Be 'Registry::HKEY_USERS\S-1-5-21-1\Software\Foo'
        ConvertTo-TwRegistryProviderPath 'HKCU:\Software\Foo' | Should -Be 'Registry::HKEY_CURRENT_USER\Software\Foo'
        ConvertTo-TwRegistryProviderPath 'HKLM:\SOFTWARE\Foo' -UserSid 'S-1-5-21-1' | Should -Be 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Foo'
    }

    It 'converts DWORD values above 0x7FFFFFFF to the signed bit pattern' {
        ConvertTo-TwRegistryData -Type DWord -Value 4294967295 | Should -Be -1
        ConvertTo-TwRegistryData -Type DWord -Value 2147483650 | Should -Be ([int32]-2147483646)
        ConvertTo-TwComparableRegistryValue -Type DWord -Value -1 | Should -Be '4294967295'
    }

    It 'converts binary hex strings and arrays the same way' {
        ConvertTo-TwComparableRegistryValue -Type Binary -Value '0A FF' | Should -Be (ConvertTo-TwComparableRegistryValue -Type Binary -Value @(10, 255))
    }

    It 'refuses to delete top-level keys' {
        Use-TwTripwire
        { Remove-TwRegistryKey -Path 'HKCU:\Software' } | Should -Throw '*top-level*'
    }

    It 'Set-TwRegistryValue -WhatIf does not write' {
        Use-TwTripwire
        { Set-TwRegistryValue -Path 'HKCU:\Software\TweakerTestNeverCreated' -Name 'X' -Type DWord -Value 1 -WhatIf } | Should -Not -Throw
        Should -Invoke New-ItemProperty -Times 0 -Exactly
        Test-Path 'HKCU:\Software\TweakerTestNeverCreated' | Should -BeFalse
    }

    It 'Get-TwRegistryValue reads without changing anything' {
        $v = Get-TwRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'CurrentBuildNumber'
        $v.Exists | Should -BeTrue
        [int]$v.Value | Should -BeGreaterThan 10000
        (Get-TwRegistryValue -Path 'HKCU:\Software\TweakerTestNeverCreated' -Name 'X').Exists | Should -BeFalse
    }
}

Describe 'Apply -> backup -> undo (mocked system)' {
    BeforeEach {
        $script:DataRoot = New-TwTestContext
        $null = Use-TwFakeSystem
    }
    AfterEach {
        if (Test-Path $script:DataRoot) { Remove-Item $script:DataRoot -Recurse -Force }
    }

    It 'restores an existing registry value to its real original (not a guessed default)' {
        Set-TwFakeRegistry 'HKLM:\SOFTWARE\Policies\Test' 'Value' 'DWord' 7
        $tweak = New-TwTestTweak @{
            registry = @(@{ path = 'HKLM:\SOFTWARE\Policies\Test'; name = 'Value'; type = 'DWord'; value = 0 })
            undo     = @{ registry = @(@{ path = 'HKLM:\SOFTWARE\Policies\Test'; name = 'Value'; delete = $true }) }
        }
        (Invoke-TwTweak -Tweak $tweak -Action Apply).Status | Should -Be 'Success'
        (Get-TwFakeRegistry 'HKLM:\SOFTWARE\Policies\Test' 'Value').Value | Should -Be 0
        Get-TwTweakState -Tweak $tweak | Should -Be 'Applied'

        (Invoke-TwTweak -Tweak $tweak -Action Undo).Status | Should -Be 'Success'
        (Get-TwFakeRegistry 'HKLM:\SOFTWARE\Policies\Test' 'Value').Value | Should -Be 7
        Get-TwTweakState -Tweak $tweak | Should -Be 'NotApplied'
    }

    It 'removes a value (and the key it created) when the value did not exist before' {
        $tweak = New-TwTestTweak @{
            registry = @(@{ path = 'HKCU:\Software\Classes\CLSID\{test}\InprocServer32'; name = ''; type = 'String'; value = '' })
            undo     = @{ deleteKeys = @('HKCU:\Software\Classes\CLSID\{test}') }
        }
        (Invoke-TwTweak -Tweak $tweak -Action Apply).Status | Should -Be 'Success'
        Get-TwFakeRegistry 'HKCU:\Software\Classes\CLSID\{test}\InprocServer32' '' | Should -Not -BeNullOrEmpty

        $entry = @((Get-TwBackupSession)[0].entries)[0]
        $entry.existed | Should -BeFalse
        $entry.createdKey | Should -Not -BeNullOrEmpty

        (Invoke-TwTweak -Tweak $tweak -Action Undo).Status | Should -Be 'Success'
        Get-TwFakeRegistry 'HKCU:\Software\Classes\CLSID\{test}\InprocServer32' '' | Should -BeNullOrEmpty
        $script:Fake.Calls | Should -Contain ('removekey ' + 'Registry::HKEY_CURRENT_USER\Software\Classes\CLSID\{test}\InprocServer32'.ToLowerInvariant())
    }

    It 'writes the backup before changing anything' {
        Set-TwFakeRegistry 'HKLM:\SOFTWARE\Policies\Test' 'A' 'DWord' 1
        Mock Set-TwRegistryValue { throw 'boom' }
        $tweak = New-TwTestTweak @{ registry = @(@{ path = 'HKLM:\SOFTWARE\Policies\Test'; name = 'A'; type = 'DWord'; value = 0 }) }
        $r = Invoke-TwTweak -Tweak $tweak -Action Apply
        $r.Status | Should -Be 'Failed'
        $sessions = @(Get-TwBackupSession)
        $sessions.Count | Should -Be 1
        @($sessions[0].entries)[0].value | Should -Be 1
    }

    It 'restores service startup types and task states' {
        $script:Fake.Services['DiagTrack'] = 'AutomaticDelayed'
        $script:Fake.Tasks['\Microsoft\Windows\Test\Task'] = 'Enabled'
        $tweak = New-TwTestTweak @{
            services       = @(@{ name = 'DiagTrack'; startupType = 'Disabled'; stop = $true })
            scheduledTasks = @(@{ path = '\Microsoft\Windows\Test\Task'; state = 'Disabled' })
            undo           = @{ services = @(@{ name = 'DiagTrack'; startupType = 'Automatic' }); scheduledTasks = @(@{ path = '\Microsoft\Windows\Test\Task'; state = 'Enabled' }) }
        }
        (Invoke-TwTweak -Tweak $tweak -Action Apply).Changes | Should -Be 2
        $script:Fake.Services['DiagTrack'] | Should -Be 'Disabled'
        $script:Fake.Tasks['\Microsoft\Windows\Test\Task'] | Should -Be 'Disabled'

        $null = Invoke-TwTweak -Tweak $tweak -Action Undo
        $script:Fake.Services['DiagTrack'] | Should -Be 'AutomaticDelayed'   # real original, not the "undo" default
        $script:Fake.Tasks['\Microsoft\Windows\Test\Task'] | Should -Be 'Enabled'
    }

    It 'falls back to the documented default when there is no backup' {
        Set-TwFakeRegistry 'HKLM:\SOFTWARE\Policies\Test' 'B' 'DWord' 0
        $tweak = New-TwTestTweak @{
            registry = @(@{ path = 'HKLM:\SOFTWARE\Policies\Test'; name = 'B'; type = 'DWord'; value = 0 })
            undo     = @{ registry = @(@{ path = 'HKLM:\SOFTWARE\Policies\Test'; name = 'B'; delete = $true }) }
        }
        (Invoke-TwTweak -Tweak $tweak -Action Undo).Status | Should -Be 'Success'
        Get-TwFakeRegistry 'HKLM:\SOFTWARE\Policies\Test' 'B' | Should -BeNullOrEmpty
    }

    It 'skips values that are already in the desired state (no backup, NoChange)' {
        Set-TwFakeRegistry 'HKLM:\SOFTWARE\Policies\Test' 'C' 'DWord' 0
        $tweak = New-TwTestTweak @{ registry = @(@{ path = 'HKLM:\SOFTWARE\Policies\Test'; name = 'C'; type = 'DWord'; value = 0 }) }
        (Invoke-TwTweak -Tweak $tweak -Action Apply).Status | Should -Be 'NoChange'
        @(Get-TwBackupSession).Count | Should -Be 0
    }

    It 'finds the real original across sessions even after a re-apply' {
        Set-TwFakeRegistry 'HKLM:\SOFTWARE\Policies\Test' 'D' 'DWord' 5
        $tweak = New-TwTestTweak @{ registry = @(@{ path = 'HKLM:\SOFTWARE\Policies\Test'; name = 'D'; type = 'DWord'; value = 0 }) }
        $null = Start-TwBackupSession
        $null = Invoke-TwTweak -Tweak $tweak -Action Apply
        # Somebody changes the value outside Tweaker; a later session applies again.
        Set-TwFakeRegistry 'HKLM:\SOFTWARE\Policies\Test' 'D' 'DWord' 9
        Start-Sleep -Milliseconds 1100
        $null = Start-TwBackupSession
        $null = Invoke-TwTweak -Tweak $tweak -Action Apply
        $null = Invoke-TwTweak -Tweak $tweak -Action Undo
        (Get-TwFakeRegistry 'HKLM:\SOFTWARE\Policies\Test' 'D').Value | Should -Be 9
    }

    It '-WhatIf changes nothing and writes no backup' {
        Set-TwFakeRegistry 'HKLM:\SOFTWARE\Policies\Test' 'E' 'DWord' 1
        $tweak = New-TwTestTweak @{ registry = @(@{ path = 'HKLM:\SOFTWARE\Policies\Test'; name = 'E'; type = 'DWord'; value = 0 }) }
        $r = Invoke-TwTweak -Tweak $tweak -Action Apply -WhatIf
        $r.Status | Should -Be 'WhatIf'
        (Get-TwFakeRegistry 'HKLM:\SOFTWARE\Policies\Test' 'E').Value | Should -Be 1
        @(Get-TwBackupSession).Count | Should -Be 0
    }

    It 'skips tweaks outside their build range' {
        $tweak = New-TwTestTweak @{ minBuild = 30000; registry = @(@{ path = 'HKLM:\SOFTWARE\Policies\Test'; name = 'F'; type = 'DWord'; value = 0 }) }
        $r = Invoke-TwTweak -Tweak $tweak -Action Apply
        $r.Status | Should -Be 'Skipped'
        $r.Message | Should -Be 'UnsupportedBuild'
        Get-TwTweakState -Tweak $tweak | Should -Be 'Unsupported'
    }

    It 'refuses to apply in read-only mode' {
        (Get-TwContext).ReadOnly = $true
        $tweak = New-TwTestTweak @{ registry = @(@{ path = 'HKLM:\SOFTWARE\Policies\Test'; name = 'G'; type = 'DWord'; value = 0 }) }
        (Invoke-TwTweak -Tweak $tweak -Action Apply).Message | Should -Be 'ReadOnly'
        Get-TwFakeRegistry 'HKLM:\SOFTWARE\Policies\Test' 'G' | Should -BeNullOrEmpty
    }

    It 'reports Partial when only some values match' {
        Set-TwFakeRegistry 'HKLM:\SOFTWARE\Policies\Test' 'H1' 'DWord' 0
        Set-TwFakeRegistry 'HKLM:\SOFTWARE\Policies\Test' 'H2' 'DWord' 1
        $tweak = New-TwTestTweak @{ registry = @(
                @{ path = 'HKLM:\SOFTWARE\Policies\Test'; name = 'H1'; type = 'DWord'; value = 0 },
                @{ path = 'HKLM:\SOFTWARE\Policies\Test'; name = 'H2'; type = 'DWord'; value = 0 }) }
        Get-TwTweakState -Tweak $tweak | Should -Be 'Partial'
    }

    It 'redirects HKCU to the interactive user hive' {
        (Get-TwContext).TargetUserSid = 'S-1-5-21-42'
        $tweak = New-TwTestTweak @{ registry = @(@{ path = 'HKCU:\Software\Test'; name = 'I'; type = 'DWord'; value = 1 }) }
        $null = Invoke-TwTweak -Tweak $tweak -Action Apply
        $script:Fake.Reg.ContainsKey('registry::hkey_users\s-1-5-21-42\software\test|i') | Should -BeTrue
        $script:Fake.Reg.ContainsKey('registry::hkey_current_user\software\test|i') | Should -BeFalse
    }
}

Describe 'Batches and session rollback' {
    BeforeEach {
        $script:DataRoot = New-TwTestContext
        $null = Use-TwFakeSystem
        $script:T1 = New-TwTestTweak @{ id = 'interface.one'; category = 'interface'; requiresExplorerRestart = $true
            registry = @(@{ path = 'HKCU:\Software\Test'; name = 'One'; type = 'DWord'; value = 1 }) }
        $script:T2 = New-TwTestTweak @{ id = 'interface.two'; category = 'interface'; requiresReboot = $true
            registry = @(@{ path = 'HKCU:\Software\Test'; name = 'Two'; type = 'DWord'; value = 1 }) }
        $script:Bad = New-TwTestTweak @{ id = 'interface.bad'; category = 'interface'
            registry = @(@{ path = 'HKCU:\Software\Test'; name = 'Bad'; type = 'DWord'; value = 1 }) }
        (Get-TwContext).Tweaks = @($script:T1, $script:T2, $script:Bad)
    }
    AfterEach {
        if (Test-Path $script:DataRoot) { Remove-Item $script:DataRoot -Recurse -Force }
    }

    It 'continues after a failing tweak and reports everything' {
        Mock Set-TwRegistryValue -ParameterFilter { $Name -eq 'Bad' } { throw 'access denied' }
        $report = Invoke-TwTweakBatch -Apply 'interface.one', 'interface.bad', 'interface.two', 'nope.missing'
        @($report.Results | Where-Object Status -eq 'Success').Count | Should -Be 2
        @($report.Results | Where-Object Status -eq 'Failed').Count | Should -Be 1
        $report.Unknown | Should -Contain 'nope.missing'
        $report.ExplorerRestarted | Should -BeTrue
        Should -Invoke Restart-TwExplorer -Times 1 -Exactly
        $report.RebootRequired.Count | Should -Be 1
        Should -Invoke New-TwRestorePoint -Times 1 -Exactly
    }

    It 'creates the restore point only once per app session' {
        $null = Invoke-TwTweakBatch -Apply 'interface.one'
        $null = Invoke-TwTweakBatch -Apply 'interface.two'
        Should -Invoke New-TwRestorePoint -Times 1 -Exactly
    }

    It 'rolls back a whole session' {
        Set-TwFakeRegistry 'HKCU:\Software\Test' 'One' 'DWord' 0
        $report = Invoke-TwTweakBatch -Apply 'interface.one', 'interface.two' -NoExplorerRestart
        $results = Restore-TwBackupSession -Id $report.BackupSession
        @($results | Where-Object Status -eq 'Success').Count | Should -Be 2
        (Get-TwFakeRegistry 'HKCU:\Software\Test' 'One').Value | Should -Be 0
        Get-TwFakeRegistry 'HKCU:\Software\Test' 'Two' | Should -BeNullOrEmpty
    }

    It 'full rollback uses the oldest recorded value' {
        Set-TwFakeRegistry 'HKCU:\Software\Test' 'One' 'DWord' 3
        $null = Invoke-TwTweakBatch -Apply 'interface.one' -NoExplorerRestart
        Set-TwFakeRegistry 'HKCU:\Software\Test' 'One' 'DWord' 4
        Start-Sleep -Milliseconds 1100
        $null = Invoke-TwTweakBatch -Apply 'interface.one' -NoExplorerRestart
        $null = Restore-TwFullBackup
        (Get-TwFakeRegistry 'HKCU:\Software\Test' 'One').Value | Should -Be 3
    }

    It 'undoes applied siblings of an exclusive group' {
        $a = New-TwTestTweak @{ id = 'updates.mode-a'; category = 'updates'; exclusiveGroup = 'wu'; registry = @(@{ path = 'HKLM:\SOFTWARE\Policies\WU'; name = 'A'; type = 'DWord'; value = 1 }) }
        $b = New-TwTestTweak @{ id = 'updates.mode-b'; category = 'updates'; exclusiveGroup = 'wu'; registry = @(@{ path = 'HKLM:\SOFTWARE\Policies\WU'; name = 'B'; type = 'DWord'; value = 1 }) }
        (Get-TwContext).Tweaks = @($a, $b)
        $null = Invoke-TwTweakBatch -Apply 'updates.mode-a'
        Get-TwTweakState -Tweak $a | Should -Be 'Applied'
        $report = Invoke-TwTweakBatch -Apply 'updates.mode-b'
        ($report.Results | Where-Object Id -eq 'updates.mode-a').Action | Should -Be 'Undo'
        Get-TwTweakState -Tweak $a | Should -Be 'NotApplied'
        Get-TwTweakState -Tweak $b | Should -Be 'Applied'
    }

    It 'does nothing in -WhatIf (no restore point, no backup)' {
        $report = Invoke-TwTweakBatch -Apply 'interface.one' -WhatIf
        $report.WhatIf | Should -BeTrue
        Should -Invoke New-TwRestorePoint -Times 0 -Exactly
        @(Get-TwBackupSession).Count | Should -Be 0
        Get-TwFakeRegistry 'HKCU:\Software\Test' 'One' | Should -BeNullOrEmpty
    }
}

Describe 'Restore point' {
    BeforeEach {
        $script:DataRoot = New-TwTestContext
        $null = Use-TwFakeSystem -RealRestorePoint
    }

    It 'lifts the 24h limit and puts the original frequency value back' {
        Mock Test-TwSystemRestoreEnabled { $true }
        Mock Checkpoint-Computer { }
        Set-TwFakeRegistry 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' 'SystemRestorePointCreationFrequency' 'DWord' 1440
        $r = New-TwRestorePoint -Description 'test'
        $r.Success | Should -BeTrue
        Should -Invoke Checkpoint-Computer -Times 1 -Exactly
        @($script:Fake.Calls -like '*SystemRestorePointCreationFrequency=0').Count | Should -Be 1
        (Get-TwFakeRegistry 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' 'SystemRestorePointCreationFrequency').Value | Should -Be 1440
    }

    It 'warns instead of failing silently when protection is off' {
        Mock Test-TwSystemRestoreEnabled { $false }
        $r = New-TwRestorePoint -Description 'test'
        $r.Success | Should -BeFalse
        $r.Message | Should -Be 'SystemProtectionDisabled'
    }
}
