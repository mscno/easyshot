"""Exercise real shell control flow with a local, non-networking notarytool stub."""
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SUBMISSION = "24d25893-0996-475a-ba83-1ecd25c5096d"
STUB = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
command = sys.argv[2]
with open(os.environ["CALL_LOG"], "a") as log:
    log.write(command + "\\n")
mode = os.environ["TEST_MODE"]
if command == "submit":
    print(json.dumps({"id": os.environ["SUBMISSION_ID"]}))
elif command == "wait":
    if mode.startswith("timeout"):
        print(json.dumps({"message": "Timeout"}))
        sys.exit(124)
    print(json.dumps({"status": "Invalid" if mode == "invalid" else "Accepted"}))
elif command == "info":
    print(json.dumps({"status": "Accepted" if mode == "timeout-accepted" else "In Progress"}))
elif command == "log":
    Path(sys.argv[-1]).write_text(json.dumps({"issues": [{"message": "Invalid signature"}]}))
else:
    sys.exit(99)
'''


class NotarizationTests(unittest.TestCase):
    def run_case(self, mode, submission=SUBMISSION, timeout="90m"):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        folder = Path(temp.name)
        binary = folder / "bin"
        binary.mkdir()
        stub = binary / "xcrun"
        stub.write_text(STUB)
        stub.chmod(0o755)
        archive = folder / "Easyshot.zip"
        archive.write_bytes(b"local test fixture")
        log = folder / "calls.txt"
        env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ["PATH"],
                   NOTARY_PROFILE="test-only", NOTARY_KEYCHAIN="", NOTARY_TIMEOUT=timeout,
                   TEST_MODE=mode, CALL_LOG=str(log), SUBMISSION_ID=submission)
        result = subprocess.run(["bash", str(ROOT / "scripts/notarize.sh"), str(archive), "app", str(folder)],
                                env=env, capture_output=True, text=True, timeout=10)
        calls = log.read_text().splitlines() if log.exists() else []
        return result, calls, folder

    def test_accepted_submission_succeeds_and_retains_id(self):
        result, calls, folder = self.run_case("accepted")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["submit", "wait"])
        self.assertEqual(json.loads((folder / "app-notarization-submission.json").read_text())["id"], SUBMISSION)

    def test_rejected_submission_fails_and_saves_apple_log(self):
        result, calls, folder = self.run_case("invalid")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, ["submit", "wait", "log"])
        self.assertTrue((folder / "app-notarization-log.json").exists())

    def test_timeout_keeps_pending_submission_and_does_not_resubmit(self):
        result, calls, folder = self.run_case("timeout-pending")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, ["submit", "wait", "info"])
        self.assertEqual(json.loads((folder / "app-notarization-status.json").read_text())["status"], "In Progress")
        self.assertIn("No release DMG will be published", result.stderr)

    def test_acceptance_at_timeout_boundary_succeeds(self):
        result, calls, _ = self.run_case("timeout-accepted")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["submit", "wait", "info"])

    def test_malformed_submission_id_never_waits(self):
        result, calls, _ = self.run_case("accepted", submission="not-a-submission")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, ["submit"])

    def test_invalid_timeout_fails_before_uploading(self):
        result, calls, _ = self.run_case("accepted", timeout="invalid")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
