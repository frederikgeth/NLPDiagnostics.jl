"""Check the explicit MathematicalProof reference inventory (not mathematical validity).

Run from any directory with Python 3. This lexical check includes conditional
labels; it does not find dynamically constructed labels or certify call paths.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
INVENTORY = ROOT / "docs/proof_audit_inventory.md"


def producers():
    result = {}
    for path in sorted((ROOT / "src").rglob("*.jl")):
        relative = path.relative_to(ROOT).as_posix()
        # Enum declaration, serialization label, and exported API name only.
        if relative == "src/reports/types.jl":
            continue
        function = None
        for line in path.read_text().splitlines():
            match = re.match(r"^function\s+([^\s(]+)", line)
            if match:
                function = match[1]
            if "MathematicalProof" in line:
                if relative == "src/NLPDiagnostics.jl" and function is None:
                    continue
                if function is None:
                    raise ValueError(f"Unclassified proof reference in {relative}")
                key = (relative, function)
                result[key] = result.get(key, 0) + 1
    return result


def main():
    expected = {}
    for line in INVENTORY.read_text().splitlines():
        if not line.startswith("| src/"):
            continue
        path, function, count, decision, status, evidence = [v.strip() for v in line.strip("|").split("|")]
        key = (path, function.strip("`"))
        if key in expected or decision not in ("retain", "fix", "demote") or status not in ("scoped tests", "open", "demoted"):
            raise ValueError(f"Invalid inventory row: {line}")
        if status == "demoted" and (decision != "demote" or int(count) != 0):
            raise ValueError(f"Demoted producer must have zero proof references: {line}")
        expected[key] = int(count)
    actual = producers()
    missing = sorted(actual.keys() - expected.keys())
    stale = sorted(k for k in expected.keys() - actual.keys() if expected[k] != 0)
    changed = sorted(k for k in actual.keys() & expected.keys() if actual[k] != expected[k])
    if missing or stale or changed:
        print(f"missing={missing}\nstale={stale}\nchanged_counts={changed}")
        return 1
    print(f"Inventory matched: {len(actual)} producer functions, {sum(actual.values())} explicit proof references.")
    print("This is a scope check, not a correctness certificate.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
