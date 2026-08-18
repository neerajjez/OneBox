# Kasm "Visual Studio Code" workspace + an SSH client.
#
# Why this image exists
# --------------------
# kasmweb/vs-code:1.17.0 ships VS Code and the Remote-SSH extension but NOT the
# `ssh` binary the extension shells out to. Remote-SSH fails with:
#
#     Got error from ssh: spawn ssh ENOENT
#     Resolver error: Error: ssh is not on the PATH
#
# You cannot fix that from inside a running session: Kasm starts workspace
# containers with NoNewPrivs=1, so `sudo apt install openssh-client` fails with
# "the 'no new privileges' flag is set". Installing it at build time is the only
# durable route — a `docker exec -u root` install works but dies with the
# session, because Kasm destroys the container on logout.
#
# Build:  docker build -t local/kasm-vs-code:1.17.0-ssh kasm/images/vs-code-ssh
# Rebuild when the Kasm version changes — the FROM tag is pinned deliberately
# (rule 20: never `latest` in anything deployed).
FROM kasmweb/vs-code:1.17.0

USER root

# openssh-client  — the `ssh` binary Remote-SSH needs (this is the whole point)
# ssh-askpass     — lets VS Code prompt for the password in a GUI dialog rather
#                   than a hidden terminal, which is where Remote-SSH otherwise
#                   appears to silently hang on a password-auth host
RUN apt-get update \
 && apt-get install -y --no-install-recommends openssh-client ssh-askpass \
 && apt-get clean \
 && find /var/lib/apt/lists -mindepth 1 -delete

# Kasm workspaces run as uid 1000 (kasm-user). Restore it explicitly — leaving
# the image as root would hand every session container a root desktop.
USER 1000
