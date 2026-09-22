# RustDesk Darckware Installer Design

Date: 2026-09-22

## Objective

Create a public Windows 11 deployment repository named
`marcelodarckferreira/rustdesk-darckware`. An operator clones the repository and
runs one elevated entry point to install Tailscale, RustDesk, or both. The
installer carries Darckware branding, configures the fixed private RustDesk
server, and supports clients that reach the tailnet through an existing
Tailscale router instead of installing Tailscale locally.

The first release brands the installer and deployment experience. It installs
the official signed RustDesk client; changing the RustDesk application's own
name, icons, and interface is a separate future project requiring a maintained
source fork, Windows builds, code signing, and AGPL compliance work.

## Supported Environment

- Windows 11 x86-64.
- Windows PowerShell 5.1 or PowerShell 7.
- An administrator account and outbound HTTPS access for downloading pinned
  installers.
- Git for the primary clone workflow. GitHub's source ZIP is the documented
  fallback when Git is unavailable.

Windows 10, Windows Server, ARM64, offline installation, Intune, and GPO
packaging are outside the first release.

## Repository and Distribution

The local working copy lives at `/root/project/rustdesk/installwin11`; the
intended public remote is
`https://github.com/marcelodarckferreira/rustdesk-darckware`.

The repository contains scripts, tests, Darckware assets, documentation, and a
machine-readable artifact manifest. Vendor binaries are not committed. The
installer downloads them from official HTTPS release endpoints and verifies
their pinned SHA-256 values before execution.

The initial artifact pins are:

- RustDesk `1.4.9`, x86-64 EXE, from the official GitHub release.
- Tailscale `1.102.3`, x86-64 MSI, from the official stable package server.

Changing a dependency requires an explicit manifest update, checksum update,
and a test run. The installer never follows a `latest` URL.

## User Experience

`install.cmd` is the human-facing entry point. It launches `install.ps1`, which
self-elevates once through UAC and presents a WinForms wizard with Darckware
branding. The wizard contains:

1. A component page with independent checkboxes for **Tailscale** and
   **RustDesk**. At least one must be selected.
2. A Tailscale page, shown when Tailscale is selected, requesting the hostname
   and auth key.
3. A RustDesk connectivity page, shown when RustDesk is selected and the
   installer will not establish a local Tailscale connection. It offers use of
   an already-connected local Tailscale client or a Tailscale-router route. The
   route choice requests the router's LAN IPv4 address.
4. An optional unattended-access page. The operator can enter and confirm a
   permanent RustDesk password or leave it unset.
5. A confirmation page that never displays the Tailscale auth key or RustDesk
   password.
6. A progress page and a final report containing component status, network
   mode, connectivity checks, and the RustDesk ID when RustDesk was installed.

The same engine supports non-interactive command-line parameters for testing
and managed deployment. Secret values may be supplied only through secure
process input or protected temporary files, not ordinary command-line
arguments.

## Installation Flows

### Tailscale only

1. Validate the hostname and auth-key presence.
2. Download and verify the pinned Tailscale MSI.
3. Install it silently with unattended mode enabled.
4. Store the auth key in a uniquely named temporary file whose ACL grants only
   Administrators and SYSTEM access.
5. Run `tailscale up` with `--auth-key=file:<path>`, the requested
   `--hostname`, and `--unattended=true`.
6. Remove the temporary key file in a `finally` block.
7. Confirm that Tailscale reports a connected backend state and an assigned
   tailnet IP.

### RustDesk only with existing local Tailscale

1. Confirm that Tailscale is installed, connected, and can reach the fixed
   RustDesk server.
2. Download, verify, and silently install RustDesk.
3. Apply the fixed server configuration and optional permanent password.
4. Ensure the RustDesk service is running and report its ID.

### RustDesk only through a Tailscale router

1. Validate the entered router address as an IPv4 address reachable through an
   active local interface.
2. Create or reconcile a persistent host route for
   `100.105.235.114/32` through that router. The installer does not redirect the
   complete `100.64.0.0/10` CGNAT range.
3. Test TCP ports `21116` and `21117` on the RustDesk server. UDP `21116` is not
   treated as verified by this TCP-only preflight.
4. Download, verify, and silently install RustDesk.
5. Apply the fixed server configuration and optional permanent password.
6. Ensure the service is running and report its ID.

The router station itself is an external prerequisite: it must be connected to
both the client's LAN and Tailscale, forward LAN traffic to Tailscale, provide
the return path or source NAT, and allow the traffic in its firewall and
tailnet policy.

### Tailscale and RustDesk

