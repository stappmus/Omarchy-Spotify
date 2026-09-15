#!/usr/bin/env python3

import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/bluetooth-audio-recovery.py"
SPEC = importlib.util.spec_from_file_location("bluetooth_audio_recovery", SCRIPT)
recovery = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(recovery)


ADDRESS = "02:11:22:33:44:55"


def sink(state="SUSPENDED", address=ADDRESS):
    return {
        "index": 7,
        "name": "bt_sink",
        "state": state,
        "properties": {
            "device.api": "bluez5",
            "api.bluez5.profile": "a2dp-sink",
            "api.bluez5.address": address,
            "api.bluez5.path": "/org/bluez/hci0/dev_02_11_22_33_44_55",
            "device.name": "bluez_card.02_11_22_33_44_55",
            "device.description": "Test headset",
        },
    }


def stream(index=9, target=7, pid="123", corked=False):
    return {
        "index": index,
        "sink": target,
        "corked": corked,
        "properties": {"application.process.id": pid},
    }


class RecoveryTests(unittest.TestCase):
    def test_staging_name_round_trip(self):
        name = recovery.staging_name(ADDRESS)
        self.assertEqual(recovery.staging_address(name), ADDRESS)
        self.assertIsNone(recovery.staging_address("unrelated_sink"))
        self.assertIsNone(recovery.staging_address(recovery.STAGING_PREFIX + "invalid"))

    def test_candidates_require_a_live_plugin_pid_and_a2dp(self):
        device = sink()
        items = [stream(), stream(index=10, pid="456"), stream(index=11, corked=True)]
        with patch.object(recovery, "player_pids", return_value={"123"}):
            self.assertEqual(recovery.player_candidates([device], items), [(items[0], device)])
        device["properties"]["api.bluez5.profile"] = "headset-head-unit"
        with patch.object(recovery, "player_pids", return_value={"123"}):
            self.assertEqual(recovery.player_candidates([device], items), [])

    def test_real_bluez_state_is_required_for_healthy_playback(self):
        device = sink("RUNNING")
        item = stream()
        with patch.object(recovery, "listing", side_effect=lambda kind: [device] if kind == "sinks" else [item]), \
             patch.object(recovery, "restore_staging", return_value=True), \
             patch.object(recovery, "player_candidates", return_value=[(item, device)]), \
             patch.object(recovery, "transport_active", return_value=True), \
             patch.object(recovery, "pactl") as command:
            self.assertTrue(recovery.recover())
            command.assert_not_called()

    def test_force_ignores_pipewire_running_claim(self):
        device = sink("RUNNING")
        item = stream()
        with patch.object(recovery, "listing", side_effect=lambda kind: [device] if kind == "sinks" else [item]), \
             patch.object(recovery, "restore_staging", return_value=True), \
             patch.object(recovery, "player_candidates", return_value=[(item, device)]), \
             patch.object(recovery, "pactl", side_effect=RuntimeError("recovery started")):
            with self.assertRaisesRegex(RuntimeError, "recovery started"):
                recovery.recover(force=True)

    def run_recovery(self, *, rebuild=False, during_wait=None):
        devices = [sink()]
        streams = [stream(), stream(index=10, pid="unrelated")]
        commands = []

        def pactl(*args):
            commands.append(args)
            if args[0] == "load-module":
                devices.append(
                    {
                        "index": 11,
                        "name": recovery.staging_name(ADDRESS),
                        "owner_module": 12,
                    }
                )
                return "12"
            if args[0] == "get-default-sink":
                return "bt_sink"
            if args[0] == "move-sink-input":
                target = next(device for device in devices if device["name"] == args[2])
                next(item for item in streams if item["index"] == args[1])["sink"] = target["index"]
            if args[0] == "unload-module":
                self.assertFalse(any(item["sink"] == 11 for item in streams))
                devices[:] = [device for device in devices if device["index"] != 11]
            return ""

        def wait(_duration):
            if during_wait:
                during_wait(devices, streams)

        with patch.object(
            recovery,
            "listing",
            side_effect=lambda kind: devices.copy()
            if kind == "sinks"
            else [item.copy() for item in streams],
        ), patch.object(recovery, "restore_staging", return_value=True), patch.object(
            recovery, "player_pids", return_value={"123"}
        ), patch.object(recovery, "pactl", side_effect=pactl), patch.object(
            recovery, "release_player_control", return_value="mpris.spotify"
        ) as release, patch.object(
            recovery, "transport_active", return_value=False
        ), patch.object(
            recovery, "rebuild_a2dp_profile"
        ) as rebuild_profile, patch.object(
            recovery, "player_action"
        ) as action, patch.object(
            recovery.time, "sleep", side_effect=wait
        ):
            self.assertFalse(recovery.recover(rebuild=rebuild))
        return commands, streams, release, rebuild_profile, action

    def test_recovery_parks_every_stream_on_affected_sink(self):
        commands, streams, release, rebuild, action = self.run_recovery()
        self.assertEqual([item["sink"] for item in streams], [7, 7])
        moved_to_silent = [
            args[1]
            for args in commands
            if args[0] == "move-sink-input" and args[2].startswith(recovery.STAGING_PREFIX)
        ]
        self.assertEqual(moved_to_silent, [9, 10])
        release.assert_called_once()
        action.assert_called_once_with("mpris.spotify", "Play")
        rebuild.assert_not_called()

    def test_second_attempt_rebuilds_a2dp_while_streams_are_silent(self):
        commands, _streams, _release, rebuild, _action = self.run_recovery(rebuild=True)
        rebuild.assert_called_once()
        silent_moves = [args for args in commands if args[0] == "move-sink-input"]
        self.assertTrue(all(args[2].startswith(recovery.STAGING_PREFIX) for args in silent_moves[:2]))

    def test_rebuild_failure_still_restores_playback_state(self):
        device = sink()
        item = stream()
        devices = [device]
        streams = [item]

        def pactl(*args):
            if args[0] == "load-module":
                devices.append(
                    {
                        "index": 11,
                        "name": recovery.staging_name(ADDRESS),
                        "owner_module": 12,
                    }
                )
                return "12"
            if args[0] == "get-default-sink":
                return "bt_sink"
            if args[0] == "move-sink-input":
                target = next(device for device in devices if device["name"] == args[2])
                item["sink"] = target["index"]
            return ""

        with patch.object(
            recovery,
            "listing",
            side_effect=lambda kind: devices.copy()
            if kind == "sinks"
            else [entry.copy() for entry in streams],
        ), patch.object(recovery, "restore_staging", return_value=True), patch.object(
            recovery, "player_pids", return_value={"123"}
        ), patch.object(recovery, "pactl", side_effect=pactl), patch.object(
            recovery, "release_player_control", return_value="mpris.spotify"
        ), patch.object(
            recovery, "transport_active", return_value=False
        ), patch.object(
            recovery,
            "rebuild_a2dp_profile",
            side_effect=RuntimeError("profile failed"),
        ), patch.object(recovery, "player_action") as action, patch.object(
            recovery.time, "sleep"
        ):
            with self.assertRaisesRegex(RuntimeError, "profile failed"):
                recovery.recover(rebuild=True)
        self.assertEqual(item["sink"], 7)
        action.assert_called_once_with("mpris.spotify", "Play")

    def test_user_routing_change_is_respected(self):
        def reroute(_devices, streams):
            streams[0]["sink"] = 99

        _commands, streams, *_ = self.run_recovery(during_wait=reroute)
        self.assertEqual(streams[0]["sink"], 99)

    def test_disappearing_headset_keeps_streams_silent(self):
        def disconnect(devices, _streams):
            devices[:] = [device for device in devices if device["index"] != 7]

        commands, streams, *_ = self.run_recovery(during_wait=disconnect)
        self.assertEqual([item["sink"] for item in streams], [11, 11])
        self.assertFalse(any(args[0] == "unload-module" for args in commands))

    def test_rebuild_preserves_selected_a2dp_codec_profile(self):
        device = sink()
        card = {"name": device["properties"]["device.name"], "active_profile": "a2dp-sink-sbc_xq"}
        with patch.object(recovery, "listing", return_value=[card]), patch.object(
            recovery, "pactl"
        ) as command, patch.object(recovery.time, "sleep"), patch.object(
            recovery, "wait_for_sink", return_value=device
        ):
            recovery.rebuild_a2dp_profile(device)
        self.assertEqual(
            command.call_args_list,
            [
                unittest.mock.call("set-card-profile", card["name"], "off"),
                unittest.mock.call("set-card-profile", card["name"], "a2dp-sink-sbc_xq"),
            ],
        )

    def test_rebuild_restores_profile_if_interrupted_while_off(self):
        device = sink()
        card = {"name": device["properties"]["device.name"], "active_profile": "a2dp-sink-aac"}
        with patch.object(recovery, "listing", return_value=[card]), patch.object(
            recovery, "pactl"
        ) as command, patch.object(
            recovery.time, "sleep", side_effect=RuntimeError("interrupted")
        ):
            with self.assertRaisesRegex(RuntimeError, "interrupted"):
                recovery.rebuild_a2dp_profile(device)
        self.assertEqual(
            command.call_args_list,
            [
                unittest.mock.call("set-card-profile", card["name"], "off"),
                unittest.mock.call("set-card-profile", card["name"], "a2dp-sink-aac"),
            ],
        )

    def test_release_control_confirms_pause_before_resume(self):
        statuses = iter(["Playing", "Playing", "Paused"])
        with patch.object(recovery, "mpris_service", return_value="mpris.spotify"), patch.object(
            recovery, "playback_status", side_effect=lambda _service: next(statuses)
        ), patch.object(recovery, "player_action") as action, patch.object(
            recovery.time, "sleep"
        ):
            self.assertEqual(recovery.release_player_control(stream()), "mpris.spotify")
        action.assert_called_once_with("mpris.spotify", "Pause")

    def test_release_control_resumes_after_confirmation_timeout(self):
        with patch.object(recovery, "mpris_service", return_value="mpris.spotify"), patch.object(
            recovery, "playback_status", return_value="Playing"
        ), patch.object(recovery, "player_action") as action, patch.object(
            recovery.time, "sleep"
        ):
            with self.assertRaises(subprocess.TimeoutExpired):
                recovery.release_player_control(stream())
        self.assertEqual(
            action.call_args_list,
            [
                unittest.mock.call("mpris.spotify", "Pause"),
                unittest.mock.call("mpris.spotify", "Play"),
            ],
        )


if __name__ == "__main__":
    unittest.main()
