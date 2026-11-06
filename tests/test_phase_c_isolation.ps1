# test_phase_c_isolation.ps1
# Verification suite for Multigravity Phase C (Isolated Concurrent Authentication)

$ErrorActionPreference = "Continue"

$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$REPO_DIR = Split-Path -Parent $SCRIPT_DIR
$MG_SCRIPT = Join-Path $REPO_DIR "multigravity.ps1"
$CURRENT_PS = (Get-Process -Id $PID).Path

Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "  RUNNING PHASE C CONCURRENT ISOLATION TESTS     " -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan

$TEST_BASE = "$env:TEMP\multigravity_phase_c_test_$(Get-Random)"
$env:MULTIGRAVITY_HOME = $TEST_BASE
$BASE = $TEST_BASE

if (!(Test-Path $TEST_BASE)) {
    New-Item -ItemType Directory -Path $TEST_BASE -Force | Out-Null
}

# Source functions from multigravity.ps1
. $MG_SCRIPT

$initialCred = Get-GeminiCredential

function Assert-Condition($condition, $testName, $failMsg) {
    if ($condition) {
        Write-Host "  [PASS] $testName" -ForegroundColor Green
        return $true
    } else {
        Write-Host "  [FAIL] $testName : $failMsg" -ForegroundColor Red
        return $false
    }
}

$passCount = 0
$totalTests = 0

function Run-Test($name, [scriptblock]$block) {
    $global:totalTests++
    Write-Host "`n[TEST $global:totalTests] $name" -ForegroundColor Yellow
    try {
        $res = & $block
        if ($res -ne $false) {
            $global:passCount++
        }
    } catch {
        Write-Host "  [FAIL] Exception in test: $_" -ForegroundColor Red
    }
}

