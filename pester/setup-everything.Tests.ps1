#===========================================================================
# Tests - Setup everything button

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    $script:functionPath = Join-Path $script:repoRoot "functions\public\Invoke-WPFSetupEverything.ps1"

    # Reads the fixed key list out of the function body, so the test fails when the list and the
    # config drift apart instead of restating the list here and agreeing with itself
    function script:Get-WinUtilSetupKeyList {
        param(
            [Parameter(Mandatory)]
            [string]$Name
        )

        $tokens = $null
        $syntaxErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:functionPath, [ref]$tokens, [ref]$syntaxErrors)
        if ($syntaxErrors.Count -ne 0) {
            throw ($syntaxErrors | Out-String)
        }

        $assignment = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -eq "`$$Name"
        }, $true) | Select-Object -First 1

        if ($null -eq $assignment) {
            throw "Could not find the `$$Name assignment in Invoke-WPFSetupEverything.ps1"
        }

        # @( ... ) is an array expression and "a", "b" an array literal; both carry the values as
        # string constants, so the constants under the assignment are the list either way
        $arrayNode = $assignment.Right.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.ArrayExpressionAst] -or
                $node -is [System.Management.Automation.Language.ArrayLiteralAst]
        }, $true) | Select-Object -First 1

        if ($null -eq $arrayNode) {
            throw "Could not find the `$$Name array in Invoke-WPFSetupEverything.ps1"
        }

        $elements = $assignment.Right.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
                $node -is [System.Management.Automation.Language.ExpandableStringExpressionAst]
        }, $true)

        return @($elements | ForEach-Object { [string]$_.Value })
    }

    function script:Get-WinUtilConfigObject {
        param(
            [Parameter(Mandatory)]
            [string]$Name
        )

        Get-Content -Path (Join-Path $script:repoRoot "config\$Name.json") -Raw | ConvertFrom-Json
    }

    $script:appKeys = Get-WinUtilSetupKeyList -Name "appKeys"
    $script:tweakKeys = Get-WinUtilSetupKeyList -Name "tweakKeys"
    $script:undoToggleKeys = Get-WinUtilSetupKeyList -Name "undoToggleKeys"
}

Describe "Setup everything key lists" {
    It "lists 15 unique application keys" {
        $script:appKeys.Count | Should -Be 15
        @($script:appKeys | Select-Object -Unique).Count | Should -Be 15
    }

    It "references applications that exist in config/applications.json" {
        $applications = Get-WinUtilConfigObject -Name "applications"
        $configNames = @($applications.PSObject.Properties.Name)
        $missing = @($script:appKeys | Where-Object { $configNames -notcontains $_ })

        if ($missing.Count -gt 0) {
            throw "Setup everything references missing application(s): $($missing -join ', ')"
        }
    }

    It "leaves the restore point out of the tweak list" {
        $script:tweakKeys | Should -Not -Contain "WPFTweaksRestorePoint"
    }

    It "validates the restore point key and passes it into the job" {
        $source = Get-Content -Path $script:functionPath -Raw

        $source | Should -Match '\$restorePointKey = "WPFTweaksRestorePoint"'
        $source | Should -Match '@\(\$restorePointKey\) \+ @\(\$tweakKeys\)'
        $source | Should -Match 'RestorePointKey = \$restorePointKey'
    }

    It "takes the restore point before the winget install" {
        $source = Get-Content -Path $script:functionPath -Raw
        $restoreIndex = $source.IndexOf('Invoke-WinUtilTweaks $RestorePointKey')

        $restoreIndex | Should -BeGreaterThan -1
        $restoreIndex | Should -BeLessThan $source.IndexOf('Install-WinUtilWinget')
        $restoreIndex | Should -BeLessThan $source.IndexOf('Install-WinUtilProgramWinget')
    }

    It "references tweaks that exist in config/tweaks.json" {
        $tweaks = Get-WinUtilConfigObject -Name "tweaks"
        $configNames = @($tweaks.PSObject.Properties.Name)
        $missing = @($script:tweakKeys | Where-Object { $configNames -notcontains $_ })

        if ($missing.Count -gt 0) {
            throw "Setup everything references missing tweak(s): $($missing -join ', ')"
        }
    }
}

