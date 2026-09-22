# Experiment record

A useful diagnostic result must be reproducible and interpretable. Copy the
[TOML experiment-record template](../assets/experiment-record.toml) before
running a new comparison and fill the fields that apply.

## Before running

Record the observable question, source/model bytes, permissions, environment,
formulation, coordinates, units, reference policy, point construction, solver
options, diagnostic policies, and work limits. For a comparison, declare the
baseline, intervention, prediction, held-constant inputs, and negative controls.

Do not fill these fields from the result after inspecting it. If the plan changes,
retain the original record and create a revision with the reason.

## After running

Record every termination class, unavailable measurement, failure, exclusion, and
raw artifact. Keep failed and time-limited runs in denominators. Hashing a report
supports byte comparison but does not establish that its input provenance is true.

Separate three statements:

- **Observation:** what the recorded model, solver, or diagnostic produced.
- **Supported claim:** the narrowest interpretation justified by the evidence.
- **Unsupported claims:** tempting extensions that require other evidence.

Name the next measurement that could distinguish the remaining explanations.

## OPF additions

For OPF experiments, use `data_paths`, `transformations`, `reference_policy`,
`unit_convention`, and `source_to_model_mapping` to retain:

- the original network source and component statuses;
- parser and data-normalization steps;
- system and zone per-unit bases;
- island and reference-bus selection;
- formulation-specific coordinates; and
- mapping between source components, JuMP variables, and reported entities.

When comparing scaling or formulations, store both the model-coordinate point
and its common physical representation. A shared variable name is not sufficient
evidence that two coordinates have the same meaning.

## Human-readable companion

The TOML file is an index, not a lab notebook. Keep a short Markdown companion
explaining why the point, intervention, and acceptance policy are scientifically
appropriate. Link source records and raw outputs rather than pasting only selected
successful excerpts.
