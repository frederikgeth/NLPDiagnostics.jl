# Tutorial: a reproducible three-bus OPF investigation

This tutorial follows one small AC optimal-power-flow model from source bytes to
a diagnostic reevaluation at an Ipopt result. It demonstrates a research
record, not a claim that one case validates the workflow for other networks.

!!! note "Learning goals"
    After this tutorial, you can preserve OPF source provenance, distinguish an
    invalid constructed start from solver-result evidence, and bound the claim
    supported by a successful diagnostic reevaluation.

    **Prerequisites:** JuMP, solver statuses, and basic AC OPF concepts. **Time:**
    about 25 minutes. **Artifact:** a hashed source, start report, solver policy,
    and returned-point report.

The checked-in MATPOWER fixture comes from the PowerModels test corpus and is
redistributed under the license beside it. It deliberately exercises parser
normalization, including reference-bus handling and an HVDC line.

## 1. Freeze the question and source

Question: does the ACP formulation expose a complete initialization, and does
Ipopt return a point without error-severity model evaluations under the selected
diagnostic policy?

```@example three_bus_opf
using Ipopt, JuMP, NLPDiagnostics, PowerModels, SHA
import MathOptInterface as MOI

case_path = joinpath(
    pkgdir(NLPDiagnostics),
    "test",
    "fixtures",
    "power_repair_case3.m",
)
license_path = replace(case_path, ".m" => ".LICENSE")
source_sha256 = bytes2hex(sha256(read(case_path)))

@assert isfile(case_path) && isfile(license_path)
@assert length(source_sha256) == 64
(file = basename(case_path), sha256 = source_sha256)
```

For a publication, retain this hash together with the repository revision,
environment manifest, parser version, and any transformation applied after
parsing. A hash records byte identity; it does not authenticate the physical
case or permission to use it.

## 2. Parse and build a fresh formulation

PowerModels logs its normalization decisions. We silence its logger only to keep
the rendered example compact; a real experiment should capture those messages.

```@example three_bus_opf
PowerModels.silence()
data = PowerModels.parse_file(case_path)

pm = PowerModels.instantiate_model(
    deepcopy(data),
    PowerModels.ACPPowerModel,
    PowerModels.build_opf,
)
model = pm.model

source_summary = (
    base_mva = data["baseMVA"],
    buses = length(data["bus"]),
    branches = length(data["branch"]),
    dc_lines = length(data["dcline"]),
    reference_buses = sort!(collect(PowerModels.ids(pm, :ref_buses))),
    variables = num_variables(model),
)
@assert source_summary == (
    base_mva = 100.0,
    buses = 3,
    branches = 3,
    dc_lines = 1,
    reference_buses = [1],
    variables = 28,
)
source_summary
```

The original file contains no type-3 reference bus; the parser reports and
applies a fallback policy selecting bus 1. That normalization is part of model
provenance. It should not be described as an operator-authorized source fact.

## 3. Inspect initialization before solving

```@example three_bus_opf
start_report = analyze(model; check_initialization = true)
start_codes = Set(finding.code for finding in start_report)

@assert :initialization_violates_variable_bounds in start_codes
@assert :constraint_feasibility_violation in start_codes
(
    errors = length(findings(start_report; severity = SeverityError)),
    bound_violations = length(findings(
        start_report;
        code = :initialization_violates_variable_bounds,
    )),
)
```

This establishes that the constructed start is not an accepted model point. It
does not establish that the OPF is infeasible. Preserve the finding's affected
variable and source/model mapping before deciding whether to alter initialization.

## 4. Solve under an explicit policy

The options below are part of the experiment. `sb=yes` suppresses Ipopt's banner;
it does not change the mathematical model.

```@example three_bus_opf
solver_options = Dict(
    "print_level" => 0,
    "sb" => "yes",
    "tol" => 1.0e-8,
    "max_iter" => 500,
)
set_optimizer(model, optimizer_with_attributes(Ipopt.Optimizer, solver_options...))
optimize!(model)

termination = termination_status(model)
primal = primal_status(model)
@assert termination in (MOI.LOCALLY_SOLVED, MOI.OPTIMAL)
@assert primal == MOI.FEASIBLE_POINT
(termination = termination, primal = primal)
```

The termination and primal statuses are solver observations. They are necessary
context, but they do not replace evaluation of the returned point.

## 5. Re-evaluate the returned point

```@example three_bus_opf
result = analyze_solver_result(model; label = "case3 Ipopt result")
result_report = result.report

@assert result.point !== nothing
@assert result_report.metadata[:solver_result_point_available] == "true"
@assert result_report.metadata[:solver_result_postmortem_available] == "true"
@assert isempty(findings(result_report; severity = SeverityError))

result_summary = (
    termination = result_report.metadata[:postmortem_termination],
    point_kind = result.point.provenance.kind,
    diagnostic_errors = length(findings(result_report; severity = SeverityError)),
)
result_summary
```

The public solver result contains all 28 model coordinates, the Ipopt extension
provides postmortem termination evidence, and reevaluation produces no
error-severity findings under this policy. Structural warnings can remain true:
the ACP model contains inequalities and formulation structure that are not
summarized by a square equality system.

## 6. Interpret the comparison

The result supports a narrow conclusion: for these exact source bytes, parser
and ACP formulation, environment, solver options, and diagnostic policy, Ipopt
returned a complete feasible-status point without error-severity reevaluation
findings. It does not establish:

- that every source value reflects the intended physical system;
- that the parser's fallback reference is the desired operational reference;
- uniqueness or global optimality;
- transfer to another formulation, solver, or network; or
- operational security or engineer repair benefit.

The initial-point errors and accepted returned point should both remain in the
record. Dropping the failed start would conceal an important part of the solver
experiment.

## Exercise

Run the case with a second independently justified start. Freeze its construction
before solving. Compare start feasibility, termination, returned-point findings,
objective, and solver work. Which observations are directly comparable, and
which require a mapping into common physical coordinates?

!!! tip "Hint"
    Record both starts before either solve. Solver status and work are directly
    comparable only under the same solver policy; formulation changes require a
    declared coordinate map for state comparisons.

!!! info "Expected observations"
    Start feasibility can differ while both runs still reach accepted result
    points. Similar objectives do not imply identical states or global
    optimality. If the starts lead to different results, preserve both records
    and design a further controlled comparison instead of selecting one silently.
