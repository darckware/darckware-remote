# RustDesk Darckware Installer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a public, branded Windows 11 installer repository that installs Tailscale, RustDesk, or both and configures either direct tailnet access or a persistent host route through a Tailscale router.

**Architecture:** A thin WinForms UI creates a validated install request and passes it to a UI-independent PowerShell orchestration module. Focused modules own artifact verification, secret handling, routing, Tailscale, and RustDesk so Pester can test decisions without modifying the test machine. Vendor installers are downloaded from pinned official URLs, then checked by SHA-256 and Authenticode before execution.

**Tech Stack:** Windows PowerShell 5.1-compatible PowerShell, WinForms, Pester 5.7.1, Windows networking cmdlets, GitHub Actions on `windows-latest`.

**Spec:** `docs/superpowers/specs/2026-09-22-rustdesk-darckware-installer-design.md`

## Global Constraints

- Support Windows 11 x86-64 with Windows PowerShell 5.1 or PowerShell 7.
- The repository is public at `marcelodarckferreira/rustdesk-darckware`; no secret may be committed or logged.
- Pin RustDesk `1.4.9` x86-64 EXE and Tailscale `1.102.3` x86-64 MSI; never use a `latest` download URL.
- Configure RustDesk ID server `100.105.235.114`, relay `100.105.235.114:21117`, no API server, and public key `30OQH25Eg+VmQH06Y6h7GXiuHML4V8Km4MltPVfP4ys=`.
- Route mode creates only `100.105.235.114/32`, never the complete `100.64.0.0/10` range.
- Treat a Tailscale auth key and a RustDesk permanent password as secrets throughout their lifetimes.
- Vendor binaries stay out of Git and run only after HTTPS, pinned SHA-256, and Authenticode publisher validation.
- The initial release brands the installer; it does not modify the RustDesk application's internal branding.
- A real Windows 11 VM acceptance run is required before calling a release production-ready.

## File Map

- `install.cmd` — stable double-click entry point.
- `install.ps1` — parameter parsing, UAC elevation, module loading, GUI/headless dispatch, and process exit code.
- `config/artifacts.json` — pinned vendor URLs, versions, SHA-256 values, filenames, and expected Authenticode publishers.
- `config/deployment.json` — non-secret RustDesk server, relay, public key, route destination, ports, and state paths.
- `src/Artifact.psm1` — manifest loading, downloads, SHA-256, and signature checks.
- `src/Security.psm1` — redaction, secure temporary secret files, and cleanup.
- `src/Network.psm1` — IPv4 validation, route planning/reconciliation, and port probes.
- `src/Tailscale.psm1` — installation, status parsing, authentication, and unattended mode.
- `src/RustDesk.psm1` — installation, config token creation/application, password application, service check, and ID retrieval.
- `src/Installer.Core.psm1` — request validation, orchestration, state, structured result, and dependency ordering.
- `src/Installer.UI.psm1` — Darckware WinForms wizard and final status display only.
- `assets/` — existing Darckware lockups and raster icons reused from the brand kit.
- `tests/*.Tests.ps1` — Pester tests mirroring module responsibilities.
- `docs/router-prerequisites.md` — requirements for the external router station.
- `docs/troubleshooting.md` — operator recovery and diagnostic commands.
- `.github/workflows/windows-tests.yml` — Windows Pester and secret/static checks.
- `README.md`, `LICENSE`, `THIRD_PARTY_NOTICES.md`, `.gitignore` — public repository packaging and attribution.

## Review Focus

- A malformed or adversarial gateway/hostname must be rejected before it reaches a Windows command; Task 3 and Task 4 include injection-shaped inputs.
- A reusable Tailscale auth key must never appear in arguments, state, result objects, exceptions, or logs; Task 2 and Task 4 test redaction and file-based delivery.
- An existing conflicting route must be shown as a replace operation and changed only after confirmation; Task 3 tests preserve/reuse/replace decisions.
- A checksum/signature/publisher mismatch must stop execution before `msiexec` or a vendor EXE runs; Task 1 tests every failure independently.
- In combined mode, a failed Tailscale connection must prevent RustDesk installation and still clean secret files; Task 6 tests ordering and cleanup.

---

### Task 1: Repository Baseline and Verified Artifact Acquisition

**Files:**
- Create: `.gitignore`
- Create: `config/artifacts.json`
- Create: `config/deployment.json`
- Create: `src/Artifact.psm1`
- Create: `tests/Artifact.Tests.ps1`

**Interfaces:**
- Consumes: official RustDesk and Tailscale HTTPS release URLs.
- Produces: `Get-InstallerConfig -RepoRoot <string> -> PSCustomObject`; `Get-VerifiedArtifact -Artifact <PSCustomObject> -CacheRoot <string> -> string`.

- [ ] **Step 1: Obtain and record exact hashes from official artifacts**

Download each pinned artifact once in an isolated temporary directory, compute its SHA-256, and compare the Tailscale value with its official checksum endpoint:

