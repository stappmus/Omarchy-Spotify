#!/usr/bin/env python3
"""Supervisor for the Omarchy Spotify native playback backend.

The plugin backend (librespot) can hold its Unix socket open yet stop
responding -- a "silent but open" wedge. Because play/pause/volume controls
all travel over that socket, a wedged daemon reads as "stuck" until someone
restarts it manually. This watcher restarts the supervised user unit
`omarchy-spotify.service` when it is ACTIVE but stops answering `ping`.

It only acts when the unit is active, so idle-stops and user stops (which
leave the unit inactive) are never resurrected -- the plugin starts the unit
on demand when playback is wanted.

Scope / known limitation: the watcher rescues the "active but silent" wedge
only. A unit that has fallen into `failed` (e.g. a systemd start-limit-hit)
is deliberately left alone: that is surfaced to the user by the plugin's own
failure classification, and auto-resurrecting a start-limited unit would
fight systemd. Adjust the tuning constants below if broader recovery is
ever wanted.
"""

import json
import os
import socket
import subprocess
import sys
import time

# --- Tuning -------------------------------------------------------------
UNIT = "omarchy-spotify.service"
POLL_SECONDS = 15            # interval between checks
PING_TIMEOUT = 8             # seconds to wait for a pong
CONSECUTIVE_FAILS = 2        # active-but-silent checks before we restart
RESTART_COOLDOWN = 120       # minimum seconds between restarts
BACKOFF_AFTER = 3            # restarts before we slow down
BACKOFF_SLEEP = 300          # seconds to pause after repeated restarts

SOCKET_PATH = f"/run/user/{os.getuid()}/omarchy-spotify/backend.sock"
PING_ID = 1

# --- Helpers ------------------------------------------------------------


def log(message: str) -> None:
    print(f"[omarchy-spotify-watchdog] {message}", flush=True)


def unit_state() -> str:
    """Return the systemd unit's active state, e.g. 'active' or 'inactive'."""
    try:
        out = subprocess.run(
            ["systemctl", "--user", "is-active", UNIT],
            capture_output=True, text=True, timeout=10,
        )
        return (out.stdout or "").strip()
    except Exception:  # noqa: BLE001 - report any failure as non-active
        return "unknown"


def ping_socket() -> bool:
    """Return True if the backend answers a protocol ping within the timeout."""
    if not os.path.exists(SOCKET_PATH):
        return False
    sock = None
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(PING_TIMEOUT)
        sock.connect(SOCKET_PATH)
        sock.sendall(
            (json.dumps({"v": 1, "id": PING_ID, "command": "ping"}) + "\n").encode()
        )
        deadline = time.monotonic() + PING_TIMEOUT
        buf = b""
        while time.monotonic() < deadline:
            sock.settimeout(max(0.1, deadline - time.monotonic()))
            chunk = sock.recv(4096)
            if not chunk:
                return False
            buf += chunk
            for line in buf.decode("utf-8", "replace").splitlines():
                try:
                    msg = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if msg.get("type") == "response" and str(msg.get("id")) == str(PING_ID):
                    return msg.get("ok") is True
        return False
    except (socket.timeout, OSError):
        return False
    except Exception:  # noqa: BLE001 - never let the watcher crash on a bad frame
        return False
    finally:
        if sock is not None:
            try:
                sock.close()
            except Exception:
                pass


def restart_unit() -> None:
    """Bounce the unit, clearing any start-limit so it can recover."""
    try:
        subprocess.run(
            ["systemctl", "--user", "reset-failed", UNIT],
            capture_output=True, text=True, timeout=10,
        )
        subprocess.run(
            ["systemctl", "--user", "restart", UNIT],
            capture_output=True, text=True, timeout=30,
        )
        log(f"restarted {UNIT}")
    except Exception as exc:  # noqa: BLE001 - a failed restart must not kill the watcher
        log(f"restart command failed: {exc}")


# --- Main loop ----------------------------------------------------------

def main() -> int:
    log(f"started (poll {POLL_SECONDS}s, unit {UNIT})")
    consecutive = 0
    restarts = 0
    last_restart = 0.0

    while True:
        time.sleep(POLL_SECONDS)

        # Only supervise an ACTIVE unit. Inactive means idle-stop or a user
        # stop; the plugin owns starting it again, so we never resurrect it.
        if unit_state() != "active":
            consecutive = 0
            restarts = 0
            continue

        if ping_socket():
            consecutive = 0
            restarts = 0
            continue

        # Unit is active but did not answer: count it.
        consecutive += 1
        if consecutive < CONSECUTIVE_FAILS:
            log(f"unit active but silent ({consecutive}/{CONSECUTIVE_FAILS}); will recheck")
            continue

        # Back off if we have restarted too often without a healthy window.
        if restarts >= BACKOFF_AFTER:
            log(f"repeated restarts ({restarts}); backing off {BACKOFF_SLEEP}s")
            time.sleep(BACKOFF_SLEEP)
            consecutive = 0
            continue

        now = time.monotonic()
        if now - last_restart < RESTART_COOLDOWN:
            log("restart on cooldown; will recheck")
            continue

        # Close the check-then-act race: the unit may have been stopped since
        # we sampled it above. Never restart a unit that is no longer active.
        if unit_state() != "active":
            consecutive = 0
            continue

        restarts += 1
        last_restart = now
        consecutive = 0
        log("unit active but not answering ping; restarting backend")
        restart_unit()

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
