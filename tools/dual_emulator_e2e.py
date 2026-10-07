#!/usr/bin/env python3
import argparse
import csv
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
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

def ui_xml(serial):
    shell(serial, "uiautomator", "dump", "/sdcard/aaris-ui.xml", check=False, timeout=20)
    p = shell(serial, "cat", "/sdcard/aaris-ui.xml", check=False)
    return p.stdout or ""

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
    lowers = [x.lower() for x in options]
    node = find_node(
        serial,
        lambda n: any(
            candidate == value.lower()
            or candidate in value.lower()
            for candidate in lowers
            for value in node_values(n)
        ),
        timeout,
    )
    center = bounds_center(node.attrib.get("bounds"))
    if not center:
        raise RuntimeError(f"node has no bounds: {node.attrib}")
    shell(serial, "input", "tap", str(center[0]), str(center[1]))
    return node_text(node)

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

def wm_size(serial):
    out = shell(serial, "wm", "size").stdout or ""
    m = re.search(r"(\d+)x(\d+)", out)
    if not m:
        return (1080, 1920)
    return tuple(map(int, m.groups()))

def set_network(serial, speed, delay):
    adb(serial, "emu", "network", "speed", speed, check=False)
    adb(serial, "emu", "network", "delay", delay, check=False)

def dump_metrics(host, label, out_dir):
    shell(
        host,
        "am", "broadcast",
        "-a", DUMP_ACTION,
        "--es", "label", label,
        check=False,
    )
    time.sleep(0.5)
    remote = f"/sdcard/Android/data/{PKG}/files/dual-e2e/{label}.txt"
    local = out_dir / f"{label}.txt"
    adb(host, "pull", remote, str(local), check=False)
    return local

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
    chooser_packages = {
        "com.android.intentresolver",
        "com.google.android.intentresolver",
    }
    chooser_deadline = time.time() + 8
    while time.time() < chooser_deadline:
        nodes = parse_nodes(ui_xml(host))
        packages = {
            node.attrib.get("package", "")
            for node in nodes
        }
        if packages.intersection(chooser_packages):
            shell(host, "input", "keyevent", "KEYCODE_BACK")
            wait_text(host, "Aaris Remote", timeout=15)
            break
        time.sleep(0.25)

    click_text(controller, "Connect", timeout=20)
    wait_text(controller, "12-digit one-time code", timeout=20)
    shell(controller, "input", "text", code)
    time.sleep(0.4)
    click_text(controller, "START", timeout=15)

    wait_text(host, "Start remote support?", timeout=40)
    click_text(host, "START", timeout=15)

    # API 33 MediaProjection prompt. Text differs slightly by image/vendor.
    try:
        wait_text(host, "recording or casting", timeout=25)
    except Exception:
        # Some images phrase this as "start sharing/recording".
        pass
    click_first_text(
        host,
        ["Start now", "START NOW", "Share", "Start"],
        timeout=30,
    )

    wait_text(controller, "Remote screen open", timeout=65)
    # Give SCTP telemetry/video lanes time to open before exercising motion.
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

            metric_path = dump_metrics(host, label, out_dir)
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