```powershell
$work = Join-Path $env:TEMP 'rustdesk-darckware-hashes'
New-Item -ItemType Directory -Force $work | Out-Null
Invoke-WebRequest 'https://github.com/rustdesk/rustdesk/releases/download/1.4.9/rustdesk-1.4.9-x86_64.exe' -OutFile "$work\rustdesk-1.4.9-x86_64.exe"
Invoke-WebRequest 'https://pkgs.tailscale.com/stable/tailscale-setup-1.102.3-amd64.msi' -OutFile "$work\tailscale-setup-1.102.3-amd64.msi"
Invoke-WebRequest 'https://pkgs.tailscale.com/stable/tailscale-setup-1.102.3-amd64.msi.sha256' -OutFile "$work\tailscale.sha256"
Get-FileHash "$work\rustdesk-1.4.9-x86_64.exe" -Algorithm SHA256
Get-FileHash "$work\tailscale-setup-1.102.3-amd64.msi" -Algorithm SHA256
Get-Content "$work\tailscale.sha256"
```

Expected: two 64-character uppercase hashes; the computed Tailscale hash equals the official checksum. Record the exact lowercase values in `config/artifacts.json`. The known RustDesk 1.4.9 x86-64 EXE digest is `eaedeb0088e687bf46f7c46a9c6ea5493ce51f3134dfd6acbedb47b5b9136274`; abort if the computed value differs.

- [ ] **Step 2: Write failing manifest and artifact tests**

```powershell
BeforeAll {
    Import-Module "$PSScriptRoot/../src/Artifact.psm1" -Force
    $repo = (Resolve-Path "$PSScriptRoot/..").Path
}

Describe 'Get-InstallerConfig' {
    It 'loads exact pinned versions and deployment values' {
        $config = Get-InstallerConfig -RepoRoot $repo
        $config.Artifacts.rustdesk.version | Should -Be '1.4.9'
        $config.Artifacts.tailscale.version | Should -Be '1.102.3'
        $config.Deployment.rustdesk.idServer | Should -Be '100.105.235.114'
        $config.Deployment.route.destinationPrefix | Should -Be '100.105.235.114/32'
    }
    It 'contains only HTTPS artifact URLs and 64-character hashes' {
        $config = Get-InstallerConfig -RepoRoot $repo
        foreach ($artifact in @($config.Artifacts.rustdesk, $config.Artifacts.tailscale)) {
            $artifact.url | Should -Match '^https://'
            $artifact.sha256 | Should -Match '^[a-f0-9]{64}$'
        }
    }
}

Describe 'Get-VerifiedArtifact' {
    It 'rejects a checksum mismatch before signature verification' {
        Mock Invoke-WebRequest { Set-Content -LiteralPath $OutFile -Value 'tampered' -NoNewline }
        Mock Get-AuthenticodeSignature { throw 'signature check must not run' }
        $artifact = [pscustomobject]@{ name='x'; fileName='x.exe'; url='https://example.test/x.exe'; sha256=('0' * 64); publisher='Example' }
        { Get-VerifiedArtifact -Artifact $artifact -CacheRoot $TestDrive } | Should -Throw '*SHA-256*'
        Should -Invoke Get-AuthenticodeSignature -Times 0
    }
    It 'rejects invalid signatures and unexpected publishers' {
        # Use a fixture hash for the bytes emitted by the download mock.
        $bytes = [Text.Encoding]::UTF8.GetBytes('signed-fixture')
        $hash = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
        Mock Invoke-WebRequest { [IO.File]::WriteAllBytes($OutFile, $bytes) }
        $artifact = [pscustomobject]@{ name='x'; fileName='x.exe'; url='https://example.test/x.exe'; sha256=$hash; publisher='Expected Publisher' }
        Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status='NotSigned'; SignerCertificate=$null } }
        { Get-VerifiedArtifact -Artifact $artifact -CacheRoot $TestDrive } | Should -Throw '*Authenticode*'
        Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status='Valid'; SignerCertificate=[pscustomobject]@{ Subject='CN=Wrong Publisher' } } }
        { Get-VerifiedArtifact -Artifact $artifact -CacheRoot $TestDrive } | Should -Throw '*publisher*'
    }
}
```

- [ ] **Step 3: Run the tests and confirm the expected failure**

Run:

```powershell
Invoke-Pester tests/Artifact.Tests.ps1 -Output Detailed
```

Expected: FAIL because `Artifact.psm1` and both JSON files do not exist.

- [ ] **Step 4: Create manifests and minimal verified-download implementation**

Use this manifest shape. The Tailscale digest below is the value published by
its official `.sha256` endpoint; Step 1 independently verifies it:

```json
{
  "rustdesk": {
    "name": "RustDesk",
    "version": "1.4.9",
    "fileName": "rustdesk-1.4.9-x86_64.exe",
    "url": "https://github.com/rustdesk/rustdesk/releases/download/1.4.9/rustdesk-1.4.9-x86_64.exe",
    "sha256": "eaedeb0088e687bf46f7c46a9c6ea5493ce51f3134dfd6acbedb47b5b9136274",
    "publisher": "PURSLANE"
  },
  "tailscale": {
    "name": "Tailscale",
    "version": "1.102.3",
    "fileName": "tailscale-setup-1.102.3-amd64.msi",
    "url": "https://pkgs.tailscale.com/stable/tailscale-setup-1.102.3-amd64.msi",
    "sha256": "03ac8183c6e3ce276e9b44281ebe7e4c02aef28a971034ca170c4b665df42dce",
    "publisher": "Tailscale Inc."
  }
}
```

`config/deployment.json` must contain:

