BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'Argument helpers' {
    It 'splits comma separated ids from any shape' {
        Split-TwListArgument @('a,b', ' c ') | Should -Be @('a', 'b', 'c')
        Split-TwListArgument 'x' | Should -Be @('x')
        @(Split-TwListArgument $null).Count | Should -Be 0
    }

    It 'converts bound parameters to a command line for relaunching' {
        $s = ConvertTo-TwArgumentString ([ordered]@{ Apply = @('a', 'b'); ReadOnly = [switch]$true; NoElevate = [switch]$false; Lang = 'en' })
        $s | Should -Be '-Apply "a,b" -ReadOnly -Lang "en"'
    }
}

Describe 'Start-TwMain' {
    BeforeEach {
        $script:DataRoot = New-TwTestContext
        $null = Use-TwFakeSystem
        Mock Write-Host { }
        Mock Resolve-TwTargetUser { [pscustomobject]@{ CurrentSid = 'S-1'; InteractiveSid = 'S-1'; Mismatch = $false; TargetSid = $null } }
        $env:TWEAKER_DATA_DIR = $script:DataRoot
    }
    AfterEach {
        Remove-Item Env:\TWEAKER_DATA_DIR -ErrorAction SilentlyContinue
        if (Test-Path $script:DataRoot) { Remove-Item $script:DataRoot -Recurse -Force }
    }

    It 'lists tweaks without admin rights (exit 0)' {
        Mock Test-TwAdministrator { $false }
        Start-TwMain -Options @{ List = [switch]$true } | Should -Be 0
    }

    It 'refuses to apply without admin rights (exit 3)' {
        Mock Test-TwAdministrator { $false }
        Start-TwMain -Options @{ Apply = @('privacy.disable-telemetry') } | Should -Be 3
        $script:Fake.Calls.Count | Should -Be 0
    }

    It 'allows a dry run without admin rights' {
        Mock Test-TwAdministrator { $false }
        Start-TwMain -Options @{ Apply = @('interface.show-file-extensions') } -WhatIf | Should -Be 0
        @($script:Fake.Calls | Where-Object { $_ -notlike 'WHATIF*' }).Count | Should -Be 0
    }

    It 'returns 2 for an unknown preset' {
        Mock Test-TwAdministrator { $true }
        Start-TwMain -Options @{ Preset = 'turbo' } | Should -Be 2
    }

    It 'returns 2 for an unknown tweak id' {
        Mock Test-TwAdministrator { $true }
        Start-TwMain -Options @{ Apply = @('nope.nothing') } | Should -Be 2
    }

    It 'applies and then undoes a tweak (mocked system)' {
        Mock Test-TwAdministrator { $true }
        Set-TwFakeRegistry 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideFileExt' 'DWord' 1
        Start-TwMain -Options @{ Apply = @('interface.show-file-extensions'); NoRestorePoint = [switch]$true } | Should -Be 0
        (Get-TwFakeRegistry 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideFileExt').Value | Should -Be 0
        Start-TwMain -Options @{ Undo = @('interface.show-file-extensions') } | Should -Be 0
        (Get-TwFakeRegistry 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideFileExt').Value | Should -Be 1
    }

    It 'rolls back the last session with -Undo Last' {
        Mock Test-TwAdministrator { $true }
        Set-TwFakeRegistry 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Hidden' 'DWord' 2
        Start-TwMain -Options @{ Apply = @('interface.show-hidden-files') } | Should -Be 0
        Start-TwMain -Options @{ Undo = @('Last') } | Should -Be 0
        (Get-TwFakeRegistry 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Hidden').Value | Should -Be 2
    }

    It 'exports and imports the applied set' {
        Mock Test-TwAdministrator { $true }
        Set-TwFakeRegistry 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideFileExt' 'DWord' 0
        $null = New-Item -ItemType Directory -Path $script:DataRoot -Force
        $file = Join-Path $script:DataRoot 'export.json'
        Start-TwMain -Options @{ Export = $file } | Should -Be 0
        $doc = Get-Content $file -Raw | ConvertFrom-Json
        $doc.tweaks | Should -Contain 'interface.show-file-extensions'
        Import-TwUserConfig -Path $file | Should -Contain 'interface.show-file-extensions'
    }

    It 'redirects HKCU when elevated as another user' {
        Mock Test-TwAdministrator { $true }
        Mock Resolve-TwTargetUser { [pscustomobject]@{ CurrentSid = 'S-admin'; InteractiveSid = 'S-user'; Mismatch = $true; TargetSid = 'S-user' } }
        Start-TwMain -Options @{ Apply = @('interface.clock-seconds'); NoRestorePoint = [switch]$true } | Should -Be 0
        $script:Fake.Reg.ContainsKey('registry::hkey_users\s-user\software\microsoft\windows\currentversion\explorer\advanced|showsecondsinsystemclock') | Should -BeTrue
    }
}

Describe 'User settings' {
    It 'remembers theme and language' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('tweaker-settings-' + [guid]::NewGuid().ToString('N'))
        $env:TWEAKER_DATA_DIR = $dir
        try {
            Get-TwUserSetting -Name Theme | Should -BeNullOrEmpty
            Save-TwUserSetting -Name Theme -Value Light
            Save-TwUserSetting -Name Language -Value en
            Get-TwUserSetting -Name Theme | Should -Be 'Light'
            Get-TwUserSetting -Name Language | Should -Be 'en'
        } finally {
            Remove-Item Env:\TWEAKER_DATA_DIR -ErrorAction SilentlyContinue
            Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Presets' {
    BeforeAll {
        $null = New-TwTestContext
        $null = Use-TwFakeSystem
    }

    It 'has the four documented presets' {
        (Get-TwPreset | ForEach-Object id) | Should -Be @('minimal', 'recommended', 'gaming', 'privacy-max')
    }

    It 'preset <_> has names and descriptions in both languages' -ForEach @('minimal', 'recommended', 'gaming', 'privacy-max') {
        $p = Get-TwPreset -Name $_
        $p.name.ru | Should -Not -BeNullOrEmpty
        $p.name.en | Should -Not -BeNullOrEmpty
        $p.description.ru | Should -Not -BeNullOrEmpty
        $p.description.en | Should -Not -BeNullOrEmpty
    }

    It 'never includes unverified or unsupported tweaks' {
        $catalog = @(Import-TwTweakCatalog -Force)
        foreach ($name in 'minimal', 'recommended', 'gaming', 'privacy-max') {
            foreach ($id in Resolve-TwPresetTweakId -Name $name) {
                $t = $catalog | Where-Object id -eq $id
                $t.verified | Should -BeTrue
                Test-TwTweakSupported -Tweak $t | Should -BeTrue
            }
        }
    }

    It 'minimal is a subset of recommended' {
        $min = Resolve-TwPresetTweakId -Name minimal
        $rec = Resolve-TwPresetTweakId -Name recommended
        @($min | Where-Object { $rec -notcontains $_ }) | Should -BeNullOrEmpty
    }
}

Describe 'Built dist/Tweaker.ps1 (CLI smoke test, read-only)' {
    BeforeAll {
        $script:Dist = Join-Path ([System.IO.Path]::GetTempPath()) ('tweaker-cli-' + [guid]::NewGuid().ToString('N') + '.ps1')
        & (Join-Path $script:RepoRoot 'build\Build.ps1') -OutputPath $script:Dist -SkipDocs | Out-Null
        $script:Exe = (Get-Process -Id $PID).Path
        $script:Data = Join-Path ([System.IO.Path]::GetTempPath()) ('tweaker-cli-data-' + [guid]::NewGuid().ToString('N'))
    }
    AfterAll {
        Remove-Item $script:Dist -Force -ErrorAction SilentlyContinue
        Remove-Item $script:Data -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'runs -List -Lang en from the single file' {
        $env:TWEAKER_DATA_DIR = $script:Data
        try {
            $out = & $script:Exe -NoProfile -ExecutionPolicy Bypass -File $script:Dist -List -Lang en 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 0
            $out | Should -Match 'privacy\.disable-telemetry'
            $out | Should -Match 'Privacy'
        } finally { Remove-Item Env:\TWEAKER_DATA_DIR -ErrorAction SilentlyContinue }
    }

    It 'runs from a script block (the irm | iex path) and keeps Cyrillic intact' {
        $env:TWEAKER_DATA_DIR = $script:Data
        try {
            $code = "`$t = [IO.File]::ReadAllText('$($script:Dist)'); & ([scriptblock]::Create(`$t)) -List -Category privacy -Lang ru *>&1 | Out-String | ForEach-Object { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(`$_)) }"
            $b64 = & $script:Exe -NoProfile -ExecutionPolicy Bypass -Command $code
            $text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($b64 -join '')))
            $text | Should -Match ([regex]::Escape((Get-Content (Join-Path $script:RepoRoot 'config\lang\ru.json') -Raw -Encoding UTF8 | ConvertFrom-Json).'category.privacy'))
        } finally { Remove-Item Env:\TWEAKER_DATA_DIR -ErrorAction SilentlyContinue }
    }
}
