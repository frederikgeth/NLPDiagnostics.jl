"""Validate and freeze incident intake before diagnostics. Python standard library only.

This checks declared records and byte consistency, not permission authenticity,
independence, semantic answer leakage, or completeness of a scientific protocol.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def text_field(record, key):
    value = record.get(key)
    require(isinstance(value, str) and bool(value.strip()), f"missing text: {key}")


def local_path(root, name):
    require(isinstance(name, str) and bool(name), "missing relative file path")
    relative = Path(name)
    require(not relative.is_absolute() and ".." not in relative.parts,
            f"path must stay inside material root: {name}")
    path = (root / relative).resolve()
    require(path.is_relative_to(root.resolve()) and path.is_file(),
            f"missing file or path outside material root: {name}")
    return path


def file_record(root, record, inventory):
    require(isinstance(record, dict), "file record must contain path and sha256")
    path = local_path(root, record.get("path"))
    expected = record.get("sha256")
    require(isinstance(expected, str) and re.fullmatch(r"[0-9a-f]{64}", expected),
            f"invalid sha256: {record.get('path')}")
    require(digest(path) == expected, f"sha256 mismatch: {record['path']}")
    canonical = path.relative_to(root.resolve()).as_posix()
    inventory[canonical] = expected
    return canonical


def file_list(root, value, inventory, label):
    require(isinstance(value, list) and bool(value), f"{label} must contain files")
    paths = [file_record(root, item, inventory) for item in value]
    require(len(set(paths)) == len(paths), f"duplicate file in {label}")
    return set(paths)


def code_inventory(root):
    paths = set()
    for directory in ("src", "ext", "benchmarks/power_repair_pilot"):
        paths.update((root / directory).rglob("*.jl"))
    for relative in (
        "Project.toml", "benchmarks/common.jl", "benchmarks/power_diagnostics_v2.jl",
        "benchmarks/run_power_diagnostics_v2.jl",
        "benchmarks/environments/power_repair_pilot/Project.toml",
        "benchmarks/environments/power_repair_pilot/Manifest.toml",
        "studies/power_diagnostic_pilot/intake.py",
        "studies/power_diagnostic_pilot/protocol.md",
    ):
        path = root / relative
        require(path.is_file(), f"missing workflow file: {relative}")
        paths.add(path)
    return {path.relative_to(root).as_posix(): digest(path) for path in sorted(paths)}


def validate(collection_path, code_root=ROOT):
    collection_path = collection_path.resolve()
    root = collection_path.parent
    collection = json.loads(collection_path.read_text())
    require(isinstance(collection, dict), "collection must be an object")
    require(collection.get("schema_version") == "power-incident-collection-v1",
            "unsupported collection schema")
    incidents = collection.get("incidents")
    require(isinstance(incidents, list) and bool(incidents), "no incident records supplied")
    inventory = {collection_path.name: digest(collection_path)}
    file_record(root, collection.get("evaluation_plan"), inventory)
    ids, incident_paths, private, public = set(), set(), set(), set()
    for reference in incidents:
        name = file_record(root, reference, inventory)
        require(name not in incident_paths, f"duplicate incident record: {name}")
        incident_paths.add(name)
        incident = json.loads((root / name).read_text())
        require(isinstance(incident, dict), f"incident must be an object: {name}")
        require(incident.get("schema_version") == "power-incident-intake-v1",
                f"unsupported incident schema: {name}")
        require(incident.get("status") == "prepared_for_evaluation",
                f"incident is not prepared: {name}")
        for field in ("incident_id", "curator", "permission_reference",
                      "independent_preparation_statement", "model_and_environment",
                      "inclusion_reason", "resolution_summary"):
            text_field(incident, field)
        ident = incident["incident_id"]
        require(ident not in ids, f"duplicate incident id: {ident}")
        ids.add(ident)
        required = set()
        for field in ("source_records", "original_models", "solver_logs"):
            required.update(file_list(root, incident.get(field), inventory, field))
        private.update(file_list(root, incident.get("resolution_evidence"), inventory,
                                 "resolution_evidence"))
        private.add(file_record(root, incident.get("scoring_key"), inventory))
        baseline = file_list(root, incident.get("baseline_materials"), inventory,
                             "baseline_materials")
        require(required <= baseline, f"baseline omits source/model/log evidence: {ident}")
        public.update(baseline)
        for field in ("redactions_and_transformations", "known_scope_limitations"):
            require(isinstance(incident.get(field), list) and
                    all(isinstance(item, str) and item.strip() for item in incident[field]),
                    f"{field} must be an explicit list of text entries")
    # Detect aliases and renamed byte-identical copies, including across incidents.
    private.update(incident_paths)
    private.add(collection_path.name)
    private_hashes = {inventory[name] for name in private}
    require(not any(inventory[name] in private_hashes for name in public),
            "baseline exposes private resolution, scoring key, or intake metadata")
    return {
        "schema_version": "power-incident-intake-freeze-v1",
        "status": "prepared_not_run",
        "scope": "declared intake and workflow bytes; no authenticity or efficacy claim",
        "collection": collection_path.name,
        "incident_ids": sorted(ids),
        "material_sha256": dict(sorted(inventory.items())),
        "workflow_sha256": code_inventory(code_root),
    }


def verify(freeze_path, collection_path, code_root=ROOT):
    frozen = json.loads(freeze_path.read_text())
    current = validate(collection_path, code_root)
    require(frozen == current, "freeze differs from current intake or workflow; do not run")
    return current


def main(args=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("check", "freeze", "verify"))
    parser.add_argument("collection", type=Path)
    parser.add_argument("--freeze", type=Path, dest="freeze_path")
    options = parser.parse_args(args)
    if options.action != "check" and options.freeze_path is None:
        parser.error("freeze and verify require --freeze PATH")
    try:
        if options.action == "verify":
            result = verify(options.freeze_path, options.collection)
        else:
            result = validate(options.collection)
            if options.action == "freeze":
                # Exclusive creation prevents silently replacing a previous freeze.
                with options.freeze_path.open("x") as stream:
                    json.dump(result, stream, indent=2, sort_keys=True)
                    stream.write("\n")
        print(f"{options.action}: {len(result['incident_ids'])} incident(s); prepared, not run")
        return 0
    except (ValueError, OSError) as error:
        print(f"intake rejected: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
