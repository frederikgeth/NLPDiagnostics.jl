module ActivityEvidenceContractTests
using Test
import MathOptInterface as MOI
import NLPDiagnostics as ND
newmodel() = MOI.Utilities.UniversalFallback(MOI.Utilities.Model{Float64}())
getfinding(r,c) = only(filter(f -> f.code == c,r.findings))
function check_numerical(r,c)
    f = getfinding(r,c)
    @test f.basis == ND.NumericalObservation
    @test f.confidence != ND.ConfidenceCertain
    data = only(filter(f -> f["code"] == string(c),ND.report_data(r)["findings"]))
    @test data["basis"] == "numerical_observation"
    return f
end
@testset "Computed residuals do not certify exact-real infeasibility" begin
    m = newmodel(); x = MOI.add_variable(m)
    # Exact real value at x=1 is 1; Float64 loses x during addition.
    f = MOI.ScalarNonlinearFunction(:-,Any[
        MOI.ScalarNonlinearFunction(:+,Any[1e16,x]),1e16])
    MOI.add_constraint(m,f,MOI.EqualTo(1.0))
    @test (big(10)^16 + 1) - big(10)^16 == 1
    r = ND.analyze_active_set(m,[1.0])
    check_numerical(r,:constraint_feasibility_violation)
    # A genuine numerical violation still remains visible.
    r = ND.analyze_active_set(m,[0.0])
    check_numerical(r,:constraint_feasibility_violation)
end
function cone()
    m = newmodel(); xs = MOI.add_variables(m,2)
    MOI.add_constraint(m,MOI.VectorOfVariables(xs),MOI.SecondOrderCone(2))
    return m
end
function with_methods(e,methods; entries=e.jacobian_entries)
    ND.NumericalEvaluation{Float64}(e.point,e.objective_value,e.objective_source,
        e.objective_gradient,e.constraint_values,e.constraint_sources,entries,
        methods,e.capabilities,e.failures)
end
@testset "Cone activity and tangents preserve numerical evidence" begin
    m=cone()
    for (point,code) in (([0.5,1.0],:coupled_set_feasibility_violation),
                        ([1.0,1.0],:coupled_set_boundary_active),
                        ([0.0,0.0],:coupled_set_nonsmooth_boundary_active))
        check_numerical(ND.analyze_active_set(m,point),code)
    end
    e=ND.evaluate_numerical(m,[1.0,1.0])
    for method in (:exact_symbolic,:central_finite_difference)
        r=ND.analyze_active_set(m,with_methods(e,fill(method,2)))
        check_numerical(r,:coupled_set_smooth_boundary_tangent_available)
        f=check_numerical(r,:coupled_set_smooth_boundary_tangent_gradient_available)
        @test Dict(f.evidence[end].details)["derivative_methods"] == string(method)
        @test f.confidence == (method == :exact_symbolic ? ND.ConfidenceHigh : ND.ConfidenceMedium)
    end
    partial=ND.analyze_active_set(m,with_methods(e,[:partial_central_finite_difference,:exact_symbolic]))
    @test isempty(filter(f -> f.code == :coupled_set_smooth_boundary_tangent_gradient_available,partial.findings))
    @test getfinding(partial,:coupled_set_boundary_tangent_gradient_unavailable).basis == ND.NumericalObservation
    # A historical/manual evaluation with complete zero derivatives cannot
    # upgrade computed stationarity into a proof either.
    zero=ND.analyze_active_set(m,with_methods(e,fill(:exact_symbolic,2);entries=empty(e.jacobian_entries)))
    z=getfinding(zero,:coupled_set_smooth_boundary_tangent_gradient_zero)
    @test z.basis == ND.LocalInference
    @test occursin("underflow",z.why_it_matters)
end
end
