function Invoke-WPFSetupEverything {
    <#

    .SYNOPSIS
        Runs one fixed setup: installs the standard apps, applies the recommended tweaks and enables GPU scheduling

    .DESCRIPTION
        Every key is fixed here instead of read from the checkboxes, so a press always performs
        the same set. Installs and tweaks share a single job, so the progress bar and the log
        cover the whole sequence rather than stopping after the apps.

    #>

    $appKeys = @(
        "7zip"
        "battlenet"
        "brave"
        "chrome"
        "discord"
        "epicgames"
        "firefox"
        "freedownloadmanager"
        "klite"
        "lightshot"
        "msiafterburner"
        "nvidiaapp"
        "nvidiabroadcast"
        "steam"
        "whatsapp"
    )

    # The restore point is taken first, so the app installs and the tweaks are both covered
    $restorePointKey = "WPFTweaksRestorePoint"

    $tweakKeys = @(
        "WPFTweaksActivity"
        "WPFTweaksConsumerFeatures"
        "WPFTweaksDeliveryOptimization"
        "WPFTweaksEndTaskOnTaskbar"
        "WPFTweaksDisableExplorerAutoDiscovery"
        "WPFTweaksLocation"
        "WPFTweaksDisableStoreSearch"
        "WPFTweaksServices"
        "WPFTweaksTelemetry"
        "WPFTweaksWidget"
        "WPFTweaksWPBT"
        "WPFTweaksDisableBGapps"
        "WPFTweaksBraveDebloat"
        "WPFTweaksRemoveHomeAndGallery"
        "WPFTweaksEdgeDebloat"
        "WPFTweaksRemoveOneDrive"
        "WPFTweaksRightClickMenu"
        "WPFTweaksDisableNotifications"
        "WPFTweaksWindowsAI"
        "WPFToggleDarkMode"
        "WPFToggleLongPaths"
        "WPFToggleShowExt"
        "WPFToggleHiddenFiles"
        "WPFToggleGameMode"
        "WPFToggleDisableLockscreen"
        "WPFToggleLoginBlur"
        "WPFToggleNumLock"
        "WPFToggleScrollbars"
        "WPFToggleHideSettingsHome"
        "WPFToggleWindowSnapping"
        "WPFToggleHAGS"
    )

    # These nine greyed toggles have an off position that is a real change, because their original
    # value is what a machine ships with the feature enabled. Applying it the way a manual click
    # does writes that state instead of leaving the Windows default. The greyed toggles whose off
    # position is already the Windows default are deliberately left out.
    $undoToggleKeys = @(
        "WPFToggleMouseAcceleration"
        "WPFToggleTaskbarAlignment"
        "WPFToggleTaskbarSearch"
        "WPFToggleTaskView"
        "WPFToggleBingSearch"
        "WPFToggleStartMenuRecommendations"
        "WPFToggleNewOutlook"
        "WPFToggleStandbyFix"
        "WPFToggleStickyKeys"
    )

    # A missing entry would silently shrink the set, so the run is refused up front instead of
    # leaving a half configured machine behind
    $missingKeys = [System.Collections.Generic.List[string]]::new()
    $packages = [System.Collections.Generic.List[object]]::new()
    $applications = $sync.configs.applicationsHashtable

    foreach ($appKey in $appKeys) {
        # Compiled application keys carry the same install prefix the UI selection uses
        $configKey = "WPFInstall$appKey"
        $app = $null
        if ($null -ne $applications -and $applications.ContainsKey($configKey)) {
            $app = $applications[$configKey]
        }

        if ($null -eq $app) {
            $missingKeys.Add($configKey)
        } else {
            $packages.Add($app)
        }
    }

    foreach ($tweakKey in @($restorePointKey) + @($tweakKeys) + @($undoToggleKeys)) {
        if ($null -eq $sync.configs.tweaks.$tweakKey) {
            $missingKeys.Add($tweakKey)
        }
    }

    if ($missingKeys.Count -gt 0) {
        Show-WinUtilMessage -Message "Setup everything cannot run because these config entries are missing: $($missingKeys -join ', ')." -Title "Setup everything" -Icon "Warning"
        return
    }

    $ManagerPreference = $sync.preferences.packagemanager
    Write-WinUtilLog -Component "Setup everything" -Message "Setup everything requested: $(@($packages).Count) app(s), $(@($tweakKeys).Count) tweak(s) to apply, $(@($undoToggleKeys).Count) toggle(s) to switch off, package manager preference: $ManagerPreference"
    Write-WinUtilLog -Component "Setup everything" -Message "Setup everything apps: $($appKeys -join ', ')"
    Write-WinUtilLog -Component "Setup everything" -Message "Setup everything tweaks to apply: $($tweakKeys -join ', ')"
    Write-WinUtilLog -Component "Setup everything" -Message "Setup everything toggles to switch off: $($undoToggleKeys -join ', ')"

    Start-WinUtilJob -Name "Setup everything" -Description "Installing apps and applying tweaks" -DisableAppList -QueueIfBusy -Parameters @{
        Packages = @($packages)
        RestorePointKey = $restorePointKey
        TweakKeys = @($tweakKeys)
        UndoToggleKeys = @($undoToggleKeys)
        ManagerPreference = $ManagerPreference
    } -ScriptBlock {
        param($Packages, $RestorePointKey, $TweakKeys, $UndoToggleKeys, $ManagerPreference)

        # The selector drops any package without a usable winget id, and NVIDIA Broadcast is
        # choco only, so those go back through it with Choco forced and come out installable
        $wingetApps = @($Packages | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.winget) -and $_.winget -ne "na" })
        $chocoOnlyApps = @($Packages | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.winget) -or $_.winget -eq "na" })

        $wingetSplit = Get-WinUtilSelectedPackages -PackageList $wingetApps -Preference $ManagerPreference
        $chocoSplit = Get-WinUtilSelectedPackages -PackageList $chocoOnlyApps -Preference "Choco"

        # Two calls can name the same package, so the merge keeps the first occurrence
        $packagesWinget = [System.Collections.Generic.List[string]]::new()
        foreach ($id in @($wingetSplit['Winget']) + @($chocoSplit['Winget'])) {
            $packageId = [string]$id
            if (-not [string]::IsNullOrWhiteSpace($packageId) -and -not $packagesWinget.Contains($packageId)) {
                $packagesWinget.Add($packageId)
            }
        }

        $packagesChoco = [System.Collections.Generic.List[string]]::new()
        foreach ($id in @($wingetSplit['Choco']) + @($chocoSplit['Choco'])) {
            $packageId = [string]$id
            if (-not [string]::IsNullOrWhiteSpace($packageId) -and -not $packagesChoco.Contains($packageId)) {
                $packagesChoco.Add($packageId)
            }
        }

        # One counter for the restore point, installs, applied tweaks and switches together, so the
        # bar reflects the whole run
        $totalSteps = 1 + $packagesWinget.Count + $packagesChoco.Count + @($TweakKeys).Count + @($UndoToggleKeys).Count
        $completedSteps = 0
        $results = @()

        Write-WinUtilLog -Component "Setup everything" -Message "Setup everything package manager split: winget=$($packagesWinget.Count), choco=$($packagesChoco.Count)"

        # A tweak can fail for reasons outside the run (System Protection off, OneDrive already
        # gone), so each failure is reported and the rest of the list still applies
        $failedTweaks = [System.Collections.Generic.List[string]]::new()

        # The restore point is taken first, so the app installs and the tweaks are both covered
        $position = $completedSteps + 1
        Step-WinUtilJob -Status "Creating a restore point ($position/$totalSteps)" -Percent ([int](($completedSteps / $totalSteps) * 100))

        try {
            Measure-WinUtilStep -Scope "Setup everything" -Name $RestorePointKey -ScriptBlock {
                Invoke-WinUtilTweaks $RestorePointKey
            }
        } catch {
            $failedTweaks.Add($RestorePointKey)
            Write-WinUtilLog -Level "ERROR" -Component "Setup everything" -Message "Tweak $RestorePointKey failed: $($_.Exception.Message)"
        }

        $completedSteps++
        Step-WinUtilJob -Percent ([int](($completedSteps / $totalSteps) * 100))

        if ($packagesWinget.Count -gt 0) {
            Step-WinUtilJob -Status "Preparing WinGet" -State "Indeterminate"
            Install-WinUtilWinget

            foreach ($program in $packagesWinget) {
                $position = $completedSteps + 1
                Step-WinUtilJob -Status "Installing $program ($position/$totalSteps)" -Percent ([int](($completedSteps / $totalSteps) * 100))

                $results += Measure-WinUtilStep -Scope "Setup everything" -Name "winget $program" -ScriptBlock {
                    Install-WinUtilProgramWinget -Action Install -Programs @($program)
                }

                $completedSteps++
                Step-WinUtilJob -Percent ([int](($completedSteps / $totalSteps) * 100))
            }
        }

        if ($packagesChoco.Count -gt 0) {
            Step-WinUtilJob -Status "Preparing Chocolatey" -State "Indeterminate"
            Install-WinUtilChoco

            $position = $completedSteps + 1
            Step-WinUtilJob -Status "Installing Chocolatey packages ($position/$totalSteps)" -Percent ([int](($completedSteps / $totalSteps) * 100))

            $chocoBase = [int](($completedSteps / $totalSteps) * 100)
            $chocoSpan = [int](($packagesChoco.Count / $totalSteps) * 100)
            $results += Measure-WinUtilStep -Scope "Setup everything" -Name "choco $($packagesChoco -join ', ')" -ScriptBlock {
                Install-WinUtilProgramChoco -Action Install -Programs $packagesChoco -ProgressBase $chocoBase -ProgressSpan $chocoSpan
            }

            $completedSteps += $packagesChoco.Count
            Step-WinUtilJob -Percent ([int](($completedSteps / $totalSteps) * 100))
        }

        foreach ($tweak in $TweakKeys) {
            $position = $completedSteps + 1
            $tweakLabel = Get-WinUtilTweakDisplayName -Key $tweak
            Step-WinUtilJob -Status "Applying $tweakLabel ($position/$totalSteps)" -Percent ([int](($completedSteps / $totalSteps) * 100))

            try {
                Measure-WinUtilStep -Scope "Setup everything" -Name $tweak -ScriptBlock {
                    Invoke-WinUtilTweaks $tweak
                }
            } catch {
                $failedTweaks.Add($tweak)
                Write-WinUtilLog -Level "ERROR" -Component "Setup everything" -Message "Tweak $tweak failed: $($_.Exception.Message)"
            }

            $completedSteps++
            Step-WinUtilJob -Percent ([int](($completedSteps / $totalSteps) * 100))
        }

        # A toggle in the off position is still a write for these, because their original value is
        # what Windows ships when the feature is on. Running undo applies that state, so the run
        # reproduces the chosen setup instead of leaving the Windows default
        foreach ($toggle in $UndoToggleKeys) {
            $position = $completedSteps + 1
            $toggleLabel = Get-WinUtilTweakDisplayName -Key $toggle
            Step-WinUtilJob -Status "Switching off $toggleLabel ($position/$totalSteps)" -Percent ([int](($completedSteps / $totalSteps) * 100))

            try {
                Measure-WinUtilStep -Scope "Setup everything" -Name "$toggle undo" -ScriptBlock {
                    Invoke-WinUtilTweaks $toggle -undo $true
                }
            } catch {
                $failedTweaks.Add($toggle)
                Write-WinUtilLog -Level "ERROR" -Component "Setup everything" -Message "Tweak $toggle failed: $($_.Exception.Message)"
            }

            $completedSteps++
            Step-WinUtilJob -Percent ([int](($completedSteps / $totalSteps) * 100))
        }

        # Default apps is the user's choice, so the page opens for them to pick instead of
        # being set behind their back. A failure only costs the shortcut; the dialog still says
        # where to go
        try {
            Start-Process "ms-settings:defaultapps" -ErrorAction Stop
        } catch {
            Write-WinUtilLog -Level "WARN" -Component "Setup everything" -Message "Could not open the Default apps page: $($_.Exception.Message)"
        }

        $failedPackages = @($results | Where-Object { $_.Outcome -eq "Failed" } | ForEach-Object { $_.Package })
        $message = "Pick Brave as the browser and Media Player Classic (K-Lite) as the media player on the Default apps page that just opened.`n`nRestart Windows to finish Hardware-accelerated GPU Scheduling and the other tweaks."
        if ($failedPackages.Count -gt 0) {
            $message += "`n`nThese packages did not install: $($failedPackages -join ', ')."
        }
        if ($failedTweaks.Count -gt 0) {
            $message += "`n`nThese tweaks failed: $($failedTweaks -join ', ')."
        }
        Show-WinUtilMessage -Message $message -Title "Setup everything" -Icon "Information"

        # A failed package still fails the job after the tweaks and the message ran
        Complete-WinUtilPackageRun -Action "Install" -Results $results

        # Tweak failures end the job as one error, marked as already reported so the job wrapper
        # adds context without counting this exception a second time
        if ($failedTweaks.Count -gt 0) {
            $exception = [System.InvalidOperationException]::new("$($failedTweaks.Count) tweak(s) failed: $($failedTweaks -join ', '). See the log for each reason.")
            $exception.Data["WinUtilErrorReported"] = $true
            throw $exception
        }
    }
}