```json
{
  "rustdesk": {
    "idServer": "100.105.235.114",
    "relayServer": "100.105.235.114:21117",
    "publicKey": "30OQH25Eg+VmQH06Y6h7GXiuHML4V8Km4MltPVfP4ys=",
    "tcpPorts": [21116, 21117]
  },
  "route": {
    "destinationPrefix": "100.105.235.114/32"
  },
  "stateRoot": "%ProgramData%\\Darckware\\RustDeskInstaller"
}
```

Implement strict file loading and verify hash before signature/publisher:

```powershell
function Get-VerifiedArtifact {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Artifact, [Parameter(Mandatory)][string]$CacheRoot)
    $target = Join-Path $CacheRoot $Artifact.fileName
    New-Item -ItemType Directory -Force $CacheRoot | Out-Null
    Invoke-WebRequest -Uri $Artifact.url -OutFile $target -UseBasicParsing
    $actual = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Artifact.sha256.ToLowerInvariant()) { Remove-Item $target -Force; throw "SHA-256 mismatch for $($Artifact.name)" }
    $signature = Get-AuthenticodeSignature -LiteralPath $target
    if ($signature.Status -ne 'Valid') { Remove-Item $target -Force; throw "Authenticode validation failed for $($Artifact.name)" }
    if ($signature.SignerCertificate.Subject -notlike "*$($Artifact.publisher)*") { Remove-Item $target -Force; throw "Unexpected publisher for $($Artifact.name)" }
    return $target
}
```

Add `.gitignore` entries for `downloads/`, `*.log`, `TestResults/`, and local secret/state fixtures.

- [ ] **Step 5: Run tests and commit**

```powershell
Invoke-Pester tests/Artifact.Tests.ps1 -Output Detailed
git diff --check
git add .gitignore config src/Artifact.psm1 tests/Artifact.Tests.ps1
git commit -m "feat: pin and verify installer artifacts"
```

Expected: all Task 1 tests PASS.

### Task 2: Secret Lifecycle and Redacted Logging

**Files:**
- Create: `src/Security.psm1`
- Create: `tests/Security.Tests.ps1`

**Interfaces:**
- Consumes: `SecureString` values from UI/headless input.
- Produces: `Protect-LogText -Text <string> -> string`; `New-ProtectedSecretFile -Secret <SecureString> -Directory <string> -> string`; `Remove-SecretFile -Path <string> -> void`.

- [ ] **Step 1: Write failing tests for redaction and guaranteed cleanup**

```powershell
BeforeAll { Import-Module "$PSScriptRoot/../src/Security.psm1" -Force }

Describe 'Protect-LogText' {
    It 'redacts Tailscale auth keys and named password fields' {
        $text = 'auth=tskey-auth-k123 password=SuperSecret rustdeskPassword=OtherSecret'
        $safe = Protect-LogText -Text $text
        $safe | Should -Not -Match 'tskey-|SuperSecret|OtherSecret'
        $safe | Should -Match '\[REDACTED\]'
    }
}

Describe 'protected secret files' {
    It 'writes the secret and removes it deterministically' {
        $secret = ConvertTo-SecureString 'tskey-auth-test' -AsPlainText -Force
        $path = New-ProtectedSecretFile -Secret $secret -Directory $TestDrive
        Test-Path $path | Should -BeTrue
        Get-Content -Raw $path | Should -Be 'tskey-auth-test'
        Remove-SecretFile -Path $path
        Test-Path $path | Should -BeFalse
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```powershell
Invoke-Pester tests/Security.Tests.ps1 -Output Detailed
```

Expected: FAIL because the module does not exist.

- [ ] **Step 3: Implement redaction and protected-file functions**

Convert the secure string only inside `try/finally`, zero and free the BSTR,
write UTF-8 without a trailing newline, and apply an ACL containing only
SYSTEM and the built-in Administrators group. `Remove-SecretFile` must use
`Remove-Item -LiteralPath -Force -ErrorAction SilentlyContinue` and be safe to
call repeatedly.

```powershell
function Protect-LogText {
    param([AllowEmptyString()][string]$Text)
    $safe = $Text -replace 'tskey-[A-Za-z0-9_-]+', '[REDACTED]'
    $safe = $safe -replace '(?i)(password|authkey|rustdeskPassword)\s*[=:]\s*\S+', '$1=[REDACTED]'
    return $safe
}
```

- [ ] **Step 4: Run tests and commit**

```powershell
Invoke-Pester tests/Security.Tests.ps1 -Output Detailed
git diff --check
git add src/Security.psm1 tests/Security.Tests.ps1
git commit -m "feat: protect installer secrets and logs"
```

Expected: all Task 2 tests PASS.

### Task 3: Gateway Validation and Managed Host Route

**Files:**
- Create: `src/Network.psm1`
- Create: `tests/Network.Tests.ps1`

**Interfaces:**
- Consumes: deployment route prefix, router IPv4, and prior managed state.
- Produces: `Test-IPv4Address -Address <string> -> bool`; `Get-RustDeskRoutePlan -DestinationPrefix <string> -Gateway <string> -CurrentRoutes <object[]> -ManagedGateway <string> -> PSCustomObject`; `Set-RustDeskHostRoute -Plan <PSCustomObject> -> void`; `Test-RustDeskPorts -Address <string> -Ports <int[]> -> object[]`.

- [ ] **Step 1: Write failing validation and route-decision tests**

```powershell
BeforeAll { Import-Module "$PSScriptRoot/../src/Network.psm1" -Force }

