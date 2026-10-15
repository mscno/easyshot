import base64
import importlib.util
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("appcast", ROOT/"scripts/generate-appcast.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class AppcastTests(unittest.TestCase):
    def test_feed_uses_build_number_fixed_release_and_native_requirements(self):
        with tempfile.TemporaryDirectory() as folder:
            dmg=Path(folder)/"App-1.2.3-AppleSilicon.dmg";dmg.write_bytes(b"verified dmg")
            info=dict(CFBundleName="App",CFBundleShortVersionString="1.2.3",CFBundleVersion="42",LSMinimumSystemVersion="26.0")
            tree=ET.fromstring(module.build_feed(info,dmg,"mscno/easyshot",base64.b64encode(bytes(64)).decode()))
            enclosure=tree.find("channel/item/enclosure")
            self.assertEqual(enclosure.get("url"),"https://github.com/mscno/easyshot/releases/download/v1.2.3/"+dmg.name)
            self.assertEqual(enclosure.get("length"),str(dmg.stat().st_size))
            self.assertEqual(enclosure.get("{"+module.NS+"}version"),"42")
            self.assertEqual(tree.find("channel/item/{"+module.NS+"}minimumSystemVersion").text,"26.0")
    def test_invalid_signatures_are_rejected(self):
        with self.assertRaises(AssertionError):
            module.build_feed(dict(CFBundleShortVersionString="1.0.0",CFBundleVersion="1"),Path("unused"),"mscno/easyshot",base64.b64encode(bytes(32)).decode())
