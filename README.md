# NLPDiagnostics.jl

> Early development prototype: public APIs and finding codes may evolve.

NLPDiagnostics.jl is an evidence-first, solver-independent debugger for
nonlinear optimization models expressed through JuMP and
MathOptInterface (MOI).

The package is at an early prototype stage. The current implementation takes a
read-only snapshot through the public MOI model API and reports:

- inconsistent, repeated, and fixing variable bounds;
- satisfied and infeasible constant constraints;
- exact canonical duplicate affine, quadratic, and nonlinear constraints; and
- variables disconnected from the objective and non-domain constraints;
- set-aware variable–constraint incidence graphs; and
- disconnected structural equation components;
- free/fixed/parameter variable and equality/inequality constraint roles;
- deterministic equality matching and unmatched-node findings; and
- initial Dulmage–Mendelsohn structural partitions.

```julia
import MathOptInterface as MOI
using NLPDiagnostics

model = MOI.Utilities.UniversalFallback(MOI.Utilities.Model{Float64}())
x = MOI.add_variable(model)
MOI.add_constraint(model, x, MOI.GreaterThan(10.0))
MOI.add_constraint(model, x, MOI.LessThan(5.0))

report = analyze(model)
display(report)
```

JuMP models can be analyzed directly when JuMP is loaded:

```julia
using JuMP
using NLPDiagnostics

model = Model()
@variable(model, x >= 0)
@constraint(model, sin(x) <= 1)

report = analyze(model)
```

Each finding separately records:

- what was observed and why it matters;
- severity;
- mathematical, numerical, physical, or representational domain;
- mathematical, structural, physical, numerical, local, or heuristic evidence;
- confidence;
- inspectable evidence and affected model entities; and
- suggested actions.

NLPDiagnostics never modifies the source model.

See [`docs/architecture.md`](docs/architecture.md) for the initial design
decisions and roadmap, and
[`docs/moi_nonlinear_api.md`](docs/moi_nonlinear_api.md) for the public MOI
capability survey.

The ordered implementation plan is maintained in
[`docs/roadmap.md`](docs/roadmap.md).
Structural matching semantics are documented in
[`docs/structural_analysis.md`](docs/structural_analysis.md).