Describe 'Test-IPv4Address' {
    It 'accepts a normal private address and rejects command-shaped input' {
        Test-IPv4Address '192.168.1.10' | Should -BeTrue
        Test-IPv4Address '192.168.1.10; Remove-Item C:\' | Should -BeFalse
        Test-IPv4Address '999.1.1.1' | Should -BeFalse
        Test-IPv4Address '::1' | Should -BeFalse
    }
}

Describe 'Get-RustDeskRoutePlan' {
    It 'creates, reuses, and explicitly replaces routes' {
        (Get-RustDeskRoutePlan '100.105.235.114/32' '192.168.1.10' @() '').Action | Should -Be 'Create'
        $same = [pscustomobject]@{ DestinationPrefix='100.105.235.114/32'; NextHop='192.168.1.10'; InterfaceIndex=7 }
        (Get-RustDeskRoutePlan '100.105.235.114/32' '192.168.1.10' @($same) '192.168.1.10').Action | Should -Be 'Reuse'
        $other = [pscustomobject]@{ DestinationPrefix='100.105.235.114/32'; NextHop='192.168.1.9'; InterfaceIndex=7 }
        $plan = Get-RustDeskRoutePlan '100.105.235.114/32' '192.168.1.10' @($other) '192.168.1.9'
        $plan.Action | Should -Be 'Replace'
        $plan.RequiresConfirmation | Should -BeTrue
    }
    It 'preserves an unmanaged conflicting route' {
        $route = [pscustomobject]@{ DestinationPrefix='100.105.235.114/32'; NextHop='192.168.1.9'; InterfaceIndex=7 }
        (Get-RustDeskRoutePlan '100.105.235.114/32' '192.168.1.10' @($route) '').Action | Should -Be 'Conflict'
    }
}
```

- [ ] **Step 2: Run the tests and verify failure**

```powershell
Invoke-Pester tests/Network.Tests.ps1 -Output Detailed
```

Expected: FAIL because `Network.psm1` does not exist.

- [ ] **Step 3: Implement pure planning before Windows mutations**

Use `[IPAddress]::TryParse`, require `AddressFamily::InterNetwork`, and reject
non-canonical text by comparing `parsed.IPAddressToString` to the input.
`Get-RustDeskRoutePlan` returns one of `Create`, `Reuse`, `Replace`, or
`Conflict`; only a route matching the saved managed gateway can be replaced.

`Set-RustDeskHostRoute` resolves the gateway's interface with
`Find-NetRoute -RemoteIPAddress`, removes only the exact managed route for a
confirmed `Replace`, then calls:

```powershell
New-NetRoute -DestinationPrefix $Plan.DestinationPrefix `
    -InterfaceIndex $Plan.InterfaceIndex -NextHop $Plan.Gateway `
    -RouteMetric 5 -PolicyStore PersistentStore -ErrorAction Stop
```

`Test-RustDeskPorts` calls `Test-NetConnection -InformationLevel Quiet` for
each configured TCP port and returns structured results rather than printing.

- [ ] **Step 4: Add mutation tests with mocked Windows cmdlets**

```powershell
It 'never removes a route for Create or Conflict plans' {
    Mock Remove-NetRoute {}
    Mock Find-NetRoute { [pscustomobject]@{ InterfaceIndex = 7 } }
    Mock New-NetRoute {}
    Set-RustDeskHostRoute ([pscustomobject]@{ Action='Create'; DestinationPrefix='100.105.235.114/32'; Gateway='192.168.1.10'; InterfaceIndex=7; Confirmed=$true })
    Should -Invoke Remove-NetRoute -Times 0
    Should -Invoke New-NetRoute -Times 1
}
```

- [ ] **Step 5: Run tests and commit**

```powershell
Invoke-Pester tests/Network.Tests.ps1 -Output Detailed
git diff --check
git add src/Network.psm1 tests/Network.Tests.ps1
git commit -m "feat: manage RustDesk router connectivity"
```

Expected: all Task 3 tests PASS.

### Task 4: Tailscale Installation and Secure Enrollment

**Files:**
- Create: `src/Tailscale.psm1`
- Create: `tests/Tailscale.Tests.ps1`

**Interfaces:**
- Consumes: verified MSI path, validated hostname, `SecureString` auth key, and Security module functions.
- Produces: `Test-TailscaleHostname -Hostname <string> -> bool`; `Get-TailscaleStatus -> PSCustomObject`; `Install-Tailscale -MsiPath <string> -> void`; `Connect-Tailscale -Hostname <string> -AuthKey <SecureString> -SecretDirectory <string> -> PSCustomObject`.

- [ ] **Step 1: Write failing tests for hostname safety, MSI invocation, and secret delivery**

```powershell
BeforeAll {
    Import-Module "$PSScriptRoot/../src/Security.psm1" -Force
    Import-Module "$PSScriptRoot/../src/Tailscale.psm1" -Force
}

