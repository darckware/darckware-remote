<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/darckware-lockup-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="assets/darckware-lockup-light.svg">
    <img src="assets/darckware-lockup-light.svg" alt="Darckware" width="430">
  </picture>
</p>

# Darckware Remote

Assisted installer to prepare Windows 11 workstations with **Tailscale**, **RustDesk**, or both components. Darckware Remote downloads the official installers, validates the SHA-256 hash, Authenticode signature, and publisher before running them, configures the RustDesk client for Darckware's private infrastructure, and records a local report with no credentials.

> The installer carries Darckware's identity, but installs the official RustDesk and Tailscale clients. It does not alter these applications' internal branding and does not include third-party binaries in the repository.

The binaries are downloaded from the official channels and signed by their respective vendors; the installer also validates the hash pinned in the manifest before running them.

## What it does

- installs Tailscale `1.102.3` in unattended mode and connects the workstation to the tailnet;
- installs RustDesk `1.4.9` and configures Darckware's private ID and relay servers;
- allows access to RustDesk via a local Tailscale or via a router station on the LAN;
- in router mode, creates only one persistent `/32` route to the authorized server;
- tests TCP ports `21116` and `21117` before installing RustDesk through the router;
- optionally allows configuring a permanent RustDesk password;
- supports re-running: existing components are reused and RustDesk is reconfigured;
- writes state and logs without storing the Tailscale key or the RustDesk password.

## Requirements

- Windows 11 x86-64;
- account with administrator permission;
- Windows PowerShell 5.1 or PowerShell 7;
- HTTPS access to the official RustDesk and Tailscale endpoints;
- Git, or access to the ZIP download from GitHub;
- for router mode, a workstation previously prepared according to [Router prerequisites](docs/router-prerequisites.md).

## Quick install

Open **Command Prompt** or **PowerShell** and run:

```powershell
git clone https://github.com/marcelodarckferreira/rustdesk-darckware.git
cd rustdesk-darckware
.\install.cmd
```

Windows will request elevation via UAC. Confirm only if the path shown matches the cloned repository.

### Without Git

1. Open the repository page on GitHub.
2. Select **Code > Download ZIP**.
3. Extract the entire ZIP to a local folder.
4. Double-click `install.cmd`.
5. Confirm the UAC prompt.

Do not run `install.cmd` directly from inside the ZIP.

## Available choices

| Selection | Result |
|---|---|
| Tailscale | Installs and connects only the Tailscale client. |
| RustDesk | Installs RustDesk using an already-connected local Tailscale or a router station. |
| Tailscale + RustDesk | Connects Tailscale first and only then installs/configures RustDesk. Does not create a static route. |

### Tailscale authentication key

Use a **one-off** key, pre-approved and with the minimum necessary tags. Avoid reusable keys. The hostname must:

- be 1 to 63 characters long;
- use only ASCII letters, numbers, and hyphens;
- start and end with a letter or number;
- not contain spaces, dots, or commands.

The key entered through the interface is kept as a secure value and delivered to Tailscale via a protected temporary file. It is removed even when enrollment fails.

## Non-interactive installation

Secrets are not accepted directly on the command line. Each secret file must contain only the value, have an ACL restricted to Administrators/SYSTEM, and be removed by the deployment system after the process finishes.

### Tailscale

```powershell
.\install.ps1 -NonInteractive `
  -InstallTailscale `
  -TailscaleHostname 'cliente-loja-01' `
  -TailscaleAuthKeyFile 'C:\Secure\tailscale-auth-key.txt'
```

### RustDesk with local Tailscale

```powershell
.\install.ps1 -NonInteractive `
  -InstallRustDesk `
  -ConnectivityMode LocalTailscale `
  -RustDeskPasswordFile 'C:\Secure\rustdesk-password.txt'
```

`-RustDeskPasswordFile` is optional.

### RustDesk via router station

```powershell
.\install.ps1 -NonInteractive `
  -InstallRustDesk `
  -ConnectivityMode Router `
  -RouterIp '192.168.1.10' `
  -ConfirmRouteReplacement
```

The confirmation parameter authorizes only the replacement of a route previously registered as managed by Darckware Remote. Conflicting unmanaged routes are preserved and cause a safe failure.

### Tailscale and RustDesk

```powershell
.\install.ps1 -NonInteractive `
  -InstallTailscale `
  -InstallRustDesk `
  -TailscaleHostname 'cliente-loja-01' `
  -TailscaleAuthKeyFile 'C:\Secure\tailscale-auth-key.txt' `
  -RustDeskPasswordFile 'C:\Secure\rustdesk-password.txt'
```

## Exit codes

| Code | Meaning |
|---:|---|
| `0` | installation completed |
| `1` | operational failure |
| `2` | invalid input |
| `1223` | UAC cancelled or wizard cancelled |

## Security and verification

Before running an installer, Darckware Remote requires:

1. official HTTPS URL and pinned version;
2. SHA-256 hash identical to the manifest;
3. valid Authenticode signature;
4. expected publisher in the certificate.

A mismatch stops the flow before `msiexec.exe` or the RustDesk executable. Keys and passwords are not written to state, result, or log. Downloaded binaries stay out of Git.

## Logs and state

Operational files are located at:

```text
%ProgramData%\Darckware\RustDeskInstaller\
```

- `installer.log`: steps and errors with secrets redacted;
- `state.json`: versions, timestamp, and any managed route;
- `downloads\`: local cache of verified installers.

See [Troubleshooting](docs/troubleshooting.md) for diagnostics and recovery.

## Re-running and removal

The installer is idempotent within the documented scope:

- an already-connected Tailscale installation is reused;
- an existing RustDesk installation receives the fixed configuration again;
- an identical `/32` route is reused;
- a divergent managed route is only replaced after confirmation;
- when using local Tailscale, only the route previously registered as managed is removed.

Darckware Remote **is not an uninstaller**. Remove RustDesk or Tailscale via **Settings > Apps > Installed apps**. Before manually removing a route, confirm the destination, gateway, and interface as described in the troubleshooting guide.

## Validation status

The repository contains Pester tests and CI for Windows. An acceptance run on a clean Windows 11 VM is still required before classifying a version as production-ready. The checklist is in [Windows 11 Acceptance](docs/windows-11-acceptance.md).

## Licenses

The scripts produced by Darckware are licensed under MIT; see [LICENSE](LICENSE). RustDesk and Tailscale maintain their own licenses, trademarks, signatures, and terms. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

This project does not claim that Darckware created or signed the third-party binaries.
