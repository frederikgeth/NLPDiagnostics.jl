module ScientificContractTests

using Test
import MathOptInterface as MOI
import NLPDiagnostics as ND

newmodel() = MOI.Utilities.UniversalFallback(MOI.Utilities.Model{Float64}())

function affine_model(coefficient=1.0; columns=1)
    model = newmodel()
    variables = MOI.add_variables(model, columns)
    row = MOI.add_constraint(model,
        MOI.ScalarAffineFunction([MOI.ScalarAffineTerm(coefficient, variables[1])], 0.0),
        MOI.EqualTo(0.0))
    return model, variables, row
end

@testset "Exact fixed polynomial evidence" begin
    model = newmodel()
    x, y = MOI.add_variables(model, 2)
    MOI.add_constraint(model, x, MOI.EqualTo(1.0))
    MOI.add_constraint(model, y, MOI.EqualTo(1.0))
    affine = MOI.ScalarAffineFunction([
        MOI.ScalarAffineTerm(1e16, x), MOI.ScalarAffineTerm(-1e16, y),
    ], 1.0)
    ci = MOI.add_constraint(model, affine, MOI.EqualTo(1.0))
    report = ND.analyze(model)
    @test isempty(ND.findings(report; code=:infeasible_fixed_affine_constraint))
    @test only(ND.findings(report; code=:redundant_fixed_affine_constraint)).basis == ND.MathematicalProof
    MOI.set(model, MOI.ConstraintSet(), ci, MOI.EqualTo(2.0))
    @test only(ND.findings(ND.analyze(model);
        code=:infeasible_fixed_affine_constraint)).basis == ND.MathematicalProof

    # The exact diagonal coefficient is divided by two according to MOI.
    quadratic = MOI.ScalarQuadraticFunction([
        MOI.ScalarQuadraticTerm(2e16, x, x),
        MOI.ScalarQuadraticTerm(-2e16, y, y),
    ], MOI.ScalarAffineTerm{Float64}[], 1.0)
    fixed = Dict{MOI.VariableIndex,Any}(x=>1.0, y=>1.0)
    @test ND._exact_fixed_polynomial_value(quadratic, fixed) == big(1)//big(1)
    @test ND._exact_fixed_polynomial_value(affine, fixed) == big(1)//big(1)

    # Canonicalization must not remove a real dependency through cancellation.
    terms = [MOI.ScalarAffineTerm(c, x) for c in (1e16, 1.0, -1e16)]
    for permuted in (terms, reverse(terms), terms[[1,3,2]])
        f = MOI.ScalarAffineFunction(permuted, 0.0)
        @test ND.variable_support(f).variables == [x]
        @test ND._exact_fixed_polynomial_value(f, fixed) == 1
    end

    # Numerical evaluation of a nonlinear expression is not a proof about it.
    nonlinear = newmodel()
    z = MOI.add_variable(nonlinear)
    MOI.add_constraint(nonlinear, z, MOI.EqualTo(1.0))
    f = MOI.ScalarNonlinearFunction(:-, Any[
        MOI.ScalarNonlinearFunction(:+, Any[1e16, z]), 1e16])
    MOI.add_constraint(nonlinear, f, MOI.EqualTo(1.0))
    finding = only(ND.findings(ND.analyze(nonlinear);
        code=:fixed_expression_numerical_violation))
    @test finding.basis == ND.NumericalObservation
    @test !occursin("proves", finding.why_it_matters)
end

