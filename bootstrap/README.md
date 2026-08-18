# bootstrap-ubuntu.sh

Step 0 for a **fresh** Ubuntu 22.04/24.04 server on OCI (ARM64 or AMD64).
Docker, Tailscale, XFCE + XRDP, hardened SSH, fail2ban, unattended upgrades.

```bash
sudo BOOTSTRAP_PASSWORD='<something-real>' ./bootstrap-ubuntu.sh
```

## Do not run this on a server you are already using

It rewrites `/etc/ssh/sshd_config` and can insert firewall rules. On a live host
that is a lockout risk, not a convenience.

`SAFETY_ABORT_IF_PROVISIONED=true` (default) aborts if the host already looks
provisioned — `/opt/server` exists, more than three containers are running, or a
previous bootstrap drop-in is present. **This machine trips that guard**, which
is intentional.

Before running on anything remote, open a second SSH session and leave it idle.

## Verified behaviour

Tested in a disposable `ubuntu:24.04` container:

| Claim | Result |
|---|---|
| ShellCheck clean at `-S warning` | pass |
| `Match` block is last in `sshd_config` | line 137 of 139 |
| `sshd -t` passes after modification | pass |
| Idempotent across 3 consecutive runs | 1 Match block, 1 of each directive |
| Aborts on a provisioned host | pass |
| Restores backup if `sshd -t` fails | pass — verified by a real failure |

That last row is not theoretical. The first test run failed validation, and the
script restored the backup and refused to restart sshd, exactly as designed.

## Four things baked in that cost real debugging time

**1. The `Match` block must be last.** A `Match` applies to every directive
until the next `Match` or EOF, so anything appended after it silently becomes
conditional. `sshd -T` does **not** print `Match` blocks — the config will look
correct while behaving differently. You cannot audit this with `sshd -T` alone.

**2. UFW does not protect published Docker ports.** Docker writes into the
`DOCKER` chain, evaluated *before* UFW's. `-p 9090:9090` is internet-reachable
with UFW default-deny, and UFW reports it blocked. The script warns about this
rather than pretending otherwise.

**3. XRDP `Policy=Default` matches on window geometry.** Connect from a
differently-sized client and it creates a *second* session; the first session's
D-Bus and ssh-agent are already registered, the new window manager refuses to
start, and the session closes about a second after a correct password. It reads
exactly like an auth failure. Fixed with `Policy=UB` plus reaping disconnected
sessions after 24h.

**4. `sshd -t` needs `/run/sshd`.** systemd creates it via tmpfiles; a fresh
container has no such thing, and validation then fails for a reason that has
nothing to do with your config. The script creates it and prints the real
`sshd -t` output on failure.

## Order of operations

`configure_ssh` runs **last**. If SSH is going to break, everything else should
already be installed — you get a working machine with one broken thing, not a
half-built machine you cannot log into.

`install_docker` runs before `create_user` needs the group, and `create_user`
re-adds the user to `docker` afterwards, so group membership works regardless.

## Configuration

Every flag is `${VAR:-default}`, so override via the environment instead of
editing the file:

```bash
sudo INSTALL_XFCE=false INSTALL_XRDP=false BOOTSTRAP_PASSWORD='...' ./bootstrap-ubuntu.sh
```

Never commit a real password here. `BOOTSTRAP_PASSWORD` exists so you don't
have to. Left at the default, the script warns and forces a change at first
login via `chage -d 0`.

## What it deliberately does not do

- **`tailscale up`** — needs interactive auth or a pre-auth key. Silently
  joining a tailnet is not a bootstrap script's decision. Printed as a next step.
- **Enable UFW** — enabling default-deny over SSH with no allow rule in place
  disconnects you permanently.
- **Reboot** — `AUTO_REBOOT=false` by default.
- **`curl | sh`** — Docker and Tailscale both install from their official APT
  repositories. A shell pipe from the internet into root is not an install
  method, and the repo gets you updates.
