#!/usr/bin/env python3
"""AirChat device tests, organised as one phase per scenario.

Each phase is a launch configuration plus the assertions that belong to it, and each reports its
own result, so a failure names the scenario instead of "the harness failed":

  link         both apps scan; they must find each other, connect and agree on the safety code
  messages     scripted channel and private messages; both sides receive, decrypt and ACK them
  tap          each side taps the first person it sees; both must be asked to compare that person's
               safety code (the interaction the nearby page is built around)
  reopen       the Android app is force-stopped and relaunched; the link must come back
  background   the Android app is sent to the background; a 1:1 message must still arrive, be
               decrypted, and be acknowledged (the foreground service is what makes this work)

Phases run in order; the exit code is non-zero if any of them failed.

Everything a phase knows comes from the heartbeat both apps print once a second:

    AIRCHAT_STATE {"platform":"ios","self":"<32 hex>","status":"scanning","scanning":true,
                   "nearby":1,"links":[{"peer":"<32 hex>","ready":true,"central":false,"mtu":23,
                   "trust":0,"code":"123456"}]}

iOS writes it to stderr, which `devicectl ... process launch --console` captures; Android writes it
to logcat under the tag `AirChat/State`. Device identifiers are discovered, never written down.

Usage
-----
    python3 tools/cross_device_test.py                        # every phase
    python3 tools/cross_device_test.py --phases link,messages  # just these
    python3 tools/cross_device_test.py --reset                 # start with no stored trust
    python3 tools/cross_device_test.py --android-apk <path> --ios-app <path>   # install first

The tap phase clears the stored safety-code verdicts as part of its launch: a code that has already
been confirmed is not offered again, by design, so observing a *first* comparison needs a device with
no verdict - and clearing app data would drop the iOS Bluetooth permission instead.

Exit codes: 0 = all phases passed, 1 = an assertion failed, 2 = environment problem.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from dataclasses import dataclass, field

STATE_MARKER = "AIRCHAT_STATE "
IOS_SELF_TEST = "channel:hi-from-ios,private:secret-from-ios"
ANDROID_SELF_TEST = "channel:hi-from-android,private:secret-from-android"
IOS_EXPECTED = ("hi-from-android", "secret-from-android")
ANDROID_EXPECTED = ("hi-from-ios", "secret-from-ios")
DEFAULT_IOS_BUNDLE = "app.airchat.ios"
DEFAULT_ANDROID_PKG = "com.airchat.app.debug"
DEFAULT_ACTIVITY = "com.airchat.app.MainActivity"
ALL_PHASES = ("link", "messages", "tap", "reopen", "background")

RUNTIME_PERMISSIONS = (
    "android.permission.BLUETOOTH_SCAN",
    "android.permission.BLUETOOTH_CONNECT",
    "android.permission.BLUETOOTH_ADVERTISE",
    "android.permission.POST_NOTIFICATIONS",
)

# A debug scan window is 5 minutes; every phase must be done well inside it.
SCAN_WINDOW_BUDGET = 240


def log(message: str) -> None:
    print(f"[device-test] {message}", flush=True)


def run(command: list[str], timeout: int = 120) -> subprocess.CompletedProcess:
    return subprocess.run(command, capture_output=True, text=True, timeout=timeout)


def require_tool(name: str) -> None:
    if shutil.which(name) is None and not os.path.exists(name):
        log(f"FAIL: required tool not found: {name}")
        sys.exit(2)


# --------------------------------------------------------------------- discovery


def discover_ios_udid() -> str | None:
    """The hardware UDID of the first iPhone, preferring one the Instruments transport can see.

    Deliberately falls back to the "Devices Offline" section: an iPhone can show up there while
    CoreDevice - the transport this harness actually uses to install and launch - reports it as
    available and paired, and refusing to test a usable phone helps nobody.
    """
    try:
        out = run(["xcrun", "xctrace", "list", "devices"]).stdout
    except Exception as error:  # noqa: BLE001 - surfaced to the caller
        log(f"could not list iOS devices: {error}")
        return None

    online: str | None = None
    offline: str | None = None
    section = ""
    for line in out.splitlines():
        if line.startswith("=="):
            section = line
            continue
        if "iPhone" not in line:
            continue
        match = re.search(r"\(([^()]+)\)\s*$", line)
        if not match:
            continue
        if "Offline" in section:
            offline = offline or match.group(1)
        else:
            online = online or match.group(1)

    if online is None and offline is not None:
        log(f"note: the iPhone is only listed under Devices Offline, using it anyway: {offline}")
    return online or offline


def discover_android_serial() -> str | None:
    try:
        out = run(["adb", "devices"]).stdout
    except Exception as error:  # noqa: BLE001
        log(f"could not list Android devices: {error}")
        return None
    for line in out.splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 2 and parts[1] == "device":
            return parts[0]
    return None


def grant_android_permissions(adb: list[str], package: str) -> None:
    """Grants the runtime permissions a fresh install would otherwise wait for.

    Reinstalling drops every runtime permission, after which the system shows a dialog an automated
    run cannot answer. Failures are ignored: POST_NOTIFICATIONS is install-time before Android 13.
    """
    for permission in RUNTIME_PERMISSIONS:
        result = run(adb + ["shell", "pm", "grant", package, permission])
        if result.returncode != 0:
            log(f"note: could not grant {permission} (harmless where it is install-time)")


# ----------------------------------------------------------------- state parsing


def latest_state(path: str, platform: str) -> dict | None:
    """The most recent heartbeat for one platform, or None if there is not one yet."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            text = handle.read()
    except FileNotFoundError:
        return None
    found = None
    for line in text.splitlines():
        index = line.find(STATE_MARKER)
        if index < 0:
            continue
        try:
            candidate = json.loads(line[index + len(STATE_MARKER):])
        except json.JSONDecodeError:
            continue
        if candidate.get("platform") == platform:
            found = candidate
    return found


