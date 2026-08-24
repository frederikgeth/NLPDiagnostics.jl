# API stability policy

NLPDiagnostics is still pre-release, so the full historical root namespace is
not a promise that every exported name is stable. The project now separates
three compatibility tiers.

## `NLPDiagnostics.Stable`

New application code should target the deliberately small `Stable` facade. Its
current 16 exports cover model snapshots, numerical evaluations, solver-neutral
analysis, findings, evidence, and renderer-neutral report serialization. The
facade is additive-only during the current release cycle: new fields and typed
report-boundary records may be added, but signature or semantic changes require
an explicit release decision and updated contract tests.

The machine-readable export inventory is
[`docs/api_tier_inventory_summary.json`](api_tier_inventory_summary.json).

## `NLPDiagnostics.Advanced`

`Advanced` contains research-facing profiling, rank-policy, and capability
experiments. It is intentionally available for exploration but carries no
Stable-tier compatibility guarantee. Experimental behavior and unavailable
capabilities must remain explicit in its result schemas.

## Legacy root exports

Root exports remain available for backward compatibility while the package is
consolidated. A root-only export is not implicitly Stable. Before a breaking
release, each root-only name should either be promoted into `Stable`, assigned
to `Advanced`, or documented as legacy/deprecated with a migration path.

The tier audit is executable with:

```text
julia --project=work/benchmark-environment --startup-file=no \
  benchmarks/audit_api_tiers.jl
```

The generated inventory includes the complete `legacy_root_exports` list, so
each of the 531 root-only names is explicitly reviewable rather than hidden
behind an aggregate count.

This policy does not claim semantic correctness, numerical qualification, or
release readiness. Those remain governed by the roadmap trust gates and the
calibration release gate.
