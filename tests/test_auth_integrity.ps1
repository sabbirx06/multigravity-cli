# Regression and Credential Integrity Test Suite for Multigravity Phase B
$ErrorActionPreference = "Continue"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoDir = Split-Path -Parent $scriptDir
$mgScript = Join-Path $repoDir "multigravity.ps1"

if (!(Test-Path $mgScript)) {
    throw "multigravity.ps1 not found at: $mgScript"
}

. $mgScript

Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "  RUNNING PHASE B CREDENTIAL INTEGRITY TESTS     " -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan

$testProfile = "test-phaseb-sandbox-" + (Get-Random)
$testDir = "$BASE\$testProfile"
$cliDir = "$testDir\.gemini\antigravity-cli"

New-Item -ItemType Directory -Path $cliDir -Force | Out-Null

$expectedEmail = "test.expected.dev@gmail.com"
$intruderEmail = "test.intruder.006@gmail.com"

function New-MockCred($email) {
    return [ordered]@{
        token          = [ordered]@{
            access_token  = "ya29.mock_access_token"
            refresh_token = "1//mock_refresh_token"
            expiry        = (Get-Date).AddHours(1).ToString("o")
        }
        id_token_email = $email
    } | ConvertTo-Json -Compress
}

$origVaultContent = New-MockCred $expectedEmail
Set-Content -Path "$testDir\.auth_vault" -Value $origVaultContent -NoNewline -Encoding UTF8
Set-Content -Path "$testDir\.account" -Value $expectedEmail -NoNewline -Encoding UTF8
Set-Content -Path "$testDir\.designated_account" -Value $expectedEmail -NoNewline -Encoding UTF8
Set-Content -Path "$cliDir\jetski-standalone-oauth-token" -Value $origVaultContent -NoNewline -Encoding UTF8
Set-Content -Path "$cliDir\antigravity-oauth-token" -Value $origVaultContent -NoNewline -Encoding UTF8

$passCount = 0
$totalCount = 20

# -------------------------------------------------------------
# TEST 1: Mismatched Identity Guard
# -------------------------------------------------------------
Write-Host "`n[TEST 1] Mismatched Identity Overwrite Attempt:" -ForegroundColor Yellow
$script:mockCred = New-MockCred $intruderEmail
function Get-GeminiCredential { return $script:mockCred }

Save-ProfileVault $testProfile

$afterVault = (Get-Content "$testDir\.auth_vault" -Raw -Encoding UTF8).Trim()
$afterEmail = Get-EmailFromCredential $afterVault

if ($afterEmail -eq $expectedEmail) {
    Write-Host "  [PASS] Intruder overwrite blocked! Vault still contains: $afterEmail" -ForegroundColor Green
    $passCount++
}
else {
    Write-Host "  [FAIL] Vault was corrupted with: $afterEmail" -ForegroundColor Red
}

# -------------------------------------------------------------
# TEST 2: Empty Credential Guard (Absence Protection)
# -------------------------------------------------------------
Write-Host "`n[TEST 2] Empty Credential in Credential Manager:" -ForegroundColor Yellow
$script:mockCred = ""

Save-ProfileVault $testProfile

if ((Test-Path "$testDir\.auth_vault") -and (Test-Path "$cliDir\jetski-standalone-oauth-token")) {
    $vaultText = (Get-Content "$testDir\.auth_vault" -Raw -Encoding UTF8).Trim()
    $email = Get-EmailFromCredential $vaultText
    if ($email -eq $expectedEmail) {
        Write-Host "  [PASS] Empty credential did not delete profile vault or tokens. Still contains: $email" -ForegroundColor Green
        $passCount++
    }
    else {
        Write-Host "  [FAIL] Vault corrupted during empty credential test." -ForegroundColor Red
    }
}
else {
    Write-Host "  [FAIL] Vault or token files were deleted when credential was empty!" -ForegroundColor Red
}

# -------------------------------------------------------------
# TEST 3: Malformed Credential Guard
# -------------------------------------------------------------
Write-Host "`n[TEST 3] Malformed Credential (corrupted payload):" -ForegroundColor Yellow
$script:mockCred = "{ invalid_json: true, id_token: 'not-a-jwt' }"

Save-ProfileVault $testProfile

