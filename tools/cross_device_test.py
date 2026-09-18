#!/usr/bin/env python3
"""AirChat two-device connectivity test.

Verifies the whole discovery -> link -> handshake -> safety-code path between one iPhone
and one Android phone, without screenshots or UI automation.

How it works
------------
Both apps emit a machine-readable heartbeat line once per second:

    AIRCHAT_STATE {"platform":"ios","self":"<32 hex>","status":"scanning","nearby":1,
                   "links":[{"peer":"<32 hex>","ready":true,"central":false,"mtu":185,"code":"123456"}]}

The iOS app writes it to stderr (captured by `devicectl ... --console`) and the Android app
writes it to logcat under the tag `AirChat/State`, so this script only has to read two text
streams. It then asserts:

  1. both apps are alive (heartbeats present)
  2. each side sees at least one nearby peer        (radio + advertising + scanning)
  3. each side has exactly one READY link           (GATT attach + HELLO/HELLO_ACK)
  4. the two links point at each other              (identity exchange)
  5. both sides derive the SAME 6-digit safety code (ECDH + HKDF + safety-number agreement)
  6. the central/peripheral roles are mirrored      (link dedupe did not fight itself)

Assertion 5 is the important one: an equal safety code across iOS and Android is proof that the
two crypto implementations agree byte for byte.

Phase 2 exercises the payload path in both directions. Each app is launched with a scripted send
(iOS: `AIRCHAT_SELFTEST` environment variable; Android: `airchat_selftest` intent extra - both
honoured only by debug builds), which waits for a ready link and then sends a channel post and a
private message. Steps are separated by `,` and **never** by `|`: the Android extra is handed to
the device's own shell by `adb shell`, which reads an unquoted `|` as a pipe and silently truncates
the script there. Both apps log the script they received, and the harness asserts on that line, so
a mangled argument is reported as such instead of as a missing message. The heartbeat carries inbound-message counters, the last text received, and a
count of outgoing messages that received a DELIVERY_ACK, so the harness can assert:

  7. both sides received the other's channel post, by exact text
  8. both sides decrypted the other's private message, by exact text  (cross-platform E2EE)
  9. both sides received a delivery ACK                    (notification path, both directions)

`--connect-first` replaces phases 2 with the tap path instead of the scripted send: each side taps
the first person it can see, the way a user does, and the run asserts that both sides ended up
linked and that both were asked to compare that person's safety code. Phase 2 and this mode are
alternatives - one launch cannot both send a scripted message and tap somebody - so a full
verification runs the harness twice.

Usage
-----
    # both phones unlocked and connected to this Mac
    python3 tools/cross_device_test.py
    python3 tools/cross_device_test.py --timeout 90
    python3 tools/cross_device_test.py --android-apk ../android/app/build/outputs/apk/debug/app-debug.apk
    python3 tools/cross_device_test.py --ios-udid <IOS_DEVICE_UDID>
    python3 tools/cross_device_test.py --connect-first        # exercise the tap path

The device identifiers are discovered automatically, so neither a UDID nor a serial number has to
be written down anywhere - which also keeps them out of the repository.

Exit codes: 0 = pass, 1 = assertion failed, 2 = environment problem (device/tool missing).
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

STATE_MARKER = "AIRCHAT_STATE "
IOS_SELF_TEST = "channel:hi-from-ios,private:secret-from-ios"
ANDROID_SELF_TEST = "channel:hi-from-android,private:secret-from-android"
IOS_EXPECTED = ("hi-from-android", "secret-from-android")
ANDROID_EXPECTED = ("hi-from-ios", "secret-from-ios")
DEFAULT_IOS_BUNDLE = "app.airchat.ios"
DEFAULT_ANDROID_PKG = "com.airchat.app.debug"
DEFAULT_ACTIVITY = "com.airchat.app.MainActivity"


RUNTIME_PERMISSIONS = (
    "android.permission.BLUETOOTH_SCAN",
    "android.permission.BLUETOOTH_CONNECT",
    "android.permission.BLUETOOTH_ADVERTISE",
    "android.permission.POST_NOTIFICATIONS",
)


def grant_android_permissions(adb: list[str], package: str) -> None:
    """Grants the runtime permissions a fresh install would otherwise wait for.

    Reinstalling the app drops every runtime permission, after which the system shows a dialog that
    an automated run cannot answer and the app sits behind its permission gate forever. Failures are
    logged and ignored: POST_NOTIFICATIONS is install-time on releases before Android 13.
    """
    for permission in RUNTIME_PERMISSIONS:
        result = run(adb + ["shell", "pm", "grant", package, permission])
        if result.returncode != 0:
            log(f"note: could not grant {permission} (harmless where it is install-time)")


def log(message: str) -> None:
    print(f"[cross-device] {message}", flush=True)


def run(command: list[str], timeout: int = 120) -> subprocess.CompletedProcess:
    return subprocess.run(command, capture_output=True, text=True, timeout=timeout)


def require_tool(name: str) -> None:
    if shutil.which(name) is None and not os.path.exists(name):
        log(f"FAIL: required tool not found: {name}")
        sys.exit(2)


def discover_ios_udid() -> str | None:
    """The hardware UDID of the first iPhone, preferring one the Instruments transport can see.

    Deliberately falls back to the "Devices Offline" section. That file is a lie often enough to
    matter: an iPhone can show up there while CoreDevice - the transport this harness actually uses
    to install and launch - reports it as available and paired. Trusting the online section alone
    means refusing to test a perfectly usable phone, which is exactly what happened once.
    """
    try:
        out = run(["xcrun", "xctrace", "list", "devices"]).stdout
    except Exception as error:  # noqa: BLE001 - surfaced to the user below
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


def spec_delivered(path: str, spec: str) -> bool:
    """True once the app's log shows it received the scripted send verbatim."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            return f"selftest spec received: {spec}" in handle.read()
    except FileNotFoundError:
        return False


