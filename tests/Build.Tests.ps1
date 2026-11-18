BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:DistDir = Join-Path ([System.IO.Path]::GetTempPath()) ('tweaker-build-' + [guid]::NewGuid().ToString('N'))
    $script:DistFile = Join-Path $script:DistDir 'Tweaker.ps1'
    & (Join-Path $script:RepoRoot 'build\Build.ps1') -OutputPath $script:DistFile -SkipDocs | Out-Null
}

AfterAll {
    if (Test-Path $script:DistDir) { Remove-Item $script:DistDir -Recurse -Force }
}

Describe 'Build output' {
    It 'produces dist/Tweaker.ps1' {
        $script:DistFile | Should -Exist
    }

    It 'parses without errors' {
        $tokens = $null; $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($script:DistFile, [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }

    It 'is pure ASCII (survives irm | iex in Windows PowerShell 5.1)' {
        $bytes = [System.IO.File]::ReadAllBytes($script:DistFile)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }

    It 'contains no dev loader' {
        $text = Get-Content -LiteralPath $script:DistFile -Raw
        $text | Should -Not -Match '#region DevLoader'
    }

    It 'stamps a version when -Version is given' {
        $file = Join-Path $script:DistDir 'Versioned.ps1'
        & (Join-Path $script:RepoRoot 'build\Build.ps1') -OutputPath $file -Version '9.8.7' -SkipDocs | Out-Null
        (Get-Content -LiteralPath $file -Raw) | Should -Match "TwVersion = '9\.8\.7'"
    }
}

Describe 'Source hygiene' {
    BeforeAll {
        $script:ScriptFiles = Get-ChildItem -Path (Join-Path $script:RepoRoot 'src'), (Join-Path $script:RepoRoot 'build'), (Join-Path $script:RepoRoot 'tests') -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1'
        $script:ScriptFiles += Get-Item (Join-Path $script:RepoRoot 'PSScriptAnalyzerSettings.psd1')
    }

    It 'saves <_> as UTF-8 with BOM' -ForEach @(
        Get-ChildItem -Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'src'), (Join-Path (Split-Path -Parent $PSScriptRoot) 'build'), (Join-Path (Split-Path -Parent $PSScriptRoot) 'tests') -Recurse -File -Include '*.ps1', '*.psd1' |
            ForEach-Object { $_.FullName.Substring((Split-Path -Parent $PSScriptRoot).Length + 1) }
    ) {
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $script:RepoRoot $_))
        ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeTrue
    }

    It 'keeps engine code under src ASCII-only (UI text lives in config/lang)' {
        $offenders = foreach ($f in Get-ChildItem (Join-Path $script:RepoRoot 'src') -Recurse -File -Include '*.ps1') {
            $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
            if (@($bytes[3..($bytes.Length - 1)] | Where-Object { $_ -gt 127 }).Count -gt 0) { $f.Name }
        }
        $offenders | Should -BeNullOrEmpty
    }

    It 'never uses Invoke-Expression in src' {
        $hits = foreach ($f in Get-ChildItem (Join-Path $script:RepoRoot 'src') -Recurse -File -Include '*.ps1') {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
            $ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    @('Invoke-Expression', 'iex') -contains $node.GetCommandName()
                }, $true) | ForEach-Object { "$($f.Name):$($_.Extent.StartLineNumber)" }
        }
        $hits | Should -BeNullOrEmpty
    }
}