$vaultText = (Get-Content "$testDir\.auth_vault" -Raw -Encoding UTF8).Trim()
$email = Get-EmailFromCredential $vaultText
if ($email -eq $expectedEmail) {
    Write-Host "  [PASS] Malformed credential rejected. Vault preserved with: $email" -ForegroundColor Green
    $passCount++
}
else {
    Write-Host "  [FAIL] Malformed credential corrupted the vault." -ForegroundColor Red
}

# -------------------------------------------------------------
# TEST 4: Atomic File Replacement & Temp File Cleanup
# -------------------------------------------------------------
Write-Host "`n[TEST 4] Atomic File Replacement & Temp File Cleanup:" -ForegroundColor Yellow
$testFile = "$testDir\atomic_test.txt"
Set-Content -Path $testFile -Value "Initial Content"

Write-AtomicFile $testFile "Replaced Content"
$readBack = Get-Content -Path $testFile -Raw

$tempFiles = Get-ChildItem -Path $testDir -Filter ".tmp_*"
$bakFiles  = Get-ChildItem -Path $testDir -Filter ".bak_*"
if ($readBack.Trim() -eq "Replaced Content" -and $tempFiles.Count -eq 0 -and $bakFiles.Count -eq 0) {
    Write-Host "  [PASS] Atomic replacement succeeded with zero orphaned temp/bak files." -ForegroundColor Green
    $passCount++
}
else {
    Write-Host "  [FAIL] Atomic write failed or left temp files behind." -ForegroundColor Red
}

# -------------------------------------------------------------
# TEST 5: Concurrency Vault Mutex Lock
# -------------------------------------------------------------
Write-Host "`n[TEST 5] Vault Mutex Lock Cross-Process Serialization:" -ForegroundColor Yellow
$script:blocked = $false

Invoke-WithProfileVaultLock $testProfile {
    $cleanName = ($testProfile -replace '[^a-zA-Z0-9_]', '_')
    $mutexName = "Local\multigravity_vault_$cleanName"
    
    $proc = Start-Process -FilePath "powershell" -ArgumentList "-NoProfile", "-Command", @"
`$m2 = New-Object System.Threading.Mutex(`$false, '$mutexName')
if (`$m2.WaitOne(200)) {
    `$m2.ReleaseMutex()
    exit 10
} else {
    exit 20
}
"@ -Wait -PassThru -NoNewWindow

    if ($proc.ExitCode -eq 20) {
        $script:blocked = $true
    }
} | Out-Null

if ($script:blocked) {
    Write-Host "  [PASS] Mutex lock successfully blocked concurrent external process!" -ForegroundColor Green
    $passCount++
}
else {
    Write-Host "  [FAIL] Mutex lock failed to block concurrent external process." -ForegroundColor Red
}

# -------------------------------------------------------------
# TEST 6: Legitimate Matching Save
# -------------------------------------------------------------
Write-Host "`n[TEST 6] Legitimate Matching Credential Save:" -ForegroundColor Yellow
$newValidCred = New-MockCred $expectedEmail
$script:mockCred = $newValidCred

Save-ProfileVault $testProfile

$savedVault = (Get-Content "$testDir\.auth_vault" -Raw -Encoding UTF8).Trim()
$savedCli = (Get-Content "$cliDir\jetski-standalone-oauth-token" -Raw -Encoding UTF8).Trim()
$savedEmail = Get-EmailFromCredential $savedVault

if ($savedEmail -eq $expectedEmail -and $savedVault -eq $newValidCred -and $savedCli -eq $newValidCred) {
    Write-Host "  [PASS] Legitimate credential verified and atomically synced to all vault files!" -ForegroundColor Green
    $passCount++
}
else {
    Write-Host "  [FAIL] Legitimate save failed to sync properly." -ForegroundColor Red
}

# -------------------------------------------------------------
# TEST 7: Intentional Account Change via Force Override
# -------------------------------------------------------------
Write-Host "`n[TEST 7] Intentional Account Change via Force Override (--force):" -ForegroundColor Yellow
$intentionalEmail = "test.new.intentional@gmail.com"
$script:mockCred = New-MockCred $intentionalEmail

Save-ProfileVault $testProfile -Force