Describe 'Test-TailscaleHostname' {
    It 'accepts DNS-safe names and rejects injection-shaped names' {
        Test-TailscaleHostname 'cliente-loja-01' | Should -BeTrue
        Test-TailscaleHostname '-bad' | Should -BeFalse
        Test-TailscaleHostname 'bad;whoami' | Should -BeFalse
        Test-TailscaleHostname ('a' * 64) | Should -BeFalse
    }
}

Describe 'Connect-Tailscale' {
    It 'uses an auth-key file, removes it, and never returns the key' {
        Mock New-ProtectedSecretFile { Join-Path $TestDrive 'auth.key' }
        Mock Remove-SecretFile {}
        Mock Invoke-TailscaleCommand { [pscustomobject]@{ ExitCode=0; Output='ok' } }
        Mock Get-TailscaleStatus { [pscustomobject]@{ Connected=$true; TailscaleIPs=@('100.64.1.2') } }
        $secret = ConvertTo-SecureString 'tskey-auth-secret' -AsPlainText -Force
        $result = Connect-Tailscale -Hostname 'cliente-01' -AuthKey $secret -SecretDirectory $TestDrive
        Should -Invoke Invoke-TailscaleCommand -ParameterFilter { $Arguments -contains '--auth-key=file:' + (Join-Path $TestDrive 'auth.key') }
        Should -Invoke Remove-SecretFile -Times 1
        ($result | ConvertTo-Json -Compress) | Should -Not -Match 'tskey-'
    }
}
```

- [ ] **Step 2: Run tests and verify failure**

```powershell
Invoke-Pester tests/Tailscale.Tests.ps1 -Output Detailed
```

Expected: FAIL because `Tailscale.psm1` does not exist.

- [ ] **Step 3: Implement installation, status, and enrollment**

`Install-Tailscale` must invoke `msiexec.exe` with an argument array:

```powershell
@('/i', $MsiPath, '/qn', '/norestart', 'TS_UNATTENDEDMODE=always', 'TS_NOLAUNCH=1')
```

Accept MSI success codes `0`, `1641`, and `3010`; return whether reboot is
required. `Get-TailscaleStatus` parses `tailscale.exe status --json` and treats
`BackendState == 'Running'` plus at least one Tailscale IP as connected.

`Connect-Tailscale` must use:

```powershell
$secretPath = New-ProtectedSecretFile -Secret $AuthKey -Directory $SecretDirectory
try {
    $args = @('up', "--auth-key=file:$secretPath", "--hostname=$Hostname", '--unattended=true')
    $command = Invoke-TailscaleCommand -Arguments $args
    if ($command.ExitCode -ne 0) { throw 'Tailscale enrollment failed' }
    $status = Get-TailscaleStatus
    if (-not $status.Connected) { throw 'Tailscale did not reach Running state' }
    return $status
} finally {
    Remove-SecretFile -Path $secretPath
}
```

- [ ] **Step 4: Add failure-cleanup and idempotency tests**

Test that `Remove-SecretFile` runs when `Invoke-TailscaleCommand` throws, that a
connected existing installation is reused, and that MSI code `3010` produces
`RebootRequired = $true` without being treated as failure.

- [ ] **Step 5: Run tests and commit**

```powershell
Invoke-Pester tests/Tailscale.Tests.ps1 -Output Detailed
git diff --check
git add src/Tailscale.psm1 tests/Tailscale.Tests.ps1
git commit -m "feat: install and enroll Tailscale securely"
```

Expected: all Task 4 tests PASS.

### Task 5: RustDesk Installation and Fixed Server Configuration

**Files:**
- Create: `src/RustDesk.psm1`
- Create: `tests/RustDesk.Tests.ps1`

**Interfaces:**
- Consumes: verified RustDesk EXE, deployment values, and optional `SecureString` password.
- Produces: `New-RustDeskConfigToken -Host <string> -Key <string> -Relay <string> -> string`; `Install-RustDesk -InstallerPath <string> -> void`; `Set-RustDeskConfiguration -ExecutablePath <string> -ConfigToken <string> -Password <SecureString> -> void`; `Get-RustDeskId -ExecutablePath <string> -> string`.

- [ ] **Step 1: Write failing deterministic token and command tests**

```powershell
BeforeAll { Import-Module "$PSScriptRoot/../src/RustDesk.psm1" -Force }

Describe 'New-RustDeskConfigToken' {
    It 'round-trips the exact host, key, blank API, and relay JSON' {
        $token = New-RustDeskConfigToken -Host '100.105.235.114' -Key 'public-key=' -Relay '100.105.235.114:21117'
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(((-join $token.ToCharArray()[($token.Length-1)..0]) -replace '-', '+' -replace '_', '/') + ('=' * ((4 - $token.Length % 4) % 4))))
        $parsed = $json | ConvertFrom-Json
        $parsed.host | Should -Be '100.105.235.114'
        $parsed.key | Should -Be 'public-key='
        $parsed.api | Should -Be ''
        $parsed.relay | Should -Be '100.105.235.114:21117'
    }
}

