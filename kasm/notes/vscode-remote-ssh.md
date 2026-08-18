# VS Code Remote-SSH from a Kasm workspace to this host

Diagnosed 2026-08-16.

## The symptom

In the Kasm "Visual Studio Code" workspace, connecting to `ssh-remote+172.20.0.1`
fails immediately:

```
Got error from ssh: spawn ssh ENOENT
Finding installed ssh failed: ssh is not on the PATH
Resolver error: Error: ssh is not on the PATH
```

and in the workspace terminal, `sudo apt install openssh-client` also fails.

## The cause — two separate things

**1. `kasmweb/vs-code:1.17.0` has no `ssh` binary.**

The image ships VS Code and the Remote-SSH *extension*, but the extension is
only a wrapper: it shells out to a real `ssh` client. There isn't one.

```
$ ls /usr/bin/ssh*
ls: cannot access '/usr/bin/ssh*': No such file or directory
```

**2. You cannot install it from inside a session.**

```
sudo: The "no new privileges" flag is set, which prevents sudo from running as root.
```

Kasm starts workspace containers with `NoNewPrivs=1`, so `sudo` can never
escalate — regardless of the sudoers file. This is Kasm's own default, not
something this project configured; `docker inspect` shows `SecurityOpt=[]` while
`/proc/1/status` shows `NoNewPrivs: 1`.

It is a *good* default and should not be removed. It means workspace software
must be baked into the image.

### Ruled out

- **Network.** `curl http://archive.ubuntu.com/...` from the workspace returns
  `200` over IPv4. apt is not blocked. (DNS returns AAAA records first and the
  host has no IPv6 egress, but the fallback to IPv4 works.)
- **Firewall / sshd.** Once `ssh` exists, it connects on the first try:
  `prodadmin@172.20.0.1: Permission denied (publickey,password)` — that is sshd
  answering and asking for credentials, i.e. the whole path works. `iptables`
  already permits `172.20.0.0/16 → 22`, and `sshd_config` has
  `Match User prodadmin Address 172.20.0.0/16,100.64.0.0/10` allowing password auth
  from exactly this subnet.

## The fix

`kasm/images/vs-code-ssh/Dockerfile` — `FROM kasmweb/vs-code:1.17.0` plus
`openssh-client` and `ssh-askpass`, dropping back to `USER 1000`.

```bash
docker build -t local/kasm-vs-code:1.17.0-ssh kasm/images/vs-code-ssh
```

Then register it in Kasm as a **new** workspace (Admin → Workspaces → Add):

| Field | Value |
|---|---|
| Friendly Name | `Visual Studio Code (SSH)` |
| Docker Image | `local/kasm-vs-code:1.17.0-ssh` |
| Docker Registry | *(blank — the image is local, never pulled)* |
| Cores / Memory | same as the stock VS Code workspace |
| Group | whichever groups already had VS Code |

Add it as a new entry rather than editing the stock one: if a local image ever
fails to provision, the untouched `kasmweb/vs-code:1.17.0` entry is the rollback
and needs no repair.

A pre-change dump of the `images` and `group_images` tables lives in
`/mnt/data/backups/kasm-db-images-*.sql`.

## Stop-gap for a session already running

Works immediately, dies when the session is destroyed — Kasm removes the
container on logout:

```bash
docker exec -u 0 <workspace-container> \
  apt-get update -qq && apt-get install -y -qq openssh-client
```

Use it to test; do not rely on it.

## Known rough edge — nothing in `$HOME` persists

`persistent_profile_path` is unset on every image, so each session starts with a
fresh home directory. Consequences for SSH specifically:

- `~/.ssh/known_hosts` resets, so the host-key prompt appears every session.
- A key generated inside a workspace is gone at logout — so this is
  **password auth every time** unless persistence is enabled.

If that becomes annoying, set a persistent profile path on the workspace (same
Add/Edit dialog). Then `~/.ssh` survives, and an `ssh-copy-id` to `prodadmin@172.20.0.1`
once makes every later connection key-based — which is also strictly better than
typing the account password into a container.

## Connecting

Host `172.20.0.1`, user `prodadmin`. That address is the gateway of
`kasm_default_network`; it is how a workspace reaches the host it runs on. It is
not routable from anywhere else, which is the point.

Remote-SSH will download the VS Code server to `~/.vscode-server` on the **host**
on first connect — the host has IPv4 egress, so that succeeds.