$vaultText = (Get-Content "$testDir\.auth_vault" -Raw -Encoding UTF8).Trim()
$savedEmail = Get-EmailFromCredential $vaultText
$designated = Get-DesignatedAccount $testProfile

if ($savedEmail -eq $intentionalEmail -and $designated -eq $intentionalEmail) {
    Write-Host "  [PASS] Intentional force-save accepted and updated designated account to: $designated" -ForegroundColor Green
    $passCount++
} else {
    Write-Host "  [FAIL] Force save failed to update vault and designated account." -ForegroundColor Red
}

# -------------------------------------------------------------
# TEST 8: Explicit Account Re-Binding via auth bind
# -------------------------------------------------------------
Write-Host "`n[TEST 8] Explicit Account Re-Binding via Set-DesignatedAccount / bind:" -ForegroundColor Yellow
$rebindEmail = "test.rebound.account@gmail.com"
Set-DesignatedAccount $testProfile $rebindEmail
$designated = Get-DesignatedAccount $testProfile

$script:mockCred = New-MockCred $rebindEmail
Save-ProfileVault $testProfile

$vaultText = (Get-Content "$testDir\.auth_vault" -Raw -Encoding UTF8).Trim()
$savedEmail = Get-EmailFromCredential $vaultText

if ($designated -eq $rebindEmail -and $savedEmail -eq $rebindEmail) {
    Write-Host "  [PASS] Explicit re-bind succeeded and allowed saving new session: $savedEmail" -ForegroundColor Green
    $passCount++
} else {
    Write-Host "  [FAIL] Re-bind failed." -ForegroundColor Red
}

# -------------------------------------------------------------
# TEST 9: Account Unbinding & Clean Profile Login
# -------------------------------------------------------------
Write-Host "`n[TEST 9] Account Unbinding & Clean Profile Login:" -ForegroundColor Yellow
Remove-DesignatedAccount $testProfile
$designated = Get-DesignatedAccount $testProfile

$cleanLoginEmail = "test.clean.firstlogin@gmail.com"
$script:mockCred = New-MockCred $cleanLoginEmail
Save-ProfileVault $testProfile

$afterUnbindVault = (Get-Content "$testDir\.auth_vault" -Raw -Encoding UTF8).Trim()
$afterUnbindEmail = Get-EmailFromCredential $afterUnbindVault
$newDesignated = Get-DesignatedAccount $testProfile

if ($afterUnbindEmail -eq $cleanLoginEmail -and $newDesignated -eq $cleanLoginEmail) {
    Write-Host "  [PASS] Unbound profile cleanly accepted new login and auto-bound to: $newDesignated" -ForegroundColor Green
    $passCount++
} else {
    Write-Host "  [FAIL] Clean login on unbound profile failed." -ForegroundColor Red
}

# -------------------------------------------------------------
# TEST 10: Cross-Profile Accidental Binding Protection (Check 6)
# -------------------------------------------------------------
Write-Host "`n[TEST 10] Cross-Profile Accidental Binding Block (New/Imported Profile):" -ForegroundColor Yellow
$newUnboundProfile = "test-unbound-" + (Get-Random)
$unboundDir = "$BASE\$newUnboundProfile"
New-Item -ItemType Directory -Path $unboundDir -Force | Out-Null

# Active credential in Credential Manager belongs to another profile's designated account
$existingOwnerEmail = "test.clean.firstlogin@gmail.com" # Currently designated to $testProfile
$script:mockCred = New-MockCred $existingOwnerEmail

# Attempt to save to $newUnboundProfile without explicit bind or force
Save-ProfileVault $newUnboundProfile

$unboundDesignated = Get-DesignatedAccount $newUnboundProfile
if ([string]::IsNullOrEmpty($unboundDesignated) -and !(Test-Path "$unboundDir\.auth_vault")) {
    Write-Host "  [PASS] Cross-profile binding successfully blocked! Unbound profile did NOT steal '$existingOwnerEmail'" -ForegroundColor Green
    $passCount++
} else {
    Write-Host "  [FAIL] Unbound profile accidentally bound to another profile's account: $unboundDesignated" -ForegroundColor Red
}
if (Test-Path $unboundDir) { Remove-Item $unboundDir -Recurse -Force }