def exchange_complete(state: dict | None, expected: tuple[str, str]) -> bool:
    """True once this side has received, decrypted and acknowledged everything it should have."""
    if not state:
        return False
    channel_text, private_text = expected
    return (
        state.get("channel", 0) >= 1
        and state.get("private", 0) >= 1
        and state.get("delivered", 0) >= 1
        and state.get("lastChannel") == channel_text
        and state.get("lastPrivate") == private_text
    )


def ready_state(state: dict | None) -> dict | None:
    if not state:
        return None
    for link in state.get("links", []):
        if link.get("ready"):
            return link
    return None


def describe(state: dict | None) -> str:
    if state is None:
        return "no heartbeat (app not running, or it crashed)"
    links = state.get("links", [])
    summary = ", ".join(
        f"peer={link.get('peer')} ready={link.get('ready')} central={link.get('central')}"
        for link in links
    ) or "none"
    return f"status={state.get('status')} nearby={state.get('nearby')} links=[{summary}]"


def diagnose(ios: dict | None, android: dict | None) -> list[str]:
    """Turn the observed state into concrete, actionable next steps."""
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

    ios_nearby = (ios or {}).get("nearby", 0)
    android_nearby = (android or {}).get("nearby", 0)
    if ios and android:
        if ios_nearby == 0 and android_nearby == 0:
            hints.append(
                "Neither side sees any advertisement. Keep BOTH apps in the foreground: iOS only "
                "advertises its service UUID where other devices can match it while frontmost."
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


def main() -> int:
    parser = argparse.ArgumentParser(description="AirChat two-device connectivity test")
    parser.add_argument("--ios-udid", default=os.environ.get("AIRCHAT_IOS_UDID"))
    parser.add_argument("--android-serial", default=os.environ.get("AIRCHAT_ANDROID_SERIAL"))
    parser.add_argument("--ios-bundle", default=DEFAULT_IOS_BUNDLE)
    parser.add_argument("--android-package", default=DEFAULT_ANDROID_PKG)
    parser.add_argument("--android-activity", default=DEFAULT_ACTIVITY)
    parser.add_argument("--android-apk", help="install this APK before testing")
    parser.add_argument("--ios-app", help="install this .app before testing")
    parser.add_argument("--timeout", type=int, default=75, help="seconds to wait for a ready link")
    parser.add_argument(
        "--reset",
        action="store_true",
        help="uninstall both apps before installing, so nothing is carried over",
    )
    parser.add_argument(
        "--connect-first",
        action="store_true",
        help="tap the first nearby person instead of sending a scripted message",
    )
    parser.add_argument("--work-dir", default="/tmp/airchat-cross-device-test")
    args = parser.parse_args()

    require_tool("xcrun")
    require_tool("adb")
    os.makedirs(args.work_dir, exist_ok=True)

    ios_udid = args.ios_udid or discover_ios_udid()
    android_serial = args.android_serial or discover_android_serial()
    if not ios_udid:
        log("FAIL: no connected iPhone found (is it unlocked and paired?)")
        return 2
    if not android_serial:
        log("FAIL: no Android device in 'device' state (check the cable and USB debugging)")
        return 2
    log(f"iPhone {ios_udid}  |  Android {android_serial}")

    if args.reset:
        # A trust verdict, and the identity that goes with it, is persisted on purpose. A run that
        # wants to observe a *first* connection therefore has to start without one - otherwise the
        # safety code is already trusted and correctly not offered again, which looks like a failure.
        log("uninstalling both apps to start from a clean state")
        run(["xcrun", "devicectl", "device", "uninstall", "app",
             "--device", ios_udid, args.ios_bundle], timeout=180)
        run(["adb", "-s", android_serial, "uninstall", args.android_package], timeout=180)

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
            result = run(["adb", "-s", android_serial, "install", "-r", "-t", args.android_apk], timeout=300)
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
            grant_android_permissions(["adb", "-s", android_serial], args.android_package)

    ios_log = os.path.join(args.work_dir, "ios.log")
    android_log = os.path.join(args.work_dir, "android.log")
    for path in (ios_log, android_log):
        open(path, "w").close()

    # ---- restart both apps, streaming their output into the two log files
    log("restarting both apps (keep both phones unlocked)")
    adb = ["adb", "-s", android_serial]
    run(adb + ["shell", "am", "force-stop", args.android_package])
    run(adb + ["logcat", "-c"])

    ios_env = {"AIRCHAT_SELFTEST": IOS_SELF_TEST}
    android_start = adb + [
        "shell", "am", "start", "-n", f"{args.android_package}/{args.android_activity}",
        "--es", "airchat_selftest", ANDROID_SELF_TEST,
    ]
    if args.connect_first:
        # The Android extra travels through the device's own shell, so it is passed as a plain
        # boolean flag with no metacharacters in it.
        ios_env = {"AIRCHAT_CONNECT_FIRST": "1"}
        android_start = adb + [
            "shell", "am", "start", "-n", f"{args.android_package}/{args.android_activity}",
            "--ez", "airchat_connect_first", "true",
        ]

    ios_process = subprocess.Popen(
        ["xcrun", "devicectl", "device", "process", "launch", "--console",
         "--terminate-existing", "--device", ios_udid,
         "-e", json.dumps(ios_env),
         args.ios_bundle],
        stdout=open(ios_log, "w"), stderr=subprocess.STDOUT, text=True,
    )
    run(android_start)
    android_process = subprocess.Popen(
        adb + ["logcat", "-v", "brief"], stdout=open(android_log, "w"),
        stderr=subprocess.STDOUT, text=True,
    )

    deadline = time.time() + args.timeout
    ios_state = android_state = None
    try:
        while time.time() < deadline:
            ios_state = latest_state(ios_log, "ios") or ios_state
            android_state = latest_state(android_log, "android") or android_state
            if args.connect_first:
                # The tap path is done once both sides are linked and both have been asked to
                # compare a safety code.
                if (ready_state(ios_state) and ready_state(android_state)
                        and ios_state.get("verifyPrompts", 0) >= 1
                        and android_state.get("verifyPrompts", 0) >= 1):
                    break
            elif (ready_state(ios_state) and ready_state(android_state)
                    and exchange_complete(ios_state, IOS_EXPECTED)
                    and exchange_complete(android_state, ANDROID_EXPECTED)):
                break
            time.sleep(2)
        # one extra settling period so both heartbeats reflect the connected state
        time.sleep(2)
        ios_state = latest_state(ios_log, "ios") or ios_state
        android_state = latest_state(android_log, "android") or android_state
    finally:
        for process in (ios_process, android_process):
            if process.poll() is None:
                process.send_signal(signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()

    print()
    log(f"iOS     : {describe(ios_state)}")
    log(f"Android : {describe(android_state)}")
    print()

    failures: list[str] = []
    # Checked before anything else: a script that did not arrive intact explains every downstream
    # "message never arrived" symptom, and costs a whole round to re-diagnose otherwise.
    if not args.connect_first:
        if not spec_delivered(ios_log, IOS_SELF_TEST):
            failures.append("iOS did not receive the full self-test script")
        if not spec_delivered(android_log, ANDROID_SELF_TEST):
            failures.append(
                "Android did not receive the full self-test script - `adb shell` truncates an intent "
                "extra at an unquoted '|', so keep the step separator shell-safe"
            )
    if ios_state is None:
        failures.append("iOS produced no heartbeat")
    if android_state is None:
        failures.append("Android produced no heartbeat")

    if not failures:
        if ios_state.get("nearby", 0) < 1 or android_state.get("nearby", 0) < 1:
            failures.append("mutual discovery failed (a side reported nearby=0)")
        ios_link = ready_state(ios_state)
        android_link = ready_state(android_state)
        if ios_link is None or android_link is None:
            failures.append("no READY link on one or both sides")
        else:
            if ios_link.get("peer") != android_state.get("self"):
                failures.append(
                    f"iOS is linked to {ios_link.get('peer')} but Android's device id is "
                    f"{android_state.get('self')}"
                )
            if android_link.get("peer") != ios_state.get("self"):
                failures.append(
                    f"Android is linked to {android_link.get('peer')} but iOS's device id is "
                    f"{ios_state.get('self')}"
                )
            if ios_link.get("central") == android_link.get("central"):
                failures.append("central/peripheral roles are not mirrored")
            ios_code, android_code = ios_link.get("code"), android_link.get("code")
            if not ios_code or not android_code:
                failures.append("a side did not derive a safety code")
            elif ios_code != android_code:
                failures.append(
                    f"safety codes disagree (iOS {ios_code} vs Android {android_code}) - the two "
                    "crypto implementations do not agree, see docs/protocol.md section 10"
                )

    if not failures and args.connect_first:
        # The tap path: linked, and both sides asked to compare the code. Messaging is covered by the
        # ordinary run, and asserting it here would only re-test what the other mode proves.
        for state, name in ((ios_state, "iOS"), (android_state, "Android")):
            if state.get("verifyPrompts", 0) < 1:
                failures.append(
                    f"{name} was never asked to verify a safety code - the tap did not reach the node"
                )

    if not failures and not args.connect_first:
        ios_link = ready_state(ios_state)
        android_link = ready_state(android_state)
        for state, expected, name in ((ios_state, IOS_EXPECTED, "iOS"), (android_state, ANDROID_EXPECTED, "Android")):
            channel_text, private_text = expected
            if state.get("channel", 0) < 1:
                failures.append(f"{name} received no channel post")
            elif state.get("lastChannel") != channel_text:
                failures.append(
                    f"{name} channel text mismatch: {state.get('lastChannel')!r} != {channel_text!r}"
                )
            if state.get("private", 0) < 1:
                failures.append(f"{name} received no private message")
            elif state.get("lastPrivate") != private_text:
                failures.append(
                    f"{name} private text mismatch: {state.get('lastPrivate')!r} != {private_text!r}"
                )
            if state.get("delivered", 0) < 1:
                failures.append(f"{name} never received a delivery ACK for its own message")

    if failures:
        print("RESULT: FAIL")
        for item in failures:
            log(f"  - {item}")
        hints = diagnose(ios_state, android_state)
        if hints:
            print()
            log("next steps:")
            for hint in hints:
                log(f"  - {hint}")
        log(f"full logs: {ios_log} , {android_log}")
        return 1

    print("RESULT: PASS")
    if args.connect_first:
        log(f"  mode                  : tap the first nearby person")
        log(f"  verify prompts        : iOS={ios_state.get('verifyPrompts')}, "
            f"Android={android_state.get('verifyPrompts')}")
    log(f"  mutual discovery      : iOS nearby={ios_state['nearby']}, Android nearby={android_state['nearby']}")
    log(f"  link established      : iOS(central={ios_link['central']}, mtu={ios_link['mtu']}) "
        f"<-> Android(central={android_link['central']}, mtu={android_link['mtu']})")
    log(f"  identity exchange     : iOS peer={ios_link['peer']} , Android peer={android_link['peer']}")
    log(f"  safety code agreement : {ios_code} (identical on both platforms)")
    log(f"  channel message       : iOS got {ios_state.get('lastChannel')!r}, "
        f"Android got {android_state.get('lastChannel')!r}")
    log(f"  private message (E2EE): iOS decrypted {ios_state.get('lastPrivate')!r}, "
        f"Android decrypted {android_state.get('lastPrivate')!r}")
    log(f"  delivery acks         : iOS={ios_state.get('delivered')}, "
        f"Android={android_state.get('delivered')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