def ready_state(state: dict | None) -> dict | None:
    if not state:
        return None
    for link in state.get("links", []):
        if link.get("ready"):
            return link
    return None


def spec_delivered(path: str, spec: str) -> bool:
    """True once the app's log shows it received the scripted send verbatim."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            return f"selftest spec received: {spec}" in handle.read()
    except FileNotFoundError:
        return False


def describe(state: dict | None) -> str:
    if state is None:
        return "no heartbeat (app not running, or it crashed)"
    links = state.get("links", [])
    summary = ", ".join(
        f"peer={link.get('peer')} ready={link.get('ready')} central={link.get('central')}"
        for link in links
    ) or "none"
    return (
        f"status={state.get('status')} scanning={state.get('scanning')} "
        f"nearby={state.get('nearby')} links=[{summary}]"
    )


def diagnose(ios: dict | None, android: dict | None) -> list[str]:
    """Turns the observed state into concrete next steps."""
    hints: list[str] = []
    for name, state in (("iOS", ios), ("Android", android)):
        if state is None:
            hints.append(f"{name}: app is not running or produced no heartbeat - relaunch it.")
            continue
        status = state.get("status")
        if status == "permissionmissing":
            hints.append(f"{name}: Bluetooth permission missing - grant it in the app.")
        elif status == "bluetoothunavailable":
            hints.append(f"{name}: Bluetooth is off or unsupported - turn it on.")
        elif status == "failed":
            hints.append(f"{name}: transport reported a failure - check the app's log screen.")
        elif status in ("idle", "stopped") and state.get("nearby", 0) == 0:
            hints.append(f"{name}: not scanning. A scan is a user action; the debug hooks start one.")

    ios_nearby = (ios or {}).get("nearby", 0)
    android_nearby = (android or {}).get("nearby", 0)
    if ios and android:
        if ios_nearby == 0 and android_nearby == 0:
            hints.append(
                "Neither side sees any advertisement. Keep BOTH apps in the foreground and press "
                "\u300c\u626b\u63cf\u300d on at least one of them: scanning is a user action, and iOS only advertises "
                "its service UUID where other devices can match it while frontmost."
            )
        elif android_nearby == 0:
            hints.append(
                "Android sees nothing while iOS does: the iPhone may be backgrounded/locked, or its "
                "advertisement is not reaching the Android radio."
            )
        elif ios_nearby == 0:
            hints.append(
                "iOS sees nothing while Android does: check that the Android app is in the "
                "foreground and that its advertising actually started."
            )
        elif not ready_state(ios) or not ready_state(android):
            hints.append(
                "Both sides see each other but no link became ready. The GATT connection or the "
                "HELLO handshake is not completing - see docs/protocol.md sections 5 and 6."
            )
    return hints


# ------------------------------------------------------------------- assertions


def check_link(ios: dict | None, android: dict | None) -> list[str]:
    """The invariants every phase depends on: one link each, pointing at each other, same code."""
    failures: list[str] = []
    ios_link = ready_state(ios)
    android_link = ready_state(android)
    if ios_link is None or android_link is None:
        return ["no READY link on one or both sides"]
    if ios_link.get("peer") != (android or {}).get("self"):
        failures.append(
            f"iOS is linked to {ios_link.get('peer')} but Android's device id is "
            f"{(android or {}).get('self')}"
        )
    if android_link.get("peer") != (ios or {}).get("self"):
        failures.append(
            f"Android is linked to {android_link.get('peer')} but iOS's device id is "
            f"{(ios or {}).get('self')}"
        )
    if ios_link.get("central") == android_link.get("central"):
        failures.append("central/peripheral roles are not mirrored")
    ios_code, android_code = ios_link.get("code"), android_link.get("code")
    if not ios_code or not android_code:
        failures.append("a side did not derive a safety code")
    elif ios_code != android_code:
        failures.append(
            f"safety codes disagree (iOS {ios_code} vs Android {android_code}) - one peer, two "
            "handshakes, or two crypto implementations that do not agree; see docs/protocol.md "
            "section 10"
        )
    return failures


# ----------------------------------------------------------------------- phases


@dataclass
class Outcome:
    name: str
    failures: list[str] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not self.failures


class DeviceEnv:
    """One pair of phones: launching, logging and state reading for every phase."""

    def __init__(self, args: argparse.Namespace, ios_udid: str, android_serial: str) -> None:
        self.args = args
        self.ios_udid = ios_udid
        self.android_serial = android_serial
        self.adb = ["adb", "-s", android_serial]
        os.makedirs(args.work_dir, exist_ok=True)

    # -- launching ---------------------------------------------------------

    def launch_ios(self, tag: str, env: dict[str, str]) -> tuple[subprocess.Popen, str]:
        """Starts the iOS app with `--console`, which streams its output until it exits.

        Always a background process: `--console` blocks, so it can never be run synchronously.
        """
        path = os.path.join(self.args.work_dir, f"{tag}-ios.log")
        open(path, "w").close()
        process = subprocess.Popen(
            ["xcrun", "devicectl", "device", "process", "launch", "--console",
             "--terminate-existing", "--device", self.ios_udid,
             "-e", json.dumps(env), self.args.ios_bundle],
            stdout=open(path, "w"), stderr=subprocess.STDOUT, text=True,
        )
        return process, path

    def start_android(self, args: list[str], tag: str) -> tuple[subprocess.Popen, str]:
        """Clears logcat, starts streaming it, then launches the activity.

        The stream starts before the app so no heartbeat of the new run is missed, and the file is
        new so a phase can only ever observe the run it started - a stale "ready" line from a
        previous run is exactly what would make a recovery test pass without recovering.
        """
        path = os.path.join(self.args.work_dir, f"{tag}-android.log")
        run(self.adb + ["logcat", "-c"])
        open(path, "w").close()
        process = subprocess.Popen(
            self.adb + ["logcat", "-v", "brief"],
            stdout=open(path, "w"), stderr=subprocess.STDOUT, text=True,
        )
        result = run(self.adb + ["shell", "am", "start", "-n",
                                 f"{self.args.android_package}/{self.args.android_activity}"] + args)
        started = "Starting:" in (result.stdout or "") + (result.stderr or "")
        if not started:
            # A launch that quietly does nothing is the difference between "the app is broken" and
            # "the app never ran" - and the second one leaves no trace in the log it never wrote.
            log(
                "  WARNING: am start did not report Starting: "
                + (result.stdout or result.stderr or "no output").strip().splitlines()[0]
            )
        return process, path

    #: Every phase forgets stored safety-code verdicts before it starts.
    #:
    #: A verdict is a user decision - and a REJECTED one deliberately blocks 1:1 sending - so a
    #: phone that was used to reject a peer earlier would fail the messaging phase for a reason that
    #: has nothing to do with the code under test. Clearing them needs no reinstall, which would also
    #: drop the Bluetooth permission and stall the run on a system dialog.
    CLEAR_TRUST_IOS = {"AIRCHAT_CLEAR_TRUST": "1"}
    CLEAR_TRUST_ANDROID = ["--ez", "airchat_clear_trust", "true"]

    def restart_both(self, tag: str, ios_env: dict[str, str], android_args: list[str]):
        run(self.adb + ["shell", "am", "force-stop", self.args.android_package])
        ios_process, ios_log = self.launch_ios(tag, {**ios_env, **self.CLEAR_TRUST_IOS})
        android_process, android_log = self.start_android(
            android_args + self.CLEAR_TRUST_ANDROID, tag
        )
        return ios_process, android_process, ios_log, android_log

    def stop(self, handles) -> None:
        """Terminates whatever in `handles` is a live process.

        Callers pass the tuples the launch helpers return, which also carry log paths; skipping
        anything without a `poll()` keeps those call sites readable.
        """
        for handle in handles:
            if handle is None or not hasattr(handle, "poll") or handle.poll() is not None:
                continue
            handle.send_signal(signal.SIGTERM)
            try:
                handle.wait(timeout=10)
            except subprocess.TimeoutExpired:
                handle.kill()

    # -- observation -------------------------------------------------------

    def states(self, ios_log: str, android_log: str) -> tuple[dict | None, dict | None]:
        return latest_state(ios_log, "ios"), latest_state(android_log, "android")

    def wait_for(
        self,
        ios_log: str,
        android_log: str,
        condition,
        description: str,
        timeout: int,
        poll: float = 2.0,
    ) -> tuple[dict | None, dict | None, bool]:
        deadline = time.time() + timeout
        ios = android = None
        while time.time() < deadline:
            ios_new, android_new = self.states(ios_log, android_log)
            ios = ios_new or ios
            android = android_new or android
            if condition(ios, android):
                time.sleep(1.0)  # let the last heartbeat reflect the settled state
                ios_new, android_new = self.states(ios_log, android_log)
                return ios_new or ios, android_new or android, True
            time.sleep(poll)
        log(f"  timed out after {timeout}s waiting for: {description}")
        if ios is None:
            log("  iOS produced no heartbeat at all - it never ran, or it crashed")
        if android is None:
            log("  Android produced no heartbeat at all - it never ran, or it crashed")
        return ios, android, False


# -- phases ------------------------------------------------------------------


def phase_link(env: DeviceEnv) -> Outcome:
    """Discovery, connection and safety-code agreement, with nothing else going on."""
    outcome = Outcome("link")
    processes = env.restart_both(
        "link",
        ios_env={"AIRCHAT_SCAN": "1"},
        android_args=["--ez", "airchat_scan", "true"],
    )
    try:
        ios, android, ok = env.wait_for(
            processes[2], processes[3],
            lambda i, a: ready_state(i) is not None and ready_state(a) is not None,
            "both sides to have a READY link",
            min(env.args.timeout, SCAN_WINDOW_BUDGET),
        )
    finally:
        env.stop(processes)

    if not ok:
        outcome.failures.append("the link never became ready (a scan is a user action; see hints)")
    outcome.failures += check_link(ios, android)
    if not outcome.failures:
        link = ready_state(ios)
        outcome.notes.append(f"safety code {link.get('code')} on both platforms")
    return outcome


def phase_messages(env: DeviceEnv) -> Outcome:
    """The scripted payload path: channel post, private message, delivery ack."""
    outcome = Outcome("messages")
    processes = env.restart_both(
        "messages",
        ios_env={"AIRCHAT_SELFTEST": IOS_SELF_TEST},
        android_args=["--es", "airchat_selftest", ANDROID_SELF_TEST],
    )
    ios_log, android_log = processes[2], processes[3]
    try:
        def complete(ios, android) -> bool:
            return all(
                state is not None
                and state.get("channel", 0) >= 1
                and state.get("private", 0) >= 1
                and state.get("delivered", 0) >= 1
                for state in (ios, android)
            )

        ios, android, ok = env.wait_for(
            ios_log, android_log, complete, "the scripted exchange to finish", env.args.timeout
        )
    finally:
        env.stop(processes)

    # Checked first: a script that did not arrive intact explains every downstream "message never
    # arrived" symptom, and costs a whole round to re-diagnose otherwise.
    if not spec_delivered(ios_log, IOS_SELF_TEST):
        outcome.failures.append("iOS did not receive the full self-test script")
    if not spec_delivered(android_log, ANDROID_SELF_TEST):
        outcome.failures.append(
            "Android did not receive the full self-test script - `adb shell` truncates an intent "
            "extra at an unquoted '|', so keep the step separator shell-safe"
        )
    if not ok:
        outcome.failures.append("the scripted exchange did not complete in time")
    outcome.failures += check_link(ios, android)

    for state, expected, name in (
        (ios, IOS_EXPECTED, "iOS"),
        (android, ANDROID_EXPECTED, "Android"),
    ):
        channel_text, private_text = expected
        if (state or {}).get("channel", 0) < 1:
            outcome.failures.append(f"{name} received no channel post")
        elif state.get("lastChannel") != channel_text:
            outcome.failures.append(
                f"{name} channel text mismatch: {state.get('lastChannel')!r} != {channel_text!r}"
            )
        if (state or {}).get("private", 0) < 1:
            outcome.failures.append(f"{name} received no private message")
        elif state.get("lastPrivate") != private_text:
            outcome.failures.append(
                f"{name} private text mismatch: {state.get('lastPrivate')!r} != {private_text!r}"
            )
        if (state or {}).get("delivered", 0) < 1:
            outcome.failures.append(f"{name} never received a delivery ACK for its own message")
    if not outcome.failures:
        outcome.notes.append("channel, private message and delivery acks verified in both directions")
    return outcome


def phase_tap(env: DeviceEnv) -> Outcome:
    """Tapping the first nearby person: the connection and the safety-code prompt."""
    outcome = Outcome("tap")
    processes = env.restart_both(
        "tap",
        ios_env={"AIRCHAT_CONNECT_FIRST": "1"},
        android_args=["--ez", "airchat_connect_first", "true"],
    )
    try:
        ios, android, ok = env.wait_for(
            processes[2], processes[3],
            lambda i, a: (
                ready_state(i) is not None
                and ready_state(a) is not None
                and (i or {}).get("verifyPrompts", 0) >= 1
                and (a or {}).get("verifyPrompts", 0) >= 1
            ),
            "both sides to be linked and asked to verify a safety code",
            min(env.args.timeout, SCAN_WINDOW_BUDGET),
        )
    finally:
        env.stop(processes)

    if not ok:
        for state, name in ((ios, "iOS"), (android, "Android")):
            if (state or {}).get("verifyPrompts", 0) < 1:
                outcome.failures.append(
                    f"{name} was never asked to verify a safety code - the tap did not reach the node"
                )
    outcome.failures += check_link(ios, android)
    if not outcome.failures:
        outcome.notes.append(
            f"verify prompts: iOS={ios.get('verifyPrompts')}, Android={android.get('verifyPrompts')}"
        )
    return outcome


def phase_reopen(env: DeviceEnv) -> Outcome:
    """Cold start recovery: kill the Android app outright and see the link come back."""
    outcome = Outcome("reopen")
    ios_process, android_process, ios_log, android_log = env.restart_both(
        "reopen-before",
        ios_env={"AIRCHAT_SCAN": "1"},
        android_args=["--ez", "airchat_scan", "true"],
    )
    android_restart_process = None
    try:
        ios, android, ok = env.wait_for(
            ios_log, android_log,
            lambda i, a: ready_state(i) is not None and ready_state(a) is not None,
            "the initial link",
            min(env.args.timeout, SCAN_WINDOW_BUDGET),
        )
        if not ok:
            outcome.failures.append("no link to recover from - the initial connection failed")
            return outcome

        peer = ready_state(android).get("peer")
        started = time.time()
        # A fresh Android log, so the wait below cannot be satisfied by the pre-restart heartbeat.
        android_process.terminate()
        android_restart_process, android_log = env.start_android(
            ["--ez", "airchat_scan", "true"], "reopen-after"
        )
        ios2, android2, back = env.wait_for(
            ios_log, android_log,
            lambda i, a: (
                ready_state(i) is not None
                and ready_state(a) is not None
                and ready_state(a).get("peer") == peer
            ),
            "the link to be re-established after the Android app restarted",
            min(env.args.timeout, SCAN_WINDOW_BUDGET),
        )
        if not back:
            outcome.failures.append("the link did not come back after the Android app restarted")
        else:
            outcome.notes.append(f"recovered in {time.time() - started:.0f}s to the same peer")
        outcome.failures += check_link(ios2, android2)
    finally:
        env.stop((ios_process, android_process, android_restart_process))
    return outcome


def phase_background(env: DeviceEnv) -> Outcome:
    """The Android app is backgrounded; a 1:1 message must still arrive, arrive readable, and be acked."""
    outcome = Outcome("background")
    ios_process, android_process, ios_log, android_log = env.restart_both(
        "background",
        ios_env={"AIRCHAT_SCAN": "1"},
        android_args=["--ez", "airchat_scan", "true"],
    )
    send_process = None
    try:
        ios, android, ok = env.wait_for(
            ios_log, android_log,
            lambda i, a: ready_state(i) is not None and ready_state(a) is not None,
            "the initial link",
            min(env.args.timeout, SCAN_WINDOW_BUDGET),
        )
        if not ok:
            outcome.failures.append("no link to test the background case with")
            return outcome

        # HOME, not force-stop: this is the case the foreground service has to survive.
        run(env.adb + ["shell", "input", "keyevent", "KEYCODE_HOME"])
        time.sleep(3)
        focus = run(env.adb + ["shell", "dumpsys", "window"]).stdout
        resumed = next((line for line in focus.splitlines() if "mCurrentFocus" in line), "?")
        outcome.notes.append(f"Android focus after HOME: {resumed.split('u0 ')[-1].strip()[:60]}")

        # The iOS side sends, because the Android side has nothing scripted to send: this measures
        # whether a backgrounded Android app still receives, decrypts and acknowledges.
        send_process, ios_log = env.launch_ios(
            "background-send", {"AIRCHAT_SELFTEST": IOS_SELF_TEST}
        )
        ios2, android2, received = env.wait_for(
            ios_log, android_log,
            lambda i, a: (
                (a or {}).get("private", 0) >= 1
                and (a or {}).get("channel", 0) >= 1
                and (i or {}).get("delivered", 0) >= 1
            ),
            "the backgrounded Android app to receive and acknowledge",
            env.args.timeout,
        )
        if not received:
            outcome.failures.append(
                "a backgrounded Android app did not receive and acknowledge the message - the "
                "foreground service is what should keep the link alive"
            )
        else:
            outcome.notes.append(
                f"Android (background) got {android2.get('lastPrivate')!r} and iOS got the ack"
            )
            # The iOS side is the one that sends in this phase, so this is the text it sent.
            expected_text = IOS_SELF_TEST.split("private:")[1]
            if (android2 or {}).get("lastPrivate") != expected_text:
                outcome.failures.append(
                    f"Android decrypted {android2.get('lastPrivate')!r} while backgrounded, expected "
                    f"{expected_text!r}"
                )
        outcome.failures += check_link(ios2, android2)
    finally:
        env.stop((ios_process, android_process, send_process))
    return outcome


PHASES = {
    "link": phase_link,
    "messages": phase_messages,
    "tap": phase_tap,
    "reopen": phase_reopen,
    "background": phase_background,
}


# ------------------------------------------------------------------------- main


def main() -> int:
    parser = argparse.ArgumentParser(description="AirChat device tests")
    parser.add_argument("--ios-udid", default=os.environ.get("AIRCHAT_IOS_UDID"))
    parser.add_argument("--android-serial", default=os.environ.get("AIRCHAT_ANDROID_SERIAL"))
    parser.add_argument("--ios-bundle", default=DEFAULT_IOS_BUNDLE)
    parser.add_argument("--android-package", default=DEFAULT_ANDROID_PKG)
    parser.add_argument("--android-activity", default=DEFAULT_ACTIVITY)
    parser.add_argument("--android-apk", help="install this APK before testing")
    parser.add_argument("--ios-app", help="install this .app before testing")
    parser.add_argument("--timeout", type=int, default=90, help="seconds per wait")
    parser.add_argument("--work-dir", default="/tmp/airchat-device-test")
    parser.add_argument(
        "--phases",
        default=",".join(ALL_PHASES),
        help=f"comma-separated subset of: {', '.join(ALL_PHASES)}",
    )
    parser.add_argument(
        "--reset",
        action="store_true",
        help=(
            "uninstall both apps before installing. Rarely needed: the tap phase clears stored "
            "verdicts itself. A reinstall also drops the iOS Bluetooth permission, so the phone "
            "shows a system dialog the run cannot answer."
        ),
    )
    args = parser.parse_args()

    phases = [name.strip() for name in args.phases.split(",") if name.strip()]
    unknown = [name for name in phases if name not in PHASES]
    if unknown:
        log(f"FAIL: unknown phase(s): {', '.join(unknown)}")
        return 2

    require_tool("xcrun")
    require_tool("adb")

    ios_udid = args.ios_udid or discover_ios_udid()
    android_serial = args.android_serial or discover_android_serial()
    if not ios_udid:
        log("FAIL: no connected iPhone found (is it unlocked and paired?)")
        return 2
    if not android_serial:
        log("FAIL: no Android device in 'device' state (check the cable and USB debugging)")
        return 2
    log(f"iPhone {ios_udid}  |  Android {android_serial}  |  phases: {', '.join(phases)}")

    adb = ["adb", "-s", android_serial]

    if args.reset:
        log("uninstalling both apps to start from a clean state")
        run(["xcrun", "devicectl", "device", "uninstall", "app",
             "--device", ios_udid, args.ios_bundle], timeout=180)
        run(adb + ["uninstall", args.android_package], timeout=180)

    if args.ios_app:
        log(f"installing {args.ios_app}")
        result = run(["xcrun", "devicectl", "device", "install", "app",
                      "--device", ios_udid, args.ios_app], timeout=300)
        if result.returncode != 0:
            log("FAIL: iOS install failed:\n" + result.stdout + result.stderr)
            return 2
    if args.android_apk:
        log(f"installing {args.android_apk}")
        try:
            result = run(adb + ["install", "-r", "-t", args.android_apk], timeout=300)
        except subprocess.TimeoutExpired:
            log(
                "FAIL: Android install timed out after 300s. This is almost always a dialog on the "
                "phone - a USB connection-mode chooser or an install confirmation - and the transfer "
                "itself is fine: unplug/replug, choose a file-transfer mode and dismiss the dialog."
            )
            return 2
        if result.returncode != 0:
            log("FAIL: Android install failed:\n" + result.stdout + result.stderr)
            return 2
        if args.reset:
            grant_android_permissions(adb, args.android_package)

    env = DeviceEnv(args, ios_udid, android_serial)

    results: list[Outcome] = []
    for name in phases:
        log(f"--- phase: {name} ---")
        try:
            outcome = PHASES[name](env)
        except subprocess.TimeoutExpired as error:
            outcome = Outcome(name, [f"a device command timed out: {error}"])
        results.append(outcome)
        for note in outcome.notes:
            log(f"    {note}")
        if outcome.ok:
            log(f"    PASS: {name}")
        else:
            log(f"    FAIL: {name}")
            for failure in outcome.failures:
                log(f"      - {failure}")

    print()
    failed = [result for result in results if not result.ok]
    for result in results:
        log(f"  {'PASS' if result.ok else 'FAIL'}  {result.name}")
    if failed:
        print("RESULT: FAIL")
        hints = diagnose(latest_state(os.path.join(args.work_dir, "link-ios.log"), "ios"),
                         latest_state(os.path.join(args.work_dir, "link-android.log"), "android"))
        if hints:
            log("next steps:")
            for hint in hints:
                log(f"  - {hint}")
        log(f"full logs: {args.work_dir}/*.log")
        return 1

    print("RESULT: PASS")
    log(f"  {len(results)} phase(s) passed: {', '.join(result.name for result in results)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