Describe 'Install-RustDesk' {
    It 'uses the documented silent-install switch and rejects nonzero exit' {
        Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
        Install-RustDesk -InstallerPath 'C:\cache\rustdesk.exe'
        Should -Invoke Start-Process -ParameterFilter { $ArgumentList -contains '--silent-install' -and $Wait }
    }
}
```

- [ ] **Step 2: Run tests and verify failure**

```powershell
Invoke-Pester tests/RustDesk.Tests.ps1 -Output Detailed
```

Expected: FAIL because `RustDesk.psm1` does not exist.

- [ ] **Step 3: Implement config token generation and installation**

Serialize an ordered object with `key`, `host`, `api`, and `relay` using
`ConvertTo-Json -Compress`, UTF-8 encode it, Base64URL encode without padding,
and reverse the resulting characters to match RustDesk's open-source parser.

Install with `--silent-install`, wait for completion, locate
`$env:ProgramFiles\RustDesk\rustdesk.exe`, ensure the `RustDesk` service reaches
`Running`, then apply `--config <token>` from the installed executable.

- [ ] **Step 4: Add password secrecy, existing install, and ID tests**

Mock external invocation and assert that the result/log object omits the
password. Test that an existing installed EXE skips `--silent-install` but
still receives `--config`, and trim/validate `--get-id` output as digits.

- [ ] **Step 5: Run tests and commit**

```powershell
Invoke-Pester tests/RustDesk.Tests.ps1 -Output Detailed
git diff --check
git add src/RustDesk.psm1 tests/RustDesk.Tests.ps1
git commit -m "feat: install and configure RustDesk"
```

Expected: all Task 5 tests PASS.

### Task 6: Orchestration, State, and Failure Ordering

**Files:**
- Create: `src/Installer.Core.psm1`
- Create: `tests/Installer.Core.Tests.ps1`

**Interfaces:**
- Consumes: `PSCustomObject InstallRequest` with `InstallTailscale`, `InstallRustDesk`, `ConnectivityMode`, `RouterIp`, `TailscaleHostname`, `TailscaleAuthKey`, `RustDeskPassword`, and `ConfirmRouteReplacement`.
- Produces: `Test-InstallRequest -Request <PSCustomObject> -> void`; `Invoke-DarckwareInstall -Request <PSCustomObject> -RepoRoot <string> -> PSCustomObject`.

- [ ] **Step 1: Write failing request-matrix and dependency-order tests**

```powershell
BeforeAll { Import-Module "$PSScriptRoot/../src/Installer.Core.psm1" -Force }

Describe 'Test-InstallRequest' {
    It 'rejects no components and missing mode-specific fields' {
        { Test-InstallRequest ([pscustomobject]@{ InstallTailscale=$false; InstallRustDesk=$false }) } | Should -Throw '*component*'
        $route = [pscustomobject]@{ InstallTailscale=$false; InstallRustDesk=$true; ConnectivityMode='Router'; RouterIp='' }
        { Test-InstallRequest $route } | Should -Throw '*router*'
    }
}

Describe 'Invoke-DarckwareInstall' {
    It 'stops before RustDesk when combined Tailscale enrollment fails' {
        Mock Get-InstallerConfig { [pscustomobject]@{ Artifacts=[pscustomobject]@{}; Deployment=[pscustomobject]@{} } }
        Mock Invoke-TailscaleStage { throw 'enrollment failed' }
        Mock Invoke-RustDeskStage {}
        $request = [pscustomobject]@{ InstallTailscale=$true; InstallRustDesk=$true; ConnectivityMode='LocalTailscale'; TailscaleHostname='pc-01'; TailscaleAuthKey=(ConvertTo-SecureString 'secret' -AsPlainText -Force) }
        { Invoke-DarckwareInstall -Request $request -RepoRoot $TestDrive } | Should -Throw '*enrollment failed*'
        Should -Invoke Invoke-RustDeskStage -Times 0
    }
}
```

- [ ] **Step 2: Run tests and verify failure**

```powershell
Invoke-Pester tests/Installer.Core.Tests.ps1 -Output Detailed
```

Expected: FAIL because `Installer.Core.psm1` does not exist.

- [ ] **Step 3: Implement validation, stage ordering, state, and structured results**

Order stages as `Validate -> Prepare state/log -> Tailscale -> Connectivity ->
RustDesk -> Final verification -> Save non-secret state`. For router mode, call
the pure route planner before mutation and require `ConfirmRouteReplacement`
when its action is `Replace`. For combined mode, force `LocalTailscale` and
never call `Set-RustDeskHostRoute`.

Return this stable result shape:

```powershell
[pscustomobject]@{
    Success = $true
    Tailscale = [pscustomobject]@{ Requested=$true; Installed=$true; Connected=$true; RebootRequired=$false }
    RustDesk = [pscustomobject]@{ Requested=$true; Installed=$true; Configured=$true; Id='123456789' }
    Network = [pscustomobject]@{ Mode='LocalTailscale'; RouteAction='None'; PortChecks=@() }
    LogPath = $logPath
}
```

The state JSON may store component versions, managed route destination/gateway,
and timestamps only. Pass every log line through `Protect-LogText`.

- [ ] **Step 4: Add idempotency, route confirmation, and redacted-error tests**

Test rerunning against existing component state, refusing an unmanaged route
conflict, requiring confirmation for a managed replacement, never persisting
secure strings, and redacting a `tskey-` value included in a mocked exception.

- [ ] **Step 5: Run all core tests and commit**

```powershell
Invoke-Pester tests/Artifact.Tests.ps1,tests/Security.Tests.ps1,tests/Network.Tests.ps1,tests/Tailscale.Tests.ps1,tests/RustDesk.Tests.ps1,tests/Installer.Core.Tests.ps1 -Output Detailed
git diff --check
git add src/Installer.Core.psm1 tests/Installer.Core.Tests.ps1
git commit -m "feat: orchestrate selectable installer components"
```

Expected: all core tests PASS.

### Task 7: Branded WinForms Wizard and Entry Points

**Files:**
- Create: `assets/darckware-icon-16.png`
- Create: `assets/darckware-icon-32.png`
- Create: `assets/darckware-icon-128.png`
- Create: `assets/darckware-icon-512.png`
- Create: `assets/darckware-lockup-dark.svg`
- Create: `assets/darckware-lockup-light.svg`
- Create: `src/Installer.UI.psm1`
- Create: `install.ps1`
- Create: `install.cmd`
- Create: `tests/Installer.UI.Tests.ps1`
- Create: `tests/Install.EntryPoint.Tests.ps1`

**Interfaces:**
- Consumes: validation/orchestration functions from `Installer.Core.psm1`.
- Produces: `Show-InstallerWizard -Config <PSCustomObject> -> InstallRequest`; `Show-InstallResult -Result <PSCustomObject> -> void`; process exit codes `0` success, `1` operational failure, `2` invalid input, `1223` UAC cancellation.

- [ ] **Step 1: Copy the approved Darckware assets**

Copy exact existing assets from `/root/project/darckware/docs/marca/` into
`assets/`; do not redraw or recolor them:

```bash
cp /root/project/darckware/docs/marca/png/darckware-icon-{16,32,128,512}.png assets/
cp /root/project/darckware/docs/marca/darckware-lockup-{dark,light}.svg assets/
```

- [ ] **Step 2: Write failing UI-state and entry-point tests**

Keep WinForms rendering behind functions so tests cover state transitions
without opening windows:

```powershell
Describe 'Get-WizardPageState' {
    It 'shows Tailscale fields only when selected' {
        $state = Get-WizardPageState -InstallTailscale $true -InstallRustDesk $false -TailscaleConnected $false
        $state.ShowTailscaleFields | Should -BeTrue
        $state.ShowConnectivityFields | Should -BeFalse
    }
    It 'asks for routing only for RustDesk without local Tailscale' {
        $state = Get-WizardPageState -InstallTailscale $false -InstallRustDesk $true -TailscaleConnected $false
        $state.ShowConnectivityFields | Should -BeTrue
    }
}