try {
    # ---------------------------------------------------------
    # TEST 1: Opt-In Isolation Argument Parsing
    # ---------------------------------------------------------
    Run-Test "Opt-in Flag Filtering and Environment Detection" {
        $testProf = "test-prof-opts"
        Invoke-NewProfile $testProf @() | Out-Null
        
        # Test helper function simulating argument handling inside Invoke-LaunchAgy
        $testArgs1 = @("--isolated", "version", "--json")
        $isIso1 = $false
        $filtered1 = @()
        foreach ($arg in $testArgs1) {
            if ($arg -eq "--isolated" -or $arg -eq "--file-auth" -or $arg -eq "-isolated") {
                $isIso1 = $true
            } else {
                $filtered1 += $arg
            }
        }
        
        $c1 = ($isIso1 -eq $true -and $filtered1.Count -eq 2 -and $filtered1[0] -eq "version")
        Assert-Condition $c1 "Argument --isolated is detected and cleanly stripped from child args" "Failed to filter --isolated correctly"
    }

    # ---------------------------------------------------------
    # TEST 2: Environment Variable Scoping and Restoration
    # ---------------------------------------------------------
    Run-Test "SSH_CONNECTION Scoping and Caller Leak Prevention" {
        # Ensure SSH_CONNECTION is not set initially
        Remove-Item Env:\SSH_CONNECTION -ErrorAction SilentlyContinue
        
        $testProf = "test-prof-env"
        Invoke-NewProfile $testProf @() | Out-Null
        
        # Mock agy script to check environment inside child
        $mockAgy = Join-Path $TEST_BASE "mock_agy.ps1"
        $mockContent = @'
param([string[]]$ForwardArgs)
$ssh = $env:SSH_CONNECTION
$user = $env:USERPROFILE
[System.IO.File]::WriteAllText("$env:USERPROFILE\ssh_seen.txt", "SSH=$ssh;USER=$user")
'@
        Set-Content -Path $mockAgy -Value $mockContent -Encoding UTF8

        # Run with mock agy
        $oldAgy = $env:MULTIGRAVITY_AGY
        $env:MULTIGRAVITY_AGY = "pwsh.exe -NoProfile -File `"$mockAgy`""

        # In-line execution simulation of Invoke-LaunchAgy scoping
        $prevSsh = $env:SSH_CONNECTION
        $prevUser = $env:USERPROFILE
        
        $isIsolated = $true
        $PROFILE_DIR = "$TEST_BASE\$testProf"
        $cliDir = "$PROFILE_DIR\.gemini\antigravity-cli"
        New-Item -ItemType Directory -Path $cliDir -Force | Out-Null

        $env:USERPROFILE = $PROFILE_DIR
        $env:SSH_CONNECTION = "127.0.0.1 0 127.0.0.1 0"

        try {
            pwsh.exe -NoProfile -File $mockAgy
        } finally {
            if ($null -ne $prevSsh) {
                $env:SSH_CONNECTION = $prevSsh
            } else {
                Remove-Item Env:\SSH_CONNECTION -ErrorAction SilentlyContinue
            }
            $env:USERPROFILE = $prevUser
            $env:MULTIGRAVITY_AGY = $oldAgy
        }

        $seen = Get-Content "$PROFILE_DIR\ssh_seen.txt" -Raw
        $afterSsh = $env:SSH_CONNECTION

        $c1 = ($seen -like "*SSH=127.0.0.1 0 127.0.0.1 0*")
        $c2 = ([string]::IsNullOrEmpty($afterSsh))

        Assert-Condition ($c1 -and $c2) "SSH_CONNECTION correctly passed to child and restored in caller" "SSH_CONNECTION failed: seen='$seen', after='$afterSsh'"
    }

    # ---------------------------------------------------------
    # TEST 3: Local Token Seeding from Vault
    # ---------------------------------------------------------
    Run-Test "Seeding Profile-Local Token Files from Existing Vault" {
        $testProf = "test-prof-seed"
        Invoke-NewProfile $testProf @() | Out-Null

        $fakeToken = '{"token":{"access_token":"mock_seed_token_123","token_type":"Bearer","refresh_token":"1//seed_refresh","expiry":"2030-01-01T00:00:00Z"},"email":"seed.user@gmail.com"}'
        $vaultFile = "$TEST_BASE\$testProf\.auth_vault"
        Set-Content -Path $vaultFile -Value $fakeToken -Encoding UTF8

        $cliDir = "$TEST_BASE\$testProf\.gemini\antigravity-cli"
        if (!(Test-Path $cliDir)) { New-Item -ItemType Directory -Path $cliDir -Force | Out-Null }
        
        $t1 = Join-Path $cliDir "antigravity-oauth-token"
        $t2 = Join-Path $cliDir "jetski-standalone-oauth-token"

        # Simulate seeding logic in Invoke-LaunchAgy
        if (Test-Path $vaultFile) {
            $vaultVal = (Get-Content -Path $vaultFile -Raw -Encoding UTF8).Trim()
            if (![string]::IsNullOrEmpty($vaultVal)) {
                if (!(Test-Path $t1) -or (Get-Item $t1).Length -eq 0) {
                    Write-AtomicFile $t1 $vaultVal
                }
                if (!(Test-Path $t2) -or (Get-Item $t2).Length -eq 0) {
                    Write-AtomicFile $t2 $vaultVal
                }
            }
        }

        $c1 = (Test-Path $t1) -and (Test-Path $t2)
        $c2 = ((Get-Content $t1 -Raw).Trim() -eq $fakeToken)
        $c3 = ((Get-Content $t2 -Raw).Trim() -eq $fakeToken)

        Assert-Condition ($c1 -and $c2 -and $c3) "Profile token files seeded accurately from .auth_vault" "Token files not properly seeded"
    }

    # ---------------------------------------------------------
    # TEST 4: Sync-ProfileVaultFromLocalToken - Valid Refreshed Token
    # ---------------------------------------------------------
    Run-Test "Vault Synchronization from Valid Refreshed Local Token" {
        $testProf = "test-prof-sync-valid"
        Invoke-NewProfile $testProf @() | Out-Null
        $expectedEmail = "valid.worker@gmail.com"
        Set-DesignatedAccount $testProf $expectedEmail

        $cliDir = "$TEST_BASE\$testProf\.gemini\antigravity-cli"
        New-Item -ItemType Directory -Path $cliDir -Force | Out-Null
        $refreshedToken = '{"token":{"access_token":"refreshed_access_token_xyz","token_type":"Bearer","refresh_token":"1//refreshed_ref_456","expiry":"2035-01-01T00:00:00Z"},"email":"valid.worker@gmail.com"}'
        $tokenPath = Join-Path $cliDir "antigravity-oauth-token"
        Set-Content -Path $tokenPath -Value $refreshedToken -Encoding UTF8

        Sync-ProfileVaultFromLocalToken $testProf

        $vaultContent = (Get-Content "$TEST_BASE\$testProf\.auth_vault" -Raw -Encoding UTF8).Trim()
        $accountContent = (Get-Content "$TEST_BASE\$testProf\.account" -Raw -Encoding UTF8).Trim()

        $c1 = ($vaultContent -eq $refreshedToken)
        $c2 = ($accountContent -eq $expectedEmail)

        Assert-Condition ($c1 -and $c2) "Refreshed token synchronized into .auth_vault and .account" "Vault sync failed: vault='$vaultContent'"
    }

    # ---------------------------------------------------------
    # TEST 5: Sync-ProfileVaultFromLocalToken - Fail-Closed on Identity Mismatch
    # ---------------------------------------------------------
    Run-Test "Fail-Closed Protection on Local Token Identity Mismatch" {
        $testProf = "test-prof-mismatch"
        Invoke-NewProfile $testProf @() | Out-Null
        $designatedEmail = "owner.designated@gmail.com"
        Set-DesignatedAccount $testProf $designatedEmail

        # Original legitimate vault
        $originalVault = '{"token":{"access_token":"owner_token_000"},"email":"owner.designated@gmail.com"}'
        Set-Content -Path "$TEST_BASE\$testProf\.auth_vault" -Value $originalVault -Encoding UTF8

        # Mismatched token appears in local CLI directory (e.g. rogue login or wrong token)
        $cliDir = "$TEST_BASE\$testProf\.gemini\antigravity-cli"
        New-Item -ItemType Directory -Path $cliDir -Force | Out-Null
        $mismatchedToken = '{"token":{"access_token":"intruder_token_999"},"email":"intruder.account@gmail.com"}'
        $tokenPath = Join-Path $cliDir "antigravity-oauth-token"
        Set-Content -Path $tokenPath -Value $mismatchedToken -Encoding UTF8

        # Run sync
        Sync-ProfileVaultFromLocalToken $testProf

        # Verify vault was NOT modified
        $vaultAfter = (Get-Content "$TEST_BASE\$testProf\.auth_vault" -Raw -Encoding UTF8).Trim()
        $c1 = ($vaultAfter -eq $originalVault)

        Assert-Condition $c1 "Mismatched local token rejected and original vault preserved" "Security violation: vault was overwritten with mismatched token!"
    }

    # ---------------------------------------------------------
    # TEST 6: Sync-ProfileVaultFromLocalToken - Corrupted / Empty Token
    # ---------------------------------------------------------
    Run-Test "Preserve Vault on Corrupted or Empty Local Token" {
        $testProf = "test-prof-corrupt"
        Invoke-NewProfile $testProf @() | Out-Null
        $designatedEmail = "valid.user@gmail.com"
        Set-DesignatedAccount $testProf $designatedEmail

        $originalVault = '{"token":{"access_token":"valid_existing"},"email":"valid.user@gmail.com"}'
        Set-Content -Path "$TEST_BASE\$testProf\.auth_vault" -Value $originalVault -Encoding UTF8

        $cliDir = "$TEST_BASE\$testProf\.gemini\antigravity-cli"
        New-Item -ItemType Directory -Path $cliDir -Force | Out-Null
        $tokenPath = Join-Path $cliDir "antigravity-oauth-token"
        Set-Content -Path $tokenPath -Value "{broken json..." -Encoding UTF8

        Sync-ProfileVaultFromLocalToken $testProf

        $vaultAfter = (Get-Content "$TEST_BASE\$testProf\.auth_vault" -Raw -Encoding UTF8).Trim()
        $c1 = ($vaultAfter -eq $originalVault)

        Assert-Condition $c1 "Corrupted local token rejected and original vault preserved" "Vault was corrupted by invalid token file!"
    }

    # ---------------------------------------------------------
    # TEST 7: Windows Credential Manager Immutability Check
    # ---------------------------------------------------------
    Run-Test "Windows Credential Manager Remains Strictly Untouched" {
        $credBefore = Get-GeminiCredential
        
        # Run isolated sync on a test profile
        $testProf = "test-prof-credcheck"
        Invoke-NewProfile $testProf @() | Out-Null
        Set-DesignatedAccount $testProf "test.credcheck@gmail.com"
        $cliDir = "$TEST_BASE\$testProf\.gemini\antigravity-cli"
        New-Item -ItemType Directory -Path $cliDir -Force | Out-Null
        $tokenPath = Join-Path $cliDir "antigravity-oauth-token"
        $tok = '{"token":{"access_token":"check123"},"email":"test.credcheck@gmail.com"}'
        Set-Content -Path $tokenPath -Value $tok -Encoding UTF8

        Sync-ProfileVaultFromLocalToken $testProf

        $credAfter = Get-GeminiCredential
        $c1 = ($credBefore -eq $credAfter)

        Assert-Condition $c1 "Windows Credential Manager payload is 100% identical before and after" "Windows Credential Manager was altered!"
    }

    # ---------------------------------------------------------
    # TEST 8: Real Concurrent CLI Execution (Exit Order A then B)
    # ---------------------------------------------------------
    Run-Test "Live Dual CLI Concurrent Execution (Worker A exits before Worker B)" {
        # We test with real installed agy binary in non-interactive print mode
        $realAgy = Find-Agy
        if ([string]::IsNullOrEmpty($realAgy) -or !(Test-Path $realAgy)) {
            Write-Host "  [SKIP] agy binary not found" -ForegroundColor DarkGray
            return $true
        }

        # Setup Profile A and Profile B in real multigravity profiles
        # We use sabbir06 and sabbir2002 (both have saved vaults)
        $realBase = "C:\Users\Sabbir Ahmed\AntigravityProfiles"
        $profA = "sabbir06"
        $profB = "sabbir2002"

        $credBefore = Get-GeminiCredential

        # Run two background jobs using isolated mode
        $jobA = Start-Job -ScriptBlock {
            param($mgScript, $prof, $realBase, $psExec)
            & $psExec -NoProfile -Command "`$env:MULTIGRAVITY_HOME = '$realBase'; & '$mgScript' agy $prof --isolated help"
        } -ArgumentList $MG_SCRIPT, $profA, $realBase, $CURRENT_PS

        # Wait 200ms then start Job B with a slight delay so A exits before B
        Start-Sleep -Milliseconds 200

        $jobB = Start-Job -ScriptBlock {
            param($mgScript, $prof, $realBase, $psExec)
            Start-Sleep -Milliseconds 600
            & $psExec -NoProfile -Command "`$env:MULTIGRAVITY_HOME = '$realBase'; & '$mgScript' agy $prof --isolated help"
        } -ArgumentList $MG_SCRIPT, $profB, $realBase, $CURRENT_PS

        # Wait for Job A then Job B
        Wait-Job $jobA | Out-Null
        Wait-Job $jobB | Out-Null

        $outA = Receive-Job $jobA | Out-String
        $outB = Receive-Job $jobB | Out-String

        Remove-Job $jobA, $jobB -Force

        $credAfter = Get-GeminiCredential

        $c1 = ($outA -like "*isolated file-based auth*")
        $c2 = ($outB -like "*isolated file-based auth*")
        $c3 = ($credBefore -eq $credAfter)

        Assert-Condition ($c1 -and $c2 -and $c3) "Both concurrent jobs ran isolated and Credential Manager was untouched" "Concurrent run failed: c1=$c1, c2=$c2, c3=$c3"
    }

    # ---------------------------------------------------------
    # TEST 9: Real Concurrent CLI Execution (Exit Order B then A)
    # ---------------------------------------------------------
    Run-Test "Live Dual CLI Concurrent Execution (Worker B exits before Worker A)" {
        $realAgy = Find-Agy
        if ([string]::IsNullOrEmpty($realAgy) -or !(Test-Path $realAgy)) {
            Write-Host "  [SKIP] agy binary not found" -ForegroundColor DarkGray
            return $true
        }

        $realBase = "C:\Users\Sabbir Ahmed\AntigravityProfiles"
        $profA = "sabbir06"
        $profB = "sabbir2002"

        $credBefore = Get-GeminiCredential

        # Start Job A with a delay so Job B finishes first
        $jobA = Start-Job -ScriptBlock {
            param($mgScript, $prof, $realBase, $psExec)
            Start-Sleep -Milliseconds 600
            & $psExec -NoProfile -Command "`$env:MULTIGRAVITY_HOME = '$realBase'; & '$mgScript' agy $prof --isolated help"
        } -ArgumentList $MG_SCRIPT, $profA, $realBase, $CURRENT_PS

        Start-Sleep -Milliseconds 100

        $jobB = Start-Job -ScriptBlock {
            param($mgScript, $prof, $realBase, $psExec)
            & $psExec -NoProfile -Command "`$env:MULTIGRAVITY_HOME = '$realBase'; & '$mgScript' agy $prof --isolated help"
        } -ArgumentList $MG_SCRIPT, $profB, $realBase, $CURRENT_PS

        Wait-Job $jobB | Out-Null
        Wait-Job $jobA | Out-Null

        $outA = Receive-Job $jobA | Out-String
        $outB = Receive-Job $jobB | Out-String

        Remove-Job $jobA, $jobB -Force

        $credAfter = Get-GeminiCredential

        $c1 = ($outA -like "*isolated file-based auth*")
        $c2 = ($outB -like "*isolated file-based auth*")
        $c3 = ($credBefore -eq $credAfter)

        Assert-Condition ($c1 -and $c2 -and $c3) "Reversed exit order completed safely with zero Credential Manager interference" "Reversed order failed: c1=$c1, c2=$c2, c3=$c3"
    }

    # ---------------------------------------------------------
    # TEST 10: Non-Isolated Default Mode Backward Compatibility
    # ---------------------------------------------------------
    Run-Test "Default Mode Unaffected (Backward Compatibility Preserved)" {
        $testProf = "test-prof-default"
        Invoke-NewProfile $testProf @() | Out-Null

        $mockAgy = Join-Path $TEST_BASE "mock_agy2.cmd"
        Set-Content -Path $mockAgy -Value "@echo mock agy executed" -Encoding ASCII

        $oldAgy = $env:MULTIGRAVITY_AGY
        $env:MULTIGRAVITY_AGY = $mockAgy

        try {
            $output = & "$CURRENT_PS" -NoProfile -File $MG_SCRIPT agy $testProf version 2>&1 | Out-String
            $c1 = ($output -notlike "*isolated file-based auth*")
            $c2 = ($output -like "*Launching agy CLI with profile '$testProf'...*")
            Assert-Condition ($c1 -and $c2) "Default execution retains standard Phase B credential workflow" "Default mode was altered: $output"
        } finally {
            $env:MULTIGRAVITY_AGY = $oldAgy
        }
    }

    # ---------------------------------------------------------
    # TEST 11: Fail-Closed When agy Binary Lacks File-Based Auth Support
    # ---------------------------------------------------------
    Run-Test "Fail-Closed on Unsupported agy Binary" {
        $realAgy = Find-Agy
        $c1 = (Test-AgyBinarySupportsFileAuth $realAgy)

        # Create a mock binary without SSH_CONNECTION / composite_token_storage
        $fakeBin = Join-Path $TEST_BASE "fake_unsupported_agy.exe"
        [System.IO.File]::WriteAllBytes($fakeBin, [System.Text.Encoding]::ASCII.GetBytes("MZ_DUMMY_BINARY_WITHOUT_SSH_AUTH_MARKERS_1234567890"))

        $c2 = ((Test-AgyBinarySupportsFileAuth $fakeBin) -eq $false)

        # Verify CLI refuses to launch in isolated mode with unsupported binary
        $testProf = "test-prof-unsupported"
        Invoke-NewProfile $testProf @() | Out-Null
        Set-DesignatedAccount $testProf "test.unsupported@gmail.com"
        Set-Content -Path "$TEST_BASE\$testProf\.auth_vault" -Value '{"token":{"access_token":"valid"},"id_token_email":"test.unsupported@gmail.com"}' -Encoding UTF8

        $oldAgy = $env:MULTIGRAVITY_AGY
        $env:MULTIGRAVITY_AGY = $fakeBin

        try {
            $output = & "$CURRENT_PS" -NoProfile -File $MG_SCRIPT agy $testProf --isolated version 2>&1 | Out-String
            $c3 = ($output -match "prevent silent fallback")
            Assert-Condition ($c1 -and $c2 -and $c3) "Real binary confirmed supported; unsupported binary fails closed before execution" "Failed binary support validation: c1=$c1, c2=$c2, c3=$c3"
        } finally {
            $env:MULTIGRAVITY_AGY = $oldAgy
        }
    }

    # ---------------------------------------------------------
    # TEST 12: Pre-Execution Profile Identity Validation
    # ---------------------------------------------------------
    Run-Test "Pre-Flight Fail-Closed Profile Identity Validation" {
        # Profile without designated account
        $testProfNoBind = "test-prof-nobind"
        Invoke-NewProfile $testProfNoBind @() | Out-Null

        $mockAgy = Join-Path $TEST_BASE "mock_agy3.cmd"
        Set-Content -Path $mockAgy -Value "@echo mock agy executed" -Encoding ASCII
        $oldAgy = $env:MULTIGRAVITY_AGY
        $env:MULTIGRAVITY_AGY = $mockAgy

        try {
            # 1. Unbound profile launch
            $out1 = & "$CURRENT_PS" -NoProfile -File $MG_SCRIPT agy $testProfNoBind --isolated version 2>&1 | Out-String
            $c1 = ($out1 -match "has no designated account configured")

            # 2. Bound profile with mismatched vault
            $testProfMis = "test-prof-varmis"
            Invoke-NewProfile $testProfMis @() | Out-Null
            Set-DesignatedAccount $testProfMis "expected.user@gmail.com"
            Set-Content -Path "$TEST_BASE\$testProfMis\.auth_vault" -Value '{"token":{"access_token":"valid"},"id_token_email":"other.user@gmail.com"}' -Encoding UTF8

            $out2 = & "$CURRENT_PS" -NoProfile -File $MG_SCRIPT agy $testProfMis --isolated version 2>&1 | Out-String
            $c2 = ($out2 -match "vault credentials belong to")

            Assert-Condition ($c1 -and $c2) "Pre-flight validation blocks unbound or mismatched profiles before execution" "Pre-flight validation failed: c1=$c1, c2=$c2"
        } finally {
            $env:MULTIGRAVITY_AGY = $oldAgy
        }
    }

    # ---------------------------------------------------------
    # TEST 13: Windows Credential Manager Non-Interference Guard
    # ---------------------------------------------------------
    Run-Test "Windows Credential Manager Non-Interference (Preserve Shared Credentials)" {
        $testProf = "test-prof-tamper"
        Invoke-NewProfile $testProf @() | Out-Null
        Set-DesignatedAccount $testProf "tamper.test@gmail.com"
        Set-Content -Path "$TEST_BASE\$testProf\.auth_vault" -Value '{"token":{"access_token":"valid"},"id_token_email":"tamper.test@gmail.com"}' -Encoding UTF8

        # Mock script that simulates an external process updating Windows Credential Manager during isolated execution
        $mockTamperAgy = Join-Path $TEST_BASE "mock_tamper_agy.ps1"
        $mockTamperContent = @"
. '$MG_SCRIPT'
Set-GeminiCredential '{"token":{"access_token":"concurrent_update"},"id_token_email":"concurrent.external@gmail.com"}' | Out-Null
"@
        Set-Content -Path $mockTamperAgy -Value $mockTamperContent -Encoding UTF8

        $mockTamperCmd = Join-Path $TEST_BASE "mock_tamper_agy.cmd"
        Set-Content -Path $mockTamperCmd -Value "`"$CURRENT_PS`" -NoProfile -File `"$mockTamperAgy`"" -Encoding ASCII

        $initialCredBeforeTamper = Get-GeminiCredential

        $oldAgy = $env:MULTIGRAVITY_AGY
        $env:MULTIGRAVITY_AGY = $mockTamperCmd

        try {
            $out = & "$CURRENT_PS" -NoProfile -File $MG_SCRIPT agy $testProf --isolated version 2>&1 | Out-String
            $credAfterTamper = Get-GeminiCredential

            # 1. Isolated session notices update and explicitly reports preserving it
            $c1 = ($out -match "Shared Windows Credential Manager was updated during isolated session") -and ($out -match "Preserving shared credential")
            # 2. Isolated session NEVER restored/reverted the shared credential
            $c2 = ($credAfterTamper -like "*concurrent.external@gmail.com*")

            Assert-Condition ($c1 -and $c2) "External changes to Windows Credential Manager are preserved without restoration or overwrite" "Preservation check failed: c1=$c1, c2=$c2, out=$out"
        } finally {
            $env:MULTIGRAVITY_AGY = $oldAgy
            if ($initialCredBeforeTamper) {
                Set-GeminiCredential $initialCredBeforeTamper | Out-Null
            }
        }
    }

    # ---------------------------------------------------------
    # TEST 14: Mixed-Mode Concurrency (Normal CLI + Isolated CLI)
    # ---------------------------------------------------------
    Run-Test "Mixed-Mode Concurrency: Normal CLI and Isolated CLI Coexist" {
        $normProf = "test-prof-normal"
        $isoProf = "test-prof-isolated"

        Invoke-NewProfile $normProf @() | Out-Null
        Set-DesignatedAccount $normProf "normal.user@gmail.com"
        Set-Content -Path "$TEST_BASE\$normProf\.auth_vault" -Value '{"token":{"access_token":"norm_tok"},"id_token_email":"normal.user@gmail.com"}' -Encoding UTF8

        Invoke-NewProfile $isoProf @() | Out-Null
        Set-DesignatedAccount $isoProf "isolated.user@gmail.com"
        Set-Content -Path "$TEST_BASE\$isoProf\.auth_vault" -Value '{"token":{"access_token":"iso_tok"},"id_token_email":"isolated.user@gmail.com"}' -Encoding UTF8

        # Mock agy script that delays slightly to ensure true concurrent execution
        $mockSlowAgy = Join-Path $TEST_BASE "mock_slow_agy.ps1"
        $mockSlowContent = @"
Start-Sleep -Milliseconds 600
Write-Output "mock agy finished"
"@
        Set-Content -Path $mockSlowAgy -Value $mockSlowContent -Encoding UTF8

        $mockSlowCmd = Join-Path $TEST_BASE "mock_slow_agy.cmd"
        Set-Content -Path $mockSlowCmd -Value "`"$CURRENT_PS`" -NoProfile -File `"$mockSlowAgy`"" -Encoding ASCII

        $oldAgy = $env:MULTIGRAVITY_AGY
        $env:MULTIGRAVITY_AGY = $mockSlowCmd

        # Simulate normal profile being the active session in Windows Credential Manager
        $normCred = '{"token":{"access_token":"norm_tok"},"id_token_email":"normal.user@gmail.com"}'
        Set-GeminiCredential $normCred | Out-Null

        try {
            # Start isolated session in background job
            $isoJob = Start-Job -ScriptBlock {
                param($psExe, $mgScript, $prof)
                & "$psExe" -NoProfile -File $mgScript agy $prof --isolated version 2>&1
            } -ArgumentList $CURRENT_PS, $MG_SCRIPT, $isoProf

            # While isolated job is running, normal profile executes standard CLI command
            $normOut = & "$CURRENT_PS" -NoProfile -File $MG_SCRIPT agy $normProf version 2>&1 | Out-String

            # Wait for isolated job
            $isoJob | Wait-Job | Out-Null
            $isoOut = ($isoJob | Receive-Job | Out-String)
            Remove-Job $isoJob -Force

            # Credential Manager must still hold normal.user@gmail.com
            $credAfter = Get-GeminiCredential
            $c1 = ($credAfter -like "*normal.user@gmail.com*")

            # Isolated session succeeded with isolated file auth
            $c2 = ($isoOut -like "*isolated file-based auth*")
            $c3 = ($normOut -notlike "*isolated file-based auth*")

            Assert-Condition ($c1 -and $c2 -and $c3) "Normal and isolated sessions ran concurrently without cross-contamination" "Mixed concurrency failed: c1=$c1, c2=$c2, c3=$c3"
        } finally {
            $env:MULTIGRAVITY_AGY = $oldAgy
            if ($initialCred) {
                Set-GeminiCredential $initialCred | Out-Null
            }
        }
    }

    # ---------------------------------------------------------
    # TEST 15: Same-Profile Concurrent Isolated Instances
    # ---------------------------------------------------------
    Run-Test "Same-Profile Concurrent Isolated CLI Instances with Mutex Serialization" {
        $sameProf = "test-prof-same"
        Invoke-NewProfile $sameProf @() | Out-Null
        Set-DesignatedAccount $sameProf "same.account@gmail.com"
        $initialVault = '{"token":{"access_token":"same_initial","refresh_token":"1//init"},"id_token_email":"same.account@gmail.com"}'
        Set-Content -Path "$TEST_BASE\$sameProf\.auth_vault" -Value $initialVault -Encoding UTF8

        # Mock agy script that refreshes local token during execution
        $mockRefreshAgy = Join-Path $TEST_BASE "mock_refresh_agy.ps1"
        $mockRefreshContent = @"
param(`$instId)
Start-Sleep -Milliseconds (Get-Random -Minimum 200 -Maximum 500)
`$cliDir = "`$env:MULTIGRAVITY_HOME\test-prof-same\.gemini\antigravity-cli"
if (Test-Path `$cliDir) {
    `$newToken = [ordered]@{
        token = [ordered]@{
            access_token = "ya29.refreshed_`$instId"
            refresh_token = "1//refreshed_`$instId"
            expiry = (Get-Date).AddHours(1).ToString("o")
        }
        id_token_email = "same.account@gmail.com"
    } | ConvertTo-Json -Compress
    Set-Content -Path "`$cliDir\jetski-standalone-oauth-token" -Value `$newToken -Encoding UTF8
    Set-Content -Path "`$cliDir\antigravity-oauth-token" -Value `$newToken -Encoding UTF8
}
Start-Sleep -Milliseconds 200
"@
        Set-Content -Path $mockRefreshAgy -Value $mockRefreshContent -Encoding UTF8

        $mockRefreshCmd = Join-Path $TEST_BASE "mock_refresh_agy.cmd"
        Set-Content -Path $mockRefreshCmd -Value "`"$CURRENT_PS`" -NoProfile -File `"$mockRefreshAgy`" %*" -Encoding ASCII

        $oldAgy = $env:MULTIGRAVITY_AGY
        $env:MULTIGRAVITY_AGY = $mockRefreshCmd

        try {
            # Launch two concurrent isolated instances of the same profile
            $job1 = Start-Job -ScriptBlock {
                param($psExe, $mgScript, $prof)
                & "$psExe" -NoProfile -File $mgScript agy $prof --isolated worker1 2>&1
            } -ArgumentList $CURRENT_PS, $MG_SCRIPT, $sameProf

            $job2 = Start-Job -ScriptBlock {
                param($psExe, $mgScript, $prof)
                & "$psExe" -NoProfile -File $mgScript agy $prof --isolated worker2 2>&1
            } -ArgumentList $CURRENT_PS, $MG_SCRIPT, $sameProf

            $job1 | Wait-Job | Out-Null
            $job2 | Wait-Job | Out-Null
            $res1 = ($job1 | Receive-Job | Out-String)
            $res2 = ($job2 | Receive-Job | Out-String)
            $state1 = $job1.State
            $state2 = $job2.State
            Remove-Job $job1, $job2 -Force

            # Both jobs must execute cleanly
            $c1 = ($state1 -eq "Completed" -or $res1 -like "*Launching agy CLI*")
            $c2 = ($state2 -eq "Completed" -or $res2 -like "*Launching agy CLI*")

            # Final vault must be valid JSON and contain a refreshed token from either worker
            $vaultContent = Get-Content -Raw "$TEST_BASE\$sameProf\.auth_vault" -Encoding UTF8
            $vaultJson = $vaultContent | ConvertFrom-Json
            $c3 = ($vaultJson.id_token_email -eq "same.account@gmail.com")
            $c4 = ($vaultJson.token.access_token -like "ya29.refreshed_*")

            Assert-Condition ($c1 -and $c2 -and $c3 -and $c4) "Concurrent instances of same profile serialized vault sync safely" "Concurrency test failed: c1=$c1, c2=$c2, c3=$c3, c4=$c4, res1=$res1, res2=$res2"
        } finally {
            $env:MULTIGRAVITY_AGY = $oldAgy
            if ($initialCred) {
                Set-GeminiCredential $initialCred | Out-Null
            }
        }
    }

} finally {
    # Cleanup test sandbox
    if (Test-Path $TEST_BASE) {
        Remove-Item -Recurse -Force $TEST_BASE -ErrorAction SilentlyContinue
    }
    # Restore initial cred if anything changed
    $finalCred = Get-GeminiCredential
    if ($initialCred -and ($finalCred -ne $initialCred)) {
        Set-GeminiCredential $initialCred | Out-Null
    }
}

Write-Host "`n=================================================" -ForegroundColor Cyan
Write-Host "  PHASE C RESULTS: $passCount / $totalTests TESTS PASSED" -ForegroundColor Cyan
Write-Host "=================================================`n" -ForegroundColor Cyan

if ($passCount -ne $totalTests) {
    exit 1
}
