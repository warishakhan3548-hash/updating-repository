#!/usr/bin/env python3
import argparse
import csv
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
import json
import urllib.error
import urllib.request
from pathlib import Path

PKG = "com.aaris.remoteassist"
MAIN = f"{PKG}/.ui.MainActivity"
MOTION = f"{PKG}/.debug.E2eMotionActivity"
DUMP_ACTION = f"{PKG}.debug.DUMP_E2E"

def run(cmd, check=True, capture=True, timeout=30):
    p = subprocess.run(
        cmd,
        check=False,
        text=True,
        capture_output=capture,
        timeout=timeout,
    )
    if check and p.returncode != 0:
        raise RuntimeError(
            f"command failed ({p.returncode}): {' '.join(cmd)}\n"
            f"stdout={p.stdout[-2000:] if p.stdout else ''}\n"
            f"stderr={p.stderr[-2000:] if p.stderr else ''}"
        )
    return p

def adb(serial, *args, check=True, timeout=30):
    return run(["adb", "-s", serial, *args], check=check, timeout=timeout)

def shell(serial, *args, check=True, timeout=30):
    return adb(serial, "shell", *args, check=check, timeout=timeout)

def raw_ui_xml(serial):
    shell(
        serial,
        "uiautomator", "dump", "/sdcard/aaris-ui.xml",
        check=False,
        timeout=20,
    )
    p = shell(
        serial,
        "cat", "/sdcard/aaris-ui.xml",
        check=False,
    )
    return p.stdout or ""

def ui_xml(serial):
    raw = raw_ui_xml(serial)

    # Hosted emulators can occasionally surface an ANR for the launcher/System
    # UI while our app itself is healthy. Treat "Wait" as infrastructure
    # recovery, never "Close app"; then re-read the foreground UI. Physical
    # app ANRs are still visible in logcat/artifacts and are not auto-dismissed
    # unless the dialog belongs to package=android.
    if "isn't responding" in raw and 'package="android"' in raw:
        try:
            root = ET.fromstring(raw)
            for node in root.iter("node"):
                if (
                    node.attrib.get("text", "").strip().lower() == "wait"
                    and node.attrib.get("package", "") == "android"
                ):
                    center = bounds_center(node.attrib.get("bounds"))
                    if center:
                        shell(
                            serial, "input", "tap",
                            str(center[0]), str(center[1]),
                            check=False,
                        )
                        time.sleep(0.8)
                        return raw_ui_xml(serial)
        except ET.ParseError:
            pass
    return raw

def parse_nodes(xml_text):
    try:
        root = ET.fromstring(xml_text)
    except ET.ParseError:
        return []
    return list(root.iter("node"))

def node_values(node):
    return [
        value.strip()
        for value in [
            node.attrib.get("text", ""),
            node.attrib.get("content-desc", ""),
        ]
        if value and value.strip()
    ]

def node_text(node):
    return " ".join(node_values(node)).strip()

