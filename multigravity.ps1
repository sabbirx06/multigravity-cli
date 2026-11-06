<#
.SYNOPSIS
Run multiple Antigravity IDE profiles at the same time.
#>

param (
    [Parameter(Position = 0, Mandatory = $false)]
    [string]$cmd,
    
    [Parameter(Position = 1, Mandatory = $false)]
    [string]$arg1,

    [Parameter(Position = 2, Mandatory = $false)]
    [string]$arg2,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ForwardArgs
)

$BASE = if ($env:MULTIGRAVITY_HOME) { $env:MULTIGRAVITY_HOME } else { "$env:USERPROFILE\AntigravityProfiles" }

function Find-AntigravityIde {
    $paths = @(
        "$env:LOCALAPPDATA\Programs\Antigravity IDE\Antigravity IDE.exe",
        "$env:PROGRAMFILES\Antigravity IDE\Antigravity IDE.exe",
        "${env:ProgramFiles(x86)}\Antigravity IDE\Antigravity IDE.exe"
    )
    foreach ($p in $paths) {
        if (Test-Path $p) { return $p }
    }
    
    $cmd = Get-Command antigravity-ide.cmd -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $cmd = Get-Command antigravity-ide -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    
    return $null
}

function Find-AntigravityApp {
    $paths = @(
        "$env:LOCALAPPDATA\Programs\Antigravity\Antigravity.exe",
        "$env:PROGRAMFILES\Antigravity\Antigravity.exe",
        "${env:ProgramFiles(x86)}\Antigravity\Antigravity.exe"
    )
    foreach ($p in $paths) {
        if (Test-Path $p) { return $p }
    }
    
    # Try to find in PATH
    $exeCommand = Get-Command antigravity.exe -ErrorAction SilentlyContinue
    if ($exeCommand) { return $exeCommand.Source }
    
    return $null
}

function Find-Agy {
    $cmd = Get-Command agy.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $cmd = Get-Command agy -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $paths = @(
        "$env:LOCALAPPDATA\agy\bin\agy.EXE",
        "$env:USERPROFILE\.local\bin\agy.EXE"
    )
    foreach ($p in $paths) {
        if (Test-Path $p) { return $p }
    }

    return $null
}