Describe 'install.ps1 contract' {
    It 'does not define plain-text secret parameters' {
        $content = Get-Content "$PSScriptRoot/../install.ps1" -Raw
        $content | Should -Not -Match '\[string\]\s*\$(TailscaleAuthKey|RustDeskPassword)'
        $content | Should -Match 'TailscaleAuthKeyFile'
        $content | Should -Match 'RustDeskPasswordFile'
    }
}
```

- [ ] **Step 3: Run tests and verify failure**

```powershell
Invoke-Pester tests/Installer.UI.Tests.ps1,tests/Install.EntryPoint.Tests.ps1 -Output Detailed
```

Expected: FAIL because the UI and entry points do not exist.

- [ ] **Step 4: Implement the wizard and launcher**

Use system fonts, Darckware colors `#0B0D10`, `#12151A`, `#5CF2C4`, and
`#3DAEFF`, and the provided assets. The auth-key and password text boxes must
use `UseSystemPasswordChar = $true`. The confirmation page shows only whether a
secret was supplied. Disable Next until the current page validates.

`install.ps1` imports all modules relative to `$PSScriptRoot`, self-elevates
while preserving only non-secret file-path parameters, and supports:

```powershell
param(
    [switch]$InstallTailscale,
    [switch]$InstallRustDesk,
    [ValidateSet('Auto','LocalTailscale','Router')][string]$ConnectivityMode = 'Auto',
    [string]$RouterIp,
    [string]$TailscaleHostname,
    [string]$TailscaleAuthKeyFile,
    [string]$RustDeskPasswordFile,
    [switch]$NonInteractive,
    [switch]$ConfirmRouteReplacement
)
```

`install.cmd` contains only:

```batch
@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
exit /b %ERRORLEVEL%
```

- [ ] **Step 5: Run UI/entry tests and commit**

```powershell
Invoke-Pester tests/Installer.UI.Tests.ps1,tests/Install.EntryPoint.Tests.ps1 -Output Detailed
git diff --check
git add assets src/Installer.UI.psm1 install.ps1 install.cmd tests/Installer.UI.Tests.ps1 tests/Install.EntryPoint.Tests.ps1
git commit -m "feat: add Darckware installation wizard"
```

Expected: all Task 7 tests PASS and the wizard opens on Windows 11 without
starting installation until confirmation.

### Task 8: Public Documentation, CI, and Release Verification

**Files:**
- Create: `README.md`
- Create: `LICENSE`
- Create: `THIRD_PARTY_NOTICES.md`
- Create: `docs/router-prerequisites.md`
- Create: `docs/troubleshooting.md`
- Create: `.github/workflows/windows-tests.yml`
- Create: `tests/Repository.Tests.ps1`

**Interfaces:**
- Consumes: completed repository entry points and module test suite.
- Produces: documented clone/install/recovery workflow and automated Windows verification.