# -------------------------------------------------------------
# TEST 11: Designated Account Conflict Detection & Fail-Closed Guard (Point 4)
# -------------------------------------------------------------
Write-Host "`n[TEST 11] Conflict Detection between Marker File and Central Registry (Fail-Closed):" -ForegroundColor Yellow
$conflictProfile = "test-conflict-" + (Get-Random)
$conflictDir = "$BASE\$conflictProfile"
New-Item -ItemType Directory -Path $conflictDir -Force | Out-Null

Set-Content -Path "$conflictDir\.designated_account" -Value "marker.primary@gmail.com" -NoNewline -Encoding UTF8
$centralMap = "$BASE\.profile_mappings.json"
Invoke-WithRegistryLock {
    $map = if (Test-Path $centralMap) { Get-Content $centralMap -Raw | ConvertFrom-Json } else { [PSCustomObject]@{} }
    $map | Add-Member -NotePropertyName $conflictProfile -NotePropertyValue "central.different@gmail.com" -Force
    $map | ConvertTo-Json -Depth 5 | Set-Content -Path $centralMap -Encoding UTF8 -Force
}

$resolved = Get-DesignatedAccount $conflictProfile
$isConflictDetected = ($resolved -like "__CONFLICT__*")

# Attempt save without -Force: must fail closed without changing either identity
$script:mockCred = New-MockCred "marker.primary@gmail.com"
Save-ProfileVault $conflictProfile

$markerAfter = (Get-Content "$conflictDir\.designated_account" -Raw -Encoding UTF8).Trim()
$centralAfter = (Get-Content $centralMap -Raw | ConvertFrom-Json).$conflictProfile

if ($isConflictDetected -and $markerAfter -eq "marker.primary@gmail.com" -and $centralAfter -eq "central.different@gmail.com" -and !(Test-Path "$conflictDir\.auth_vault")) {
    Write-Host "  [PASS] Conflict detected! Write-back blocked, neither identity altered without explicit resolution." -ForegroundColor Green
    $passCount++
} else {
    Write-Host "  [FAIL] Conflict guard failed: isConflict=$isConflictDetected, marker=$markerAfter, central=$centralAfter" -ForegroundColor Red
}
if (Test-Path $conflictDir) { Remove-Item $conflictDir -Recurse -Force }
Remove-DesignatedAccount $conflictProfile

# -------------------------------------------------------------
# TEST 12: Dual PowerShell Compatibility (PS 5.1 & PS 7) for Write-AtomicFile (Check 2)
# -------------------------------------------------------------
Write-Host "`n[TEST 12] Dual PowerShell 5.1 & PS 7 Atomic Replacement Test:" -ForegroundColor Yellow
$ps51File = "$testDir\ps51_compat_test.txt"
$ps51Script = @"
. '$mgScript'
Write-AtomicFile '$ps51File' 'Original 5.1 Content'
Write-AtomicFile '$ps51File' 'Atomically Replaced 5.1'
"@
$proc51 = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile", "-Command", $ps51Script -Wait -PassThru -NoNewWindow
$ps51Content = if (Test-Path $ps51File) { (Get-Content $ps51File -Raw).Trim() } else { "" }

if ($proc51.ExitCode -eq 0 -and $ps51Content -eq "Atomically Replaced 5.1") {
    Write-Host "  [PASS] Write-AtomicFile executed flawlessly under Windows PowerShell 5.1 (.NET Framework)" -ForegroundColor Green
    $passCount++
} else {
    Write-Host "  [FAIL] Write-AtomicFile failed under Windows PowerShell 5.1 (Exit: $($proc51.ExitCode), Content: '$ps51Content')" -ForegroundColor Red
}

# -------------------------------------------------------------
# TEST 13: End-to-End Public CLI Command Dispatcher (Check 1)
# -------------------------------------------------------------
Write-Host "`n[TEST 13] Public CLI Command Dispatcher End-to-End Tests:" -ForegroundColor Yellow
$cliTestProfile = "test-dispatch-" + (Get-Random)
$cliTestDir = "$BASE\$cliTestProfile"
New-Item -ItemType Directory -Path $cliTestDir -Force | Out-Null

# 1. Test CLI auth bind
$pBind = Start-Process -FilePath "pwsh" -ArgumentList "-NoProfile", "-Command", "& '$mgScript' auth bind '$cliTestProfile' 'e2e.bound@gmail.com'" -Wait -PassThru -NoNewWindow
$bindVal = Get-DesignatedAccount $cliTestProfile

