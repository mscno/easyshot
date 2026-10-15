#!/usr/bin/env python3
"""Offline checks only: never calls Apple or reads signing credentials."""
import argparse
import json
import plistlib
import re
import struct
import subprocess
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--ready", action="store_true", help="Treat missing listing fields as errors")
parser.add_argument("--app", type=Path, help="Also check a built Store .app bundle")
args = parser.parse_args()
errors, pending = [], []
draft = ROOT / "docs/app-store"
metadata = json.loads((draft / "metadata.json").read_text())


def require(condition, message):
    if not condition:
        errors.append(message)


require(not args.ready or args.app is not None, "--ready also requires --app for bundle checks")
for field, limit in (("name", 30), ("subtitle", 30), ("keywords", 100)):
    require(0 < len(metadata[field]) <= limit, f"{field} must contain 1–{limit} characters")
require(len((draft / "description.txt").read_text()) <= 4000, "Description exceeds 4,000 characters")
require(metadata["bundleId"] == "no.paraply.easyshot", "Unexpected bundle ID")
require(metadata["price"] == "FREE", "Listing must be free")
require(metadata["architecture"] == "arm64", "Only Apple Silicon is supported")
require(metadata["minimumMacOS"] == "26.0", "Expected macOS 26 minimum")
require(metadata["seller"] == "Paraply Ventures AS", "Unexpected seller")
require(metadata["releaseMode"] == "MANUAL", "Keep release under manual control")
require(metadata["privacy"] == {"tracking": False, "dataCollected": False}, "Privacy answers changed; review policy")
for field in ("marketingUrl", "supportUrl", "privacyPolicyUrl"):
    value = metadata.get(field, "")
    if not value:
        pending.append(f"Confirm and publish {field}")
    else:
        parsed = urlparse(value)
        require(parsed.scheme == "https" and bool(parsed.hostname), f"Invalid HTTPS {field}")
contact = metadata["reviewContact"]
if not contact.get("email"):
    pending.append("Add a working App Review contact email")
else:
    require(bool(re.fullmatch(r"[^\s@]+@[^\s@]+\.[^\s@]+", contact["email"])), "Invalid contact email")
if not contact.get("phone"):
    pending.append("Add an App Review contact phone number")

# Check actual PNG headers and transparency, without image libraries or network I/O.
screenshots = metadata.get("screenshots", [])
require(len(screenshots) <= 10, "At most ten screenshots per listing")
if not screenshots:
    pending.append("Add actual Store-edition screenshots")
for filename in screenshots:
    screenshot = (draft / filename).resolve()
    if not screenshot.is_file():
        errors.append(f"Missing screenshot: {filename}")
        continue
    data = screenshot.read_bytes()
    if len(data) < 33 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        errors.append(f"Screenshot must be a valid PNG: {filename}")
        continue
    width, height = struct.unpack(">II", data[16:24])
    require((width, height) in {(1280, 800), (1440, 900), (2560, 1600), (2880, 1800)}, f"Invalid Mac screenshot dimensions: {filename} ({width}×{height})")
    transparent = data[25] in (4, 6)
    offset = 8
    while offset + 12 <= len(data):
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        kind = data[offset + 4:offset + 8]
        if kind == b"tRNS":
            transparent = True
        offset += length + 12
        if kind == b"IEND":
            break
    require(not transparent, f"Screenshot has an alpha channel: {filename}")

manifest = plistlib.loads((ROOT / "Resources/PrivacyInfo.xcprivacy").read_bytes())
require(manifest["NSPrivacyTracking"] is False, "Manifest enables tracking")
require(not manifest["NSPrivacyCollectedDataTypes"], "Manifest declares data collection")
entitlements = plistlib.loads((ROOT / "Resources/Easyshot-AppStore.entitlements").read_bytes())
require(entitlements.get("com.apple.security.app-sandbox") is True, "Missing App Sandbox entitlement")
allowed = {"com.apple.security.app-sandbox", "com.apple.security.files.user-selected.read-write", "com.apple.security.files.bookmarks.app-scope", "com.apple.security.device.audio-input", "com.apple.security.device.camera"}
require(set(entitlements) == allowed, "Unexpected Store entitlements; review permissions")

if args.app:
    app = args.app.resolve()
    try:
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        require(info["CFBundleIdentifier"] == metadata["bundleId"], "Built app bundle ID mismatch")
        require(info.get("LSApplicationCategoryType") == "public.app-category.utilities", "Built app Store category missing")
        executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
        arch = subprocess.check_output(["lipo", "-archs", str(executable)], text=True).strip()
        require(arch == "arm64", "Built app is not arm64 only")
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True, capture_output=True)
        result = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(app)], check=True, capture_output=True)
        signed_entitlements = plistlib.loads(result.stdout)
        require(signed_entitlements.get("com.apple.security.app-sandbox") is True, "Built app lacks App Sandbox")
        require(all(signed_entitlements.get(key) is True for key in allowed), "Built app entitlement mismatch")
        symbols = subprocess.check_output(["nm", "-u", str(executable)], text=True)
        require(not re.search(r"_(AXIsProcessTrusted\w*|CGEventPost)\b", symbols), "Store binary references restricted Accessibility/event APIs")
        require((app / "Contents/Resources/PrivacyInfo.xcprivacy").read_bytes() == (ROOT / "Resources/PrivacyInfo.xcprivacy").read_bytes(), "Built privacy manifest differs")
        signature = subprocess.run(["codesign", "-dv", "--verbose=2", str(app)], check=True, capture_output=True, text=True).stderr
        if "TeamIdentifier=93627F7C77" not in signature or not re.search(r"Authority=(Apple Distribution|3rd Party Mac Developer Application):", signature):
            pending.append("Replace ad-hoc/development preview signing with Paraply App Store distribution signing")
    except (OSError, KeyError, ValueError, subprocess.CalledProcessError) as error:
        errors.append(f"Bundle check failed: {error}")

for message in errors:
    print(f"ERROR: {message}")
for message in pending:
    print(f"PENDING: {message}")
if errors or (args.ready and pending):
    raise SystemExit(1)
print("Offline draft checks passed." if pending else "Offline checks passed. Apple validation and manual review remain separate.")
