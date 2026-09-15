#!/usr/bin/env python3
"""Recover local Spotify playback after a Bluetooth A2DP transport failure.

Some multipoint headsets leave PipeWire's sink in RUNNING state after another
paired computer temporarily takes audio, while BlueZ's actual media transport
stays idle. A blocked PulseAudio write can also stall librespot controls.

This helper runs only alongside the plugin's on-demand playback unit. It parks
audio on a silent sink, verifies that the player command queue responds, and
rebuilds the selected A2DP profile only if the real BlueZ transport stays idle.
"""

from __future__ import annotations

import fcntl
import json
import os
import re
import selectors
import signal
import subprocess
import sys
import time
from typing import Any

PLAYER_UNITS = ("omarchy-spotify.service", "omarchy-spotifyd.service")
STAGING_PREFIX = "omarchy_spotify_bt_recovery_"
TRANSPORT_ERROR = b"Failure in Bluetooth audio transport"
stopping = False


def log(message: str) -> None:
    print(message, flush=True)


def command(args: list[str], *, timeout: float = 4, check: bool = True) -> str:
    result = subprocess.run(
        args, capture_output=True, text=True, timeout=timeout, check=check
    )
    return result.stdout.strip()


def pactl(*args: object) -> str:
    return command(["/usr/bin/pactl", *map(str, args)])


def user_busctl(*args: object) -> str:
    return command(
        ["/usr/bin/busctl", "--user", "--timeout=2", *map(str, args)],
        timeout=3,
    )


def system_busctl(*args: object, check: bool = True) -> str:
    return command(
        ["/usr/bin/busctl", "--system", "--timeout=2", *map(str, args)],
        timeout=3,
        check=check,
    )


def listing(kind: str) -> list[dict[str, Any]]:
    return json.loads(pactl("-f", "json", "list", kind))


def player_pids() -> set[str]:
    result = set()
    for unit in PLAYER_UNITS:
        output = command(
            [
                "/usr/bin/systemctl",
                "--user",
                "show",
                unit,
                "--property=MainPID",
                "--value",
            ],
            check=False,
        )
        result.update(
            value for value in output.split() if value.isdigit() and value != "0"
        )
    return result


def bluetooth_sink(sink: dict[str, Any]) -> bool:
    props = sink.get("properties", {})
    return (
        props.get("device.api") == "bluez5"
        and props.get("api.bluez5.profile") == "a2dp-sink"
        and bool(props.get("api.bluez5.address"))
    )


def player_candidates(
    sinks: list[dict[str, Any]], streams: list[dict[str, Any]]
) -> list[tuple[dict[str, Any], dict[str, Any]]]:
    active_pids = player_pids()
    sinks_by_index = {sink["index"]: sink for sink in sinks}
    result = []
    for stream in streams:
        sink = sinks_by_index.get(stream.get("sink"))
        props = stream.get("properties", {})
        if (
            sink
            and bluetooth_sink(sink)
            and not stream.get("corked", True)
            and str(props.get("application.process.id", "")) in active_pids
        ):
            result.append((stream, sink))
    return result


def mpris_service(stream: dict[str, Any]) -> str | None:
    pid = str(stream.get("properties", {}).get("application.process.id", ""))
    if not pid.isdigit():
        return None
    suffix = "instance" + pid
    for line in user_busctl("list", "--no-pager").splitlines():
        fields = line.split()
        name = fields[0] if fields else ""
        if name.startswith("org.mpris.MediaPlayer2.") and name.endswith(suffix):
            return name
    return None


def playback_status(service: str) -> str:
    value = user_busctl(
        "get-property",
        service,
        "/org/mpris/MediaPlayer2",
        "org.mpris.MediaPlayer2.Player",
        "PlaybackStatus",
    )
    return value.removeprefix('s "').removesuffix('"')


def player_action(service: str, action: str) -> None:
    user_busctl(
        "call",
        service,
        "/org/mpris/MediaPlayer2",
        "org.mpris.MediaPlayer2.Player",
        action,
    )


