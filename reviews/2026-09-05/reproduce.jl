# Bounded counterexamples for the scientific review, not passing regressions.
# These assertions describe the observed bugs at the reviewed revision.
# After fixes, replace them with assertions of the correct behavior in test/.
using Test
import MathOptInterface as MOI
import NLPDiagnostics as ND
using LinearAlgebra
LinearAlgebra.BLAS.set_num_threads(1)

newmodel() = MOI.Utilities.UniversalFallback(MOI.Utilities.Model{Float64}())

@testset "Review: floating-point evaluation is not an infeasibility proof" begin
    m = newmodel()
    x, y = MOI.add_variables(m, 2)
    MOI.add_constraint(m, x, MOI.EqualTo(1.0))
    MOI.add_constraint(m, y, MOI.EqualTo(1.0))
    f = MOI.ScalarAffineFunction([
        MOI.ScalarAffineTerm(1e16, x), MOI.ScalarAffineTerm(-1e16, y),
    ], 1.0)
    MOI.add_constraint(m, f, MOI.EqualTo(1.0))
    # Exact integer arithmetic verifies the unique point satisfies the row.
    @test big(1) + big(10)^16 - big(10)^16 == 1
    report = ND.analyze(m)
    wrong = ND.findings(report; code=:infeasible_fixed_affine_constraint)
    @test length(wrong) == 1
    @test only(wrong).basis == ND.MathematicalProof
    @test only(wrong).confidence == ND.ConfidenceCertain
    println("FALSE PROOF: ", only(wrong).observation)

    enclosure = ND._interval_add(ND.IntervalEnclosure(1e16, 1e16),
        ND.IntervalEnclosure(1.0, 1.0))
    exact = big(10)^16 + 1
    @test !(BigFloat(enclosure.lower) <= exact <= BigFloat(enclosure.upper))
    println("NON-ENCLOSURE: ", enclosure, " excludes exact value ", exact)
end

@testset "Review: stale evaluation accepted and relabelled" begin
    m = newmodel()
    x = MOI.add_variable(m)
    ci = MOI.add_constraint(m,
        MOI.ScalarAffineFunction([MOI.ScalarAffineTerm(1.0, x)], 0.0),
        MOI.EqualTo(0.0))
    point = ND.evaluation_point(m, [1.0])
    old = ND.evaluate_numerical(m, point)
    old_fingerprint = ND.model_fingerprint(m)
    MOI.set(m, MOI.ConstraintFunction(), ci,
        MOI.ScalarAffineFunction([MOI.ScalarAffineTerm(1e6, x)], 0.0))
    fresh = ND.evaluate_numerical(m, point)
    @test old.constraint_values == [1.0]
    @test fresh.constraint_values == [1e6]
    @test old_fingerprint != ND.model_fingerprint(m)
    report = ND.analyze(m; evaluation=old)
    @test report.metadata[:model_fingerprint] == ND.model_fingerprint(m)
    println("STALE EVALUATION: old residual=", old.constraint_values,
        ", fresh residual=", fresh.constraint_values,
        "; report accepts old values with current model fingerprint")
end

struct ReviewEvaluator <: MOI.AbstractNLPEvaluator end
@testset "Review: NLPBlock fingerprint ignores bounds" begin
    m = newmodel()
    MOI.add_variable(m)
    MOI.set(m, MOI.NLPBlock(),
        MOI.NLPBlockData([MOI.NLPBoundsPair(0.0, 1.0)], ReviewEvaluator(), false))
    before = ND.model_fingerprint(m)
    MOI.set(m, MOI.NLPBlock(),
        MOI.NLPBlockData([MOI.NLPBoundsPair(2.0, 3.0)], ReviewEvaluator(), false))
    @test ND.model_fingerprint(m) == before
    println("FINGERPRINT COLLISION: disjoint NLPBlock bounds have identical digest")
end

@testset "Review: dense SVD guard ignores full factor sizes" begin
    n = 1200
    m = newmodel()
    x = MOI.add_variables(m, n)
    MOI.add_constraint(m,
        MOI.ScalarAffineFunction([MOI.ScalarAffineTerm(1.0, x[1])], 0.0),
        MOI.EqualTo(0.0))
    evaluation = ND.evaluate_numerical(m, ND.evaluation_point(m, zeros(n)))
    policy = ND.RankPolicy(Float64; backend=:dense_svd,
        max_dense_entries=n, compute_vectors=false)
    result = ND.jacobian_rank_estimate(evaluation, policy)
    @test result.available
    GC.gc()
    allocated = @allocated ND.jacobian_rank_estimate(evaluation, policy)
    @test allocated > 8n^2
    println("DENSE GUARD: ", n, " permitted entries, compute_vectors=false, ",
        allocated, " allocated bytes after warmup")
end

@testset "Review: cache key omits point provenance" begin
    m = newmodel()
    MOI.add_variable(m)
    cache = ND.EvaluationCache()
    user = ND.evaluation_point(m, [1.0]; label="same")
    synthetic = ND.evaluation_point(m, [1.0]; label="same",
        provenance=ND.EvaluationPointProvenance(ND.SyntheticSmokePoint;
            source="review synthetic control"))
    @test user != synthetic
    first_eval = ND.evaluate_numerical(m, user; cache)
    second_eval = ND.evaluate_numerical(m, synthetic; cache)
    @test second_eval === first_eval
    @test second_eval.point.provenance.kind == ND.UserPoint
    println("PROVENANCE LOST: requested synthetic point returns cached UserPoint")
end

@testset "Review: component row identity collision" begin
    m = newmodel()
    x, y = MOI.add_variables(m, 2)
    # VariableIndex bounds and ScalarAffineFunction rows can share raw index 1.
    MOI.add_constraint(m, x, MOI.GreaterThan(0.0))
    MOI.add_constraint(m,
        MOI.ScalarAffineFunction([MOI.ScalarAffineTerm(1.0, y)], 0.0),
        MOI.EqualTo(0.0))
    evaluation = ND.evaluate_numerical(m, ND.evaluation_point(m, [1.0, 1.0]))
    sources = evaluation.constraint_sources
    @test length(sources) == 2
    @test sources[1] != sources[2]
    @test ND._entity_row_key(sources[1]) == ND._entity_row_key(sources[2])
    # Choose the first row's own nonzero coordinate; the dictionary overwrites
    # it with the second row, whose derivative in this coordinate is zero.
    entry = only(filter(e -> e.row == 1, evaluation.jacobian_entries))
    variable = evaluation.point.variables[entry.column]
    component = ND.ComponentMetadata(:review, "first row";
        variables=[variable], constraints=[sources[1]], expected_rank=1)
    report = ND.analyze_component_ranks(m, evaluation; components=[component])
    wrong = ND.findings(report; code=:component_expected_rank_mismatch)
    @test length(wrong) == 1
    println("WRONG COMPONENT ROW: ", only(wrong).observation)
end