@testset "Type-qualified component row identity" begin
    model = newmodel()
    x, y = MOI.add_variables(model, 2)
    MOI.add_constraint(model, x, MOI.GreaterThan(0.0))
    MOI.add_constraint(model,
        MOI.ScalarAffineFunction([MOI.ScalarAffineTerm(1.0, y)], 0.0),
        MOI.EqualTo(0.0))
    evaluation = ND.evaluate_numerical(model, ND.evaluation_point(model, [1.0, 1.0]))
    sources = evaluation.constraint_sources
    @test ND._entity_legacy_row_key(sources[1]) == ND._entity_legacy_row_key(sources[2])
    @test ND._entity_row_key(sources[1]) != ND._entity_row_key(sources[2])
    lookup = ND._entity_row_lookup(sources)
    for row in eachindex(sources)
        entry = only(filter(e -> e.row == row, evaluation.jacobian_entries))
        component = ND.ComponentMetadata(:review, "row $row";
            variables=[evaluation.point.variables[entry.column]],
            constraints=[sources[row]], expected_rank=1)
        report = ND.analyze_component_ranks(model, evaluation; components=[component])
        @test report.metadata[:component_rank_comparison_count] == "1"
        @test isempty(ND.findings(report; code=:component_expected_rank_mismatch))
        ref = sources[row]
        renamed = ND.EntityRef(ref.kind, ref.index; subindex=ref.subindex,
            function_type=ref.function_type, set_type=ref.set_type, name="new display name")
        @test ND._find_entity_row(lookup, renamed) == row
    end
    untyped = ND.EntityRef(:constraint, sources[1].index)
    @test ND._find_entity_row(lookup, untyped) == 0
    @test ND._find_entity_row(ND._entity_row_lookup([sources[1]]), untyped) == 1
    @test ND._find_entity_row(ND._entity_row_lookup([sources[1], sources[1]]), sources[1]) == 0
    unknown = ND.ComponentMetadata(:review, "ambiguous";
        variables=[x], constraints=[untyped], expected_rank=1)
    @test ND.analyze_component_ranks(model, evaluation; components=[unknown]).metadata[
        :component_rank_unavailable_count] == "1"

    feasibility = ND.constraint_feasibility_summary(model, evaluation)
    scales = [ND.ComponentConstraintScaleSemantics(:review, "row $row", [source];
        nominal_scale=0.01) for (row, source) in enumerate(sources)]
    scaled = ND.analyze_component_constraint_scales(scales, feasibility; mismatch_factor=2.0)
    mismatch = only(ND.findings(scaled; code=:component_constraint_nominal_scale_mismatch))
    # x >= 0 is satisfied; only the y == 0 equation is violated at (1,1).
    affine_source = only(filter(s -> occursin("ScalarAffineFunction", s.function_type), sources))
    @test only(mismatch.affected) == affine_source
    @test scaled.metadata[:component_constraint_scale_checked_count] == "2"
    ambiguous_scale = ND.ComponentConstraintScaleSemantics(:review, "ambiguous", [untyped]; nominal_scale=0.01)
    @test ND.analyze_component_constraint_scales([ambiguous_scale], feasibility).metadata[
        :component_constraint_scale_unavailable_count] == "1"
end

@testset "Cache preserves full point provenance" begin
    model, _, _ = affine_model()
    kinds = [ND.UserPoint, ND.SyntheticSmokePoint, ND.SolverResultPoint,
        ND.CompletedInitializationPoint]
    for order in (kinds, reverse(kinds))
        cache = ND.EvaluationCache()
        for kind in order
            point = ND.evaluation_point(model, [1.0]; label="same",
                provenance=ND.EvaluationPointProvenance(kind; source="test",
                    metadata=Dict("fixture"=>"identity")))
            evaluation = ND.evaluate_numerical(model, point; cache)
            @test evaluation.point == point
            @test evaluation.point.provenance.kind == kind
            @test ND.evaluate_numerical(model, point; cache) === evaluation
        end
        @test cache.misses == length(kinds)
    end
    cache = ND.EvaluationCache()
    for (complete, value) in ((true,"a"), (false,"a"), (false,"b"))
        point = ND.evaluation_point(model, [1.0]; label="same",
            provenance=ND.EvaluationPointProvenance(ND.UserPoint; source="test",
                complete, metadata=Dict("fixture"=>value)))
        @test ND.evaluate_numerical(model, point; cache).point == point
    end
    @test cache.misses == 3
end