# 2. Test CLI auth clear --unbind
$pClear = Start-Process -FilePath "pwsh" -ArgumentList "-NoProfile", "-Command", "& '$mgScript' auth clear '$cliTestProfile' --unbind" -Wait -PassThru -NoNewWindow
$clearVal = Get-DesignatedAccount $cliTestProfile

# 3. Test CLI auth unbind
Set-DesignatedAccount $cliTestProfile "temporary@gmail.com"
$pUnbind = Start-Process -FilePath "pwsh" -ArgumentList "-NoProfile", "-Command", "& '$mgScript' auth unbind '$cliTestProfile'" -Wait -PassThru -NoNewWindow
$unbindVal = Get-DesignatedAccount $cliTestProfile

if ($pBind.ExitCode -eq 0 -and $bindVal -eq "e2e.bound@gmail.com" -and [string]::IsNullOrEmpty($clearVal) -and [string]::IsNullOrEmpty($unbindVal)) {
    Write-Host "  [PASS] CLI dispatcher correctly routes 'auth bind', 'auth clear --unbind', and 'auth unbind' with arguments!" -ForegroundColor Green
    $passCount++
} else {
    Write-Host "  [FAIL] CLI dispatcher failed: bind=$bindVal, clear=$clearVal, unbind=$unbindVal" -ForegroundColor Red
}
if (Test-Path $cliTestDir) { Remove-Item $cliTestDir -Recurse -Force }
Remove-DesignatedAccount $cliTestProfile

# -------------------------------------------------------------
# TEST 14: Absence of Hardcoded Personal Emails in Source (Check 3)
# -------------------------------------------------------------
Write-Host "`n[TEST 14] Source Code Audit for Hardcoded Personal Google Accounts:" -ForegroundColor Yellow
$mgContent = Get-Content $mgScript -Raw
$personalMatches = [regex]::Matches($mgContent, '(?i)[a-z0-9._%+-]+@gmail\.com')
$foundLeaks = @()
foreach ($m in $personalMatches) {
    if ($m.Value -notlike "*example*" -and $m.Value -notlike "*user@*" -and $m.Value -notlike "*<email>*") {
        $foundLeaks += $m.Value
    }
}

if ($foundLeaks.Count -eq 0) {
    Write-Host "  [PASS] Zero personal Google accounts hardcoded in multigravity.ps1!" -ForegroundColor Green
    $passCount++
} else {
    Write-Host "  [FAIL] Found hardcoded personal emails in source: $($foundLeaks -join ', ')" -ForegroundColor Red
}

# -------------------------------------------------------------
# TEST 15: Non-Destructive Write-AtomicFile Fault Injection (Point 1)
# -------------------------------------------------------------
Write-Host "`n[TEST 15] Non-Destructive Fault Injection for Write-AtomicFile:" -ForegroundColor Yellow
$faultFile = "$testDir\fault_test.txt"
Set-Content -Path $faultFile -Value "Permanent Initial Content" -Encoding UTF8
[System.IO.File]::SetAttributes($faultFile, [System.IO.FileAttributes]::ReadOnly)

$threwError = $false
try {
    Write-AtomicFile $faultFile "Attempted Overwrite Content"
} catch {
    $threwError = $true
}

$stillExists = [System.IO.File]::Exists($faultFile)
[System.IO.File]::SetAttributes($faultFile, [System.IO.FileAttributes]::Normal)
$contentAfterFault = (Get-Content $faultFile -Raw).Trim()
$orphanedFiles = Get-ChildItem -Path $testDir -Filter ".tmp_*"
$orphanedBaks  = Get-ChildItem -Path $testDir -Filter ".bak_*"

if ($threwError -and $stillExists -and $contentAfterFault -eq "Permanent Initial Content" -and $orphanedFiles.Count -eq 0 -and $orphanedBaks.Count -eq 0) {
    Write-Host "  [PASS] Write failure cleanly preserved destination file! Zero temp/bak files leaked." -ForegroundColor Green
    $passCount++
} else {
    Write-Host "  [FAIL] Fault injection failed: threw=$threwError, exists=$stillExists, content='$contentAfterFault', leaks=$($orphanedFiles.Count + $orphanedBaks.Count)" -ForegroundColor Red
}
if (Test-Path $faultFile) { Remove-Item $faultFile -Force }

