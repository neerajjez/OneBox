# xrdp: "works sometimes, needs a service restart"

Diagnosed and fixed 2026-08-16.

## The symptom

The RDP login screen appears, the password is accepted, and then the session
closes immediately. Restarting `xrdp` makes it work again — for a while.

## The cause

Two settings combined into a trap.

**1. Disconnected sessions lived forever.**

```
KillDisconnected=false
DisconnectedTimeLimit=0     # 0 = never
```

A session that ended badly — client crash, network drop, laptop closed — left
its `Xorg`, `xfce4-session` and `xrdp-chansrv` running indefinitely. One such
session was found still running from **Aug 15 07:57**, over a day old, holding
`/tmp/.X10-lock` and `/tmp/.X11-unix/X10`.

**2. `Policy=Default` matches on screen geometry.**

`Default` reconnects a user to an existing session only if the *bpp and display
size also match*. Connect from a differently-sized Remmina window and xrdp
creates a **new** session instead of reconnecting.

Together: the new session starts, `xfce4-session` finds the orphan's D-Bus and
SSH agent already registered for that user, refuses to start a second instance,
and exits. `sesman` sees the window manager exit and tears the session down —
about one second after a correct password.

The smoking gun in `/var/log/xrdp-sesman.log`:

```
13:48:21 Session started successfully for user prodadmin on display 11
13:48:21 Session in progress on display 11, waiting until the window manager (pid 570354) exits
13:48:22 Calling auth_stop_session and auth_end from pid 570352
```

and in `~/.xsession-errors`:

```
xfce4-session-Message: SSH authentication agent is already running
gpg-agent: a gpg-agent is already running - not starting a new one
```

Restarting xrdp "fixed" it only because the restart killed the orphans.

## The fix

**`/etc/xrdp/sesman.ini`** (mirrored in `host/xrdp/sesman.ini`):

| Setting | Was | Now | Why |
|---|---|---|---|
| `Policy` | `Default` | **`UB`** | Reconnect the same user to their session regardless of window size. xorgxrdp resizes dynamically, so geometry does not need to match. |
| `KillDisconnected` | `false` | **`true`** | Bound how long a dead session can linger. |
| `DisconnectedTimeLimit` | `0` | **`86400`** | Reap after a day — long enough that reconnecting the next morning still works, short enough that a broken session cannot persist forever. |

`IdleTimeLimit` stays `0`: an *idle* session is not a *broken* one, and killing
long-running work because someone stepped away would be its own bug.

**`/etc/xrdp/startwm.sh`** gains a guard that removes stale X locks whose `Xorg`
is genuinely dead. It skips `$DISPLAY`, so it cannot harm the session starting
it. Verified against a live display: it correctly refused to touch the current
one and cleaned only the dead.

## Monitoring

`scripts/kasm-probe.sh` now exports:

- `xrdp_sessions` — live X servers
- `xrdp_orphan_locks` — stale locks with no matching `Xorg`

`XrdpOrphanedSessions` alerts when orphans persist for 15 minutes, so this
surfaces before someone hits a failed login rather than after.

## If it happens again

```bash
sudo tail -40 /var/log/xrdp-sesman.log        # does the WM exit right after start?
tail -30 ~/.xsession-errors                   # what the WM said before dying
ps -eo pid,lstart,cmd | grep -E 'Xorg :1|xfce4-session'   # orphans, with start times
ls -la /tmp/.X*-lock /tmp/.X11-unix/          # stale locks
```

Reaping by hand is `kill` on the orphan pids and removing the matching lock and
socket. If that is ever needed again, the guard or the timeout did not work —
investigate rather than just clearing it.