@testset "Captured evaluations reject changed public models" begin
    model, variables, ci = affine_model()
    point = ND.evaluation_point(model, [1.0])
    old = ND.evaluate_numerical(model, point)
    @test ND.analyze(model; evaluation=old).metadata[:evaluation_model_binding] ==
        "captured_public_description"
    manual = ND.NumericalEvaluation(old.point, old.objective_value, old.objective_source,
        old.objective_gradient, old.constraint_values, old.constraint_sources,
        old.jacobian_entries, old.jacobian_row_methods, old.capabilities, old.failures,
        old.call_statistics, old.objective_gradient_method)
    @test ND.analyze(model; evaluation=manual).metadata[:evaluation_model_binding] == "unverified"
    MOI.set(model, MOI.ConstraintFunction(), ci,
        MOI.ScalarAffineFunction([MOI.ScalarAffineTerm(1e6, variables[1])], 0.0))
    @test_throws ArgumentError ND.analyze(model; evaluation=old)
    @test_throws ArgumentError ND.constraint_feasibility_summary(model, old)
    @test_throws ArgumentError ND.analyze_component_ranks(model, old)
    @test ND.evaluate_numerical(model, point).constraint_values == [1e6]
    fresh = ND.evaluate_numerical(model, point)
    MOI.set(model, MOI.ConstraintSet(), ci, MOI.EqualTo(2.0))
    @test_throws ArgumentError ND.analyze_numerical(model, fresh)
    fresh = ND.evaluate_numerical(model, point)
    MOI.set(model, MOI.ObjectiveSense(), MOI.MAX_SENSE)
    MOI.set(model, MOI.ObjectiveFunction{MOI.VariableIndex}(), variables[1])
    @test_throws ArgumentError ND.analyze_numerical(model, fresh)
    other, _, _ = affine_model()
    @test_throws ArgumentError ND.analyze(other; evaluation=old)
end

struct ContractEvaluator <: MOI.AbstractNLPEvaluator end
@testset "NLPBlock public fingerprint coverage" begin
    model = newmodel()
    MOI.add_variable(model)
    function fingerprint(bounds, objective)
        MOI.set(model, MOI.NLPBlock(), MOI.NLPBlockData(bounds, ContractEvaluator(), objective))
        return ND.model_fingerprint(model)
    end
    a = fingerprint([MOI.NLPBoundsPair(0.0, 1.0)], false)
    @test a == fingerprint([MOI.NLPBoundsPair(0.0, 1.0)], false)
    @test a != fingerprint([MOI.NLPBoundsPair(2.0, 3.0)], false)
    @test a != fingerprint([MOI.NLPBoundsPair(0.0, 1.0)], true)
    @test a != fingerprint([MOI.NLPBoundsPair(0.0, 1.0), MOI.NLPBoundsPair(0.0, 1.0)], false)
end

@testset "Rectangular dense factor and output guards" begin
    n = 1200
    model, _, _ = affine_model(; columns=n)
    evaluation = ND.evaluate_numerical(model, ND.evaluation_point(model, zeros(n)))
    values_only = ND.RankPolicy(Float64; backend=:dense_svd,
        max_dense_entries=n, compute_vectors=false)
    result = ND.jacobian_rank_estimate(evaluation, values_only)
    @test result.available && result.rank == 1
    @test isempty(result.right_nullspace) && isempty(result.left_nullspace)
    # Bounded regression: a full n×n factor alone exceeds this allowance.
    allocated = @allocated ND.jacobian_rank_estimate(evaluation, values_only)
    @test allocated < 4n^2
    @test !ND.jacobian_rank_estimate(evaluation, ND.RankPolicy(Float64;
        max_dense_entries=n, compute_vectors=true)).available
    @test !ND.jacobian_rank_estimate(evaluation, ND.RankPolicy(Float64;
        backend=:normal_eigen, max_dense_entries=n, compute_vectors=false)).available
    empty = newmodel()
    MOI.add_variables(empty, n)
    empty_eval = ND.evaluate_numerical(empty, ND.evaluation_point(empty, zeros(n)))
    @test !ND.jacobian_rank_estimate(empty_eval, ND.RankPolicy(Float64;
        max_dense_entries=0, compute_vectors=true)).available
    @test ND.jacobian_rank_estimate(empty_eval, ND.RankPolicy(Float64;
        max_dense_entries=0, compute_vectors=false)).available
end

end # module