- [ ] **Step 1: Write failing repository-completeness and secret-scan tests**

```powershell
Describe 'public repository contract' {
    It 'contains required operator documentation and assets' {
        @('README.md','LICENSE','THIRD_PARTY_NOTICES.md','docs/router-prerequisites.md','docs/troubleshooting.md','assets/darckware-icon-512.png') | ForEach-Object {
            Test-Path (Join-Path $PSScriptRoot '..' $_) | Should -BeTrue
        }
    }
    It 'contains no committed Tailscale auth key' {
        $tracked = git -C "$PSScriptRoot/.." ls-files
        foreach ($file in $tracked) {
            if (Test-Path "$PSScriptRoot/../$file" -PathType Leaf) {
                (Get-Content "$PSScriptRoot/../$file" -Raw -ErrorAction SilentlyContinue) | Should -Not -Match 'tskey-(auth|client)-[A-Za-z0-9_-]{10,}'
            }
        }
    }
}
```

- [ ] **Step 2: Run the repository test and verify failure**

```powershell
Invoke-Pester tests/Repository.Tests.ps1 -Output Detailed
```

Expected: FAIL because public documentation and CI files are missing.

- [ ] **Step 3: Write operator documentation and attribution**

README must include these exact primary workflows:

```powershell
git clone https://github.com/marcelodarckferreira/rustdesk-darckware.git
cd rustdesk-darckware
.\install.cmd
```

Document GitHub ZIP fallback, UAC, three component choices, one-off
pre-approved Tailscale auth keys, hostname rules, route-mode prerequisites,
log location, rerun behavior, uninstall boundaries, and the statement that
vendor binaries are downloaded from and signed by their respective vendors.

License Darckware-authored scripts under the MIT License and preserve vendor
notices in `THIRD_PARTY_NOTICES.md`; do not imply that MIT relicenses either
vendor binary. Link to RustDesk's AGPL source and Tailscale's package terms.

- [ ] **Step 4: Add Windows CI with pinned Pester and all tests**

```yaml
name: windows-tests
on:
  push:
  pull_request:
permissions:
  contents: read
jobs:
  test:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install Pester
        shell: powershell
        run: Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Force -SkipPublisherCheck
      - name: Run tests
        shell: powershell
        run: Invoke-Pester tests -CI -Output Detailed
```

- [ ] **Step 5: Run the complete automated suite and static checks**

```powershell
Invoke-Pester tests -CI -Output Detailed
git diff --check
git grep -n -E 'tskey-(auth|client)-[A-Za-z0-9_-]{10,}' -- . ':!docs/superpowers/plans/*'
```

Expected: Pester PASS, `git diff --check` exits 0, and the secret grep returns no
matches. The plan itself is excluded because it contains synthetic key-prefix
test strings.

- [ ] **Step 6: Perform Windows 11 VM acceptance tests**

On a clean snapshot, record results for:

```text
1. Tailscale only with a one-off pre-approved key and unique hostname.
2. RustDesk only with an already-connected local Tailscale client.
3. RustDesk only through a prepared router station and persistent /32 route.
4. Tailscale + RustDesk, confirming no static route is created.
5. Invalid auth key, unreachable router, blocked TCP 21116/21117, modified download, and UAC cancellation.
6. A second identical run for each successful mode.
```

Expected: successful modes produce connected components and redacted logs;
negative modes fail before dependent changes; reruns are idempotent.

- [ ] **Step 7: Commit the release-ready repository**

```bash
git add README.md LICENSE THIRD_PARTY_NOTICES.md docs .github tests/Repository.Tests.ps1
git commit -m "docs: publish installer usage and verification"
git status --short
```

Expected: clean worktree after the commit.

### Task 9: Create and Publish the Public GitHub Repository

**Files:**
- Modify: `.git/config` through Git remote commands only.

**Interfaces:**
- Consumes: a refreshed `gh` login for `marcelodarckferreira` and a clean, verified `main` branch.
- Produces: public repository `https://github.com/marcelodarckferreira/rustdesk-darckware` with branch protection-ready CI.

- [ ] **Step 1: Refresh and verify GitHub authentication interactively**

```bash
gh auth refresh -h github.com
gh auth status
```

Expected: account `marcelodarckferreira` is active with repository creation and
push permissions. Never paste a GitHub token into a tracked file or chat log.

- [ ] **Step 2: Re-run final local verification**

```powershell
Invoke-Pester tests -CI -Output Detailed
git status --short
git log --oneline --decorate -10
```

Expected: tests PASS and worktree is clean.

- [ ] **Step 3: Create the public repository and push main**

```bash
gh repo create marcelodarckferreira/rustdesk-darckware --public --source=. --remote=origin --push --description "Instalador Darckware para Tailscale e RustDesk no Windows 11"
git remote -v
```

Expected: `origin` points to the public GitHub repository and `main` is pushed.

- [ ] **Step 4: Verify the remote and CI without mutating it**

```bash
gh repo view marcelodarckferreira/rustdesk-darckware --json nameWithOwner,visibility,url,defaultBranchRef
gh run list --repo marcelodarckferreira/rustdesk-darckware --limit 5
```

Expected: visibility is `PUBLIC`, default branch is `main`, and the Windows test
workflow completes successfully before announcing the repository ready.
