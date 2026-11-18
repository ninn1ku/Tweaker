BeforeDiscovery {
    $repo = Split-Path -Parent $PSScriptRoot
    $script:TweakFiles = @(Get-ChildItem (Join-Path $repo 'config\tweaks') -Filter '*.json' -ErrorAction SilentlyContinue |
            ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } })
    $script:AllTweakCases = foreach ($f in $script:TweakFiles) {
        $doc = [System.IO.File]::ReadAllText($f.Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        foreach ($t in @($doc.tweaks)) { @{ Id = $t.id; File = $f.Name; Tweak = $t } }
    }
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $null = New-TwTestContext
    $script:Schema = Get-TwJsonResource -Path 'config/schema/tweaks.schema.json'
    $script:TweakSchema = $script:Schema.definitions.tweak
    function Read-Json([string]$Path) { [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json }
}

Describe 'JSON schema validator' {
    It 'accepts a valid tweak' {
        $t = New-TwTestTweak @{ registry = @(@{ path = 'HKLM:\SOFTWARE\Policies\X'; name = 'Y'; type = 'DWord'; value = 0 }) }
        @(Test-TwJsonSchema -InputObject $t -Schema $script:TweakSchema -Root $script:Schema) | Should -BeNullOrEmpty
    }

    It 'rejects <Case>' -ForEach @(
        @{ Case = 'a missing en text'; Patch = { param($t) $t.name = [pscustomobject]@{ ru = 'x' } } }
        @{ Case = 'an unknown risk'; Patch = { param($t) $t.risk = 'yolo' } }
        @{ Case = 'an HKU path'; Patch = { param($t) $t.registry = @([pscustomobject]@{ path = 'HKU:\.DEFAULT\X'; name = 'a'; type = 'DWord'; value = 1 }) } }
        @{ Case = 'an unknown registry type'; Patch = { param($t) $t.registry = @([pscustomobject]@{ path = 'HKLM:\SOFTWARE\X'; name = 'a'; type = 'Dword32'; value = 1 }) } }
        @{ Case = 'an http source'; Patch = { param($t) $t.source = 'http://example.com' } }
        @{ Case = 'an unknown property'; Patch = { param($t) $t | Add-Member -NotePropertyName script -NotePropertyValue 'Remove-Item C:\' } }
        @{ Case = 'a bad id'; Patch = { param($t) $t.id = 'Privacy Disable' } }
        @{ Case = 'an unknown preset'; Patch = { param($t) $t.presets = @('turbo') } }
    ) {
        $t = New-TwTestTweak
        & $Patch $t
        @(Test-TwJsonSchema -InputObject $t -Schema $script:TweakSchema -Root $script:Schema).Count | Should -BeGreaterThan 0
    }
}

Describe 'Tweak catalog file <Name>' -ForEach $script:TweakFiles {
    It 'is valid JSON and matches the schema' {
        $doc = Read-Json $Path
        $errors = @(Test-TwJsonSchema -InputObject $doc -Schema $script:Schema)
        $errors -join "`n" | Should -BeNullOrEmpty
    }

    It 'only holds tweaks of its own category' {
        $doc = Read-Json $Path
        @($doc.tweaks | Where-Object { $_.category -ne $doc.category }).id | Should -BeNullOrEmpty
        $Name | Should -Be ($doc.category + '.json')
    }
}

Describe 'Tweak <Id>' -ForEach $script:AllTweakCases {
    It 'id starts with its category' {
        $Id.Split('.')[0] | Should -Be $Tweak.category
    }

    It 'changes something' {
        $n = @($Tweak.registry).Count + @($Tweak.services).Count + @($Tweak.scheduledTasks).Count + @($Tweak.optionalFeatures).Count + @($Tweak.commands).Count
        if ($null -eq $Tweak.registry) { $n-- }
        $n | Should -BeGreaterThan 0
    }

    It 'has an undo for every registry value, service, task and feature' {
        $undo = $Tweak.undo
        foreach ($r in @($Tweak.registry | Where-Object { $_ })) {
            $hasValue = @($undo.registry | Where-Object { $_ -and $_.path -eq $r.path -and $_.name -eq $r.name }).Count -gt 0
            $hasKey = @($undo.deleteKeys | Where-Object { $_ -and ($r.path -eq $_ -or $r.path.StartsWith($_ + '\')) }).Count -gt 0
            ($hasValue -or $hasKey) | Should -BeTrue -Because "$($r.path)\$($r.name) needs an undo entry"
        }
        foreach ($s in @($Tweak.services | Where-Object { $_ })) {
            @($undo.services | Where-Object { $_ -and $_.name -eq $s.name }).Count | Should -Be 1 -Because "service $($s.name) needs an undo entry"
        }
        foreach ($t in @($Tweak.scheduledTasks | Where-Object { $_ })) {
            @($undo.scheduledTasks | Where-Object { $_ -and $_.path -eq $t.path }).Count | Should -Be 1 -Because "task $($t.path) needs an undo entry"
        }
        foreach ($f in @($Tweak.optionalFeatures | Where-Object { $_ })) {
            @($undo.optionalFeatures | Where-Object { $_ -and $_.name -eq $f.name }).Count | Should -Be 1 -Because "feature $($f.name) needs an undo entry"
        }
    }

    It 'uses values that fit their registry type' {
        foreach ($r in @(@($Tweak.registry) + @($Tweak.undo.registry | Where-Object { $_ -and -not $_.delete }) | Where-Object { $_ })) {
            switch ($r.type) {
                'DWord' { ($r.value -is [int] -or $r.value -is [long]) -and $r.value -ge 0 -and $r.value -le 4294967295 | Should -BeTrue -Because "$($r.name) is a DWORD" }
                'QWord' { ($r.value -is [int] -or $r.value -is [long] -or $r.value -is [decimal]) | Should -BeTrue -Because "$($r.name) is a QWORD" }
                { $_ -in 'String', 'ExpandString' } { $r.value -is [string] | Should -BeTrue -Because "$($r.name) is a string" }
                'MultiString' { @($r.value | Where-Object { $_ -isnot [string] }).Count | Should -Be 0 }
                'Binary' { @($r.value | Where-Object { $_ -isnot [int] -or $_ -lt 0 -or $_ -gt 255 }).Count | Should -Be 0 }
            }
        }
    }

    It 'references only known engine commands' {
        $known = (Get-TwCommandTable).Keys
        foreach ($c in @($Tweak.commands | Where-Object { $_ })) { $known | Should -Contain $c.name }
    }

    It 'is not in a preset unless verified' {
        if (-not $Tweak.verified) { @($Tweak.presets).Count | Should -Be 0 }
    }

    It 'has a warning text when it is advanced' {
        if ($Tweak.risk -eq 'advanced') { $Tweak.warning | Should -Not -BeNullOrEmpty }
    }

    It 'has a sensible build range' {
        if ($null -ne $Tweak.maxBuild) { $Tweak.maxBuild | Should -BeGreaterOrEqual $Tweak.minBuild }
    }
}

Describe 'Catalog as a whole' {
    It 'has unique ids across all files' {
        $ids = foreach ($f in Get-ChildItem (Join-Path $script:RepoRoot 'config\tweaks') -Filter '*.json') { (Read-Json $f.FullName).tweaks.id }
        $dupes = @($ids | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name)
        $dupes | Should -BeNullOrEmpty
    }

    It 'loads through the runtime loader without rejecting anything' {
        $null = New-TwTestContext
        $loaded = @(Import-TwTweakCatalog -Force)
        $expected = 0
        foreach ($f in Get-ChildItem (Join-Path $script:RepoRoot 'config\tweaks') -Filter '*.json') { $expected += @((Read-Json $f.FullName).tweaks).Count }
        $loaded.Count | Should -Be $expected
    }
}

Describe 'Language files' {
    BeforeAll {
        $script:Ru = Read-Json (Join-Path $script:RepoRoot 'config\lang\ru.json')
        $script:En = Read-Json (Join-Path $script:RepoRoot 'config\lang\en.json')
    }

    It 'ru and en have the same keys' {
        $ruKeys = @($script:Ru.PSObject.Properties.Name | Sort-Object)
        $enKeys = @($script:En.PSObject.Properties.Name | Sort-Object)
        @(Compare-Object $ruKeys $enKeys | ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" }) | Should -BeNullOrEmpty
    }

    It 'has no empty strings' {
        @($script:Ru.PSObject.Properties | Where-Object { -not $_.Value }).Name | Should -BeNullOrEmpty
        @($script:En.PSObject.Properties | Where-Object { -not $_.Value }).Name | Should -BeNullOrEmpty
    }

    It 'keeps Cyrillic intact when read as UTF-8' {
        $script:Ru.'app.title' | Should -Match '[\u0400-\u04FF]|Tweaker'
        Import-TwLanguage -Language ru
        Get-TwString 'category.privacy' | Should -Match '[\u0400-\u04FF]'
    }

    It 'names every category' {
        foreach ($c in (Read-Json (Join-Path $script:RepoRoot 'config\categories.json')).categories) {
            $script:Ru."category.$($c.id)" | Should -Not -BeNullOrEmpty
            $script:En."category.$($c.id)" | Should -Not -BeNullOrEmpty
        }
    }

    It 'covers every Get-TwString key used in src' {
        $keys = foreach ($f in Get-ChildItem (Join-Path $script:RepoRoot 'src') -Recurse -Include '*.ps1', '*.xaml') {
            [regex]::Matches((Get-Content $f.FullName -Raw), "Get-TwString\s+(?:-Key\s+)?'([a-z0-9_.]+)'") | ForEach-Object { $_.Groups[1].Value }
            [regex]::Matches((Get-Content $f.FullName -Raw), "\{tw:([a-z0-9_.]+)\}") | ForEach-Object { $_.Groups[1].Value }
        }
        $missing = @($keys | Select-Object -Unique | Where-Object { -not $script:Ru.PSObject.Properties[$_] -or -not $script:En.PSObject.Properties[$_] })
        $missing | Should -BeNullOrEmpty
    }
}
