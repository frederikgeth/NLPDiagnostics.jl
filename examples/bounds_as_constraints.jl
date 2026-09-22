using JuMP
using NLPDiagnostics.Stable
import NLPDiagnostics

bound_model = Model()
@variable(bound_model, production <= 4)
@assert isempty(findings(
    analyze(bound_model);
    code = :bound_expressed_as_constraint,
))

row_model = Model()
@variable(row_model, production)
@constraint(row_model, transformer_capacity, 2production + 1 <= 9)

report = analyze(row_model)
finding = only(findings(report; code = :bound_expressed_as_constraint))
details = Dict(finding.evidence[1].details)

@assert finding.basis == NLPDiagnostics.MathematicalProof
@assert finding.domain == NLPDiagnostics.RepresentationalIssue
@assert details["equivalent_bound"] == "LessThan(4.0)"
@assert details["preserves_scalar_feasible_set"] == "true"

println(finding.observation)
println("Equivalent variable bound: ", details["equivalent_bound"])
println("The source model was inspected without being rewritten.")