Install and validate Tailscale first, then install RustDesk using the local
Tailscale connection. Do not create a static route through another station in
this mode.

## RustDesk Configuration

The deployment uses these fixed values:

- ID server: `100.105.235.114`
- Relay server: `100.105.235.114:21117`
- Public key: read from a committed deployment configuration file populated
  from the server's `data/id_ed25519.pub`; the private key is never copied.
- API server: unset because this deployment uses RustDesk Server OSS.

The script installs the client before applying configuration with the supported
elevated RustDesk command-line interface. It generates the documented config
string deterministically from the fixed host, relay, and public key, applies it
with `rustdesk.exe --config`, and verifies the resulting settings where the CLI
permits. If a permanent password was supplied, it is passed to
`rustdesk.exe --password` without logging the value.

## Structure

```text
install.cmd
install.ps1
README.md
LICENSE
config/
  artifacts.json
  deployment.json
assets/
  darckware-icon-*.png
  darckware-lockup-*.svg
src/
  Installer.UI.psm1
  Installer.Core.psm1
  Network.psm1
  RustDesk.psm1
  Tailscale.psm1
tests/
  Installer.Core.Tests.ps1
  Network.Tests.ps1
  RustDesk.Tests.ps1
  Tailscale.Tests.ps1
docs/
  router-prerequisites.md
  troubleshooting.md
```

The UI module only gathers validated input and displays progress. The core
module owns orchestration. Component and network modules expose small,
independently testable functions and do not depend on WinForms.

## Idempotency and Existing Installations

Rerunning the installer is supported:

- A matching or newer installed Tailscale version is reused; authentication is
  changed only when the operator explicitly selects Tailscale and supplies a
  key.
- RustDesk is reconfigured even when version 1.4.9 is already installed.
- A static host route with the expected destination and gateway is reused. A
  route to the same destination with another gateway is replaced only after
  the confirmation page shows the change.
- Selecting local Tailscale removes only the route previously managed by this
  installer, identified by destination plus a state record. It does not delete
  unrelated routes.

The installer stores non-secret state under
`%ProgramData%\Darckware\RustDeskInstaller\state.json` and logs under the same
directory.

## Security

- Never commit, persist in state, or write to logs a Tailscale auth key or
  RustDesk password.
- Recommend one-off, pre-approved Tailscale auth keys with least-privilege tags.
- Create the temporary auth-key file with restrictive ACLs and remove it in all
  success and failure paths.
- Redact values matching Tailscale key prefixes and all secret-bearing fields
  before writing structured logs.
- Require HTTPS and an exact SHA-256 match before running downloaded artifacts.
- Validate that downloaded Windows binaries have a valid Authenticode
  signature and the expected publisher in addition to checking SHA-256.
- Use explicit argument arrays rather than constructing shell command strings
  from operator input.
- Accept only a conservative hostname syntax and valid IPv4 addresses.

The RustDesk public key and tailnet server IP are configuration, not secrets.

## Failure Handling

Each stage fails closed with a human-readable error and a nonzero exit code.
The installer does not run an artifact after a checksum or signature failure.
It always removes secret temporary files. If route creation succeeds but the
subsequent RustDesk installation fails, the route remains because it is an
explicit requested network configuration; the final report explains that
state and provides a removal command. Component failures stop dependent work:
if selected Tailscale installation or connection fails, RustDesk installation
does not continue in the combined mode.

Logs include timestamps, selected non-secret options, versions, exit codes,
and redacted diagnostic output. The final page links to the log and relevant
troubleshooting section.

## Testing and Verification

Pester unit tests cover:

- component-selection rules;
- IPv4 and hostname validation;
- artifact manifest parsing and checksum enforcement;
- RustDesk config-string generation;
- route reconciliation decisions;
- command construction without exposing secrets;
- log redaction;
- idempotent behavior for existing installations.

Windows 11 VM acceptance tests cover all four useful selections: Tailscale
only, RustDesk through existing Tailscale, RustDesk through a router, and both
components. Negative tests cover an invalid auth key, unreachable router,
blocked server ports, bad checksum, failed UAC elevation, and rerunning the
installer.

Linux-side static verification checks PowerShell syntax where tooling permits,
JSON validity, expected asset presence, absence of committed secret patterns,
and documentation commands. A real Windows 11 VM is required before the first
release is called production-ready.

## Publication

The repository is initialized and developed locally first. Publishing requires
refreshing the expired GitHub CLI authentication for `marcelodarckferreira`.
The initial public release includes the source, test results, dependency
versions and hashes, and clear attribution to RustDesk and Tailscale. It does
not claim that Darckware authored or signed either vendor binary.