def release_player_control(stream: dict[str, Any]) -> str | None:
    """Drain a blocked audio write and prove transport commands work again."""
    service = mpris_service(stream)
    if service is None or playback_status(service) != "Playing":
        return None
    try:
        player_action(service, "Pause")
        for _ in range(20):
            time.sleep(0.1)
            if playback_status(service) == "Paused":
                return service
        raise subprocess.TimeoutExpired("Spotify Pause", 2)
    except Exception:
        try:
            player_action(service, "Play")
        except Exception:
            pass
        raise


def staging_name(address: str) -> str:
    return STAGING_PREFIX + address.lower().replace(":", "_")


def staging_address(name: str) -> str | None:
    suffix = name.removeprefix(STAGING_PREFIX)
    if name == suffix or not re.fullmatch(r"[0-9a-f]{2}(?:_[0-9a-f]{2}){5}", suffix):
        return None
    return suffix.replace("_", ":").upper()


def sink_for_address(
    sinks: list[dict[str, Any]], address: str
) -> dict[str, Any] | None:
    return next(
        (
            sink
            for sink in sinks
            if bluetooth_sink(sink)
            and str(
                sink.get("properties", {}).get("api.bluez5.address", "")
            ).upper()
            == address.upper()
        ),
        None,
    )


def restore_staging(sinks: list[dict[str, Any]]) -> bool:
    """Restore streams parked by this helper, including after its own restart."""
    clean = True
    for staging in [s for s in sinks if s.get("name", "").startswith(STAGING_PREFIX)]:
        address = staging_address(staging["name"])
        target = sink_for_address(sinks, address) if address else None
        streams = [s for s in listing("sink-inputs") if s["sink"] == staging["index"]]
        if streams and target is None:
            clean = False
            continue
        for stream in streams:
            try:
                pactl("move-sink-input", stream["index"], target["name"])
            except subprocess.CalledProcessError:
                pass
        if any(s["sink"] == staging["index"] for s in listing("sink-inputs")):
            clean = False
        else:
            pactl("unload-module", staging["owner_module"])
    return clean


def transport_active(sink: dict[str, Any]) -> bool:
    device_path = sink.get("properties", {}).get("api.bluez5.path", "")
    if not device_path:
        return False
    paths = system_busctl("tree", "org.bluez", "--list").splitlines()
    transports = [
        path
        for path in paths
        if path.startswith(device_path + "/sep") and "/fd" in path
    ]
    for path in transports:
        state = system_busctl(
            "get-property",
            "org.bluez",
            path,
            "org.bluez.MediaTransport1",
            "State",
            check=False,
        )
        if state == 's "active"':
            return True
    return False


def wait_for_sink(address: str) -> dict[str, Any] | None:
    for _ in range(30):
        sink = sink_for_address(listing("sinks"), address)
        if sink is not None:
            return sink
        time.sleep(0.1)
    return None


def rebuild_a2dp_profile(sink: dict[str, Any]) -> None:
    props = sink.get("properties", {})
    card_name = props.get("device.name", "")
    address = props.get("api.bluez5.address", "")
    card = next((item for item in listing("cards") if item.get("name") == card_name), None)
    profile = card.get("active_profile") if card else None
    if not card_name or not address or not str(profile).startswith("a2dp-sink"):
        raise RuntimeError("Bluetooth A2DP profile is unavailable")
    try:
        pactl("set-card-profile", card_name, "off")
        time.sleep(0.5)
    finally:
        pactl("set-card-profile", card_name, profile)
    if wait_for_sink(address) is None:
        raise RuntimeError("Bluetooth A2DP sink did not return")
    log(f"Rebuilt A2DP profile for {props.get('device.description', address)}")


