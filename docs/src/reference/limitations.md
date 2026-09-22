# Scope and limitations

NLPDiagnostics is an evidence-preserving research prototype. It is useful for
investigating represented models; it is not an oracle for model intent or
physical correctness.

## What the package does

- Takes a read-only snapshot through public MOI interfaces.
- Reports supported static and structural model properties.
- Evaluates values and derivatives at explicit, provenance-bearing points.
- Preserves numerical policy, tolerance, coordinate, and availability context.
- Offers optional solver and power-system extension evidence when the relevant
  packages are loaded.

## What it does not establish

- that source data, units, topology, or operator intent are correct;
- that one local point describes global NLP geometry;
- that a numerical threshold transfers across formulations or scales;
- that solver success implies application-level correctness or safety;
- that a suggested action is an authorized or correct model repair; or
- that synthetic benchmark success improves engineer performance.

The package never modifies the source model. Suggested actions are investigation
steps. Apply a model change only after establishing its meaning from the relevant
source and domain evidence.

## Current power-system boundary

The PowerModels and BMOPFTools integrations are optional research extensions.
Coverage depends on formulation, public metadata, coordinate mapping, and
available solver evidence. The versioned source/solver workflow currently lives
under `benchmarks/` and is outside the Stable API. DC, unbalanced, equipment-wide
provenance, and operational-security claims are not implied by its synthetic
validation.

## Reproducibility boundary

Version identifiers and hashes support comparison but do not authenticate
permission, source intent, or physical fidelity. For publishable experiments,
archive the model/data revision, environment, options, points, policies, raw
results, failures, and analysis code. Distinguish regression tests from held-out
calibration and human evaluation.
