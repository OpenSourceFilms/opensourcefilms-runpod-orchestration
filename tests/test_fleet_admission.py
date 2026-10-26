"""Synthetic, offline fail-closed checks for GPU-placement advice.

Not tests of the OSF production scheduler, Runpod API or native GPU brokers.
"""
from __future__ import annotations
import copy
import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

BASE = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = BASE / "examples" / "fleet_admission.py"
spec = importlib.util.spec_from_file_location("fleet_admission", SCRIPT)
admission = importlib.util.module_from_spec(spec)
spec.loader.exec_module(admission)


class PlacementContract(unittest.TestCase):
    def setUp(self):
        self.fixture = json.loads((BASE / "examples" / "fleet_snapshot.example.json").read_text())
        self.data = copy.deepcopy(self.fixture)

    def test_deterministic_best_fit_and_stale_rejection(self):
        out = admission.plan(self.data)
        self.assertEqual(out["status"], "candidate_only")
        self.assertEqual(out["selected_pod"], "demo-gpu-b")
        self.assertIn("stale_observation", out["checked"][2]["reasons"])

    def test_request_does_not_launch_or_reserve(self):
        result = admission.plan(self.data)
        self.assertTrue(result["disclaimer"].startswith("No reservation"))
        self.assertEqual(self.data, self.fixture)

    def test_duplicate_queue_or_uncertain_prevents_new_routing(self):
        for state in ("queued", "leased", "running", "uncertain"):
            with self.subTest(state=state):
                x = copy.deepcopy(self.data)
                x["existing_jobs"].append({"job_key": x["request"]["job_key"], "state": state})
                out = admission.plan(x)
                self.assertEqual(out["status"], "already_registered")
                self.assertIsNone(out["selected_pod"])

    def test_completed_earlier_job_does_not_block_new_candidate(self):
        self.data["existing_jobs"] = [{"job_key": self.data["request"]["job_key"], "state": "succeeded"}]
        self.assertEqual(admission.plan(self.data)["status"], "candidate_only")

    def test_rejects_future_clock_and_stale(self):
        self.data["pods"][0]["observed_at_unix"] = self.data["now_unix"] + 1
        self.data["pods"][1]["observed_at_unix"] = self.data["now_unix"] - 31
        self.assertEqual(admission.plan(self.data)["status"], "no_eligible_pod")

    def test_unhealthy_or_untrusted_agents_never_selected(self):
        self.data["pods"][0]["authenticated"] = False
        self.data["pods"][1]["healthy"] = False
        out = admission.plan(self.data)
        self.assertEqual(out["status"], "no_eligible_pod")
        self.assertIn("unauthenticated", out["checked"][0]["reasons"])
        self.assertIn("unhealthy", out["checked"][1]["reasons"])

    def test_project_allowlist_and_architecture(self):
        self.data["pods"][0]["architecture"] = "hopper"
        self.data["pods"][1]["allowed_projects"] = ["another-project"]
        out = admission.plan(self.data)
        self.assertEqual(out["status"], "no_eligible_pod")
        self.assertIn("project_not_allowed", out["checked"][1]["reasons"])

    def test_software_tags_and_native_waiters(self):
        self.data["pods"][0]["tags"] = ["python"]
        self.data["pods"][1]["native_waiters"] = 1
        out = admission.plan(self.data)
        self.assertEqual(out["status"], "no_eligible_pod")
        self.assertIn("native_waiters_present", out["checked"][1]["reasons"])

    def test_broker_admittable_capacity_not_allocated_vram(self):
        self.data["pods"][0]["broker_admittable_mib"] = 23000
        self.data["pods"][1]["broker_admittable_mib"] = 20000
        self.data["pods"][0]["nvidia_smi_physically_free_mib"] = 90000
        out = admission.plan(self.data)
        self.assertEqual(out["status"], "no_eligible_pod")
        self.assertIn("insufficient_broker_capacity", out["checked"][0]["reasons"])

    def test_tie_break_is_pod_id(self):
        self.data["pods"][0]["broker_admittable_mib"] = 26000
        out = admission.plan(self.data)
        self.assertEqual(out["selected_pod"], "demo-gpu-a")

    def test_duplicate_ids_are_malformed(self):
        self.data["pods"][1]["pod_id"] = self.data["pods"][0]["pod_id"]
        with self.assertRaisesRegex(admission.InvalidSnapshot, "duplicate"):
            admission.plan(self.data)

    def test_boolean_cannot_impersonate_integer_capacity(self):
        self.data["request"]["vram_mib"] = True
        with self.assertRaises(admission.InvalidSnapshot):
            admission.plan(self.data)

    def test_forged_broker_capacity_is_malformed(self):
        self.data["pods"][0]["broker_admittable_mib"] = self.data["pods"][0]["vram_total_mib"] + 1
        with self.assertRaises(admission.InvalidSnapshot):
            admission.plan(self.data)

    def test_nonfinite_or_negative_timestamps_fail(self):
        for invalid in (float("nan"), float("inf"), -1, "2026-10-26"):
            with self.subTest(invalid=invalid):
                self.data["pods"][0]["observed_at_unix"] = invalid
                with self.assertRaises(admission.InvalidSnapshot):
                    admission.plan(self.data)

    def test_negative_waiters_and_nonboolean_health_fail(self):
        self.data["pods"][0]["native_waiters"] = -1
        with self.assertRaises(admission.InvalidSnapshot):
            admission.plan(self.data)
        self.data["pods"][0]["native_waiters"] = 0
        self.data["pods"][0]["authenticated"] = "true"
        with self.assertRaises(admission.InvalidSnapshot):
            admission.plan(self.data)

    def test_unknown_schema_fails_closed(self):
        self.data["schema"] = "runpod.production/1"
        with self.assertRaisesRegex(admission.InvalidSnapshot, "schema"):
            admission.plan(self.data)

    def test_cli_no_network_and_known_exit_codes(self):
        with tempfile.TemporaryDirectory() as d:
            f = pathlib.Path(d)/"snapshot.json"
            f.write_text(json.dumps(self.data))
            result = subprocess.run([sys.executable, str(SCRIPT), str(f)],capture_output=True,text=True,timeout=10)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(json.loads(result.stdout)["selected_pod"],"demo-gpu-b")
            x = copy.deepcopy(self.data)
            x["pods"] = []
            f.write_text(json.dumps(x))
            result = subprocess.run([sys.executable, str(SCRIPT), str(f)],capture_output=True,text=True,timeout=10)
            self.assertEqual(result.returncode,2)
            x["schema"] = "not_a_real_schema"
            f.write_text(json.dumps(x))
            result = subprocess.run([sys.executable, str(SCRIPT), str(f)],capture_output=True,text=True,timeout=10)
            self.assertEqual(result.returncode,3)
            self.assertIn("invalid_snapshot",result.stderr)


if __name__ == "__main__":
    unittest.main()
