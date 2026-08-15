# Codex Telegram waker

The optional Codex Telegram waker gives a queued Telegram Relay request an external path into a currently idle Firstmate Codex primary.
It is a local transport nudge, not a Relay consumer or decision maker.
The primary remains the only process that runs the canonical Relay poll and response workflow, and captain decisions remain unanswered until the captain decides them.

## Supported scope

The waker deliberately supports one configuration:

- Linux with user systemd and `/proc`.
- A Firstmate primary running the Codex harness.
- That primary running in one uniquely identifiable tmux pane whose current path is the exact `FM_HOME`.
- A currently locked primary whose inherited tmux control socket is available when the waker is installed.
- An existing append-only Telegram bridge log containing `queued <request-id>` and `offered <request-id>` records.

The fixed user-unit names intentionally allow only one installed primary-home binding per operating-system user.

Claude, OpenCode, Pi, pi-signed, Grok, Kimi, and Muse are not applicable because the process binding accepts only an exact Codex session-lock owner.
Muse is additionally not a supported Firstmate primary harness.
Herdr, Zellij, Orca, and cmux are not applicable because this lifecycle accepts only the tmux pane bound through the lock owner's tty and inherited `TMUX` socket.
Codex App is not applicable because it is not a selectable Firstmate runtime backend.

## Install

Run the tracked installer with an explicit absolute path to the existing bridge log:

```sh
FM_HOME=/absolute/path/to/firstmate \
  bin/fm-codex-telegram-waker.sh install \
  --bridge-log /absolute/path/to/firstmate-telegram/bridge.log
```

The installer verifies the currently locked primary and records its exact inherited tmux control-socket pathname before atomically writing `firstmate-codex-telegram-waker.path` and `firstmate-codex-telegram-waker.service` under `${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user`, reloading user systemd, and enabling the path unit.
It does not start a service or type into that current primary, so the path unit still watches a future change to `state/.lock`.
Future primary lock changes on that same socket path start the service.
If a future primary uses a different tmux socket path, rerun `install` while that primary is locked to replace the owned units with its new exact socket binding.

The service reads the log without modifying it.
It never invokes `fm-x-poll.sh`, `/connector/poll`, a reply command, or a network client.
Its systemd sandbox grants write-namespace access only to the containing directory of the exact inherited tmux control socket required for that binding, allows Unix-domain sockets for tmux, and denies IP networking.

## Runtime contract

At startup the service requires the lock PID to exist under `/proc`, verifies its process identity and exact Codex executable shape, reads that process's controlling tty and inherited tmux socket, and requires exactly one matching live pane.
It also requires that pane's current path to resolve to the exact `FM_HOME`.
It exits without typing when any of those facts is missing, changed, dead, or ambiguous.

The private state at `state/codex-telegram-waker/state` atomically stores the bridge device, inode, byte cursor, queue order, unresolved request IDs, and last injection attempt.
A partial final log line is not consumed.
A rotated, replaced, or truncated log fails closed and requires an explicit reinstall after the operator resolves the log identity.

For each unresolved ID, the service reuses the tmux delivery busy classifier, shared composer classifier, and verified type-once submit primitive.
Busy, pending, pending-unproven, unknown, and unreadable panes all defer.
Only a confirmed-empty Codex composer receives the fixed `watcher` operational input.
The request remains pending after a confirmed submit and is retried until its matching `offered <request-id>` record appears.
A different request's `offered` record cannot clear it.

The path and service units provide the user-systemd singleton, and a read-only lock on `state/codex-telegram-waker/` provides a second portable single-process boundary without creating a writable lock file.
The service exits cleanly when the bound primary process dies, changes identity, changes tty, loses its exact pane, leaves the exact home, or no longer owns `state/.lock`.

## Liveness

A PID from a prior process listing is not liveness evidence by itself.
Claim the waker is live only when its current service PID exists under `/proc/<pid>` and the dedicated beat advances across two observations:

```sh
pid=$(systemctl --user show firstmate-codex-telegram-waker.service \
  --property MainPID --value)
test -d "/proc/$pid"
first=$(cat "$FM_HOME/state/codex-telegram-waker/beat")
sleep 3
second=$(cat "$FM_HOME/state/codex-telegram-waker/beat")
test "$first" != "$second"
```

`bin/fm-codex-telegram-waker.sh status` performs the same `/proc` plus advancing-beat check and otherwise prints `runtime: not proven live`.

## Uninstall

Remove the lifecycle with the same `FM_HOME` used for installation:

```sh
FM_HOME=/absolute/path/to/firstmate \
  bin/fm-codex-telegram-waker.sh uninstall
```

Uninstall refuses a colliding unit that lacks the script's ownership marker or names a different home.
It stops and removes only the two named user units and `state/codex-telegram-waker`, then reloads user systemd.
It does not modify the Telegram bridge, Relay inbox or queue, other units, credentials, projects, or fleet state.

[`verification/supervision.md`](verification/supervision.md#codex-telegram-waker) records the active regression entry point and supported-axis evidence.
