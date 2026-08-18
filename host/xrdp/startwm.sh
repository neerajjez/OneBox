#!/bin/sh
# xrdp X session start script (c) 2015, 2017, 2021 mirabilos
# published under The MirOS Licence

# Rely on /etc/pam.d/xrdp-sesman using pam_env to load both
# /etc/environment and /etc/default/locale to initialise the
# locale and the user environment properly.

# --- xrdp robustness: reap stale X state before starting the WM -------------
# Added 2026-08-16. Symptom this fixes: login succeeds, then the session closes
# after ~1s because xfce4-session finds a previous session's D-Bus/agent still
# registered and refuses to start a second instance.
#
# Only touches displays whose Xorg is genuinely DEAD, and never the current
# display ($DISPLAY), so an active session cannot be harmed.
_xrdp_cleanup_stale_displays() {
    _cur="${DISPLAY#:}"; _cur="${_cur%%.*}"
    for _lock in /tmp/.X*-lock; do
        [ -e "$_lock" ] || continue
        _d="${_lock#/tmp/.X}"; _d="${_d%-lock}"
        case "$_d" in (*[!0-9]*|'') continue;; esac
        [ "$_d" = "$_cur" ] && continue
        if ! pgrep -f "Xorg :${_d}\b" >/dev/null 2>&1; then
            rm -f "$_lock" "/tmp/.X11-unix/X${_d}" 2>/dev/null
        fi
    done
}
_xrdp_cleanup_stale_displays

if test -r /etc/profile; then
	. /etc/profile
fi

if test -r ~/.profile; then
	. ~/.profile
fi

test -x /etc/X11/Xsession && exec /etc/X11/Xsession
exec /bin/sh /etc/X11/Xsession