function Test-AgyBinarySupportsFileAuth {
    param([string]$path)
    if ([string]::IsNullOrEmpty($path) -or !(Test-Path $path)) { return $false }
    if ($path.EndsWith(".cmd", [System.StringComparison]::OrdinalIgnoreCase) -or 
        $path.EndsWith(".bat", [System.StringComparison]::OrdinalIgnoreCase) -or
        $path.EndsWith(".ps1", [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    try {
        $fs = [System.IO.File]::OpenRead($path)
        try {
            $bufSize = 1048576
            $buf = New-Object byte[] $bufSize
            $found1 = $false
            $found2 = $false
            while (($bytesRead = $fs.Read($buf, 0, $bufSize)) -gt 0) {
                $text = [System.Text.Encoding]::ASCII.GetString($buf, 0, $bytesRead)
                if (!$found1 -and $text.Contains("SSH_CONNECTION")) { $found1 = $true }
                if (!$found2 -and ($text.Contains("composite_token_storage") -or $text.Contains("shouldBypassKeyring"))) { $found2 = $true }
                if ($found1 -and $found2) { return $true }
            }
            return ($found1 -and $found2)
        } finally {
            $fs.Dispose()
        }
    } catch {
        return $false
    }
}

$IDE_APP = if ($env:MULTIGRAVITY_IDE) { $env:MULTIGRAVITY_IDE } else { Find-AntigravityIde }
$APP     = if ($env:MULTIGRAVITY_APP) { $env:MULTIGRAVITY_APP } else { Find-AntigravityApp }
$AGY_APP = if ($env:MULTIGRAVITY_AGY) { $env:MULTIGRAVITY_AGY } else { Find-Agy }

function Get-TemplatesDir {
    return "$BASE\.templates"
}

function Get-SystemDataDir {
    return "$env:APPDATA\Antigravity"
}

function Get-SystemIdeDataDir {
    return "$env:APPDATA\Antigravity IDE"
}

function Get-SystemExtensionsDir {
    return "$env:USERPROFILE\.antigravity\extensions"
}

function Get-SystemIdeExtensionsDir {
    return "$env:USERPROFILE\.antigravity-ide\extensions"
}

function Test-SharedProfile {
    param($name)
    return Test-Path "$BASE\$name\.shared"
}

if (-not ([System.Management.Automation.PSTypeName]'Multigravity.CredHelper').Type) {
    $credHelperSrc = @'
using System;
using System.Runtime.InteropServices;

namespace Multigravity {
    public class CredHelper {
        public const uint CRED_TYPE_GENERIC = 1;
        public const uint CRED_PERSIST_LOCAL_MACHINE = 2;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct CREDENTIAL {
            public uint Flags;
            public uint Type;
            public string TargetName;
            public string Comment;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
            public uint CredentialBlobSize;
            public IntPtr CredentialBlob;
            public uint Persist;
            public uint AttributeCount;
            public IntPtr Attributes;
            public string TargetAlias;
            public string UserName;
        }

        [DllImport("Advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool CredRead(string target, uint type, int reservedFlag, out IntPtr credentialPtr);

        [DllImport("Advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool CredWrite([In] ref CREDENTIAL credential, uint flags);

        [DllImport("Advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool CredDelete(string target, uint type, uint flags);

        [DllImport("Advapi32.dll", SetLastError = true)]
        public static extern void CredFree(IntPtr cred);

        public static string Read(string target) {
            IntPtr ptr;
            if (!CredRead(target, CRED_TYPE_GENERIC, 0, out ptr)) return null;
            try {
                var cred = (CREDENTIAL)Marshal.PtrToStructure(ptr, typeof(CREDENTIAL));
                byte[] bytes = new byte[cred.CredentialBlobSize];
                Marshal.Copy(cred.CredentialBlob, bytes, 0, (int)cred.CredentialBlobSize);
                return System.Text.Encoding.UTF8.GetString(bytes);
            } finally {
                CredFree(ptr);
            }
        }

        public static bool Write(string target, string userName, string secret) {
            byte[] bytes = System.Text.Encoding.UTF8.GetBytes(secret);
            IntPtr blobPtr = Marshal.AllocHGlobal(bytes.Length);
            try {
                Marshal.Copy(bytes, 0, blobPtr, bytes.Length);
                CREDENTIAL cred = new CREDENTIAL {
                    Flags = 0,
                    Type = CRED_TYPE_GENERIC,
                    TargetName = target,
                    Comment = "Multigravity Managed Credential",
                    CredentialBlobSize = (uint)bytes.Length,
                    CredentialBlob = blobPtr,
                    Persist = CRED_PERSIST_LOCAL_MACHINE,
                    AttributeCount = 0,
                    Attributes = IntPtr.Zero,
                    TargetAlias = null,
                    UserName = userName
                };
                return CredWrite(ref cred, 0);
            } finally {
                Marshal.FreeHGlobal(blobPtr);
            }
        }

        public static bool Delete(string target) {
            return CredDelete(target, CRED_TYPE_GENERIC, 0);
        }
    }
}
'@
    Add-Type -TypeDefinition $credHelperSrc -ErrorAction SilentlyContinue
}

$GEMINI_CRED_TARGET = "gemini:antigravity"
$GEMINI_CRED_USER   = "antigravity"

function Get-GeminiCredential {
    try {
        return [Multigravity.CredHelper]::Read($GEMINI_CRED_TARGET)
    } catch {
        return $null
    }
}

function Set-GeminiCredential {
    param([string]$secret)
    if ([string]::IsNullOrEmpty($secret)) { return $false }
    try {
        return [Multigravity.CredHelper]::Write($GEMINI_CRED_TARGET, $GEMINI_CRED_USER, $secret)
    } catch {
        return $false
    }
}

function Remove-GeminiCredential {
    try {
        return [Multigravity.CredHelper]::Delete($GEMINI_CRED_TARGET)
    } catch {
        return $false
    }
}

function Get-EmailFromCredential {
    param([string]$credJson)
    if ([string]::IsNullOrEmpty($credJson)) { return $null }
    try {
        $data = $credJson | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($data -and $data.id_token_email) {
            return $data.id_token_email
        }
        if ($data -and $data.email) {
            return $data.email
        }
        if ($data -and $data.id_token) {
            $parts = $data.id_token.Split('.')
            if ($parts.Length -ge 2) {
                $payload = $parts[1].Replace('-', '+').Replace('_', '/')
                while ($payload.Length % 4 -ne 0) { $payload += "=" }
                $bytes = [Convert]::FromBase64String($payload)
                $claims = [System.Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($claims -and $claims.email) {
                    return $claims.email
                }
            }
        }
    } catch {}
    return $null
}

function Get-DesignatedAccount {
    param($profileName)
    $profileDir = "$BASE\$profileName"

    $markerVal = $null
    $marker = "$profileDir\.designated_account"
    if (Test-Path $marker) {
        $val = (Get-Content -Path $marker -Raw -Encoding UTF8).Trim()
        if (![string]::IsNullOrEmpty($val)) { $markerVal = $val }
    }

    $centralVal = $null
    $centralMap = "$BASE\.profile_mappings.json"
    if (Test-Path $centralMap) {
        try {
            $map = Get-Content -Path $centralMap -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($map -and $map.PSObject.Properties[$profileName]) {
                $val = [string]($map.$profileName).Trim()
                if (![string]::IsNullOrEmpty($val)) { $centralVal = $val }
            }
        } catch {}
    }

    # Conflict detection between local marker and central registry
    if (![string]::IsNullOrEmpty($markerVal) -and ![string]::IsNullOrEmpty($centralVal)) {
        if ($markerVal.Trim().ToLowerInvariant() -ne $centralVal.Trim().ToLowerInvariant()) {
            return "__CONFLICT__|$markerVal|$centralVal"
        }
        return $markerVal
    }

    if (![string]::IsNullOrEmpty($markerVal)) {
        return $markerVal
    }

    if (![string]::IsNullOrEmpty($centralVal)) {
        return $centralVal
    }

    return $null
}

function Find-ProfileByDesignatedAccount {
    param($email)
    if ([string]::IsNullOrWhiteSpace($email)) { return $null }
    $clean = $email.Trim().ToLowerInvariant()

    if (Test-Path $BASE) {
        $profiles = Get-ChildItem -Directory -Path $BASE | Where-Object { $_.PSIsContainer -and $_.Name -ne ".templates" }
        foreach ($p in $profiles) {
            $des = Get-DesignatedAccount $p.Name
            if ($des -and $des -notlike "__CONFLICT__:*") {
                if ($des.Trim().ToLowerInvariant() -eq $clean) {
                    return $p.Name
                }
            }
        }
    }
    return $null
}

function Invoke-WithRegistryLock {
    param([scriptblock]$action)
    $mutexName = "Local\multigravity_central_registry_lock"
    $mutex = New-Object System.Threading.Mutex($false, $mutexName)
    $hasLock = $false
    try {
        try {
            $hasLock = $mutex.WaitOne(10000)
        } catch [System.Threading.AbandonedMutexException] {
            $hasLock = $true
        }
        if (!$hasLock) {
            Write-Error "  [auth-guard] Could not acquire central registry lock (timed out after 10s)."
            return $null
        }
        & $action
    } finally {
        if ($hasLock) {
            try { $mutex.ReleaseMutex() } catch {}
        }
        $mutex.Dispose()
    }
}

function Set-DesignatedAccount {
    param($profileName, $email)
    if ([string]::IsNullOrWhiteSpace($profileName) -or [string]::IsNullOrWhiteSpace($email)) { return }
    $profileDir = "$BASE\$profileName"
    if (Test-Path $profileDir) {
        Write-AtomicFile "$profileDir\.designated_account" $email
    }
    Invoke-WithRegistryLock {
        $centralMap = "$BASE\.profile_mappings.json"
        $map = [ordered]@{}
        if (Test-Path $centralMap) {
            try {
                $loaded = Get-Content -Path $centralMap -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($loaded) {
                    foreach ($prop in $loaded.PSObject.Properties) {
                        $map[$prop.Name] = $prop.Value
                    }
                }
            } catch {}
        }
        $map[$profileName] = $email
        $json = $map | ConvertTo-Json -Depth 5
        Write-AtomicFile $centralMap $json
    }
}

function Remove-DesignatedAccount {
    param($profileName)
    if ([string]::IsNullOrWhiteSpace($profileName)) { return }
    $profileDir = "$BASE\$profileName"
    if (Test-Path "$profileDir\.designated_account") {
        Remove-Item "$profileDir\.designated_account" -Force -ErrorAction SilentlyContinue
    }
    Invoke-WithRegistryLock {
        $centralMap = "$BASE\.profile_mappings.json"
        if (Test-Path $centralMap) {
            try {
                $loaded = Get-Content -Path $centralMap -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($loaded -and $loaded.PSObject.Properties[$profileName]) {
                    $newMap = [ordered]@{}
                    foreach ($prop in $loaded.PSObject.Properties) {
                        if ($prop.Name -ne $profileName) {
                            $newMap[$prop.Name] = $prop.Value
                        }
                    }
                    $json = $newMap | ConvertTo-Json -Depth 5
                    Write-AtomicFile $centralMap $json
                }
            } catch {}
        }
    }
}

function Write-AtomicFile {
    param(
        [string]$targetPath,
        [string]$content
    )
    $fullTarget = [System.IO.Path]::GetFullPath($targetPath)
    $dir = [System.IO.Path]::GetDirectoryName($fullTarget)
    if (!(Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $guid = [System.Guid]::NewGuid().ToString("N")
    $fileName = [System.IO.Path]::GetFileName($fullTarget)
    $tempFile = Join-Path $dir (".tmp_" + $fileName + "_" + $guid)
    $bakFile  = Join-Path $dir (".bak_" + $fileName + "_" + $guid)

    try {
        [System.IO.File]::WriteAllText($tempFile, $content, [System.Text.Encoding]::UTF8)
        if ([System.IO.File]::Exists($fullTarget)) {
            # Win32 ReplaceFile replaces target with tempFile atomically
            [System.IO.File]::Replace($tempFile, $fullTarget, $bakFile)
            if ([System.IO.File]::Exists($bakFile) -and [System.IO.File]::Exists($fullTarget)) {
                try { [System.IO.File]::Delete($bakFile) } catch {}
            }
        } else {
            [System.IO.File]::Move($tempFile, $fullTarget)
        }
    } catch {
        $writeErr = $_
        # Non-destructive recovery: If ReplaceFile moved target to bakFile but replacement failed
        if (![System.IO.File]::Exists($fullTarget) -and [System.IO.File]::Exists($bakFile)) {
            try {
                [System.IO.File]::Move($bakFile, $fullTarget)
            } catch {
                $restoreErr = $_
                Write-Error "  [auth-guard] CRITICAL: Target '$fullTarget' failed replacement AND restoration failed: $restoreErr. Recovery backup PRESERVED at '$bakFile'."
                throw $restoreErr
            }
        }
        throw $writeErr
    } finally {
        if ([System.IO.File]::Exists($tempFile)) {
            try { [System.IO.File]::Delete($tempFile) } catch {}
        }
        # PRESERVE BACKUP INVARIANT: Never delete bakFile if targetPath does not exist!
        if ([System.IO.File]::Exists($bakFile)) {
            if ([System.IO.File]::Exists($fullTarget)) {
                try { [System.IO.File]::Delete($bakFile) } catch {}
            } else {
                Write-Warning "  [auth-guard] Target '$fullTarget' is missing! Preserving recovery backup at '$bakFile'."
            }
        }
    }
}

function Rollback-ProfileVault {
    param($profileName)
    $profileDir = "$BASE\$profileName"
    $txnDir = "$profileDir\.auth_txn_backup"
    if (!(Test-Path $txnDir)) { return }

    $readyMarker = Join-Path $txnDir ".txn_ready"
    $manifestFile = Join-Path $txnDir "manifest.json"

    # Incomplete snapshot protection: If the snapshot was not fully completed before interruption,
    # live credentials were NEVER modified because live updates only begin AFTER .txn_ready is written.
    if (!(Test-Path $readyMarker) -or !(Test-Path $manifestFile)) {
        Write-Warning "  [auth-guard] Incomplete transaction snapshot detected for profile '$profileName'. Live credentials were untouched. Discarding incomplete snapshot."
        Remove-Item $txnDir -Recurse -Force -ErrorAction SilentlyContinue
        return
    }

    try {
        $manifest = Get-Content $manifestFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        if ($manifest -and $manifest.tracked) {
            foreach ($prop in $manifest.tracked.PSObject.Properties) {
                $rel = $prop.Name
                $state = $prop.Value
                $backupFile = Join-Path $txnDir ($rel -replace '[\\/]', '__')
                $liveFile = Join-Path $profileDir $rel
                $liveDir = Split-Path -Parent $liveFile

                if ($state -eq "present") {
                    if (Test-Path $backupFile) {
                        if (!(Test-Path $liveDir)) { New-Item -ItemType Directory -Path $liveDir -Force | Out-Null }
                        Copy-Item $backupFile -Destination $liveFile -Force
                    } else {
                        Write-Error "  [auth-guard] Missing backup file for '$rel'! Preserving existing live file to prevent data loss."
                    }
                } elseif ($state -eq "absent") {
                    # Only remove live file if the verified manifest explicitly proves it was absent when transaction began
                    if (Test-Path $liveFile) {
                        Remove-Item $liveFile -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        }
    } catch {
        Write-Error "  [auth-guard] Failed parsing transaction manifest for '$profileName': $_. Preserving live credentials."
    }
}

function Reconcile-ProfileVault {
    param($profileName)
    $profileDir = "$BASE\$profileName"
    $txnDir = "$profileDir\.auth_txn_backup"
    if (!(Test-Path $txnDir)) { return }

    Write-Warning "  [auth-guard] Detected interrupted save for profile '$profileName'. Reconciling vault to verified baseline..."
    Rollback-ProfileVault $profileName
    if (Test-Path $txnDir) {
        Remove-Item $txnDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-WithProfileVaultLock {
    param(
        [string]$profileName,
        [scriptblock]$action
    )
    $cleanName = ($profileName -replace '[^a-zA-Z0-9_]', '_')
    $mutexName = "Local\multigravity_vault_$cleanName"
    $mutex = New-Object System.Threading.Mutex($false, $mutexName)
    $hasLock = $false
    try {
        try {
            $hasLock = $mutex.WaitOne(5000)
        } catch [System.Threading.AbandonedMutexException] {
            $hasLock = $true
        }
        if (!$hasLock) {
            Write-Error "  [auth-guard] Could not acquire vault lock for profile '$profileName' (timed out after 5s)."
            return $false
        }
        & $action
        return $true
    } finally {
        if ($hasLock) {
            try { $mutex.ReleaseMutex() } catch {}
        }
        $mutex.Dispose()
    }
}

function Save-ProfileVault {
    param($profileName, [switch]$Force)
    $profileDir = "$BASE\$profileName"
    if (!(Test-Path $profileDir)) { return }

    Invoke-WithProfileVaultLock $profileName {
        Reconcile-ProfileVault $profileName

        $current = Get-GeminiCredential
        if ([string]::IsNullOrEmpty($current)) {
            Write-Warning "  [auth-guard] Windows Credential Manager has no active Antigravity session. Preserving existing vault for '$profileName'."
            return
        }

        $email = Get-EmailFromCredential $current
        if ([string]::IsNullOrEmpty($email)) {
            Write-Warning "  [auth-guard] Active credential in Windows Credential Manager is malformed or unidentifiable. Preserving existing vault for '$profileName'."
            return
        }

        $expected = Get-DesignatedAccount $profileName
        if ($expected -like "__CONFLICT__*") {
            $parts = $expected.Split("|")
            $mVal = $parts[1]
            $cVal = $parts[2]
            if (!$Force) {
                Write-Error "  [auth-guard] IDENTITY CONFLICT DETECTED for profile '$profileName'! Local marker specifies '$mVal' but central registry specifies '$cVal'. Credential write-back is BLOCKED to prevent corruption. Resolve the conflict explicitly using 'multigravity auth bind $profileName <email>' or 'multigravity auth save $profileName --force'."
                return
            }
            $expected = $email
        } elseif ($Force) {
            $expected = $email
        } elseif (![string]::IsNullOrEmpty($expected)) {
            if ($email.Trim().ToLowerInvariant() -ne $expected.Trim().ToLowerInvariant()) {
                Write-Error "  [auth-guard] IDENTITY MISMATCH DETECTED! Active credential belongs to '$email', but profile '$profileName' is designated for '$expected'. Overwrite rejected to prevent cross-profile contamination. Use 'multigravity auth bind $profileName <email>' or 'multigravity auth save $profileName --force' to intentionally switch accounts."
                return
            }
        } else {
            # Profile has no designated account yet (e.g. newly created or imported profile)
            # Guard against accidental binding to another profile's global credential
            $ownerProfile = Find-ProfileByDesignatedAccount $email
            if ($ownerProfile -and $ownerProfile -ne $profileName) {
                Write-Error "  [auth-guard] CROSS-PROFILE BINDING BLOCKED! Active credential belongs to '$email', which is already designated to profile '$ownerProfile'. Profile '$profileName' will not be bound to this account automatically. To intentionally link this profile, use 'multigravity auth bind $profileName $email' or 'multigravity auth save $profileName --force'."
                return
            }
            $expected = $email
        }

        # Stage transaction backup with integrity manifest and ready marker
        $txnDir = "$profileDir\.auth_txn_backup"
        if (Test-Path $txnDir) { Remove-Item $txnDir -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Path $txnDir -Force | Out-Null

        $trackedFiles = @(
            ".auth_vault",
            ".account",
            ".designated_account",
            ".gemini\antigravity-cli\jetski-standalone-oauth-token",
            ".gemini\antigravity-cli\antigravity-oauth-token"
        )

        $manifest = [ordered]@{
            profile   = $profileName
            timestamp = (Get-Date).ToString("o")
            tracked   = [ordered]@{}
        }

        foreach ($rel in $trackedFiles) {
            $src = Join-Path $profileDir $rel
            $dst = Join-Path $txnDir ($rel -replace '[\\/]', '__')
            if (Test-Path $src) {
                Copy-Item $src -Destination $dst -Force
                $manifest.tracked[$rel] = "present"
            } else {
                $manifest.tracked[$rel] = "absent"
            }
        }
        $manifestJson = $manifest | ConvertTo-Json -Depth 5
        Write-AtomicFile (Join-Path $txnDir "manifest.json") $manifestJson
        Write-AtomicFile (Join-Path $txnDir ".txn_ready") "READY"

        try {
            Write-AtomicFile "$profileDir\.auth_vault" $current
            Write-AtomicFile "$profileDir\.account" $email
            Write-AtomicFile "$profileDir\.designated_account" $expected

            $cliDir = "$profileDir\.gemini\antigravity-cli"
            if (Test-Path $cliDir) {
                Write-AtomicFile "$cliDir\jetski-standalone-oauth-token" $current
                Write-AtomicFile "$cliDir\antigravity-oauth-token" $current
            }
            Set-DesignatedAccount $profileName $expected

            # Transaction completed cleanly: discard staging backup
            if (Test-Path $txnDir) {
                Remove-Item $txnDir -Recurse -Force -ErrorAction SilentlyContinue
            }
            Write-Host "  [auth] Verified and saved session for profile '$profileName' ($email)" -ForegroundColor Green
        } catch {
            Rollback-ProfileVault $profileName
            if (Test-Path $txnDir) { Remove-Item $txnDir -Recurse -Force -ErrorAction SilentlyContinue }
            Write-Error "  [auth-guard] Critical error: failed writing vault files for '$profileName'. Rolled back to previous verified state. Details: $_"
            throw $_
        }
    } | Out-Null
}

function Sync-ProfileVaultFromLocalToken {
    param($profileName)
    $profileDir = "$BASE\$profileName"
    if (!(Test-Path $profileDir)) { return }

    $cliDir = "$profileDir\.gemini\antigravity-cli"
    $tokenFile = Join-Path $cliDir "antigravity-oauth-token"
    if (!(Test-Path $tokenFile)) {
        $tokenFile = Join-Path $cliDir "jetski-standalone-oauth-token"
    }
    if (!(Test-Path $tokenFile)) {
        Write-Warning "  [auth-guard] No profile-local token file found for '$profileName'. Preserving existing vault."
        return
    }

    try {
        $raw = (Get-Content -Path $tokenFile -Raw -Encoding UTF8).Trim()
        if ([string]::IsNullOrWhiteSpace($raw)) {
            Write-Warning "  [auth-guard] Profile-local token file for '$profileName' is empty. Preserving existing vault."
            return
        }

        $data = $raw | ConvertFrom-Json -ErrorAction Stop
        if (!$data -or !$data.token) {
            Write-Warning "  [auth-guard] Profile-local token for '$profileName' is missing token payload. Preserving existing vault."
            return
        }

        $email = Get-EmailFromCredential $raw
        if ([string]::IsNullOrWhiteSpace($email)) {
            Write-Warning "  [auth-guard] Could not identify account email in local token for '$profileName'. Preserving existing vault."
            return
        }

        $expected = Get-DesignatedAccount $profileName
        if ($expected -like "__CONFLICT__*") {
            Write-Error "  [auth-guard] IDENTITY CONFLICT DETECTED for profile '$profileName'! Local marker and central registry disagree. Vault sync blocked."
            return
        }
        if (![string]::IsNullOrEmpty($expected)) {
            if ($email.Trim().ToLowerInvariant() -ne $expected.Trim().ToLowerInvariant()) {
                Write-Error "  [auth-guard] IDENTITY MISMATCH in local token for '$profileName'! Token belongs to '$email' but profile designated for '$expected'. Preserving vault."
                return
            }
        }

        Invoke-WithProfileVaultLock $profileName {
            Reconcile-ProfileVault $profileName

            $txnDir = "$profileDir\.auth_txn_backup"
            if (Test-Path $txnDir) { Remove-Item $txnDir -Recurse -Force -ErrorAction SilentlyContinue }
            New-Item -ItemType Directory -Path $txnDir -Force | Out-Null

            $trackedFiles = @(
                ".auth_vault",
                ".account"
            )

            $manifest = [ordered]@{
                profile   = $profileName
                timestamp = (Get-Date).ToString("o")
                source    = "local-token-sync"
                tracked   = [ordered]@{}
            }

            foreach ($rel in $trackedFiles) {
                $src = Join-Path $profileDir $rel
                $dst = Join-Path $txnDir ($rel -replace '[\\/]', '__')
                if (Test-Path $src) {
                    Copy-Item $src -Destination $dst -Force
                    $manifest.tracked[$rel] = "present"
                } else {
                    $manifest.tracked[$rel] = "absent"
                }
            }

            Write-AtomicFile (Join-Path $txnDir "manifest.json") ($manifest | ConvertTo-Json -Depth 5)
            Write-AtomicFile (Join-Path $txnDir ".txn_ready") "READY"

            try {
                Write-AtomicFile "$profileDir\.auth_vault" $raw
                Write-AtomicFile "$profileDir\.account" $email
                if (Test-Path $txnDir) {
                    Remove-Item $txnDir -Recurse -Force -ErrorAction SilentlyContinue
                }
                Write-Host "  [auth] Synchronized refreshed token to profile vault for '$profileName' ($email)" -ForegroundColor Green
            } catch {
                Rollback-ProfileVault $profileName
                if (Test-Path $txnDir) { Remove-Item $txnDir -Recurse -Force -ErrorAction SilentlyContinue }
                Write-Error "  [auth-guard] Failed synchronizing local token to vault for '$profileName': $_"
            }
        } | Out-Null
    } catch {
        Write-Error "  [auth-guard] Failed reading local token file for '$profileName': $_"
    }
}

function Prepare-ProfileVault {
    param($profileName)
    $profileDir = "$BASE\$profileName"
    Reconcile-ProfileVault $profileName
    $vaultFile = "$profileDir\.auth_vault"
    $sysVaultFile = "$BASE\.system_auth_vault"

    $currentSys = Get-GeminiCredential
    if (![string]::IsNullOrEmpty($currentSys)) {
        if (!(Test-Path $sysVaultFile)) {
            Set-Content -Path $sysVaultFile -Value $currentSys -NoNewline -Encoding UTF8 -Force
        }
    }

    if (Test-Path $vaultFile) {
        $saved = (Get-Content -Path $vaultFile -Raw -Encoding UTF8).Trim()
        if (![string]::IsNullOrEmpty($saved)) {
            Set-GeminiCredential $saved | Out-Null
            $email = Get-EmailFromCredential $saved
            if (![string]::IsNullOrEmpty($email)) {
                Set-Content -Path "$profileDir\.account" -Value $email -NoNewline -Encoding UTF8 -Force
                Write-Host "  [auth] Restored session for profile '$profileName' ($email)" -ForegroundColor Cyan
            } else {
                Write-Host "  [auth] Restored session for profile '$profileName'" -ForegroundColor Cyan
            }
            return
        }
    }

    Remove-GeminiCredential | Out-Null
    Write-Host "  [auth] Profile '$profileName' has no saved session. Ready for clean login." -ForegroundColor Yellow
}

function Invoke-AuthCmd {
    param(
        [string]$sub,
        $argA,
        $argB
    )
    $tokens = @()
    if ($argA -is [System.Array]) {
        $tokens += $argA
    } elseif ($argA) {
        $tokens += $argA
    }
    if ($argB -is [System.Array]) {
        $tokens += $argB
    } elseif ($argB) {
        $tokens += $argB
    }

    switch ($sub) {
        "save" {
            $name = ($tokens | Where-Object { $_ -notlike "-*" } | Select-Object -First 1)
            if ([string]::IsNullOrWhiteSpace($name)) {
                Write-Error "Error: profile name required. Usage: multigravity auth save <profile> [--force]"
                exit 1
            }
            Validate-Name $name
            $profileDir = "$BASE\$name"
            if (!(Test-Path $profileDir)) {
                Write-Error "Error: profile '$name' does not exist"
                exit 1
            }
            $force = ($tokens -contains "--force" -or $tokens -contains "-f")
            Save-ProfileVault $name -Force:$force
        }
        "bind" {
            $nonFlags = @($tokens | Where-Object { $_ -notlike "-*" })
            $name  = if ($nonFlags.Count -gt 0) { $nonFlags[0] } else { $null }
            $email = if ($nonFlags.Count -gt 1) { $nonFlags[1] } else { $null }
            if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($email)) {
                Write-Error "Error: profile name and email required. Usage: multigravity auth bind <profile> <email>"
                exit 1
            }
            Validate-Name $name
            $profileDir = "$BASE\$name"
            if (!(Test-Path $profileDir)) {
                Write-Error "Error: profile '$name' does not exist"
                exit 1
            }
            Set-DesignatedAccount $name $email
            Write-Host "Bound profile '$name' to designated account '$email'" -ForegroundColor Green
        }
        "load" {
            $name = ($tokens | Where-Object { $_ -notlike "-*" } | Select-Object -First 1)
            if ([string]::IsNullOrWhiteSpace($name)) {
                Write-Error "Error: profile name required. Usage: multigravity auth load <profile>"
                exit 1
            }
            Validate-Name $name
            $profileDir = "$BASE\$name"
            $vaultFile = "$profileDir\.auth_vault"
            if (!(Test-Path $vaultFile)) {
                Write-Error "Error: profile '$name' has no saved session in .auth_vault"
                exit 1
            }
            $saved = (Get-Content -Path $vaultFile -Raw -Encoding UTF8).Trim()
            if ([string]::IsNullOrEmpty($saved)) {
                Write-Error "Error: saved session for profile '$name' is empty"
                exit 1
            }
            Set-GeminiCredential $saved | Out-Null
            $email = Get-EmailFromCredential $saved
            if (![string]::IsNullOrEmpty($email)) {
                Write-Host "Activated authentication session for profile '$name' ($email)" -ForegroundColor Green
            } else {
                Write-Host "Activated authentication session for profile '$name'" -ForegroundColor Green
            }
        }
        "status" {
            Write-Host "Multigravity Profile Authentication Status:"
            Write-Host ""
            $activeCred = Get-GeminiCredential
            $activeEmail = if ($activeCred) { Get-EmailFromCredential $activeCred } else { $null }
            if ($activeEmail) {
                Write-Host "Currently Active System Session: $activeEmail" -ForegroundColor Cyan
            } elseif ($activeCred) {
                Write-Host "Currently Active System Session: (token present, unparsed)" -ForegroundColor Cyan
            } else {
                Write-Host "Currently Active System Session: (none / logged out)" -ForegroundColor DarkGray
            }
            Write-Host ""
            Write-Host ("{0,-15} {1,-34} {2,-34} {3}" -f "PROFILE", "DESIGNATED ACCOUNT", "VAULT ACCOUNT", "STATUS")
            Write-Host ("{0,-15} {1,-34} {2,-34} {3}" -f "-------", "------------------", "-------------", "------")
            if (Test-Path $BASE) {
                $profiles = Get-ChildItem -Directory -Path $BASE | Where-Object { $_.PSIsContainer -and $_.Name -ne ".templates" }
                foreach ($p in $profiles) {
                    $vaultFile = Join-Path $p.FullName ".auth_vault"
                    $accountFile = Join-Path $p.FullName ".account"
                    $designated = Get-DesignatedAccount $p.Name

                    # Check for conflict between local marker and central registry
                    $localMarker = Join-Path $p.FullName ".designated_account"
                    $locVal = if (Test-Path $localMarker) { (Get-Content $localMarker -Raw).Trim() } else { $null }
                    $cenVal = $null
                    if (Test-Path "$BASE\.profile_mappings.json") {
                        try {
                            $m = Get-Content "$BASE\.profile_mappings.json" -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
                            if ($m -and $m.PSObject.Properties[$p.Name]) { $cenVal = [string]($m.$($p.Name)).Trim() }
                        } catch {}
                    }
                    $isConflict = (![string]::IsNullOrEmpty($locVal) -and ![string]::IsNullOrEmpty($cenVal) -and $locVal.ToLowerInvariant() -ne $cenVal.ToLowerInvariant())

                    if ($designated -like "__CONFLICT__*") {
                        $parts = $designated.Split("|")
                        $designated = "$($parts[1]) (conflict)"
                        $isConflict = $true
                    } elseif ([string]::IsNullOrEmpty($designated)) {
                        $designated = "-"
                    }

                    $email = "-"
                    if (Test-Path $accountFile) {
                        $email = (Get-Content $accountFile -Raw).Trim()
                    } elseif (Test-Path $vaultFile) {
                        $vData = Get-Content $vaultFile -Raw -Encoding UTF8
                        $parsed = Get-EmailFromCredential $vData
                        if ($parsed) { $email = $parsed }
                    }
                    $status = if (Test-Path $vaultFile) { "saved" } else { "empty" }

                    $mismatch = ($designated -ne "-" -and $email -ne "-" -and $designated.Trim().ToLowerInvariant() -ne $email.Trim().ToLowerInvariant())
                    if ($isConflict) {
                        $status = "CONFLICT!"
                    } elseif ($mismatch) {
                        $status = "MISMATCH!"
                    } elseif ($email -ne "-" -and $email -eq $activeEmail) {
                        $status = "active"
                    }

                    if ($isConflict -or $mismatch) {
                        Write-Host ("{0,-15} {1,-34} {2,-34} " -f $p.Name, $designated, $email) -NoNewline
                        Write-Host $status -ForegroundColor Red
                    } elseif ($status -eq "active") {
                        Write-Host ("{0,-15} {1,-34} {2,-34} " -f $p.Name, $designated, $email) -NoNewline
                        Write-Host $status -ForegroundColor Green
                    } else {
                        Write-Host ("{0,-15} {1,-34} {2,-34} {3}" -f $p.Name, $designated, $email, $status)
                    }
                }
            }
        }
        "unbind" {
            $name = ($tokens | Where-Object { $_ -notlike "-*" } | Select-Object -First 1)
            if ([string]::IsNullOrWhiteSpace($name)) {
                Write-Error "Error: profile name required. Usage: multigravity auth unbind <profile>"
                exit 1
            }
            Validate-Name $name
            $profileDir = "$BASE\$name"
            if (!(Test-Path $profileDir)) {
                Write-Error "Error: profile '$name' does not exist"
                exit 1
            }
            Remove-DesignatedAccount $name
            Write-Host "Removed designated account binding for profile '$name'" -ForegroundColor Yellow
        }
        "clear" {
            $name = ($tokens | Where-Object { $_ -notlike "-*" } | Select-Object -First 1)
            if ([string]::IsNullOrWhiteSpace($name)) {
                Write-Error "Error: profile name required. Usage: multigravity auth clear <profile> [--unbind]"
                exit 1
            }
            Validate-Name $name
            $profileDir = "$BASE\$name"
            if (Test-Path "$profileDir\.auth_vault") { Remove-Item "$profileDir\.auth_vault" -Force }
            if (Test-Path "$profileDir\.account") { Remove-Item "$profileDir\.account" -Force }
            $cliDir = "$profileDir\.gemini\antigravity-cli"
            if (Test-Path "$cliDir\jetski-standalone-oauth-token") { Remove-Item "$cliDir\jetski-standalone-oauth-token" -Force -ErrorAction SilentlyContinue }
            if (Test-Path "$cliDir\antigravity-oauth-token") { Remove-Item "$cliDir\antigravity-oauth-token" -Force -ErrorAction SilentlyContinue }
            if ($tokens -contains "--unbind" -or $tokens -contains "-u") {
                Remove-DesignatedAccount $name
                Write-Host "Cleared saved session and unlinked designated account for profile '$name'"
            } else {
                Write-Host "Cleared saved session for profile '$name' (designated account binding preserved)"
            }
        }
        default {
            Write-Host "Usage: multigravity auth <save|load|bind|unbind|status|clear> [profile] [args]"
        }
    }
}

function Write-Usage {
    Write-Host "Usage: multigravity <command> [args]"
    Write-Host ""
    Write-Host "Commands:"
    Write-Host "  new <name> [options]        Create a new profile + Start Menu shortcut"
    Write-Host "      --shared                Share extensions & settings; isolate only accounts"
    Write-Host "      --from <template>        Seed from a saved template"
    Write-Host "  list                        List existing profiles"
    Write-Host "  status                      Show running state, type, and last-used per profile"
    Write-Host "  rename <old> <new>          Rename a profile (updates shortcut if present)"
    Write-Host "  delete <name>               Delete a profile and its data"
    Write-Host "  clone <src> <dest>          Copy an existing profile"
    Write-Host "  template save <profile> <name>   Save a profile as a reusable template"
    Write-Host "  template list               List saved templates"
    Write-Host "  template delete <name>      Remove a template"
    Write-Host "  auth save <name> [--force]  Save current active session to profile vault (guarded)"
    Write-Host "  auth bind <name> <email>    Bind profile to an authoritative designated account"
    Write-Host "  auth unbind <name>          Remove designated account binding for a profile"
    Write-Host "  auth load <name>            Load profile vault into active system session"
    Write-Host "  auth status                 Show designated accounts and saved sessions for all profiles"
    Write-Host "  auth clear <name> [--unbind] Clear saved session for a profile"
    Write-Host "  export <name> [path]        Archive a profile to a .zip file"
    Write-Host "  import <archive> [name]     Restore a profile from a .zip archive"
    Write-Host "  update                      Update multigravity to the latest version"
    Write-Host "  doctor                      Run a system diagnosis"
    Write-Host "  stats                       Show storage usage per profile"
    Write-Host "  completion                  Show setup instructions for shell completion"
    Write-Host "  <name> [args]               Launch Antigravity IDE (VS Code-like) with profile (Default)"
    Write-Host "  <name> --app [args]         Launch Antigravity 2.0 app with profile"
    Write-Host "  agy <name> [--isolated] [args] Launch agy CLI in terminal with profile"
    Write-Host "  <name> --cli [--isolated] [args] Launch agy CLI in terminal with profile (opt-in --isolated for concurrent file-based auth)"
    Write-Host "                              Note: --isolated scopes SSH_CONNECTION to the session; child processes inherit it."
    Write-Host "  help                        Show this help"
    Write-Host ""
    Write-Host "Profile names: alphanumeric and hyphens only (e.g. work, personal, test-1)"
    Write-Host ""
    Write-Host "Environment:"
    Write-Host "  MULTIGRAVITY_IDE     Override the Antigravity IDE executable path"
    Write-Host "  MULTIGRAVITY_APP     Override the Antigravity 2.0 app executable path"
    Write-Host "  MULTIGRAVITY_AGY     Override the agy CLI executable path"
    Write-Host "  MULTIGRAVITY_HOME    Override the profile storage directory"
}

function Validate-Name {
    param($name)
    if ([string]::IsNullOrWhiteSpace($name)) {
        Write-Error "Error: profile name required"
        exit 1
    }
    if ($name -notmatch "^[a-zA-Z0-9][a-zA-Z0-9-]*$") {
        Write-Error "Error: profile name must start with alphanumeric and contain only letters, numbers, or hyphens"
        exit 1
    }
}

function Invoke-CreateProfile {
    param($PROFILE)
    $PROFILE_DIR = "$BASE\$PROFILE"
    
    New-Item -ItemType Directory -Force -Path "$PROFILE_DIR\.antigravity\extensions" | Out-Null
    New-Item -ItemType Directory -Force -Path "$PROFILE_DIR\.antigravity-ide\extensions" | Out-Null
    New-Item -ItemType Directory -Force -Path "$PROFILE_DIR\.gemini\antigravity-cli" | Out-Null
    New-Item -ItemType Directory -Force -Path "$PROFILE_DIR\AppData\Roaming\Antigravity\User" | Out-Null
    New-Item -ItemType Directory -Force -Path "$PROFILE_DIR\AppData\Roaming\Antigravity IDE\User" | Out-Null
    New-Item -ItemType Directory -Force -Path "$PROFILE_DIR\AppData\Local" | Out-Null
}

function Invoke-CreateSharedProfile {
    param($name)
    $profileDir = "$BASE\$name"
    $sysData     = Get-SystemDataDir
    $sysDataIde  = Get-SystemIdeDataDir
    $sysExt      = Get-SystemExtensionsDir
    $sysExtIde   = Get-SystemIdeExtensionsDir

    New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
    New-Item -ItemType File      -Force -Path "$profileDir\.shared" | Out-Null
    New-Item -ItemType Directory -Force -Path "$profileDir\.gemini\antigravity-cli" | Out-Null

    # Isolated AppData so accounts don't bleed across profiles
    $userDataDir    = "$profileDir\AppData\Roaming\Antigravity\User"
    $userIdeDataDir = "$profileDir\AppData\Roaming\Antigravity IDE\User"
    New-Item -ItemType Directory -Force -Path $userDataDir | Out-Null
    New-Item -ItemType Directory -Force -Path $userIdeDataDir | Out-Null
    New-Item -ItemType Directory -Force -Path "$profileDir\AppData\Local" | Out-Null

    # Symlink settings files for Antigravity App
    if (Test-Path "$sysData\User") {
        foreach ($f in @("settings.json", "keybindings.json", "snippets")) {
            $src  = "$sysData\User\$f"
            $dest = "$userDataDir\$f"
            if ((Test-Path $src) -and !(Test-Path $dest)) {
                New-Item -ItemType SymbolicLink -Path $dest -Target $src -ErrorAction SilentlyContinue | Out-Null
            }
        }
    }

    # Symlink settings files for Antigravity IDE
    if (Test-Path "$sysDataIde\User") {
        foreach ($f in @("settings.json", "keybindings.json", "snippets")) {
            $src  = "$sysDataIde\User\$f"
            $dest = "$userIdeDataDir\$f"
            if ((Test-Path $src) -and !(Test-Path $dest)) {
                New-Item -ItemType SymbolicLink -Path $dest -Target $src -ErrorAction SilentlyContinue | Out-Null
            }
        }
    }

    # Point extensions at system folders
    $extDir = "$profileDir\.antigravity\extensions"
    if (Test-Path $sysExt) {
        if (Test-Path $extDir) { Remove-Item $extDir -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Force -Path "$profileDir\.antigravity" | Out-Null
        New-Item -ItemType SymbolicLink -Path $extDir -Target $sysExt -ErrorAction SilentlyContinue | Out-Null
    } else {
        New-Item -ItemType Directory -Force -Path $extDir | Out-Null
    }

    $extDirIde = "$profileDir\.antigravity-ide\extensions"
    if (Test-Path $sysExtIde) {
        if (Test-Path $extDirIde) { Remove-Item $extDirIde -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Force -Path "$profileDir\.antigravity-ide" | Out-Null
        New-Item -ItemType SymbolicLink -Path $extDirIde -Target $sysExtIde -ErrorAction SilentlyContinue | Out-Null
    } else {
        New-Item -ItemType Directory -Force -Path $extDirIde | Out-Null
    }
}

function Invoke-LaunchIde {
    param($PROFILE, $ArgsToForward)
    $PROFILE_DIR = "$BASE\$PROFILE"

    if (!(Test-Path $PROFILE_DIR)) {
        Write-Error "Error: profile '$PROFILE' does not exist. Run: multigravity new $PROFILE"
        exit 1
    }

    $ideExec = if ($env:MULTIGRAVITY_IDE) { $env:MULTIGRAVITY_IDE } else { Find-AntigravityIde }
    if ([string]::IsNullOrEmpty($ideExec) -or !(Test-Path $ideExec)) {
        $ideExec = if ($env:MULTIGRAVITY_APP) { $env:MULTIGRAVITY_APP } else { Find-AntigravityApp }
    }

    if ([string]::IsNullOrEmpty($ideExec) -or !(Test-Path $ideExec)) {
        Write-Error "Error: Antigravity IDE (Antigravity IDE.exe) not found. Ensure Antigravity IDE is installed or set MULTIGRAVITY_IDE."
        exit 1
    }

    Write-Host "Launching Antigravity IDE profile '$PROFILE'"
    
    $env:USERPROFILE = $PROFILE_DIR
    $env:APPDATA = "$PROFILE_DIR\AppData\Roaming"
    $env:LOCALAPPDATA = "$PROFILE_DIR\AppData\Local"
    
    $ideDataDir = "$PROFILE_DIR\AppData\Roaming\Antigravity IDE"
    $ideExtDir  = "$PROFILE_DIR\.antigravity-ide\extensions"
    $launchArgs = @("--user-data-dir", "`"$ideDataDir`"", "--extensions-dir", "`"$ideExtDir`"")
    if ($ArgsToForward -and $ArgsToForward.Count -gt 0) {
        $launchArgs += $ArgsToForward
    }

    Prepare-ProfileVault $PROFILE
    Start-Process -FilePath $ideExec -ArgumentList $launchArgs
}

function Invoke-LaunchApp {
    param($PROFILE, $ArgsToForward)
    $PROFILE_DIR = "$BASE\$PROFILE"

    if (!(Test-Path $PROFILE_DIR)) {
        Write-Error "Error: profile '$PROFILE' does not exist. Run: multigravity new $PROFILE"
        exit 1
    }

    $appExec = if ($env:MULTIGRAVITY_APP) { $env:MULTIGRAVITY_APP } else { Find-AntigravityApp }
    if ([string]::IsNullOrEmpty($appExec) -or !(Test-Path $appExec)) {
        Write-Error "Error: Antigravity 2.0 app (Antigravity.exe) not found. Ensure Antigravity is installed or set MULTIGRAVITY_APP."
        exit 1
    }

    Write-Host "Launching Antigravity 2.0 app profile '$PROFILE'"
    
    $env:USERPROFILE = $PROFILE_DIR
    $env:APPDATA = "$PROFILE_DIR\AppData\Roaming"
    $env:LOCALAPPDATA = "$PROFILE_DIR\AppData\Local"
    
    $appDataDir = "$PROFILE_DIR\AppData\Roaming\Antigravity"
    $appExtDir  = "$PROFILE_DIR\.antigravity\extensions"
    $launchArgs = @("--user-data-dir", "`"$appDataDir`"", "--extensions-dir", "`"$appExtDir`"")
    if ($ArgsToForward -and $ArgsToForward.Count -gt 0) {
        $launchArgs += $ArgsToForward
    }

    Prepare-ProfileVault $PROFILE
    Start-Process -FilePath $appExec -ArgumentList $launchArgs
}

function Invoke-LaunchAgy {
    param($PROFILE, $ArgsToForward)
    $PROFILE_DIR = "$BASE\$PROFILE"

    if (!(Test-Path $PROFILE_DIR)) {
        Write-Error "Error: profile '$PROFILE' does not exist. Run: multigravity new $PROFILE"
        exit 1
    }

    $agyExec = if ($env:MULTIGRAVITY_AGY) { $env:MULTIGRAVITY_AGY } else { Find-Agy }
    if ([string]::IsNullOrEmpty($agyExec) -or !(Test-Path $agyExec)) {
        Write-Error "Error: agy CLI not found. Ensure agy is installed and in PATH or set MULTIGRAVITY_AGY."
        exit 1
    }

    # Detect opt-in isolated mode (CLI flag or environment variable)
    $isIsolated = $false
    $filteredForwardArgs = @()
    if ($ArgsToForward) {
        foreach ($arg in $ArgsToForward) {
            if ($arg -eq "--isolated" -or $arg -eq "--file-auth" -or $arg -eq "-isolated") {
                $isIsolated = $true
            } else {
                $filteredForwardArgs += $arg
            }
        }
    }
    if ($env:MULTIGRAVITY_ISOLATED -eq "1" -or $env:MULTIGRAVITY_AUTH_MODE -eq "isolated") {
        $isIsolated = $true
    }

    if ($isIsolated) {
        Write-Host "Launching agy CLI with profile '$PROFILE' (isolated file-based auth)..." -ForegroundColor Cyan
    } else {
        Write-Host "Launching agy CLI with profile '$PROFILE'..."
    }
    Write-Host "Tip: To sign into a different Google account for this profile, type '/logout' then '/login' inside agy." -ForegroundColor DarkCyan

    $prevUserProfile = $env:USERPROFILE
    $prevAppData = $env:APPDATA
    $prevLocalAppData = $env:LOCALAPPDATA
    $prevAgyAccount = $env:AGY_ACCOUNT
    $prevSsh = $env:SSH_CONNECTION
    $prevCred = Get-GeminiCredential

    $accountFile = "$PROFILE_DIR\.account"
    if (Test-Path $accountFile) {
        $savedAccount = (Get-Content $accountFile -Raw).Trim()
        if (![string]::IsNullOrEmpty($savedAccount)) {
            $env:AGY_ACCOUNT = $savedAccount
        }
    }

    $env:USERPROFILE = $PROFILE_DIR
    $env:APPDATA = "$PROFILE_DIR\AppData\Roaming"
    $env:LOCALAPPDATA = "$PROFILE_DIR\AppData\Local"

    if ($isIsolated) {
        # 1. Fail-closed: Verify agy binary supports file-based authentication mechanism
        if (!(Test-AgyBinarySupportsFileAuth $agyExec)) {
            Write-Error "Error: Installed agy binary at '$agyExec' does not support isolated file-based authentication. Aborting to prevent silent fallback to Windows Credential Manager."
            exit 1
        }

        # 2. Fail-closed: Authoritative designated account validation
        $expected = Get-DesignatedAccount $PROFILE
        if ([string]::IsNullOrEmpty($expected)) {
            Write-Error "Error: Profile '$PROFILE' has no designated account configured. Isolated mode requires an authoritative designated account to prevent cross-profile contamination. Run: multigravity auth bind $PROFILE <email>"
            exit 1
        }
        if ($expected -like "__CONFLICT__*") {
            Write-Error "Error: Profile '$PROFILE' has conflicting designated identities between local marker and central registry. Vault sync blocked."
            exit 1
        }

        # 3. Fail-closed: Verify vault exists and matches designated account
        $vaultFile = "$PROFILE_DIR\.auth_vault"
        if (!(Test-Path $vaultFile)) {
            Write-Error "Error: Profile '$PROFILE' has no saved session in its vault (.auth_vault). Isolated mode requires an existing verified session. Run: multigravity auth save $PROFILE"
            exit 1
        }
        $vaultVal = (Get-Content -Path $vaultFile -Raw -Encoding UTF8).Trim()
        if ([string]::IsNullOrEmpty($vaultVal)) {
            Write-Error "Error: Profile '$PROFILE' vault is empty. Run: multigravity auth save $PROFILE"
            exit 1
        }
        $vaultEmail = Get-EmailFromCredential $vaultVal
        if ([string]::IsNullOrEmpty($vaultEmail) -or ($vaultEmail.Trim().ToLowerInvariant() -ne $expected.Trim().ToLowerInvariant())) {
            Write-Error "Error: Profile '$PROFILE' vault credentials belong to '$vaultEmail', but profile is designated for '$expected'. Aborting isolated launch."
            exit 1
        }

        # 4. Seed verified token files
        $cliDir = "$PROFILE_DIR\.gemini\antigravity-cli"
        if (!(Test-Path $cliDir)) {
            New-Item -ItemType Directory -Path $cliDir -Force | Out-Null
        }
        $t1 = Join-Path $cliDir "antigravity-oauth-token"
        $t2 = Join-Path $cliDir "jetski-standalone-oauth-token"
        Write-AtomicFile $t1 $vaultVal
        Write-AtomicFile $t2 $vaultVal

        # 5. Scope SSH environment override strictly to this isolated session
        $env:SSH_CONNECTION = "127.0.0.1 0 127.0.0.1 0"
    } else {
        Prepare-ProfileVault $PROFILE
    }

    try {
        if ($filteredForwardArgs -and $filteredForwardArgs.Count -gt 0) {
            & $agyExec @filteredForwardArgs
        }
        else {
            & $agyExec
        }
    }
    finally {
        if ($isIsolated) {
            Sync-ProfileVaultFromLocalToken $PROFILE

            # Isolated sessions never create, replace, delete, or restore the shared Windows credential.
            # If the shared credential changed while the isolated session was running (e.g. by another
            # concurrent session or application), report the observation without modifying it.
            $credAfter = Get-GeminiCredential
            if (![string]::IsNullOrEmpty($prevCred) -and ![string]::IsNullOrEmpty($credAfter) -and ($prevCred -ne $credAfter)) {
                $obsBefore = Get-EmailFromCredential $prevCred
                $obsAfter = Get-EmailFromCredential $credAfter
                Write-Host "  [auth-info] Shared Windows Credential Manager was updated during isolated session ($obsBefore -> $obsAfter). Preserving shared credential." -ForegroundColor DarkGray
            }
        } else {
            Save-ProfileVault $PROFILE

            if (![string]::IsNullOrEmpty($prevCred)) {
                Set-GeminiCredential $prevCred | Out-Null
            } elseif (Test-Path "$BASE\.system_auth_vault") {
                $sys = (Get-Content -Path "$BASE\.system_auth_vault" -Raw -Encoding UTF8).Trim()
                if (![string]::IsNullOrEmpty($sys)) {
                    Set-GeminiCredential $sys | Out-Null
                }
            }
        }

        if ($null -ne $prevSsh) {
            $env:SSH_CONNECTION = $prevSsh
        } else {
            Remove-Item Env:\SSH_CONNECTION -ErrorAction SilentlyContinue
        }

        $env:USERPROFILE = $prevUserProfile
        $env:APPDATA = $prevAppData
        $env:LOCALAPPDATA = $prevLocalAppData
        $env:AGY_ACCOUNT = $prevAgyAccount
    }
}

function Invoke-LaunchProfile {
    param($PROFILE, $ArgsToForward)
    Invoke-LaunchIde $PROFILE $ArgsToForward
}

function Invoke-ListProfiles {
    Write-Host "Existing profiles:"
    if (Test-Path $BASE) {
        $profiles = Get-ChildItem -Directory -Path $BASE | Where-Object { $_.PSIsContainer -and $_.Name -ne ".templates" }
        if ($profiles.Count -gt 0) {
            foreach ($p in $profiles) {
                Write-Host $p.Name
            }
        }
        elseif ($profiles -is [System.IO.DirectoryInfo]) {
            Write-Host $profiles.Name
        }
        else {
            Write-Host "(none)"
        }
    }
    else {
        Write-Host "(none)"
    }
}

function Invoke-CreateShortcut {
    param($PROFILE)
    $APP_NAME = "Multigravity $PROFILE"
    $SHORTCUT_PATH = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\$APP_NAME.lnk"
    
    $SCRIPT_PATH = $MyInvocation.MyCommand.Path
    # If script path is empty (e.g. running from prompt), try to find it
    if ([string]::IsNullOrEmpty($SCRIPT_PATH)) {
        $cmdObj = Get-Command multigravity -ErrorAction SilentlyContinue
        if ($cmdObj) { $SCRIPT_PATH = $cmdObj.Source }
    }
    
    $WshShell = New-Object -comObject WScript.Shell
    $Shortcut = $WshShell.CreateShortcut($SHORTCUT_PATH)
    $Shortcut.TargetPath = "powershell.exe"
    $Shortcut.Arguments = "-WindowStyle Hidden -ExecutionPolicy Bypass -Command `"& '$SCRIPT_PATH' $PROFILE`""
    $iconApp = if ($IDE_APP) { $IDE_APP } else { $APP }
    if ($iconApp) {
        $Shortcut.IconLocation = "$iconApp, 0"
    }
    $Shortcut.Save()

    Write-Host "Shortcut created: $SHORTCUT_PATH"
}

function Invoke-NewProfile {
    param($name, [string[]]$extraArgs)

    $shared      = $false
    $fromTpl     = ""
    $i = 0
    while ($i -lt $extraArgs.Count) {
        switch ($extraArgs[$i]) {
            "--shared" { $shared = $true }
            "--from"   { $i++; if ($i -lt $extraArgs.Count) { $fromTpl = $extraArgs[$i] } }
        }
        $i++
    }

    if ([string]::IsNullOrWhiteSpace($name)) {
        Write-Error "Error: profile name required"
        exit 1
    }

    Validate-Name $name

    $profileDir = "$BASE\$name"
    if (Test-Path $profileDir) {
        Write-Error "Error: profile '$name' already exists"
        exit 1
    }

    New-Item -ItemType Directory -Force -Path $BASE | Out-Null

    if ($fromTpl) {
        $tplPath = "$(Get-TemplatesDir)\$fromTpl"
        if (!(Test-Path $tplPath)) {
            Write-Error "Error: template '$fromTpl' not found. Run: multigravity template list"
            exit 1
        }
        Write-Host "Creating profile '$name' from template '$fromTpl'..."
        Copy-Item -Path $tplPath -Destination $profileDir -Recurse
    } elseif ($shared) {
        Invoke-CreateSharedProfile $name
    } else {
        Invoke-CreateProfile $name
    }

    Write-Host "Created profile '$name'"
    Invoke-CreateShortcut $name
}

function Invoke-DeleteProfile {
    param($PROFILE)
    Validate-Name $PROFILE

    $PROFILE_DIR = "$BASE\$PROFILE"
    if (!(Test-Path $PROFILE_DIR)) {
        Write-Error "Error: profile '$PROFILE' does not exist"
        exit 1
    }

    $confirm = Read-Host "Delete profile '$PROFILE' and all its data? [y/N]"
    if ($confirm -match "^[Yy]$") {
        try {
            Remove-Item -Recurse -Force $PROFILE_DIR -ErrorAction Stop
            
            $SHORTCUT_PATH = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Multigravity $PROFILE.lnk"
            if (Test-Path $SHORTCUT_PATH) {
                Remove-Item -Force $SHORTCUT_PATH
                Write-Host "Removed shortcut: $SHORTCUT_PATH"
            }
            Write-Host "Deleted profile '$PROFILE'"
        } catch {
            Write-Error "Error: could not delete profile directory. Ensure Antigravity is closed and no files are in use."
            Write-Host "Details: $_"
        }
    }
    else {
        Write-Host "Aborted."
    }
}

function Invoke-RenameProfile {
    param($OLD, $NEW)
    Validate-Name $OLD
    Validate-Name $NEW

    $OLD_DIR = "$BASE\$OLD"
    $NEW_DIR = "$BASE\$NEW"

    if (!(Test-Path $OLD_DIR)) {
        Write-Error "Error: profile '$OLD' does not exist"
        exit 1
    }
    if (Test-Path $NEW_DIR) {
        Write-Error "Error: profile '$NEW' already exists"
        exit 1
    }

    Rename-Item -Path $OLD_DIR -NewName $NEW

    $OLD_SHORTCUT = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Multigravity $OLD.lnk"
    if (Test-Path $OLD_SHORTCUT) {
        Remove-Item -Force $OLD_SHORTCUT
        Invoke-CreateShortcut $NEW
    }

    Write-Host "Renamed profile '$OLD' to '$NEW'"
}

function Invoke-CloneProfile {
    param($SRC, $DEST)
    Validate-Name $SRC
    Validate-Name $DEST

    $SRC_DIR = "$BASE\$SRC"
    $DEST_DIR = "$BASE\$DEST"

    if (!(Test-Path $SRC_DIR)) {
        Write-Error "Error: source profile '$SRC' does not exist"
        exit 1
    }
    if (Test-Path $DEST_DIR) {
        Write-Error "Error: destination profile '$DEST' already exists"
        exit 1
    }

    Write-Host "Cloning profile '$SRC' to '$DEST'..."
    Copy-Item -Path $SRC_DIR -Destination $DEST_DIR -Recurse
    Invoke-CreateShortcut $DEST

    Write-Host "Successfully cloned '$SRC' to '$DEST'"
}

function Get-FolderSize {
    param($Path)
    $size = (Get-ChildItem $Path -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    if ($size -ge 1GB) { "{0:N2} GB" -f ($size / 1GB) }
    elseif ($size -ge 1MB) { "{0:N2} MB" -f ($size / 1MB) }
    elseif ($size -ge 1KB) { "{0:N2} KB" -f ($size / 1KB) }
    else { "$size B" }
}

function Invoke-ProfileStats {
    if (!(Test-Path $BASE)) {
        Write-Host "No profiles found."
        return
    }

    Write-Host "Profile Storage Usage:"
    Write-Host ("{0,-20} {1,-10} {2,-10}" -f "PROFILE", "SIZE", "EXTENSIONS")
    Write-Host ("{0,-20} {1,-10} {2,-10}" -f "-------", "----", "----------")

    $profiles = Get-ChildItem -Directory -Path $BASE | Where-Object { $_.Name -ne ".templates" }
    foreach ($p in $profiles) {
        $size = Get-FolderSize $p.FullName
        $extPath = Join-Path $p.FullName ".antigravity\extensions"
        $extCount = if (Test-Path $extPath) { (Get-ChildItem $extPath).Count } else { 0 }
        Write-Host ("{0,-20} {1,-10} {2,-10}" -f $p.Name, $size, $extCount)
    }

    Write-Host ""
    $total = Get-FolderSize $BASE
    Write-Host "Total usage: $total"
}

function Invoke-DoctorCli {
    $errors = 0
    $warnings = 0

    Write-Host "Checking multigravity environment..."

    # 1. Antigravity IDE Installation (Default)
    if ($IDE_APP -and (Test-Path $IDE_APP)) {
        Write-Host "  [OK] Antigravity IDE (default): Found at $IDE_APP"
    } else {
        Write-Host "  [WARN] Antigravity IDE: Not found. Will fall back to Antigravity App if present."
        $warnings++
    }

    # 2. Antigravity 2.0 App Installation (--app)
    if ($APP -and (Test-Path $APP)) {
        Write-Host "  [OK] Antigravity 2.0 App (--app): Found at $APP"
    } else {
        Write-Host "  [WARN] Antigravity 2.0 App: Not found."
        $warnings++
    }

    # 3. agy CLI Installation (terminal)
    if ($AGY_APP -and (Test-Path $AGY_APP)) {
        Write-Host "  [OK] agy CLI (terminal): Found at $AGY_APP"
    } else {
        Write-Host "  [WARN] agy CLI: Not found. Terminal mode will not be available."
        $warnings++
    }

    # 2. Path Check
    $cmdObj = Get-Command multigravity -ErrorAction SilentlyContinue
    if ($cmdObj) {
        Write-Host "  [OK] Global Binary: $($cmdObj.Source)"
    } else {
        Write-Host "  [WARN] Global Binary: Not found in PATH. Run install script or update PATH."
        $warnings++
    }

    # 3. Base Directory
    if (Test-Path $BASE) {
        # Check writability
        try {
            $testFile = Join-Path $BASE ".write-test"
            New-Item -ItemType File -Path $testFile -Force -ErrorAction Stop | Out-Null
            Remove-Item $testFile -Force
            Write-Host "  [OK] Profile storage: $BASE (writable)"
        } catch {
            Write-Host "  [FAIL] Profile storage: $BASE (NOT writable)"
            $errors++
        }
    } else {
        Write-Host "  [WARN] Profile storage: $BASE (Not yet created)"
    }

    Write-Host ""
    if ($errors -eq 0) {
        if ($warnings -eq 0) {
            Write-Host "Your environment looks perfect!"
        } else {
            Write-Host "Found $warnings warning(s). Multigravity should still work, but some features might be degraded."
        }
    } else {
        Write-Host "Found $errors error(s) and $warnings warning(s). Please fix the errors above."
    }
}

function Invoke-UpdateCli {
    $script_url = "https://raw.githubusercontent.com/sujitagarwal/multigravity-cli/main/multigravity.ps1"
    $target = $MyInvocation.MyCommand.Path
    if ([string]::IsNullOrEmpty($target)) {
        $cmdObj = Get-Command multigravity -ErrorAction SilentlyContinue
        if ($cmdObj) { $target = $cmdObj.Source }
    }

    if ([string]::IsNullOrEmpty($target)) {
        Write-Error "Error: could not determine script path for update"
        exit 1
    }

    Write-Host "Updating multigravity from $script_url ..."
    try {
        $result = Invoke-WebRequest -Uri $script_url -UseBasicParsing -ErrorAction Stop
        [System.IO.File]::WriteAllText($target, $result.Content, [System.Text.Encoding]::UTF8)
        Write-Host "Successfully updated multigravity!"
    } catch {
        Write-Error "Error: failed to download update: $_"
        exit 1
    }
}

function Invoke-HelpCompletion {
    Write-Host "To enable autocompletion in PowerShell, add the following to your `$PROFILE:"
    Write-Host ""
    Write-Host '  Invoke-Expression (& multigravity completion powershell)'
    Write-Host ""
    Write-Host "Then restart your terminal or run: . `$PROFILE"
}

function Invoke-GenerateCompletion {
    param($shell)
    if ($shell -eq "powershell") {
@"
Register-ArgumentCompleter -Native -CommandName multigravity -ScriptBlock {
    param(`$wordToComplete, `$commandAst, `$cursorPosition)
    `$opts = @('new', 'list', 'status', 'auth', 'rename', 'delete', 'clone', 'template', 'export', 'import', 'update', 'doctor', 'stats', 'completion', 'help', 'agy', 'app', 'ide')
    `$profiles = if (Test-Path '$BASE') { Get-ChildItem -Directory -Path '$BASE' | Select-Object -ExpandProperty Name } else { @() }
    (`$opts + `$profiles) | Where-Object { `$_ -like "`$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_)
    }
}
"@
    } else {
        Write-Host "Only 'powershell' completion is supported on Windows."
    }
}

function Invoke-TemplateCmd {
    param($sub, $a, $b)
    switch ($sub) {
        "save" {
            if ([string]::IsNullOrWhiteSpace($a) -or [string]::IsNullOrWhiteSpace($b)) {
                Write-Error "Error: usage: multigravity template save <profile> <name>"; exit 1
            }
            Validate-Name $a; Validate-Name $b
            $srcDir  = "$BASE\$a"
            $tplDir  = Get-TemplatesDir
            $tplPath = "$tplDir\$b"
            if (!(Test-Path $srcDir))  { Write-Error "Error: profile '$a' does not exist"; exit 1 }
            if (Test-Path $tplPath)    { Write-Error "Error: template '$b' already exists"; exit 1 }
            New-Item -ItemType Directory -Force -Path $tplDir | Out-Null
            Write-Host "Saving '$a' as template '$b'..."
            Copy-Item -Path $srcDir -Destination $tplPath -Recurse
            $marker = "$tplPath\.shared"
            if (Test-Path $marker) { Remove-Item $marker -Force }
            Write-Host "Saved template '$b'"
        }
        "list" {
            $tplDir = Get-TemplatesDir
            Write-Host "Templates:"
            if (!(Test-Path $tplDir)) { Write-Host "  (none)"; return }
            $items = Get-ChildItem -Directory -Path $tplDir -ErrorAction SilentlyContinue
            if ($items.Count -eq 0) { Write-Host "  (none)"; return }
            foreach ($t in $items) {
                Write-Host ("  {0,-20} {1}" -f $t.Name, (Get-FolderSize $t.FullName))
            }
        }
        "delete" {
            if ([string]::IsNullOrWhiteSpace($a)) { Write-Error "Error: template name required"; exit 1 }
            Validate-Name $a
            $tplPath = "$(Get-TemplatesDir)\$a"
            if (!(Test-Path $tplPath)) { Write-Error "Error: template '$a' does not exist"; exit 1 }
            Remove-Item -Recurse -Force $tplPath
            Write-Host "Deleted template '$a'"
        }
        default {
            Write-Error "Error: usage: multigravity template <save|list|delete>"; exit 1
        }
    }
}

function Invoke-StatusProfiles {
    if (!(Test-Path $BASE)) { Write-Host "No profiles found."; return }

    Write-Host ("{0,-16} {1,-26} {2,-9} {3,-8} {4,-17} {5}" -f "PROFILE", "ACCOUNT", "RUNNING", "TYPE", "LAST USED", "SIZE")
    Write-Host ("{0,-16} {1,-26} {2,-9} {3,-8} {4,-17} {5}" -f "-------", "-------", "-------", "----", "---------", "----")

    $dirs = Get-ChildItem -Directory -Path $BASE -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne ".templates" }

    foreach ($d in $dirs) {
        $running = "no"
        $procs = Get-Process -Name "Antigravity", "Antigravity IDE", "agy" -ErrorAction SilentlyContinue
        if ($procs) {
            foreach ($proc in $procs) {
                try {
                    $cl = (Get-CimInstance Win32_Process -Filter "ProcessId = $($proc.Id)" -ErrorAction SilentlyContinue).CommandLine
                    if ($cl -and $cl -like "*$($d.Name)*") { $running = "yes"; break }
                } catch {}
            }
        }

        $ptype    = if (Test-Path "$($d.FullName)\.shared") { "shared" } else { "full" }
        $lastUsed = $d.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
        $size     = Get-FolderSize $d.FullName
        $account  = "-"
        $accFile  = Join-Path $d.FullName ".account"
        if (Test-Path $accFile) {
            $account = (Get-Content $accFile -Raw).Trim()
        } elseif (Test-Path (Join-Path $d.FullName ".auth_vault")) {
            $parsed = Get-EmailFromCredential (Get-Content (Join-Path $d.FullName ".auth_vault") -Raw -Encoding UTF8)
            if ($parsed) { $account = $parsed }
        }
        if ($account.Length -gt 25) { $account = $account.Substring(0, 22) + "..." }

        if ($running -eq "yes") {
            Write-Host ("{0,-16} {1,-26} " -f $d.Name, $account) -NoNewline
            Write-Host ("{0,-9} " -f $running) -NoNewline -ForegroundColor Green
            Write-Host ("{0,-8} {1,-17} {2}" -f $ptype, $lastUsed, $size)
        } else {
            Write-Host ("{0,-16} {1,-26} {2,-9} {3,-8} {4,-17} {5}" -f $d.Name, $account, $running, $ptype, $lastUsed, $size)
        }
    }
}

function Invoke-ExportProfile {
    param($name, $outPath)
    if ([string]::IsNullOrWhiteSpace($name)) { Write-Error "Error: profile name required"; exit 1 }
    Validate-Name $name

    $profileDir = "$BASE\$name"
    if (!(Test-Path $profileDir)) { Write-Error "Error: profile '$name' does not exist"; exit 1 }

    if ([string]::IsNullOrWhiteSpace($outPath)) { $outPath = ".\$name.zip" }

    Write-Host "Exporting '$name' to $outPath ..."
    Compress-Archive -Path $profileDir -DestinationPath $outPath -Force
    Write-Host "Done."
}

function Invoke-ImportProfile {
    param($archivePath, $name)

    if ([string]::IsNullOrWhiteSpace($archivePath)) {
        Write-Error "Error: usage: multigravity import <archive.zip> [name]"; exit 1
    }
    if (!(Test-Path $archivePath)) {
        Write-Error "Error: file not found: $archivePath"; exit 1
    }

    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($archivePath)
    }
    Validate-Name $name

    $dest = "$BASE\$name"
    if (Test-Path $dest) {
        Write-Error "Error: profile '$name' already exists - choose a different name or delete it first"
        exit 1
    }

    New-Item -ItemType Directory -Force -Path $BASE | Out-Null
    Write-Host "Importing as '$name'..."

    $tmp = "$BASE\_mg_import_$(Get-Random)"
    Expand-Archive -Path $archivePath -DestinationPath $tmp -Force

    $top = Get-ChildItem -Directory -Path $tmp
    if ($top.Count -eq 1) {
        Move-Item -Path $top[0].FullName -Destination $dest
        Remove-Item $tmp -Recurse -Force
    } else {
        Rename-Item -Path $tmp -NewName $name
    }

    Invoke-CreateShortcut $name
    Write-Host "Imported profile '$name'"
}

switch ($cmd) {
    "new" {
        $extra = @()
        if ($arg2)       { $extra += $arg2 }
        if ($ForwardArgs) { $extra += $ForwardArgs }
        Invoke-NewProfile $arg1 $extra
    }
    "list" {
        Invoke-ListProfiles
    }
    "status" {
        Invoke-StatusProfiles
    }
    "rename" {
        Invoke-RenameProfile $arg1 $arg2
    }
    "delete" {
        Invoke-DeleteProfile $arg1
    }
    "clone" {
        Invoke-CloneProfile $arg1 $arg2
    }
    "template" {
        Invoke-TemplateCmd $arg1 $arg2 ($ForwardArgs | Select-Object -First 1)
    }
    "export" {
        Invoke-ExportProfile $arg1 $arg2
    }
    "import" {
        Invoke-ImportProfile $arg1 $arg2
    }
    "update" {
        Invoke-UpdateCli
    }
    "doctor" {
        Invoke-DoctorCli
    }
    "stats" {
        Invoke-ProfileStats
    }
    "auth" {
        $extra = @()
        if ($arg2)        { $extra += $arg2 }
        if ($ForwardArgs) { $extra += $ForwardArgs }
        Invoke-AuthCmd $arg1 $extra
    }
    "completion" {
        if ($arg1) {
            Invoke-GenerateCompletion $arg1
        } else {
            Invoke-HelpCompletion
        }
    }
    "agy" {
        if ([string]::IsNullOrWhiteSpace($arg1)) {
            Write-Error "Error: profile name required for agy command. Usage: multigravity agy <profile> [args]"
            exit 1
        }
        $AllArgs = @()
        if ($arg2)        { $AllArgs += $arg2 }
        if ($ForwardArgs) { $AllArgs += $ForwardArgs }
        Invoke-LaunchAgy $arg1 $AllArgs
    }
    "app" {
        if ([string]::IsNullOrWhiteSpace($arg1)) {
            Write-Error "Error: profile name required for app command. Usage: multigravity app <profile> [args]"
            exit 1
        }
        $AllArgs = @()
        if ($arg2)        { $AllArgs += $arg2 }
        if ($ForwardArgs) { $AllArgs += $ForwardArgs }
        Invoke-LaunchApp $arg1 $AllArgs
    }
    "ide" {
        if ([string]::IsNullOrWhiteSpace($arg1)) {
            Write-Error "Error: profile name required for ide command. Usage: multigravity ide <profile> [args]"
            exit 1
        }
        $AllArgs = @()
        if ($arg2)        { $AllArgs += $arg2 }
        if ($ForwardArgs) { $AllArgs += $ForwardArgs }
        Invoke-LaunchIde $arg1 $AllArgs
    }
    "help"   { Write-Usage }
    "--help" { Write-Usage }
    "-h"     { Write-Usage }
    "" {
        Write-Usage
        exit 1
    }
    default {
        $AllArgs = @()
        if ($arg1)        { $AllArgs += $arg1 }
        if ($arg2)        { $AllArgs += $arg2 }
        if ($ForwardArgs) { $AllArgs += $ForwardArgs }

        $isApp = $false
        $isCli = $false
        $filteredArgs = @()

        foreach ($a in $AllArgs) {
            if ($a -eq "--app") {
                $isApp = $true
            } elseif ($a -eq "--cli" -or $a -eq "--terminal" -or $a -eq "agy") {
                $isCli = $true
            } else {
                $filteredArgs += $a
            }
        }

        if ($isCli) {
            Invoke-LaunchAgy $cmd $filteredArgs
        } elseif ($isApp) {
            Invoke-LaunchApp $cmd $filteredArgs
        } else {
            Invoke-LaunchIde $cmd $filteredArgs
        }
    }
}