def recover(*, force: bool = False, rebuild: bool = False) -> bool:
    """Return true once playback is healthy or has intentionally stopped."""
    sinks = listing("sinks")
    if not restore_staging(sinks):
        return False
    streams = listing("sink-inputs")
    candidates = player_candidates(sinks, streams)
    if not candidates:
        return True

    player_stream, sink = candidates[0]
    if not force and sink["state"] == "RUNNING" and transport_active(sink):
        return True

    address = sink["properties"]["api.bluez5.address"]
    staging_sink_name = staging_name(address)
    default_sink = pactl("get-default-sink")
    module = pactl(
        "load-module",
        "module-null-sink",
        "sink_name=" + staging_sink_name,
        "sink_properties=device.description=Omarchy-Spotify-Bluetooth-Recovery",
    )
    staging = None
    moved: list[int] = []
    players_to_resume: list[str] = []
    try:
        try:
            staging = next(
                s for s in listing("sinks") if s["name"] == staging_sink_name
            )
            affected_sink_index = sink["index"]
            for stream in streams:
                if stream.get("sink") != affected_sink_index:
                    continue
                try:
                    pactl("move-sink-input", stream["index"], staging_sink_name)
                    moved.append(stream["index"])
                except subprocess.CalledProcessError:
                    pass
            time.sleep(0.35)
            if player_stream["index"] in moved:
                service = release_player_control(player_stream)
                if service:
                    players_to_resume.append(service)
            if rebuild and not transport_active(sink):
                rebuild_a2dp_profile(sink)
            log("Re-linking stalled Bluetooth playback without restarting Spotify")
        finally:
            current_sinks = listing("sinks")
            target = sink_for_address(current_sinks, address)
            remaining = {s["index"]: s for s in listing("sink-inputs")}
            for index in moved:
                stream = remaining.get(index)
                if stream and staging and stream["sink"] == staging["index"] and target:
                    try:
                        pactl("move-sink-input", index, target["name"])
                    except subprocess.CalledProcessError:
                        pass
            if target and default_sink == sink["name"]:
                pactl("set-default-sink", target["name"])
            remaining = [
                stream
                for stream in listing("sink-inputs")
                if staging and stream["sink"] == staging["index"]
            ]
            if not remaining:
                pactl("unload-module", module)
            else:
                log("Bluetooth output disappeared; retaining silent recovery sink")
    finally:
        for service in players_to_resume:
            player_action(service, "Play")
    return False


def stop(_signum: int, _frame: object) -> None:
    global stopping
    stopping = True


def main() -> int:
    runtime = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    runtime = os.path.join(runtime, "omarchy-spotify-bluetooth-recovery")
    os.makedirs(runtime, mode=0o700, exist_ok=True)
    with open(os.path.join(runtime, "instance.lock"), "w", encoding="utf-8") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            log("Another Bluetooth recovery instance is already running")
            return 0

        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGINT, stop)
        monitor = subprocess.Popen(
            [
                "/usr/bin/journalctl",
                "--user",
                "--follow",
                "--unit=wireplumber",
                "--since=now",
                "--output=cat",
                "--no-pager",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        selector = selectors.DefaultSelector()
        selector.register(monitor.stdout, selectors.EVENT_READ)
        pending = time.monotonic() + 1.0
        force_recovery = False
        attempts = 0
        buffer = b""
        log("Watching Bluetooth audio transport errors")
        try:
            while not stopping:
                for key, _ in selector.select(timeout=0.25):
                    chunk = os.read(key.fd, 65536)
                    if not chunk:
                        if stopping:
                            break
                        raise RuntimeError("Audio journal monitor exited")
                    buffer += chunk
                    while b"\n" in buffer:
                        line, buffer = buffer.split(b"\n", 1)
                        if TRANSPORT_ERROR in line:
                            if pending is None:
                                pending = time.monotonic() + 1.0
                                attempts = 0
                            force_recovery = True
                            log("Bluetooth transport interrupted; checking playback")
                if pending is not None and time.monotonic() >= pending:
                    try:
                        healthy = recover(
                            force=force_recovery,
                            rebuild=attempts > 0,
                        )
                    except (
                        subprocess.SubprocessError,
                        ValueError,
                        OSError,
                        RuntimeError,
                        LookupError,
                    ) as error:
                        log("Recovery attempt failed: " + type(error).__name__)
                        healthy = False
                    if healthy:
                        log("Bluetooth playback running or intentionally stopped")
                        pending = None
                        force_recovery = False
                    else:
                        attempts += 1
                        force_recovery = False
                        pending = time.monotonic() + min(2 ** min(attempts, 5), 30)
        finally:
            selector.close()
            monitor.terminate()
            try:
                monitor.wait(timeout=5)
            except subprocess.TimeoutExpired:
                monitor.kill()
                monitor.wait(timeout=2)
            try:
                restore_staging(listing("sinks"))
            except (subprocess.SubprocessError, ValueError, OSError):
                log("Could not remove recovery sink during shutdown")
    return 0


if __name__ == "__main__":
    sys.exit(main())
