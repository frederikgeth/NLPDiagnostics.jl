"""Intake contracts use artificial temporary records, never study observations."""
import contextlib
import copy
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "intake", ROOT / "studies/power_diagnostic_pilot/intake.py")
intake = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(intake)


class IntakeContracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.collection_path = self.root / "collection.json"
        self.incident_path = self.root / "incident.json"
        self.incident = {
            "schema_version": "power-incident-intake-v1",
            "status": "prepared_for_evaluation",
            **{key: "Synthetic test declaration: " + key for key in (
                "incident_id", "curator", "permission_reference",
                "independent_preparation_statement", "model_and_environment",
                "inclusion_reason", "resolution_summary")},
            "redactions_and_transformations": [], "known_scope_limitations": [],
        }
        baseline = []
        for field in ("source_records", "original_models", "solver_logs",
                      "resolution_evidence"):
            record = self.record(field + ".txt", "artificial test " + field)
            self.incident[field] = [record]
            if field != "resolution_evidence":
                baseline.append(record)
        self.incident["baseline_materials"] = baseline
        self.incident["scoring_key"] = self.record("key.txt", "artificial answer")
        self.collection = {
            "schema_version": "power-incident-collection-v1",
            "evaluation_plan": self.record("plan.md", "artificial test plan"),
        }
        self.save()

    def record(self, name, content):
        path = self.root / name
        path.write_text(content)
        return {"path": name, "sha256": intake.digest(path)}

    def save(self):
        self.incident_path.write_text(json.dumps(self.incident))
        self.collection["incidents"] = [{
            "path": "incident.json", "sha256": intake.digest(self.incident_path)}]
        self.collection_path.write_text(json.dumps(self.collection))

    def reject(self, message):
        with self.assertRaisesRegex(ValueError, message):
            intake.validate(self.collection_path)

    def test_prepared_inventory_and_portability(self):
        frozen = intake.validate(self.collection_path)
        self.assertEqual(frozen["status"], "prepared_not_run")
        self.assertEqual(len(frozen["incident_ids"]), 1)
        self.assertIn("benchmarks/power_diagnostics_v2.jl", frozen["workflow_sha256"])
        self.assertIn("benchmarks/environments/power_repair_pilot/Manifest.toml",
                      frozen["workflow_sha256"])
        self.assertFalse(any(Path(name).is_absolute() for name in frozen["material_sha256"]))
        self.assertEqual(frozen, intake.validate(self.collection_path))

    def test_unfilled_template_is_rejected(self):
        self.incident["status"] = "template_only_not_an_incident"
        self.save()
        self.reject("not prepared")
        with self.assertRaisesRegex(ValueError, "no incident"):
            intake.validate(ROOT / "studies/power_diagnostic_pilot/intake/collection.json")

    def test_missing_declarations_and_evidence(self):
        original = copy.deepcopy(self.incident)
        for field, empty in (("permission_reference", None), ("curator", " "),
                             ("independent_preparation_statement", None),
                             ("source_records", []), ("original_models", []),
                             ("solver_logs", []), ("resolution_evidence", [])):
            with self.subTest(field=field):
                self.incident = copy.deepcopy(original)
                self.incident[field] = empty
                self.save()
                self.reject(field)

    def test_stale_evidence_and_manifest_hashes(self):
        (self.root / "source_records.txt").write_text("changed")
        self.reject("sha256 mismatch")
        self.incident_path.write_text("{}")
        self.reject("sha256 mismatch")

    def test_missing_baseline_evidence(self):
        self.incident["baseline_materials"].pop()
        self.save()
        self.reject("baseline omits")

    def test_private_answer_and_renamed_copy_rejected(self):
        for name in ("key.txt", "resolution_evidence.txt"):
            with self.subTest(name=name):
                private_copy = self.record("renamed.txt", (self.root / name).read_text())
                self.incident["baseline_materials"].append(private_copy)
                self.save()
                self.reject("baseline exposes private")
                self.incident["baseline_materials"].pop()

    def test_duplicate_records_and_ids(self):
        self.collection["incidents"] *= 2
        self.collection_path.write_text(json.dumps(self.collection))
        self.reject("duplicate incident record")
        self.save()
        self.collection["incidents"].append(self.record(
            "second.json", json.dumps(self.incident)))
        self.collection_path.write_text(json.dumps(self.collection))
        self.reject("duplicate incident id")

    def test_path_escape_and_external_symlink_rejected(self):
        for name in ("../key.txt", str(self.root / "key.txt")):
            with self.subTest(name=name):
                with self.assertRaisesRegex(ValueError, "inside material root"):
                    intake.local_path(self.root, name)
        (self.root / "external").symlink_to(ROOT / "Project.toml")
        with self.assertRaisesRegex(ValueError, "outside material root"):
            intake.local_path(self.root, "external")

    def test_freeze_rejects_changes_even_when_rehashed(self):
        freeze = self.root / "freeze.json"
        freeze.write_text(json.dumps(intake.validate(self.collection_path)))
        intake.verify(freeze, self.collection_path)
        self.incident["inclusion_reason"] = "different inclusion rule"
        self.save()
        with self.assertRaisesRegex(ValueError, "freeze differs"):
            intake.verify(freeze, self.collection_path)

    def test_workflow_changes_and_additions_invalidate_freeze(self):
        code_root = self.root / "workflow"
        for name in intake.code_inventory(ROOT):
            path = code_root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes((ROOT / name).read_bytes())
        freeze = self.root / "freeze.json"
        freeze.write_text(json.dumps(intake.validate(self.collection_path, code_root)))
        intake.verify(freeze, self.collection_path, code_root)
        extra = code_root / "src/added.jl"
        extra.write_text("# new runtime file")
        with self.assertRaisesRegex(ValueError, "freeze differs"):
            intake.verify(freeze, self.collection_path, code_root)
        extra.unlink()
        (code_root / "Project.toml").write_text("changed dependency")
        with self.assertRaisesRegex(ValueError, "freeze differs"):
            intake.verify(freeze, self.collection_path, code_root)

    def test_cli_freeze_verify_and_overwrite_protection(self):
        freeze = self.root / "freeze.json"
        command = [sys.executable, str(ROOT / "studies/power_diagnostic_pilot/intake.py")]
        for action, status in (("check", 0), ("freeze", 0), ("verify", 0), ("freeze", 1)):
            result = subprocess.run(command + [action, str(self.collection_path),
                                    "--freeze", str(freeze)], capture_output=True, text=True)
            self.assertEqual(result.returncode, status, result.stderr)
        self.assertEqual(json.loads(freeze.read_text())["status"], "prepared_not_run")

    def test_malformed_inputs_fail_without_traceback(self):
        self.collection_path.write_text("[]")
        with contextlib.redirect_stderr(io.StringIO()) as output:
            self.assertEqual(intake.main(["check", str(self.collection_path)]), 1)
        self.assertIn("collection must be an object", output.getvalue())


if __name__ == "__main__":
    unittest.main()
