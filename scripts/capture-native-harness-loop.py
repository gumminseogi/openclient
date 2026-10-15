#!/usr/bin/env python3
"""Record the DEBUG native fixture, then crop/encode its actual simulator pixels.

Usage: python3 scripts/capture-native-harness-loop.py <simulator-udid> <built-app-path>
Use the landscape iPad Pro 13-inch for the ASC exports. No UI is re-rendered here.
"""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "fastlane/app-previews/native-harness-loop/en-US"
OUT.mkdir(parents=True, exist_ok=True)
DEVICE, APP = sys.argv[1:3]
BUNDLE = "com.ntoporcov.openclient"


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


header_only = "--header" in sys.argv
raw = OUT / ("header-simulator-recording.mov" if header_only else "simulator-recording.mov")
if "--export-only" not in sys.argv:
    run("xcrun", "simctl", "install", DEVICE, APP)
    subprocess.run(["xcrun", "simctl", "terminate", DEVICE, BUNDLE], capture_output=True)
    run("xcrun", "devicectl", "device", "orientation", "set", "--device", DEVICE, "landscapeRight")
    recorder = subprocess.Popen(
        ["xcrun", "simctl", "io", DEVICE, "recordVideo", "--codec=h264", "--force", str(raw)],
        stderr=subprocess.PIPE, text=True,
    )
    try:
        for line in recorder.stderr:
            print(line.strip(), flush=True)
            if "Recording started" in line:
                break
        else:
            raise RuntimeError("Simulator recorder did not start")
        env = dict(os.environ, SIMCTL_CHILD_OPENCLIENT_SCREENSHOT_SCENE="chat",
                   SIMCTL_CHILD_OPENCLIENT_NATIVE_HARNESS_LOOP="1",
                   SIMCTL_CHILD_OPENCLIENT_UI_TEST_DARK_MODE="1")
        env["SIMCTL_CHILD_OPENCLIENT_NATIVE_HARNESS_HEADER"] = "1" if header_only else "0"
        run("xcrun", "simctl", "launch", DEVICE, BUNDLE,
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", env=env)
        time.sleep(12)
        run("xcrun", "simctl", "io", DEVICE, "screenshot", str(OUT / "native-thinking.png"))
        time.sleep(20)
    finally:
        recorder.send_signal(signal.SIGINT)
        recorder.wait(timeout=30)
    if recorder.returncode:
        raise RuntimeError(f"Simulator recorder failed: {recorder.returncode}")

info = json.loads(subprocess.check_output([
    "ffprobe", "-v", "error", "-show_streams", "-of", "json", str(raw)
]))["streams"][0]
width, height = info["width"], info["height"]
# FFmpeg autorotates the simulator's portrait framebuffer using its display matrix.
rotation = next((side["rotation"] for side in info.get("side_data_list", []) if "rotation" in side), 0)
if abs(rotation) % 180 == 90:
    width, height = height, width
if width < height:
    raise RuntimeError("The export recording must be landscape; check iPad rotation")
# The fixture's 16-point magenta sync square is at (40,40), outside both crops.
# Sample the center using the iPad's 2x framebuffer scale.
samples = subprocess.check_output([
    "ffmpeg", "-v", "error", "-i", str(raw), "-vf", "fps=30,crop=2:2:94:94,scale=1:1",
    "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1",
])
starts = []
was_magenta = False
for index in range(0, len(samples), 3):
    r, g, b = samples[index:index+3]
    magenta = r > 180 and g < 100 and b > 180
    if magenta and not was_magenta:
        starts.append(index // 3 / 30)
    was_magenta = magenta
if len(starts) < 2:
    raise RuntimeError(f"Expected two native loop cues, got {starts}; inspect the raw recording")
start, end = starts[:2]
print(f"Native loop boundaries: {start:.3f}–{end:.3f}s", flush=True)
exports = [("header", 3840, 1646)] if header_only else [("search-results", 3840, 2560)]
for name, w, h in exports:
    crop_h = int(width * h / w) // 2 * 2
    if crop_h > height:
        raise RuntimeError("Capture does not contain enough vertical pixels for the requested crop")
    target = OUT / f"{name}-native-loop.mp4"
    run("ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-ss", str(start), "-i", str(raw),
        "-t", str(end-start), "-vf", f"crop={width}:{crop_h}:0:(ih-oh)/2,scale={w}:{h}:flags=lanczos,fps=30",
        "-an", "-c:v", "libx264", "-preset", "slow", "-crf", "18", "-pix_fmt", "yuv420p",
        "-movflags", "+faststart", str(target))
    run("ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-ss", "2", "-i", str(target),
        "-frames:v", "1", str(OUT / f"{name}-poster.png"))
    print(f"Exported {target}", flush=True)
