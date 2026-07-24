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
- Dulmage–Mendelsohn partitions and irreducible well-determined blocks;
- renderer-neutral graph data; and
- deterministic terminal and Graphviz DOT graph output;
- expression-node provenance and conservative interval propagation; and
- proven/possible nonlinear operator-domain findings;
- explicit point-tagged objective, constraint, gradient, and Jacobian probing;
- `NLPBlock` and nonlinear-oracle capability adapters;
- operating-point domain and non-finite evaluation findings; and
- Jacobian row/column scale summaries;
- guarded local Jacobian rank, conditioning, and nullspace evidence; and
- explicit Hessian-of-the-Lagrangian and reduced-Hessian curvature tools;
- reproducible solver-independent formulation profile cases; and
- finite first- and second-derivative domain checks;
- overflow, underflow, and stable-expression fingerprints; and
- explicit MOI initialization analysis without invented default starts.

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

Numerical analysis is opt-in because every conclusion is local to an explicit
point:

```julia
point = evaluation_point(model, [0.5]; label = "initialization")
report = analyze(model; point = point)

# Or inspect complete MOI/JuMP start values:
initial_report = analyze(model; check_initialization = true)
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
Expression-domain evidence semantics and extension hooks are documented in
[`docs/expression_domains.md`](docs/expression_domains.md).
Numerical capability, cache, and scaling semantics are documented in
[`docs/numerical_analysis.md`](docs/numerical_analysis.md).
Derivative domains, stable expressions, and initialization are documented in
[`docs/derivatives_stability_initialization.md`](docs/derivatives_stability_initialization.md).
Profiling cases derived from the attached OPF papers are recorded in
[`docs/research_profiling_cases.md`](docs/research_profiling_cases.md).
