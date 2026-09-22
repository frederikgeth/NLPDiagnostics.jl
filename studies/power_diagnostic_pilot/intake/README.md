# Incident intake and pre-evaluation freeze

**Prepared, not run.** These templates contain no incidents. The command refuses
to freeze an empty collection. It never generates incidents, diagnostics,
participant observations, or evaluation scores.

Use Python 3.9 or later; no additional packages are required. Copy this directory
to a separate, access-controlled material directory. Do not commit confidential
incident records or the completed freeze to this repository. The freeze contains
private filenames and incident identifiers.

1. An independent curator prepares one copy of `incident.json` per incident and
   sets its status to `prepared_for_evaluation`. Fill every text declaration and
   use explicit lists for transformations and limitations (empty is allowed).
   The original `../incident_template.json` remains a historical prose template;
   this directory defines the machine-checked intake format.
2. Every file reference uses the following object. Paths are relative to the
   **collection directory**, including references inside incident files. Absolute
   paths, parent traversal, and symlinks escaping that directory are rejected.

   ```json
   {"path": "evidence/source.m", "sha256": "64 lowercase hex characters"}
   ```

   Compute SHA-256 with `shasum -a 256 evidence/source.m`. `source_records`,
   `original_models`, `solver_logs`, `resolution_evidence`, and `baseline_materials`
   are nonempty lists of these objects; `scoring_key` is one object. Curator,
   permission reference, preparation statement, model/environment description,
   inclusion reason, and resolution summary are nonempty strings. Record actual
   provenance and independent support, not a diagnostic's answer as ground truth.
3. Baseline materials must include every declared source, model, and solver log.
   Keep resolution evidence, scoring keys, incident records, and the collection
   private. The checker rejects byte-identical copies of those private files in
   any incident's baseline, even under different names. A curator must separately
   check semantic answer leakage and ensure transformations preserve the fault.
4. Complete `evaluation_plan.md`, including measurement rules and denominators
   for localization, false warnings, abstentions, and overhead. In `collection.json`,
   set `evaluation_plan` to its file reference and `incidents` to a nonempty list
   of references to the completed incident JSON files. Include supported controls
   and unsupported cases according to the frozen selection rules.
5. Check, freeze, and verify from the repository root:

   ```sh
   python3 studies/power_diagnostic_pilot/intake.py check /path/to/materials/collection.json
   python3 studies/power_diagnostic_pilot/intake.py freeze /path/to/materials/collection.json \
     --freeze /path/to/materials/intake-freeze.json
   python3 studies/power_diagnostic_pilot/intake.py verify /path/to/materials/collection.json \
     --freeze /path/to/materials/intake-freeze.json
   ```

   The freeze records every declared material's bytes and the current core,
   extensions, power-workflow helpers/CLI, pinned pilot environment, intake checker,
   and study protocol. Existing freeze files cannot be overwritten. Verification
   recomputes the complete inventory, detecting added runtime files as well as
   changed/removed files. A freeze is a local comparison record, not a signed or
   independently timestamped preregistration. Have the curator retain a protected
   copy before viewing diagnostic outputs.
6. Verify immediately before generating reports with the frozen v2 CLI, and
   again before scoring. Keep generated reports separate from the input freeze.
   The report condition receives exactly the baseline materials plus its report;
   never distribute the material directory or intake manifest wholesale. Use the
   frozen rubric to record every incident, including failures and unavailable
   results. This checker does not run diagnostics or score outcomes.

Checks establish byte consistency and explicit declarations. They do not establish
authentic permission, independent preparation, completeness of the plan, absence
of semantic leakage, runtime package integrity, or fidelity to a physical system.
Use the pinned environment and its documented instantiation process; the manifest
hash records dependency selection, not a measurement of installed package bytes.
Human study assignment and recruitment remain separate prerequisites in
`../protocol.md`. No measured repair benefit exists until actual sessions occur.

Run the artificial contract tests (temporary files only):

```sh
python3 -B -m unittest discover -s test -p test_power_incident_intake.py -v
```