def bounds_center(bounds):
    m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", bounds or "")
    if not m:
        return None
    x1, y1, x2, y2 = map(int, m.groups())
    return ((x1 + x2) // 2, (y1 + y2) // 2)

def find_node(serial, predicate, timeout=30):
    deadline = time.time() + timeout
    last = ""
    while time.time() < deadline:
        last = ui_xml(serial)
        for node in parse_nodes(last):
            if predicate(node):
                return node
        time.sleep(0.5)
    raise RuntimeError(f"UI node not found on {serial}; last UI:\n{last[-12000:]}")

def click_text(serial, text, timeout=30, contains=False):
    target = text.lower()
    def pred(node):
        values = [value.lower() for value in node_values(node)]
        return (
            any(target in value for value in values)
            if contains
            else target in values
        )
    node = find_node(serial, pred, timeout)
    center = bounds_center(node.attrib.get("bounds"))
    if not center:
        raise RuntimeError(f"node has no bounds: {node.attrib}")
    shell(serial, "input", "tap", str(center[0]), str(center[1]))
    return center

def click_first_text(serial, options, timeout=30):
    """
    Click an actual actionable control, never a title/message that merely
    contains the same word.

    MediaProjection dialogs contain both:
      title  = "Start recording or casting?"
      button = "START NOW"
    A naive substring match on "Start" taps the title and silently leaves the
    consent dialog open. Prefer clickable exact matches first, then clickable
    contains matches as a last resort.
    """
    lowers = [x.lower() for x in options]
    deadline = time.time() + timeout
    last = ""

    while time.time() < deadline:
        last = ui_xml(serial)
        nodes = parse_nodes(last)

        def clickable(node):
            return node.attrib.get("clickable", "").lower() == "true"

        selected = None

        for candidate in lowers:
            for node in nodes:
                if not clickable(node):
                    continue
                values = [value.lower() for value in node_values(node)]
                if candidate in values:
                    selected = node
                    break
            if selected is not None:
                break

        if selected is None:
            for candidate in lowers:
                for node in nodes:
                    if not clickable(node):
                        continue
                    values = [value.lower() for value in node_values(node)]
                    if any(candidate in value for value in values):
                        selected = node
                        break
                if selected is not None:
                    break

        if selected is not None:
            center = bounds_center(selected.attrib.get("bounds"))
            if not center:
                raise RuntimeError(
                    f"clickable node has no bounds: {selected.attrib}"
                )
            shell(
                serial,
                "input",
                "tap",
                str(center[0]),
                str(center[1]),
            )
            return node_text(selected)

        time.sleep(0.35)

    raise RuntimeError(
        f"clickable UI option not found on {serial}; last UI:\n"
        f"{last[-12000:]}"
    )

def wait_text(serial, text, timeout=45, contains=True):
    target = text.lower()
    return find_node(
        serial,
        lambda n: (
            any(target in value.lower() for value in node_values(n))
            if contains
            else target in [value.lower() for value in node_values(n)]
        ),
        timeout,
    )

def wait_any_text(serial, options, timeout=45):
    lowers = [option.lower() for option in options]
    return find_node(
        serial,
        lambda n: any(
            candidate in value.lower()
            for candidate in lowers
            for value in node_values(n)
        ),
        timeout,
    )

def extract_pairing_code(serial, timeout=35):
    deadline = time.time() + timeout
    last = ""
    patterns = [
        re.compile(r"\b(\d{4})\s+(\d{4})\s+(\d{4})\b"),
        re.compile(r"\b(\d{12})\b"),
    ]
    while time.time() < deadline:
        last = ui_xml(serial)
        texts = [node_text(n) for n in parse_nodes(last)]
        for text in texts:
            for pattern in patterns:
                m = pattern.search(text)
                if m:
                    digits = "".join(m.groups())
                    if len(digits) == 12:
                        return digits
        time.sleep(0.5)
    raise RuntimeError(f"pairing code not found; last UI:\n{last[-12000:]}")

def ensure_pairing_code(serial, code, timeout=20):
    """
    Verify that the Connect dialog really contains the expected one-time code.

    The production deep link is the preferred path. Some hosted Google emulator
    images open the dialog but drop the initial EditText value during
    activity/IME restoration. In that test-environment case, enter the digits
    through Android KeyEvents and verify the UI before pressing START.
    """
    if not re.fullmatch(r"\d{12}", code):
        raise RuntimeError("invalid 12-digit pairing code")

    def field_and_digits():
        xml = ui_xml(serial)
        for node in parse_nodes(xml):
            if node.attrib.get("class") != "android.widget.EditText":
                continue
            digits = re.sub(r"\D", "", node.attrib.get("text", ""))
            return node, digits
        return None, ""

    node, digits = field_and_digits()
    if digits == code:
        return

    if node is None:
        node = find_node(
            serial,
            lambda n: n.attrib.get("class") == "android.widget.EditText",
            timeout=timeout,
        )

    center = bounds_center(node.attrib.get("bounds"))
    if not center:
        raise RuntimeError("pairing EditText has no bounds")

    shell(serial, "input", "tap", str(center[0]), str(center[1]))
    for _ in range(16):
        shell(serial, "input", "keyevent", "KEYCODE_DEL", check=False)

    # KEYCODE_0..KEYCODE_9 are 7..16. This avoids hosted-emulator IME races
    # seen with `adb shell input text`.
    for digit in code:
        shell(
            serial,
            "input",
            "keyevent",
            str(7 + int(digit)),
            check=False,
        )

    deadline = time.time() + timeout
    last = ""
    while time.time() < deadline:
        _, last = field_and_digits()
        if last == code:
            return
        time.sleep(0.25)

    raise RuntimeError(
        "pairing code did not verify after numeric key injection; "
        f"visible_digits={len(last)}"
    )


def submit_connect_dialog(serial, timeout=20):
    """
    Submit the production Connect dialog without assuming the soft keyboard is
    hidden. Hosted Google images can visually expose the START button while the
    IME still intercepts coordinate taps.
    """
    # The EditText is single-line with IME_ACTION_DONE. Hardware ENTER normally
    # triggers the same production submit() callback without any screen tap.
    shell(
        serial,
        "input",
        "keyevent",
        "KEYCODE_ENTER",
        check=False,
    )

    deadline = time.time() + 2.5
    while time.time() < deadline:
        xml = ui_xml(serial)
        values = " | ".join(
            node_text(n)
            for n in parse_nodes(xml)
            if node_text(n)
        ).lower()
        if "enter the 12-digit one-time code" not in values:
            return
        time.sleep(0.2)

    # If ENTER was treated as a plain key event, hide the IME once, then tap the
    # exact clickable START button after re-reading its current bounds.
    shell(
        serial,
        "input",
        "keyevent",
        "KEYCODE_BACK",
        check=False,
    )
    time.sleep(0.5)

    xml = ui_xml(serial)
    values = " | ".join(
        node_text(n)
        for n in parse_nodes(xml)
        if node_text(n)
    ).lower()
    if "enter the 12-digit one-time code" not in values:
        # BACK dismissed the dialog instead of only hiding IME.
        raise RuntimeError(
            "Connect dialog disappeared while hiding IME before submit"
        )

    start = find_node(
        serial,
        lambda n:
            n.attrib.get("class") == "android.widget.Button"
            and n.attrib.get("clickable") == "true"
            and "start" in [v.lower() for v in node_values(n)],
        timeout=5,
    )
    center = bounds_center(start.attrib.get("bounds"))
    if not center:
        raise RuntimeError("Connect START button has no bounds")
    shell(
        serial,
        "input",
        "tap",
        str(center[0]),
        str(center[1]),
    )

    deadline = time.time() + timeout
    last = ""
    while time.time() < deadline:
        last = ui_xml(serial)
        values = " | ".join(
            node_text(n)
            for n in parse_nodes(last)
            if node_text(n)
        ).lower()
        if "enter the 12-digit one-time code" not in values:
            return
        time.sleep(0.25)

    raise RuntimeError(
        "Connect START did not submit; dialog remained visible"
    )


def wm_size(serial):
    out = shell(serial, "wm", "size").stdout or ""
    m = re.search(r"(\d+)x(\d+)", out)
    if not m:
        return (1080, 1920)
    return tuple(map(int, m.groups()))

def set_network(serial, speed, delay):
    adb(serial, "emu", "network", "speed", speed, check=False)
    adb(serial, "emu", "network", "delay", delay, check=False)

def dump_metrics(serial, label, out_dir, prefix="host"):
    shell(
        serial,
        "am", "broadcast",
        "-n", f"{PKG}/.debug.E2eDebugReceiver",
        "-a", DUMP_ACTION,
        "--es", "label", label,
        check=False,
    )
    # The debug receiver may perform one authenticated backend GET before
    # writing the file, so allow a bounded moment for goAsync() completion.
    remote = f"/sdcard/Android/data/{PKG}/files/dual-e2e/{label}.txt"
    local = out_dir / f"{prefix}-{label}.txt"
    deadline = time.time() + 8
    while time.time() < deadline:
        pulled = adb(
            serial, "pull", remote, str(local),
            check=False, timeout=15,
        )
        if pulled.returncode == 0 and local.exists():
            return local
        time.sleep(0.4)
    return local

def read_pref_map(serial, pref_name):
    result = shell(
        serial,
        "run-as", PKG,
        "cat", f"shared_prefs/{pref_name}.xml",
        check=False,
        timeout=15,
    )
    raw = result.stdout or ""
    if result.returncode != 0 or "<map" not in raw:
        return {}
    try:
        root = ET.fromstring(raw)
    except ET.ParseError:
        return {}
    values = {}
    for child in root:
        name = child.attrib.get("name")
        if not name:
            continue
        if child.tag == "string":
            values[name] = child.text or ""
        else:
            values[name] = child.attrib.get("value", "")
    return values

def backend_checkpoint(serial, side, out_dir):
    setup = read_pref_map(serial, "setup")
    sessions = read_pref_map(serial, "cloudflare_sessions")
    session_id = (
        setup.get("active_host_session")
        or setup.get("pending_controller_session")
    )
    token = (
        sessions.get(f"token_{session_id}")
        if session_id
        else None
    )
    backend_state = "-"
    backend_error = "-"
    if session_id and token:
        request = urllib.request.Request(
            f"https://aaris-remote-ice.aaris-remote-wk3548.workers.dev/v1/sessions/{session_id}",
            headers={
                "Authorization": f"Bearer {token}",
                "Accept": "application/json",
                "Cache-Control": "no-store",
            },
            method="GET",
        )
        try:
            with urllib.request.urlopen(request, timeout=12) as response:
                root = json.loads(response.read().decode("utf-8"))
                backend_state = (
                    root.get("session", {}).get("state", "-")
                )
        except Exception as error:
            backend_error = (
                f"{type(error).__name__}:{error}"
            )[:220]

    local_xml = ui_xml(serial)
    visible = " | ".join(
        node_text(node)
        for node in parse_nodes(local_xml)
        if node_text(node)
    )[:1200]

    path = out_dir / f"{side}-backend-checkpoint.txt"
    path.write_text(
        "\n".join([
            f"side={side}",
            f"has_session={bool(session_id)}",
            f"has_token={bool(token)}",
            f"backend_state={backend_state}",
            f"backend_error={backend_error}",
            f"visible_ui={visible}",
            "",
        ])
    )
    return {
        "session_id": session_id,
        "has_token": bool(token),
        "backend_state": backend_state,
        "backend_error": backend_error,
    }

def screenshot(serial, path):
    with open(path, "wb") as f:
        p = subprocess.run(
            ["adb", "-s", serial, "exec-out", "screencap", "-p"],
            stdout=f,
            stderr=subprocess.PIPE,
            check=False,
        )
    if p.returncode != 0:
        raise RuntimeError(p.stderr.decode(errors="ignore"))

def start_record(serial, remote_path, seconds):
    return subprocess.Popen(
        [
            "adb", "-s", serial, "shell",
            "screenrecord",
            "--bit-rate", "6000000",
            "--time-limit", str(seconds),
            remote_path,
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

def parse_metric_file(path):
    if not path.exists():
        return {}
    text = path.read_text(errors="replace")
    def grab(pattern, cast=float):
        m = re.search(pattern, text)
        if not m:
            return None
        try:
            return cast(m.group(1))
        except Exception:
            return None
    result = {
        "touch_events": grab(r"(?m)^touch_events=(\d+)$", int),
        "gesture_starts": grab(r"(?m)^gesture_starts=(\d+)$", int),
        "gesture_ends": grab(r"(?m)^gesture_ends=(\d+)$", int),
        "source_fps": grab(r"source=(\d+(?:\.\d+)?)fps"),
        "target_fps": grab(r"target=(\d+(?:\.\d+)?)fps"),
        "send_fps": grab(r"(?:send|sender)=(\d+(?:\.\d+)?)fps"),
        "decode_fps": grab(r"decode=(\d+(?:\.\d+)?)fps"),
        "present_fps": grab(r"present=(\d+(?:\.\d+)?)fps"),
        "gap_ms": grab(r"gap=(\d+)ms", int),
        "rtt_ms": grab(r"rtt=(\d+)ms", int),
        "loss_pct": grab(r"loss=([0-9.]+)%"),
        "queue_ms": grab(r"queue=([0-9.]+)ms"),
    }
    path_m = re.search(r"path=([^\n]+)", text)
    if path_m:
        result["path"] = path_m.group(1).strip()
    codec_m = re.search(r"(?:codec|impl)=([^\n ]+)", text)
    if codec_m:
        result["codec"] = codec_m.group(1).strip()
    return result

def gesture_batch(controller):
    w, h = wm_size(controller)
    x = w // 2
    # Keep gestures inside the remote content body, away from top/bottom chrome.
    y_hi = int(h * 0.70)
    y_lo = int(h * 0.34)
    x_l = int(w * 0.28)
    x_r = int(w * 0.72)
    shell(controller, "input", "tap", str(x), str(int(h * 0.52)))
    time.sleep(0.4)
    shell(controller, "input", "swipe", str(x), str(y_hi), str(x), str(y_lo), "550")
    time.sleep(0.5)
    shell(controller, "input", "swipe", str(x_l), str(int(h * 0.55)), str(x_r), str(int(h * 0.55)), "1000")
    time.sleep(0.5)
    shell(controller, "input", "swipe", str(x_r), str(int(h * 0.60)), str(x_l), str(int(h * 0.42)), "1400")

def ensure_accessibility(serial):
    service = (
        "com.aaris.remoteassist/"
        "com.aaris.remoteassist.accessibility.AssistAccessibilityService"
    )
    enabled = (
        shell(
            serial,
            "settings", "get", "secure",
            "enabled_accessibility_services",
            check=False,
        ).stdout
        or ""
    ).strip()
    if service.lower() not in enabled.lower():
        shell(
            serial,
            "settings", "put", "secure",
            "enabled_accessibility_services", service,
        )
    shell(
        serial,
        "settings", "put", "secure",
        "accessibility_enabled", "1",
    )
    verified = (
        shell(
            serial,
            "settings", "get", "secure",
            "enabled_accessibility_services",
            check=False,
        ).stdout
        or ""
    ).strip()
    if service.lower() not in verified.lower():
        raise RuntimeError(
            f"Accessibility service did not persist on {serial}: {verified}"
        )

def pair(host, controller, out_dir):
    # Do not force-stop after enabling Accessibility. On some emulator/system
    # builds force-stop tears down or suppresses the bound AccessibilityService
    # until the user toggles it again, which is not representative of the
    # normal permission-granted app lifecycle.
    ensure_accessibility(host)
    ensure_accessibility(controller)
    shell(host, "am", "start", "-W", "-n", MAIN)
    shell(controller, "am", "start", "-W", "-n", MAIN)
    wait_text(host, "Aaris Remote", timeout=25)
    wait_text(controller, "Aaris Remote", timeout=25)

    click_text(host, "Share", timeout=20)
    code = extract_pairing_code(host, timeout=40)
    (out_dir / "pairing_code_redacted.txt").write_text("pairing succeeded\n")

    # MainActivity intentionally opens Android's ACTION_SEND chooser so a real
    # user can share the one-time code. The E2E driver reads the code from that
    # real system sheet, then returns to Aaris Remote before the controller joins;
    # otherwise the later host approval dialog is hidden behind the chooser.
    # Exercise the production SEND path so the system chooser is real. The
    # underlying "Share this code" AlertDialog is intentionally non-cancelable;
    # returning from the chooser must NOT wait for the activity's home text or
    # press CANCEL, because CANCEL closes the live host ticket.
    click_text(host, "SEND", timeout=15)
    chooser_packages = {
        "com.android.intentresolver",
        "com.google.android.intentresolver",
    }
    chooser_deadline = time.time() + 10
    chooser_seen = False
    while time.time() < chooser_deadline:
        nodes = parse_nodes(ui_xml(host))
        packages = {
            node.attrib.get("package", "")
            for node in nodes
        }
        if packages.intersection(chooser_packages):
            chooser_seen = True
            shell(host, "input", "keyevent", "KEYCODE_BACK")
            break
        time.sleep(0.25)
    if not chooser_seen:
        # Some emulator builds resolve the chooser so quickly that UIAutomator
        # misses its package transition. Returning once is harmless if a system
        # share surface is currently on top; otherwise the host dialog remains.
        shell(host, "input", "keyevent", "KEYCODE_BACK", check=False)

    # The host share-code dialog is expected to remain visible here. The real
    # PairingGateway observer will later place "Start remote support?" above it
    # after the controller redeems the one-time code.

    # Use the production deep-link entry point instead of synthesizing
    # keyboard text. Full Google emulator images can route ADB "input text"
    # through Gboard in ways that race the dialog/IME and make the E2E flaky.
    # The deep link exercises MainActivity.handleIncomingJoin() and the exact
    # same showConnectDialog(code) + START + gateway.redeemCode() production path.
    join_uri = f"aarisremote://connect?code={code}"
    shell(
        controller,
        "am", "start",
        "-W",
        "-a", "android.intent.action.VIEW",
        "-d", join_uri,
        "-n", MAIN,
    )
    wait_text(controller, "12-digit one-time code", timeout=20)
    ensure_pairing_code(controller, code, timeout=20)
    submit_connect_dialog(controller, timeout=20)

    # Prove redeem succeeded before blaming the host observer. A successful
    # controller must persist a session and enter the verified/waiting state.
    wait_any_text(
        controller,
        [
            "Code verified",
            "Waiting for your friend",
            "Approved",
        ],
        timeout=25,
    )
    dump_metrics(host, "post_redeem", out_dir, prefix="host")
    dump_metrics(controller, "post_redeem", out_dir, prefix="controller")
    # Runner-side direct HTTP checkpoints are diagnostics only. They are
    # intentionally not an authority for app authentication because hosted
    # runners can be treated differently by edge security than Android/OkHttp.
    # The real E2E authority is the production host observer: the approval
    # dialog below appears only after the host app has authenticated its own
    # session token and observed PAIR_PENDING.
    backend_checkpoint(host, "host", out_dir)
    backend_checkpoint(controller, "controller", out_dir)

    wait_text(host, "Start remote support?", timeout=45)
    click_text(host, "START", timeout=15)

    # MediaProjection is a system dialog. Use an exact clickable button match:
    # a fuzzy "Start" search can hit the non-clickable title
    # "Start recording or casting?" and leave consent pending forever.
    wait_text(host, "Start recording or casting?", timeout=30)
    projection_button = find_node(
        host,
        lambda n:
            n.attrib.get("class") == "android.widget.Button"
            and n.attrib.get("clickable") == "true"
            and node_text(n).strip().lower() in {
                "start now",
                "share screen",
                "start sharing",
            },
        timeout=30,
    )
    projection_center = bounds_center(
        projection_button.attrib.get("bounds")
    )
    if not projection_center:
        raise RuntimeError(
            "MediaProjection consent button has no bounds"
        )
    shell(
        host,
        "input",
        "tap",
        str(projection_center[0]),
        str(projection_center[1]),
    )

    # Do not wait blindly for the controller. First prove Android actually
    # accepted the projection request on the shared phone.
    projection_deadline = time.time() + 20
    projection_active = False
    while time.time() < projection_deadline:
        state = shell(
            host,
            "dumpsys",
            "media_projection",
            check=False,
            timeout=10,
        ).stdout or ""
        if (
            "Media Projection:" in state
            and "null" not in state.split(
                "Media Projection:", 1
            )[1][:80].lower()
        ):
            projection_active = True
            break
        time.sleep(0.5)
    if not projection_active:
        raise RuntimeError(
            "MediaProjection consent was tapped but projection never became active"
        )

    # Observe the actual signaling/ICE/control-channel boot instead of a
    # blind 65s UI wait. Each checkpoint exports the production flight recorder
    # from BOTH peers with app-authenticated backend state.
    live_deadline = time.time() + 65
    next_checkpoint = time.time() + 6
    checkpoint_index = 1
    last_controller_ui = ""
    while time.time() < live_deadline:
        last_controller_ui = ui_xml(controller)
        visible = " | ".join(
            node_text(n)
            for n in parse_nodes(last_controller_ui)
            if node_text(n)
        )
        lowered = visible.lower()

        if "remote screen open" in lowered:
            dump_metrics(
                host,
                "transport_live",
                out_dir,
                prefix="host",
            )
            dump_metrics(
                controller,
                "transport_live",
                out_dir,
                prefix="controller",
            )
            break

        if "session ended" in lowered:
            dump_metrics(
                host,
                "transport_ended",
                out_dir,
                prefix="host",
            )
            dump_metrics(
                controller,
                "transport_ended",
                out_dir,
                prefix="controller",
            )
            raise RuntimeError(
                "session ended before remote video became live"
            )

        now = time.time()
        if now >= next_checkpoint:
            label = f"transport_wait_{checkpoint_index:02d}"
            dump_metrics(host, label, out_dir, prefix="host")
            dump_metrics(
                controller,
                label,
                out_dir,
                prefix="controller",
            )
            checkpoint_index += 1
            next_checkpoint = now + 8

        time.sleep(0.5)
    else:
        dump_metrics(
            host,
            "transport_timeout",
            out_dir,
            prefix="host",
        )
        dump_metrics(
            controller,
            "transport_timeout",
            out_dir,
            prefix="controller",
        )
        raise RuntimeError(
            "remote screen did not become live before timeout; last UI:\n" +
            last_controller_ui[-6000:]
        )

    # Give SCTP telemetry/video lanes a short stabilization window before
    # exercising real motion and remote gestures.
    time.sleep(4.0)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", required=True)
    ap.add_argument("--controller", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    host = args.host
    controller = args.controller

    try:
        pair(host, controller, out_dir)

        # Move the shared phone to a deterministic, continuously animated screen.
        shell(host, "am", "start", "-W", "-n", MOTION)
        time.sleep(3.0)
        screenshot(host, out_dir / "host_motion_start.png")
        screenshot(controller, out_dir / "controller_motion_start.png")

        profiles = [
            ("clean", "full", "none", 10),
            ("lte", "lte", "none", 12),
            ("umts", "umts", "umts", 14),
            ("recovered", "full", "none", 12),
        ]
        summary = []
        previous_touch = 0

        for label, speed, delay, seconds in profiles:
            set_network(host, speed, delay)
            set_network(controller, speed, delay)
            time.sleep(3.0)

            host_remote = f"/sdcard/{label}-host.mp4"
            ctl_remote = f"/sdcard/{label}-controller.mp4"
            hp = start_record(host, host_remote, seconds)
            cp = start_record(controller, ctl_remote, seconds)

            # Exercise the real controller input surface while continuous motion
            # stresses capture/encode/decode/presentation.
            started = time.time()
            while time.time() - started < max(4, seconds - 3):
                gesture_batch(controller)
                time.sleep(0.8)

            hp.wait(timeout=seconds + 8)
            cp.wait(timeout=seconds + 8)

            metric_path = dump_metrics(
                host, label, out_dir, prefix="host"
            )
            dump_metrics(
                controller, label, out_dir, prefix="controller"
            )
            metrics = parse_metric_file(metric_path)
            screenshot(host, out_dir / f"{label}-host.png")
            screenshot(controller, out_dir / f"{label}-controller.png")
            adb(host, "pull", host_remote, str(out_dir / f"{label}-host.mp4"), check=False, timeout=60)
            adb(controller, "pull", ctl_remote, str(out_dir / f"{label}-controller.mp4"), check=False, timeout=60)

            touch = metrics.get("touch_events") or 0
            touch_delta = touch - previous_touch
            previous_touch = touch
            metrics["profile"] = label
            metrics["speed"] = speed
            metrics["delay"] = delay
            metrics["touch_delta"] = touch_delta
            summary.append(metrics)

        set_network(host, "full", "none")
        set_network(controller, "full", "none")

        fields = [
            "profile", "speed", "delay", "touch_delta", "touch_events",
            "gesture_starts", "gesture_ends", "source_fps", "target_fps",
            "send_fps", "decode_fps", "present_fps", "gap_ms", "rtt_ms",
            "loss_pct", "queue_ms", "path", "codec",
        ]
        with open(out_dir / "summary.csv", "w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
            writer.writeheader()
            writer.writerows(summary)

        with open(out_dir / "summary.txt", "w") as f:
            for row in summary:
                f.write(
                    f"{row.get('profile')}: touch+={row.get('touch_delta')} "
                    f"source={row.get('source_fps')} target={row.get('target_fps')} "
                    f"send={row.get('send_fps')} decode={row.get('decode_fps')} "
                    f"present={row.get('present_fps')} gap={row.get('gap_ms')}ms "
                    f"rtt={row.get('rtt_ms')}ms loss={row.get('loss_pct')}% "
                    f"queue={row.get('queue_ms')}ms path={row.get('path')}\n"
                )

        # Hard E2E invariant: controller-side gestures must reach the host on
        # every network phase. FPS thresholds are intentionally reported rather
        # than hard-coded because emulator software codecs are not phone hardware.
        failed = [r for r in summary if (r.get("touch_delta") or 0) <= 0]
        if failed:
            raise RuntimeError(
                "remote gestures did not reach host for: " +
                ", ".join(r["profile"] for r in failed)
            )

        print((out_dir / "summary.txt").read_text())
        return 0

    except Exception as exc:
        # Preserve enough state to diagnose the failed run.
        for serial, name in [(host, "host"), (controller, "controller")]:
            try:
                (out_dir / f"{name}-ui.xml").write_text(ui_xml(serial))
                screenshot(serial, out_dir / f"{name}-failure.png")
                logs = adb(serial, "logcat", "-d", "-t", "1200", check=False, timeout=20).stdout or ""
                (out_dir / f"{name}-logcat.txt").write_text(logs)
            except Exception:
                pass
        print(f"DUAL E2E FAILED: {exc}", file=sys.stderr)
        return 1

if __name__ == "__main__":
    sys.exit(main())
