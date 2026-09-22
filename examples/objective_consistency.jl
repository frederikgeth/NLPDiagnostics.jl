using Ipopt
using JuMP
using NLPDiagnostics.Stable

affine = Model(Ipopt.Optimizer)
set_silent(affine)
@variable(affine, x >= 1)
@objective(affine, Min, x)
optimize!(affine)

affine_summary = objective_consistency_summary(
    affine;
    absolute_tolerance = 1.0e-7,
    relative_tolerance = 1.0e-7,
    feasibility_tolerance = 1.0e-7,
    stationarity_tolerance = 1.0e-7,
    dual_tolerance = 1.0e-7,
    gap_absolute_tolerance = 1.0e-7,
    gap_relative_tolerance = 1.0e-7,
)

@assert affine_summary.comparison_available
@assert affine_summary.consistent
@assert affine_summary.gap_available
@assert affine_summary.gap_passed

nonlinear = Model(Ipopt.Optimizer)
set_silent(nonlinear)
@variable(nonlinear, z, start = 0.0)
@objective(nonlinear, Min, (z - 2)^2)
optimize!(nonlinear)

nonlinear_summary = objective_consistency_summary(
    nonlinear;
    absolute_tolerance = 1.0e-7,
    relative_tolerance = 1.0e-7,
)

@assert nonlinear_summary.comparison_available
@assert nonlinear_summary.consistent
@assert !nonlinear_summary.gap_available

println("Affine endpoint: ", affine_summary)
println("Nonlinear endpoint: ", nonlinear_summary)
println("Nonlinear gap boundary: ", nonlinear_summary.gap_reason)