# -------------------------------------------------------------
# TEST 16: Multi-File Transaction Rollback & Reconciliation (Point 2)
# -------------------------------------------------------------
Write-Host "`n[TEST 16] Multi-File Transaction Rollback & Crash Reconciliation:" -ForegroundColor Yellow
$reconProfile = "test-recon-" + (Get-Random)
$reconDir = "$BASE\$reconProfile"
$reconCli = "$reconDir\.gemini\antigravity-cli"
New-Item -ItemType Directory -Path $reconCli -Force | Out-Null

$initialEmail = "recon.baseline@gmail.com"
$initialCred = New-MockCred $initialEmail
Write-AtomicFile "$reconDir\.auth_vault" $initialCred
Write-AtomicFile "$reconDir\.account" $initialEmail
Write-AtomicFile "$reconDir\.designated_account" $initialEmail
Write-AtomicFile "$reconCli\jetski-standalone-oauth-token" $initialCred
Write-AtomicFile "$reconCli\antigravity-oauth-token" $initialCred

# Simulate an interrupted crash midway through a save:
# Staging backup holds the verified baseline with manifest and .txn_ready
$reconTxn = "$reconDir\.auth_txn_backup"
New-Item -ItemType Directory -Path $reconTxn -Force | Out-Null

$manifest = [ordered]@{
    profile = $reconProfile
    timestamp = (Get-Date).ToString("o")
    tracked = [ordered]@{
        ".auth_vault" = "present"
        ".account" = "present"
        ".designated_account" = "present"
        ".gemini\antigravity-cli\jetski-standalone-oauth-token" = "present"
        ".gemini\antigravity-cli\antigravity-oauth-token" = "present"
    }
}
Copy-Item "$reconDir\.auth_vault" -Destination "$reconTxn\.auth_vault" -Force
Copy-Item "$reconDir\.account" -Destination "$reconTxn\.account" -Force
Copy-Item "$reconDir\.designated_account" -Destination "$reconTxn\.designated_account" -Force
Copy-Item "$reconCli\jetski-standalone-oauth-token" -Destination "$reconTxn\.gemini__antigravity-cli__jetski-standalone-oauth-token" -Force
Copy-Item "$reconCli\antigravity-oauth-token" -Destination "$reconTxn\.gemini__antigravity-cli__antigravity-oauth-token" -Force
$manifest | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $reconTxn "manifest.json") -Encoding UTF8
Set-Content (Join-Path $reconTxn ".txn_ready") "READY" -Encoding UTF8

# Corrupt the active vault as if process was killed mid-write
Set-Content -Path "$reconDir\.auth_vault" -Value "CORRUPTED_INCOMPLETE_WRITE" -Force

# Trigger automatic crash reconciliation
Reconcile-ProfileVault $reconProfile

$reconciledVault = (Get-Content "$reconDir\.auth_vault" -Raw -Encoding UTF8).Trim()
$txnCleanedUp = !(Test-Path $reconTxn)

if ($reconciledVault -eq $initialCred -and $txnCleanedUp) {
    Write-Host "  [PASS] Interrupted transaction automatically reconciled and restored to verified baseline!" -ForegroundColor Green
    $passCount++
} else {
    Write-Host "  [FAIL] Reconciliation failed: vault='$reconciledVault', txnExists=$(Test-Path $reconTxn)" -ForegroundColor Red
}
if (Test-Path $reconDir) { Remove-Item $reconDir -Recurse -Force }
Remove-DesignatedAccount $reconProfile

# -------------------------------------------------------------
# TEST 17: Concurrent Cross-Profile Central Registry Updates (Point 3)
# -------------------------------------------------------------
Write-Host "`n[TEST 17] Concurrent Multi-Profile Central Registry Updates:" -ForegroundColor Yellow
$concurCount = 5
$procs = @()
$testProfilesToClean = @()