Describe "Setup everything button wiring" {
    It "adds a Setup everything button to the action bar" {
        $navigation = Get-WinUtilConfigObject -Name "appnavigation"
        $entry = $navigation.WPFSetupEverything

        $entry | Should -Not -BeNullOrEmpty
        $entry.Type | Should -Be "Button"
        $entry.Content | Should -Be "Setup everything"
        $entry.Category | Should -Be "____Actions"
    }

    It "routes the button to Invoke-WPFSetupEverything" {
        $buttonSource = Get-Content -Path (Join-Path $script:repoRoot "functions\public\Invoke-WPFButton.ps1") -Raw

        $buttonSource | Should -Match '"WPFSetupEverything"\s*\{\s*Invoke-WPFSetupEverything\s*\}'
    }
}

Describe "Setup everything tweak mapping" {
    It "resolves every key to a toggle entry or a WPFTweaks entry" {
        $tweaks = Get-WinUtilConfigObject -Name "tweaks"
        $invalid = New-Object System.Collections.Generic.List[string]

        foreach ($key in $script:tweakKeys) {
            $entry = $tweaks.$key

            if ($null -eq $entry) {
                $invalid.Add("$key is missing from config/tweaks.json")
                continue
            }

            if ($entry.Type -ne "Toggle" -and $key -notlike "WPFTweaks*") {
                $invalid.Add("$key is not a Toggle and not a WPFTweaks entry")
            }
        }

        if ($invalid.Count -gt 0) {
            throw ($invalid -join "`n")
        }
    }

    It "includes the HAGS toggle with the GPU scheduling registry value" {
        $tweaks = Get-WinUtilConfigObject -Name "tweaks"
        $hags = $tweaks.WPFToggleHAGS

        $script:tweakKeys | Should -Contain "WPFToggleHAGS"
        $hags | Should -Not -BeNullOrEmpty
        $hags.Type | Should -Be "Toggle"
        $hags.category | Should -Be "Customize Preferences"
        $hags.Content | Should -Be "Hardware-accelerated GPU Scheduling"

        $registry = @($hags.registry)
        $registry | Should -HaveCount 1
        $registry[0].Path | Should -Be "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"
        $registry[0].Name | Should -Be "HwSchMode"
        $registry[0].Value | Should -Be "2"
        $registry[0].Type | Should -Be "DWord"
        $registry[0].OriginalValue | Should -Be "1"
    }
}

Describe "Setup everything undo toggles" {
    It "lists 9 unique toggles" {
        $script:undoToggleKeys.Count | Should -Be 9
        @($script:undoToggleKeys | Select-Object -Unique).Count | Should -Be 9
    }

    It "references toggles whose off position is a real change" {
        $tweaks = Get-WinUtilConfigObject -Name "tweaks"

        foreach ($key in $script:undoToggleKeys) {
            $entry = $tweaks.$key

            $entry | Should -Not -BeNullOrEmpty -Because "$key must exist in config/tweaks.json"
            @($entry.registry)[0].DefaultState | Should -Be "true" -Because "$key must be switched off by writing its original value"
        }
    }

    It "leaves out the toggles whose off position is already the Windows default" {
        $defaultOff = @(
            "WPFToggleDetailedBSoD"
            "WPFToggleVerboseLogon"
            "WPFToggleS3Sleep"
            "WPFToggleBatteryPercentage"
        )

        foreach ($key in $defaultOff) {
            $script:undoToggleKeys | Should -Not -Contain $key
        }
    }

    It "applies the undo list with -undo" {
        $source = Get-Content -Path $script:functionPath -Raw

        $source | Should -Match 'Invoke-WinUtilTweaks\s+\$toggle\s+-undo\s+\$true'
    }
}
