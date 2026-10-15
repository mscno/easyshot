#!/usr/bin/env python3
"""Publish one stable, signed appcast item for the verified release DMG."""
import base64
import datetime
import os
import plistlib
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", NS)

def build_feed(info, dmg, repo, signature):
    version = info["CFBundleShortVersionString"]
    build = info["CFBundleVersion"]
    assert len(base64.b64decode(signature, validate=True)) == 64
    assert repo in ("mscno/easyshot", "mscno/QuadcastRGB2S")
    assert dmg.name.endswith(".dmg") and dmg.stat().st_size > 0
    rss = ET.Element("rss", version="2.0")
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = info.get("CFBundleDisplayName", info["CFBundleName"])
    ET.SubElement(channel, "link").text = f"https://github.com/{repo}/releases"
    ET.SubElement(channel, "description").text = "Stable macOS releases"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"Version {version}"
    ET.SubElement(item, "pubDate").text = datetime.datetime.now(datetime.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S GMT")
    ET.SubElement(item, f"{{{NS}}}minimumSystemVersion").text = info["LSMinimumSystemVersion"]
    ET.SubElement(item, "enclosure", {
        "url": f"https://github.com/{repo}/releases/download/v{version}/{dmg.name}",
        "length": str(dmg.stat().st_size), "type": "application/octet-stream",
        f"{{{NS}}}version": str(build), f"{{{NS}}}shortVersionString": version,
        f"{{{NS}}}edSignature": signature,
    })
    return ET.tostring(rss, encoding="utf-8", xml_declaration=True)

if __name__ == "__main__":
    app, dmg, repo = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
    tools = subprocess.check_output(["bash", "scripts/fetch-sparkle.sh"], text=True).strip()
    key = os.environ["SPARKLE_KEY_FILE"]
    signer = str(Path(tools)/"bin/sign_update")
    info = plistlib.loads((app/"Contents/Info.plist").read_bytes())
    signature = subprocess.check_output([signer, "--ed-key-file", key, "-p", str(dmg)], text=True).strip()
    subprocess.run([signer, "--ed-key-file", key, "--verify", str(dmg), signature], check=True)
    feed = dmg.parent/"appcast.xml"
    feed.write_bytes(build_feed(info, dmg, repo, signature))
    subprocess.run([signer, "--ed-key-file", key, "-p", str(feed)], check=True)
    subprocess.run([signer, "--ed-key-file", key, "--verify", str(feed)], check=True)
    print("Verified update archive and signed feed:", feed)