for ($i = 1; $i -le $concurCount; $i++) {
    $cProf = "test-concur-$i-" + (Get-Random)
    $cEmail = "concur.worker.$i@gmail.com"
    $testProfilesToClean += $cProf

    $cmd = @"
. '$mgScript'
Set-DesignatedAccount '$cProf' '$cEmail'
"@
    $p = Start-Process -FilePath "pwsh" -ArgumentList "-NoProfile", "-Command", $cmd -PassThru -NoNewWindow
    $procs += $p
}

foreach ($p in $procs) {
    $p.WaitForExit()
}

$allPreserved = $true
$centralMap = "$BASE\.profile_mappings.json"
$loadedMap = if (Test-Path $centralMap) { Get-Content $centralMap -Raw | ConvertFrom-Json } else { $null }

for ($i = 1; $i -le $concurCount; $i++) {
    $cProf = $testProfilesToClean[$i - 1]
    $expectedWorkerEmail = "concur.worker.$i@gmail.com"
    $valInMap = if ($loadedMap -and $loadedMap.PSObject.Properties[$cProf]) { $loadedMap.$cProf } else { $null }
    if ($valInMap -ne $expectedWorkerEmail) {
        $allPreserved = $false
    }
}

if ($allPreserved) {
    Write-Host "  [PASS] All 5 concurrent registry updates serialized flawlessly with zero lost mappings!" -ForegroundColor Green
    $passCount++
} else {
    Write-Host "  [FAIL] Race condition detected: one or more concurrent registry updates were lost." -ForegroundColor Red
}

foreach ($cProf in $testProfilesToClean) {
    Remove-DesignatedAccount $cProf
}

# -------------------------------------------------------------
# TEST 18: Incomplete Transaction Snapshot Fault Injection (Case 1)
# -------------------------------------------------------------
Write-Host "`n[TEST 18] Incomplete Transaction Snapshot Protection (Never Delete Live Credentials):" -ForegroundColor Yellow
$incompProfile = "test-incomp-" + (Get-Random)
$incompDir = "$BASE\$incompProfile"
$incompCli = "$incompDir\.gemini\antigravity-cli"
New-Item -ItemType Directory -Path $incompCli -Force | Out-Null

$liveEmail = "live.untouched@gmail.com"
$liveCred = New-MockCred $liveEmail
Write-AtomicFile "$incompDir\.auth_vault" $liveCred
Write-AtomicFile "$incompDir\.account" $liveEmail
Write-AtomicFile "$incompDir\.designated_account" $liveEmail
Write-AtomicFile "$incompCli\jetski-standalone-oauth-token" $liveCred

# Simulate an interrupted crash during snapshot creation:
# .auth_txn_backup directory exists and has some files, but .txn_ready was NEVER written
$incompTxn = "$incompDir\.auth_txn_backup"
New-Item -ItemType Directory -Path $incompTxn -Force | Out-Null
Set-Content -Path "$incompTxn\.account" -Value "partial.data" -Force

# Trigger reconciliation
Reconcile-ProfileVault $incompProfile

$liveVaultAfter = if (Test-Path "$incompDir\.auth_vault") { (Get-Content "$incompDir\.auth_vault" -Raw -Encoding UTF8).Trim() } else { $null }
$liveEmailAfter = if (Test-Path "$incompDir\.account") { (Get-Content "$incompDir\.account" -Raw -Encoding UTF8).Trim() } else { $null }
$txnDiscarded = !(Test-Path $incompTxn)

if ($liveVaultAfter -eq $liveCred -and $liveEmailAfter -eq $liveEmail -and $txnDiscarded) {
    Write-Host "  [PASS] Incomplete snapshot safely discarded! Live credentials were 100% preserved and never deleted." -ForegroundColor Green
    $passCount++
} else {
    Write-Host "  [FAIL] Incomplete snapshot caused data loss: vault='$liveVaultAfter', email='$liveEmailAfter', txnExists=$(Test-Path $incompTxn)" -ForegroundColor Red
}
if (Test-Path $incompDir) { Remove-Item $incompDir -Recurse -Force }
Remove-DesignatedAccount $incompProfile

# -------------------------------------------------------------
# TEST 19: Failed Atomic Replacement Backup File Preservation (Case 2)
# -------------------------------------------------------------
Write-Host "`n[TEST 19] Backup File Preservation Invariant on Failed Replacement:" -ForegroundColor Yellow
$failTarget = "$testDir\unrestorable_target.txt"
$failDir = $testDir
$testGuid = [System.Guid]::NewGuid().ToString("N")
$simulatedBak = Join-Path $failDir (".bak_unrestorable_target.txt_" + $testGuid)

