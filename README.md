# NLPDiagnostics.jl

[![CI](https://github.com/frederikgeth/NLPDiagnostics.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/frederikgeth/NLPDiagnostics.jl/actions/workflows/ci.yml)
[![Documentation](https://github.com/frederikgeth/NLPDiagnostics.jl/actions/workflows/documentation.yml/badge.svg)](https://frederikgeth.github.io/NLPDiagnostics.jl/dev/)

NLPDiagnostics.jl is an evidence-first, solver-independent debugger for
nonlinear optimization models expressed through JuMP and MathOptInterface.
It helps researchers distinguish mathematical contradictions, structural
patterns, point-local numerical behaviour, and domain-specific hypotheses.

The package takes a read-only model snapshot and never repairs or rewrites the
source model. Every finding retains its evidence basis, confidence, affected
entities, and suggested investigation steps.

> **Research prototype:** public APIs and finding codes may evolve. Numerical
> thresholds and physical interpretations remain subject to their documented
> calibration boundaries.

## Quick example

```julia
using JuMP, NLPDiagnostics

model = Model()
@variable(model, x)
@constraint(model, x >= 10)
@constraint(model, x <= 5)

report = analyze(model)
display(report)
```

This contradiction is established from the represented affine constraints; no
solver run is needed. Numerical questions are tied to an explicit point:

```julia
point = evaluation_point(model, [7.0]; label = "candidate A")
local_report = analyze(model; point = point)
```

A point-local domain failure or rank estimate does not imply global model
infeasibility. The documentation develops these distinctions through runnable
NLP and OPF-oriented tutorials.

## Documentation

The [documentation site](https://frederikgeth.github.io/NLPDiagnostics.jl/dev/)
is organized for PhD candidates and researchers:

- getting started and reading reports;
- a repeatable diagnostic research workflow;
- tutorials on coefficient and unit inspection, bounds versus named rows,
  structural and numerical Hessian density, contradictions, initialization,
  rank, controlled scaling and solver traces, OPF hypotheses, formulation
  comparison, and a complete three-bus ACP solve;
- a symptom-based diagnostic playbook and reproducible experiment template;
- explanations of evidence, structure, numerical rank, and physical gauges; and
- the complete Stable API, generated finding-code inventory, prior-art map,
  and current limitations.

The source is in [`docs/src`](docs/src). Detailed calibration records, frozen
evaluations, and research ledgers remain in [`docs`](docs) and are linked from
the site's research section.

## Installation

NLPDiagnostics supports Julia 1.10 and later. During the pre-release phase:

```julia
using Pkg
Pkg.add(url = "https://github.com/frederikgeth/NLPDiagnostics.jl")
Pkg.add("JuMP")
```

For a local checkout, develop it into a dedicated experiment environment:

```julia
using Pkg
Pkg.activate("my-experiment")
Pkg.develop(path = "/path/to/NLPDiagnostics.jl")
Pkg.add("JuMP")
```

## Evidence model

Reports keep distinct evidence channels:

- exact or certified mathematical conclusions;
- structural incidence and matching results;
- numerical observations at explicit points and tolerances;
- physical expectations supplied by optional domain metadata; and
- local or heuristic interpretations that suggest further checks.

Unavailable evidence remains explicit. Agreement between independent channels
can support a hypothesis; disagreement is retained for investigation.

## Scope

The generic package supports static, structural, expression-domain, explicit-point
numerical, derivative, scaling, rank, active-set, degeneracy, curvature, and
initialization analyses. Optional extensions add JuMP integration, Ipopt and
MadNLP trace evidence, and experimental PowerModels/BMOPFTools metadata.

The current power-system report workflow is documented in
[Power diagnostics v2](docs/power_diagnostics_v2.md). Its synthetic evaluations
are development evidence, not a claim of general OPF coverage, operational
safety, or measured engineer benefit.

See [mission and scope](docs/mission_and_scope.md),
[API stability](docs/api_stability.md), and
[testing and validation](docs/testing.md) for the current project boundary.

## Development

Run the package tests with:

```sh
julia --startup-file=no --project=. -e 'using Pkg; Pkg.test()'
```

Build the documentation with:

```sh
julia --project=docs -e 'using Pkg; Pkg.develop(path=pwd()); Pkg.instantiate()'
julia --startup-file=no --project=docs docs/make.jl
```

The CI configuration also covers solver extensions, the pinned full domain
environment, the self-contained power workflow, and the documentation build.
