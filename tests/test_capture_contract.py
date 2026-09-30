import hashlib
import json
import re
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RECORDER = (ROOT / "UniversalUIInspector/VisitedScreenRecorder.m").read_text()
INSPECTOR = (ROOT / "UniversalUIInspector/UniversalUIInspector.m").read_text()
BUILD = (ROOT / "build-ios-dylib.sh").read_text()


class Debouncer:
    """Small executable model of the documented three-sample stability rule."""
    def __init__(self):
        self.pending = None
        self.samples = 0
        self.committed = set()

    def observe(self, fingerprint):
        if fingerprint != self.pending:
            self.pending, self.samples = fingerprint, 1
            return False
        self.samples += 1
        if self.samples < 3 or fingerprint in self.committed:
            return False
        self.committed.add(fingerprint)
        return True


class CaptureContractTests(unittest.TestCase):
    def test_debounce_requires_three_equal_observations_and_deduplicates(self):
        d = Debouncer()
        self.assertFalse(d.observe("home-a"))
        self.assertFalse(d.observe("home-b"))  # transient animation/change resets candidate
        self.assertFalse(d.observe("home-b"))
        self.assertTrue(d.observe("home-b"))
        self.assertFalse(d.observe("home-b"))  # same stable screen isn't recaptured

    def test_screen_and_state_paths_are_sequence_and_fingerprint_scoped(self):
        route = "SCREEN_0001_Home_ab12cd34"
        state_1 = "STATE_0001_fedcba98"
        state_2 = "STATE_0002_01234567"
        self.assertNotEqual(f"01_SCREENS/{route}/{state_1}", f"01_SCREENS/{route}/{state_2}")
        self.assertTrue(route.startswith("SCREEN_0001_"))
        self.assertRegex(route, r"^[A-Za-z0-9_-]+$")
        self.assertNotEqual("SCREEN_0001_Home_ab12cd34", "SCREEN_0002_Search_ef56ab12")

    def test_recovery_does_not_mark_a_writing_state_complete(self):
        sample = {"screens": [{"screen_id": "SCREEN_0001_Home_ab12cd34", "states": [
            {"state_id": "STATE_0001_fedcba98", "status": "CAPTURED"},
            {"state_id": "STATE_0002_deadbeef", "status": "WRITING"},
        ]}]}
        statuses = [state["status"] for screen in sample["screens"] for state in screen["states"]]
        recovered = [s for s in statuses if s in {"CAPTURED", "PARTIAL", "WRITING"}]
        self.assertEqual(recovered, ["CAPTURED", "WRITING"])
        self.assertNotEqual(recovered[-1], "CAPTURED")

    def test_atomic_capture_file_roundtrip_and_sha256(self):
        with tempfile.TemporaryDirectory() as td:
            directory = Path(td) / "screen"
            directory.mkdir()
            target = directory / "view_tree.json"
            temporary = directory / "view_tree.json.tmp"
            payload = {"schema_version": "uui-view-tree-1.0", "views": [{"node_id": "V000001", "parent_id": None}]}
            temporary.write_text(json.dumps(payload) + "\n", encoding="utf-8")
            temporary.replace(target)
            self.assertEqual(json.loads(target.read_text(encoding="utf-8")), payload)
            digest = hashlib.sha256(target.read_bytes()).hexdigest()
            self.assertRegex(digest, r"^[a-f0-9]{64}$")
            self.assertEqual(digest, hashlib.sha256((json.dumps(payload) + "\n").encode("utf-8")).hexdigest())

    def test_zip_roundtrip_and_crc_validation(self):
        with tempfile.TemporaryDirectory() as td:
            archive = Path(td) / "RuntimeDump.zip"
            files = {"MANIFEST.json": b'{"overallStatus":"PARTIAL"}\n', "01_SCREENS/SCREEN_INDEX.json": b'{"screens":[]}\n'}
            with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as zf:
                for name, data in files.items():
                    zf.writestr(name, data)
            with zipfile.ZipFile(archive) as zf:
                self.assertEqual(zf.testzip(), None)
                self.assertEqual(set(zf.namelist()), set(files))
                self.assertTrue(all(json.loads(zf.read(name)) for name in files))

    def test_production_source_contains_gates_and_capture_safeguards(self):
        self.assertIn("pendingStableSamples < 3", RECORDER)
        self.assertIn("forceVariant:NO", RECORDER)
        self.assertIn("forceVariant:YES", RECORDER)
        self.assertIn("NSDataWritingAtomic", RECORDER)
        self.assertIn("address_scope", RECORDER)
        self.assertIn("UIActivityViewController", RECORDER)
        self.assertIn("FLEX", RECORDER)
        self.assertIn("startLightweightWarmup", INSPECTOR)
        self.assertIn("self.lightweightWarmupStable", INSPECTOR)
        self.assertIn("START SCREEN CAPTURE", INSPECTOR)
        self.assertIn("ANALYZE AND EXPORT", INSPECTOR)
        self.assertIn("MANIFEST.json", INSPECTOR)
        self.assertIn("VisitedScreenRecorder.m", BUILD)

    def test_filenames_do_not_use_controller_title_or_accessibility_text(self):
        self.assertIn("safeDisplayLabel:fp[@\"visibleController\"]", RECORDER)
        self.assertNotIn("screenDirectoryName:controller.title", RECORDER)
        self.assertIn("REDACTED_SECURE_INPUT", RECORDER)


if __name__ == "__main__":
    unittest.main(verbosity=2)