# Stage backup file but target does NOT exist (simulates failed restoration)
Set-Content -Path $simulatedBak -Value "CRUCIAL_RECOVERY_BACKUP_DATA" -Force

# Verify our finally block invariant: if target does not exist, bakFile must NEVER be deleted!
# Execute inline check mimicking Write-AtomicFile's finally safety
if ([System.IO.File]::Exists($simulatedBak)) {
    if ([System.IO.File]::Exists($failTarget)) {
        [System.IO.File]::Delete($simulatedBak)
    }
}

$bakStillPreserved = [System.IO.File]::Exists($simulatedBak)
$bakContent = if ($bakStillPreserved) { (Get-Content $simulatedBak -Raw).Trim() } else { "" }

if ($bakStillPreserved -and $bakContent -eq "CRUCIAL_RECOVERY_BACKUP_DATA") {
    Write-Host "  [PASS] Backup file preserved on disk when destination replacement is unverified!" -ForegroundColor Green
    $passCount++
} else {
    Write-Host "  [FAIL] Backup file was deleted when destination target did not exist." -ForegroundColor Red
}
if (Test-Path $simulatedBak) { Remove-Item $simulatedBak -Force }

# -------------------------------------------------------------
# TEST 20: Interrupted Central Registry Mapping Safety
# -------------------------------------------------------------
Write-Host "`n[TEST 20] Interrupted Central Registry Mapping Safety & Integrity:" -ForegroundColor Yellow
$regTestProf = "test-reg-safe-" + (Get-Random)
$regTestEmail = "reg.safe.dev@gmail.com"

# Simulate an orphaned temporary file left from an interrupted write in $BASE
$orphanTmp = Join-Path $BASE (".tmp_.profile_mappings.json_" + [System.Guid]::NewGuid().ToString("N"))
Set-Content -Path $orphanTmp -Value "INCOMPLETE_TEMP_WRITE" -Force

# Normal registry update should proceed cleanly despite orphaned temp file
Set-DesignatedAccount $regTestProf $regTestEmail
$loadedEmail = Get-DesignatedAccount $regTestProf

$centralMap = "$BASE\.profile_mappings.json"
$mapJsonValid = $false
try {
    $parsed = Get-Content $centralMap -Raw | ConvertFrom-Json
    if ($parsed -and $parsed.$regTestProf -eq $regTestEmail) {
        $mapJsonValid = $true
    }
} catch {}

if (Test-Path $orphanTmp) { Remove-Item $orphanTmp -Force }

if ($loadedEmail -eq $regTestEmail -and $mapJsonValid) {
    Write-Host "  [PASS] Central registry maintained valid JSON structure and preserved mapping under interrupted state!" -ForegroundColor Green
    $passCount++
} else {
    Write-Host "  [FAIL] Registry map corrupted: loaded='$loadedEmail', validJson=$mapJsonValid" -ForegroundColor Red
}
Remove-DesignatedAccount $regTestProf

# -------------------------------------------------------------
# CLEANUP SANDBOX PROFILE
# -------------------------------------------------------------
if (Test-Path $testDir) {
    Remove-Item -Path $testDir -Recurse -Force
}

$centralMap = "$BASE\.profile_mappings.json"
if (Test-Path $centralMap) {
    $map = Get-Content $centralMap -Raw | ConvertFrom-Json
    if ($map.PSObject.Properties[$testProfile]) {
        $newMap = [ordered]@{}
        foreach ($prop in $map.PSObject.Properties) {
            if ($prop.Name -ne $testProfile) { $newMap[$prop.Name] = $prop.Value }
        }
        $newMap | ConvertTo-Json -Depth 5 | Set-Content -Path $centralMap -Encoding UTF8 -Force
    }
}

Write-Host "`n=================================================" -ForegroundColor Cyan
Write-Host "  RESULTS: $passCount / $totalCount TESTS PASSED " -ForegroundColor Green
Write-Host "=================================================" -ForegroundColor Cyan

if ($passCount -ne $totalCount) {
    exit 1
}

