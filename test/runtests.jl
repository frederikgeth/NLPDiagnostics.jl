# Intentionally broken models are the primary regression-test style.
using Test

import JuMP
import MathOptInterface as MOI
import JSON
import NLPDiagnostics

const MOIU = MOI.Utilities

struct UnknownCoupledSet <: MOI.AbstractVectorSet end
MOI.dimension(::UnknownCoupledSet) = 2

struct PluginCoupledSet <: MOI.AbstractVectorSet end
MOI.dimension(::PluginCoupledSet) = 2

mutable struct TestNLPEvaluator <: MOI.AbstractNLPEvaluator
    initialize_count::Int
    requested::Vector{Symbol}
end

include("rank_calibration.jl")
include("randomized_rank_oracles.jl")
include("point_provenance.jl")
include("fingerprints_and_crosscheck.jl")
include("scaling_covariance.jl")
include("block_scaling_covariance.jl")
include("solver_duals.jl")

@testset "typed unavailable reason schema" begin
    @test NLPDiagnostics.Advanced.UnavailableReason ===
          NLPDiagnostics.UnavailableReason
    @test NLPDiagnostics.Advanced.RankPolicy === NLPDiagnostics.RankPolicy
    @test NLPDiagnostics.Advanced.unavailable_reason_data ===
          NLPDiagnostics.unavailable_reason_data
    reason = NLPDiagnostics.UnavailableReason(
        "dense Jacobian exceeds the configured work guard";
        code = :dense_work_guard,
        category = :work_guard,
        stage = :numerical,
    )
    @test reason.code == :dense_work_guard
    @test reason.category == :work_guard
    @test reason.stage == :numerical
    @test reason.exception_type === nothing
    @test string(reason) == reason.message
    data = NLPDiagnostics.unavailable_reason_data(reason)
    @test data["schema_version"] == "nlpdiagnostics-unavailable-reason-v1"
    @test data["code"] == "dense_work_guard"
    @test data["category"] == "work_guard"
    @test data["stage"] == "numerical"
    @test data["exception_type"] === nothing

    unavailable_result = (available = false, reason = "dense work guard")
    adapted = NLPDiagnostics.unavailable_reason(
        unavailable_result;
        code = :dense_work_guard,
        category = :work_guard,
        stage = :numerical,
    )
    @test adapted isa NLPDiagnostics.UnavailableReason
    @test NLPDiagnostics.unavailable_reason_data(adapted)["message"] ==
          "dense work guard"
    @test NLPDiagnostics.unavailable_reason((available = true, reason = nothing)) ===
          nothing
    @test_throws ArgumentError NLPDiagnostics.unavailable_reason((available = false,))

    dependency = NLPDiagnostics.UnavailableReason(
        "optional solver extension is not loaded";
        code = :missing_dependency,
        category = :dependency,
        exception_type = "LoadError",
    )
    @test NLPDiagnostics.unavailable_reason_data(dependency)["exception_type"] ==
          "LoadError"
    @test_throws ArgumentError NLPDiagnostics.UnavailableReason("")
    @test_throws ArgumentError NLPDiagnostics.UnavailableReason(
        "bad category";
        category = :unknown,
    )
end

@testset "Advanced facade export tier contract" begin
    advanced_exports = filter(
        name -> name != :Advanced,
        names(NLPDiagnostics.Advanced; all=false, imported=false),
    )
    @test length(advanced_exports) == 14
    @test all(isdefined(NLPDiagnostics, name) for name in advanced_exports)
    @test all(isdefined(NLPDiagnostics.Advanced, name) for name in advanced_exports)
end

@testset "Stable facade export tier contract" begin
    stable_exports = filter(
        name -> name != :Stable,
        names(NLPDiagnostics.Stable; all=false, imported=false),
    )
    @test length(stable_exports) == 16
    @test all(isdefined(NLPDiagnostics.Stable, name) for name in stable_exports)
    @test NLPDiagnostics.Stable.ModelSnapshot === NLPDiagnostics.ModelSnapshot
    @test NLPDiagnostics.Stable.snapshot === NLPDiagnostics.snapshot
    @test NLPDiagnostics.Stable.analyze === NLPDiagnostics.analyze
    @test NLPDiagnostics.Stable.report_data === NLPDiagnostics.report_data

    tier_inventory = read(
        joinpath(normpath(joinpath(@__DIR__, "..")), "docs", "api_tier_inventory_summary.json"),
        String,
    )
    @test occursin("nlpdiagnostics-api-tier-inventory-v2", tier_inventory)
    @test occursin("\"queue_count\": 539", tier_inventory)
    @test occursin("\"advanced_candidate_count\": 102", tier_inventory)
    @test occursin("\"legacy_manual_review_count\": 437", tier_inventory)
    tier_usage_script = read(
        joinpath(normpath(joinpath(@__DIR__, "..")), "benchmarks", "audit_api_tier_usage.jl"),
        String,
    )
    @test Meta.parseall(tier_usage_script) isa Expr
    @test occursin("has_runtime_usage_evidence", tier_usage_script)
    tier_usage_summary = JSON.parse(read(
        joinpath(normpath(joinpath(@__DIR__, "..")), "docs", "api_tier_usage_summary.json"),
        String,
    ))
    @test tier_usage_summary["schema_version"] == "nlpdiagnostics-api-tier-usage-v1"
    @test tier_usage_summary["queue_count"] == 539
    @test tier_usage_summary["runtime_usage_evidence_count"] == 423
    @test tier_usage_summary["unreferenced_in_code_count"] == 4
    @test tier_usage_summary["usage_priority_counts"]["test_and_benchmark_usage"] == 133

    stable_surface_script = read(
        joinpath(normpath(joinpath(@__DIR__, "..")), "benchmarks", "audit_stable_api_surface.jl"),
        String,
    )
    @test Meta.parseall(stable_surface_script) isa Expr
    @test occursin("surface_matches", stable_surface_script)
    stable_surface_summary = JSON.parse(read(
        joinpath(normpath(joinpath(@__DIR__, "..")), "docs", "stable_api_surface_summary.json"),
        String,
    ))
    @test stable_surface_summary["schema_version"] == "nlpdiagnostics-stable-api-surface-v1"
    @test stable_surface_summary["status"] == "pass"
    @test stable_surface_summary["declared_export_count"] == 16
    @test stable_surface_summary["runtime_export_count"] == 16
    @test stable_surface_summary["surface_matches"] == true
    @test stable_surface_summary["smoke"]["status"] == "pass"

    advanced_surface_script = read(
        joinpath(normpath(joinpath(@__DIR__, "..")), "benchmarks", "audit_advanced_api_surface.jl"),
        String,
    )
    @test Meta.parseall(advanced_surface_script) isa Expr
    @test occursin("surface_matches", advanced_surface_script)
    advanced_surface_summary = JSON.parse(read(
        joinpath(normpath(joinpath(@__DIR__, "..")), "docs", "advanced_api_surface_summary.json"),
        String,
    ))
    @test advanced_surface_summary["schema_version"] == "nlpdiagnostics-advanced-api-surface-v1"
    @test advanced_surface_summary["status"] == "pass"
    @test advanced_surface_summary["declared_export_count"] == 14
    @test advanced_surface_summary["runtime_export_count"] == 14
    @test advanced_surface_summary["surface_matches"] == true
    @test advanced_surface_summary["smoke"]["status"] == "pass"

    migration_queue_script = read(
        joinpath(normpath(joinpath(@__DIR__, "..")), "benchmarks", "summarize_api_migration_queue.jl"),
        String,
    )
    @test Meta.parseall(migration_queue_script) isa Expr
    @test occursin("disposition_usage_matrix", migration_queue_script)
    migration_queue_summary = JSON.parse(read(
        joinpath(normpath(joinpath(@__DIR__, "..")), "docs", "api_migration_queue_summary.json"),
        String,
    ))
    @test migration_queue_summary["schema_version"] == "nlpdiagnostics-api-migration-queue-v1"
    @test migration_queue_summary["queue_count"] == 539
    @test migration_queue_summary["runtime_usage_evidence_count"] == 423
    @test migration_queue_summary["unreferenced_in_code_count"] == 4
    @test sum(values(migration_queue_summary["priority_counts"])) == 539
    @test migration_queue_summary["priority_counts"]["unreferenced_in_code"] == 4

    advanced_candidate_script = read(
        joinpath(normpath(joinpath(@__DIR__, "..")), "benchmarks", "summarize_api_advanced_candidates.jl"),
        String,
    )
    @test Meta.parseall(advanced_candidate_script) isa Expr
    @test occursin("family_priority_matrix", advanced_candidate_script)
    advanced_candidate_summary = JSON.parse(read(
        joinpath(normpath(joinpath(@__DIR__, "..")), "docs", "api_advanced_candidate_summary.json"),
        String,
    ))
    @test advanced_candidate_summary["schema_version"] == "nlpdiagnostics-api-advanced-candidates-v1"
    @test advanced_candidate_summary["candidate_count"] == 102
    @test advanced_candidate_summary["family_counts"]["bmopf_extension"] == 96
    @test advanced_candidate_summary["family_counts"]["port_extension"] == 6

    stable_model = MOI.Utilities.UniversalFallback(MOI.Utilities.Model{Float64}())
    stable_variable = MOI.add_variable(stable_model)
    stable_constraint = MOI.ScalarAffineFunction(
        [MOI.ScalarAffineTerm(1.0, stable_variable)], 0.0,
    )
    MOI.add_constraint(stable_model, stable_constraint, MOI.EqualTo(0.0))
    stable_point = NLPDiagnostics.Stable.EvaluationPoint(
        [stable_variable], [0.0]; label = "stable-api-smoke",
    )
    stable_snapshot = NLPDiagnostics.Stable.snapshot(stable_model)
    stable_evaluation = NLPDiagnostics.Stable.evaluate_numerical(
        stable_model, stable_point,
    )
    stable_report = NLPDiagnostics.Stable.analyze(
        stable_model;
        evaluation = stable_evaluation,
        rank_max_dense_entries = 100,
    )
    @test length(stable_snapshot.variables) == 1
    @test stable_evaluation.point == stable_point
    @test stable_report isa NLPDiagnostics.DiagnosticReport
    @test haskey(NLPDiagnostics.Stable.report_data(stable_report), "findings")
end

@testset "composable analysis policy structs" begin
    @test NLPDiagnostics.ProbePolicy(
        iterative_right_nullspace_probe_dimension = 2,
        check_sparse_qr_nullspace = true,
    ).iterative_right_nullspace_probe_dimension == 2
    @test NLPDiagnostics.CheckPolicy(initialization = true).initialization
    @test NLPDiagnostics.CheckPolicy(
        objective_jacobian_scaling = true,
    ).objective_jacobian_scaling
    @test NLPDiagnostics.CheckPolicy(convexity = true).convexity
    @test NLPDiagnostics.CheckPolicy(degrees_of_freedom = true).degrees_of_freedom
    @test NLPDiagnostics.CheckPolicy(nonsmoothness = true).nonsmoothness
    @test NLPDiagnostics.CheckPolicy(weak_activity = true).weak_activity
    legacy_check_policy = NLPDiagnostics.CheckPolicy(
        false,
        false,
        false,
        false,
        false,
        false,
        false,
        true,
    )
    @test legacy_check_policy.degeneracy
    @test !legacy_check_policy.convexity
    @test !legacy_check_policy.degrees_of_freedom
    @test !legacy_check_policy.nonsmoothness
    @test !legacy_check_policy.weak_activity
    @test_throws ArgumentError NLPDiagnostics.ProbePolicy(
        iterative_left_nullspace_probe_dimension = -1,
    )

    policy_model = MOI.Utilities.Model{Float64}()
    policy_variable = MOI.add_variable(policy_model)
    MOI.add_constraint(policy_model, policy_variable, MOI.EqualTo(0.0))
    rank_policy = NLPDiagnostics.RankPolicy(
        Float64;
        relative_tolerance = 1.0e-8,
        max_dense_entries = 100,
    )
    report = NLPDiagnostics.analyze(
        policy_model;
        rank_policy,
        probe_policy = NLPDiagnostics.ProbePolicy(),
        check_policy = NLPDiagnostics.CheckPolicy(),
    )
    @test report.metadata[:rank_policy] == "RankPolicy"
    @test report.metadata[:probe_policy] == "ProbePolicy"
    @test report.metadata[:check_policy] == "CheckPolicy"
    @test_throws ArgumentError NLPDiagnostics.analyze(
        policy_model;
        rank_policy = NLPDiagnostics.RankPolicy(Float64; backend = :sparse_qr),
    )
end

if Base.find_package("Ipopt") !== nothing
    import Ipopt

    @testset "Ipopt public iteration trace capture" begin
        model = JuMP.Model(Ipopt.Optimizer)
        JuMP.set_silent(model)
        JuMP.@variable(model, x)
        JuMP.@constraint(model, x >= 1.0)
        JuMP.@NLobjective(model, Min, (x - 2.0)^2)
        JuMP.set_start_value(x, 0.25)
        run = NLPDiagnostics.ipopt_profile_with_iteration_trace!(model;
            capture_points = true,
        )
        trace = run.trace
        @test !isempty(trace.records)
        @test length(trace.bindings) == length(trace.records)
        @test all(record.format == :ipopt_callback for record in trace.records)
        @test all(length(binding.point.values) == 1 for binding in trace.bindings)
        @test all(binding.point.label isa String for binding in trace.bindings)
        trace_data = NLPDiagnostics.iteration_trace_data(trace)
        @test trace_data["record_count"] == length(trace.records)
        @test trace_data["schema_version"] == "nlpdiagnostics-iteration-trace-v4"
        @test trace_data["summary"]["record_count"] == length(trace.records)
        @test trace_data["summary"]["binding_count"] == length(trace.bindings)
        @test trace_data["telemetry_coverage"]["barrier_parameter"] == length(trace.records)
        @test trace_data["telemetry_coverage"]["step_norm"] == length(trace.records)
        @test trace_data["telemetry_coverage"]["regularization_size"] == length(trace.records)
        @test trace_data["telemetry_coverage"]["dual_step"] == length(trace.records)
        @test trace_data["telemetry_coverage"]["line_search_trials"] == length(trace.records)
        @test all(record.semantics.primal_infeasibility ==
                  NLPDiagnostics.SolverScaledCoordinates for record in trace.records)
        @test run.result isa NLPDiagnostics.SolverProfileResult
        run_data = NLPDiagnostics.profile_result_data(run)
        @test run_data["iteration_trace"]["record_count"] == length(trace.records)
        @test haskey(run_data, "solver_profile")
        endpoint_evaluation = run.result.profile.evaluation
        endpoint_bounds = NLPDiagnostics._evaluated_row_bounds(
            JuMP.backend(model), endpoint_evaluation,
        )
        endpoint_map = NLPDiagnostics.DiagonalScalingMap(
            "ipopt-trace-identity";
            variable_keys=["x"],
            variable_scales=[1.0],
            constraint_keys=["lower-bound"],
            constraint_scales=[1.0],
            constraint_bounds=endpoint_bounds,
        )
        endpoint_data = NLPDiagnostics.solver_trace_physical_endpoint_data(
            model,
            run,
            endpoint_map;
            physical_kkt_kwargs=(
                feasibility_default_absolute_tolerance=1.0e-6,
                stationarity_default_absolute_tolerance=1.0e-6,
                dual_default_absolute_tolerance=1.0e-6,
                complementarity_default_absolute_tolerance=1.0e-6,
            ),
        )
        @test endpoint_data["schema_version"] ==
            "solver-trace-physical-endpoint-v1"
        @test endpoint_data["available"]
        @test endpoint_data["acceptance_passed"]
        @test endpoint_data["solver_trace_profile"]["iteration_trace"][
            "record_count"
        ] == length(trace.records)
        @test endpoint_data["last_captured_solver_record"]["iteration"] ==
            last(trace.records).iteration
        @test !endpoint_data["evidence_relationship"][
            "numeric_residual_comparison_performed"
        ]
        linear_telemetry = NLPDiagnostics.solver_linear_telemetry_data(trace)
        @test !linear_telemetry["available"]
        @test !linear_telemetry["factorization_work_available"]
        @test linear_telemetry["regularization_proxy"]["coverage_complete"]
        @test linear_telemetry["factorization_numerics"][
            "unavailable_reason"
        ]["schema_version"] == "nlpdiagnostics-unavailable-reason-v1"
        @test linear_telemetry["factorization_numerics"][
            "unavailable_reason"
        ]["code"] == "factorization_telemetry_unavailable"
        @test !endpoint_data["linear_solver_telemetry"]["available"]
        geometry = NLPDiagnostics.iteration_trace_jacobian_family_geometry_data(
            JuMP.backend(model),
            trace;
            row_labels=fill(
                "constraint", length(endpoint_evaluation.constraint_sources),
            ),
            column_labels=fill(
                "variable", length(endpoint_evaluation.point.variables),
            ),
            max_points=3,
        )
        single_geometry =
            NLPDiagnostics.iteration_trace_jacobian_family_geometry_data(
                JuMP.backend(model), run.trace;
                row_labels=fill(
                    "constraint",
                    length(endpoint_evaluation.constraint_sources),
                ),
                column_labels=fill(
                    "variable",
                    length(endpoint_evaluation.point.variables),
                ),
                max_points=1,
            )
        @test single_geometry["available"]
        @test single_geometry["selected_binding_count"] == 1
        @test geometry["available"]
        @test geometry["coverage_complete"]
        @test geometry["selected_binding_count"] <= 3
        @test haskey(geometry["trajectories"]["columns"], "variable")
    end
end

if Base.find_package("MadNLP") !== nothing
    import MadNLP

    @testset "MadNLP public intermediate trace callback" begin
        model = JuMP.Model(MadNLP.Optimizer)
        JuMP.set_silent(model)
        JuMP.@variable(model, x)
        JuMP.@constraint(model, x >= 1.0)
        JuMP.@NLobjective(model, Min, (x - 2.0)^2)
        JuMP.set_start_value(x, 0.25)
        run = NLPDiagnostics.madnlp_profile_with_iteration_trace!(model)
        trace = run.trace
        @test !isempty(trace.records)
        @test all(record.format == :madnlp_callback for record in trace.records)
        @test any(record.phase == :regular for record in trace.records)
        @test all(isnothing(binding.point) for binding in trace.bindings)
        @test all(!isnothing(record.barrier_parameter) for record in trace.records)
        @test all(!isnothing(record.regularization_size) for record in trace.records)
        @test all(!isempty(record.linear_telemetry) for record in trace.records)
        @test all(haskey(record.linear_telemetry,
                         "factorization_count_cumulative") for record in trace.records)
        @test all(!isnothing(record.dual_step) for record in trace.records)
        @test all(record.semantics.objective == NLPDiagnostics.OriginalModelCoordinates
                  for record in trace.records)
        @test run.result isa NLPDiagnostics.SolverProfileResult
        @test isapprox(last(trace.records).objective, JuMP.objective_value(model);
            rtol = 1.0e-8,
        )
        linear_telemetry = NLPDiagnostics.solver_linear_telemetry_data(trace)
        @test linear_telemetry["available"]
        @test linear_telemetry["factorization_work_available"]
        @test linear_telemetry["linear_solver_time_available"]
        @test linear_telemetry["fields"][
            "factorization_count_cumulative"
        ]["coverage_complete"]
        @test linear_telemetry["fields"][
            "factorization_count_cumulative"
        ]["monotone_within_segments"] !== false
        capability = NLPDiagnostics.madnlp_primal_capture_capability()
        @test capability.metadata[:primal_callback] == "unavailable"
        @test capability.metadata[:primal_callback_reason] ==
              "MadNLP's public intermediate callback exposes no stable public primal-vector accessor"
        capability_data = NLPDiagnostics.report_data(capability)
        @test length(capability_data["unavailable_reasons"]) == 1
        @test capability_data["unavailable_reasons"][1]["code"] ==
              "madnlp_primal_capture_unavailable"
        @test capability_data["unavailable_reasons"][1]["category"] == "capability"
        @test capability_data["unavailable_reasons"][1]["stage"] ==
              "madnlp_primal_capture"
        @test count(finding -> finding.code == :madnlp_primal_capture_unavailable,
                    capability.findings) == 1
    end
end

TestNLPEvaluator() = TestNLPEvaluator(0, Symbol[])

MOI.features_available(::TestNLPEvaluator) = [:Grad, :Jac, :Hess]

function MOI.initialize(evaluator::TestNLPEvaluator, requested::Vector{Symbol})
    evaluator.initialize_count += 1
    evaluator.requested = copy(requested)
    return
end

MOI.eval_objective(::TestNLPEvaluator, x) = x[1]^2 + x[2]

function MOI.eval_objective_gradient(::TestNLPEvaluator, gradient, x)
    gradient .= [2 * x[1], 1]
    return
end

function MOI.eval_constraint(::TestNLPEvaluator, values, x)
    values .= [x[1] + x[2], x[2]^2]
    return
end

MOI.jacobian_structure(::TestNLPEvaluator) =
    [(1, 1), (1, 1), (1, 2), (2, 2)]

function MOI.eval_constraint_jacobian(::TestNLPEvaluator, values, x)
    # The two (1, 1) entries are additive and deliberately duplicated.
    values .= [0.25, 0.75, 1.0, 2 * x[2]]
    return
end

MOI.hessian_lagrangian_structure(::TestNLPEvaluator) =
    [(1, 1), (2, 2), (2, 2)]

function MOI.eval_hessian_lagrangian(::TestNLPEvaluator, values, x, sigma, mu)
    # The two (2, 2) entries are additive, as permitted by MOI.
    values .= [2 * sigma, mu[2], mu[2]]
    return
end

function new_model()
    return MOIU.UniversalFallback(MOIU.Model{Float64}())
end

function findings(report, code)
    return filter(finding -> finding.code == code, report.findings)
end

@testset "optional PowerModels persistence entry points" begin
    @test_throws ArgumentError NLPDiagnostics.powermodels_analyze_jacobian_rank_persistence(
        nothing,
        NLPDiagnostics.EvaluationPoint[],
    )
    @test_throws ArgumentError NLPDiagnostics.powermodels_analyze_component_rank_persistence(
        nothing,
        NLPDiagnostics.EvaluationPoint[],
    )
end

if Base.find_package("PowerModels") !== nothing
import PowerModels

@testset "PowerModels public persistence adapter" begin
    case_path = normpath(joinpath(
        dirname(pathof(PowerModels)), "..", "test", "data", "matpower", "case3.m",
    ))
    pm = PowerModels.instantiate_model(
        PowerModels.parse_file(case_path),
        PowerModels.ACPPowerModel,
        PowerModels.build_opf,
    )
    @test Base.get_extension(NLPDiagnostics, :PowerModelsExt) !== nothing
    @test !isempty(NLPDiagnostics.powermodels_component_metadata(pm))
    component_capability_report = NLPDiagnostics.powermodels_component_rank_capability_report(pm)
    @test component_capability_report.metadata[:stage] ==
          "powermodels_component_rank_capability"
    @test length(findings(component_capability_report,
                          :component_expected_rank_unavailable)) == 1
    power_capability_report = NLPDiagnostics.powermodels_capability_report(pm)
    power_available = power_capability_report.metadata[:powermodels_scalar_angle_coordinates_available]
    @test power_available in ("true", "false")
    power_capability_data = NLPDiagnostics.report_data(power_capability_report)
    @test length(power_capability_data["unavailable_reasons"]) == (power_available == "false" ? 1 : 0)
    if power_available == "false"
        @test power_capability_report.metadata[:powermodels_scalar_angle_coordinates_reason] ==
              "one or more PowerModels networks expose no public scalar :va coordinates"
        @test power_capability_data["unavailable_reasons"][1]["code"] ==
              "powermodels_scalar_angle_coordinates_unavailable"
        @test power_capability_data["unavailable_reasons"][1]["category"] == "capability"
        @test power_capability_data["unavailable_reasons"][1]["stage"] ==
              "powermodels_capabilities"
    end
    owner = NLPDiagnostics.powermodels_jump_model(pm)
    @test owner !== nothing
    backend = JuMP.backend(owner)
    variables = MOI.get(backend, MOI.ListOfVariableIndices())
    point = NLPDiagnostics.EvaluationPoint(variables, zeros(length(variables)); label = "case3-zero")
    jacobian_report = NLPDiagnostics.powermodels_analyze_jacobian_rank_persistence(
        pm, [point, point],
    )
    @test jacobian_report.metadata[:powermodels_angle_gauge_mode_count] isa String
    component_report = NLPDiagnostics.powermodels_analyze_component_rank_persistence(
        pm, [point, point],
    )
    @test component_report.metadata[:powermodels_angle_gauge_mode_count] isa String
end
end

if Base.find_package("BMOPFTools") === nothing
@testset "BMOPFTools terminal adapter fallback" begin
    @test_throws ArgumentError NLPDiagnostics.bmopf_terminal_report(Dict{String,Any}())
    @test_throws ArgumentError NLPDiagnostics.bmopf_analyze_opf(nothing)
end
else
import BMOPFTools

if Base.find_package("Ipopt") !== nothing &&
   isdefined(BMOPFTools, :OpfScaling) &&
   isdefined(BMOPFTools, :OpfDiagnosticSchema) &&
   hasmethod(BMOPFTools.build_opf_model, Tuple{Dict{String,Any}})
    import Ipopt
    include("bmopf_scaling_covariance.jl")
    include("bmopf_scaling_formulations.jl")
end

@testset "BMOPFTools terminal adapter" begin
    @test Base.get_extension(NLPDiagnostics, :BMOPFToolsExt) !== nothing
    net = Dict{String,Any}(
        "name" => "floating-neutral-adapter-test",
        "bus" => Dict{String,Any}(
            "source" => Dict{String,Any}("terminal_names" => ["a", "n"]),
            "load" => Dict{String,Any}("terminal_names" => ["a", "n"]),
        ),
        "line" => Dict{String,Any}(
            "line" => Dict{String,Any}(
                "bus_from" => "source", "bus_to" => "load",
                "terminal_map_from" => ["a", "n"],
                "terminal_map_to" => ["a", "n"],
            ),
        ),
        "load" => Dict{String,Any}(
            "load" => Dict{String,Any}(
                "bus" => "load", "terminal_map" => ["a", "n"],
                "configuration" => "WYE",
            ),
        ),
    )
    report = NLPDiagnostics.bmopf_terminal_report(net)
    @test report.metadata[:bmopf_engine] == "BMOPFTools.analyze"
    @test report.metadata[:bmopf_grounding_n_floating] == "1"
    @test length(findings(report, :e_prov_floating_neutral)) == 1
end

struct TestBMOPFContext
    model::JuMP.Model
    net::Dict{String,Any}
    objects::Dict{BMOPFTools.OpfModelKey,Any}
    bases
end
BMOPFTools.opf_model(context::TestBMOPFContext) = context.model
BMOPFTools.opf_network(context::TestBMOPFContext) = context.net
BMOPFTools.opf_lifecycle(::TestBMOPFContext) = :kcl_finalized
BMOPFTools.opf_object(context::TestBMOPFContext, key::BMOPFTools.OpfModelKey) = context.objects[key]
BMOPFTools.opf_bases(context::TestBMOPFContext) = context.bases
if isdefined(BMOPFTools, :opf_neutral_labels)
    BMOPFTools.opf_neutral_labels(::TestBMOPFContext) = Set(["n"])
end
BMOPFTools.opf_object_keys(context::TestBMOPFContext; kind=nothing) = [
    key for key in keys(context.objects) if isnothing(kind) || key.kind == kind
]

@testset "BMOPFTools staged OPF adapter" begin
    @test Base.get_extension(NLPDiagnostics, :BMOPFToolsJuMPExt) !== nothing
    if !hasmethod(BMOPFTools.build_opf_model, Tuple{Dict{String,Any}})
        @test_throws ArgumentError NLPDiagnostics.bmopf_build_and_profile(
            Dict{String,Any}(), identity,
        )
    end
    model = JuMP.Model()
    JuMP.@variable(model, vr_a)
    JuMP.@variable(model, vr_n)
    JuMP.@variable(model, vi_a)
    JuMP.@variable(model, vi_n)
    JuMP.@variable(model, vr_load_a)
    JuMP.@variable(model, vr_load_n)
    JuMP.@variable(model, vi_load_a)
    JuMP.@variable(model, vi_load_n)
    test_constraint = JuMP.@constraint(model, vr_a == 1)
    net = Dict{String,Any}(
        "bus" => Dict{String,Any}(
            "bus" => Dict{String,Any}(
                "terminal_names" => ["a", "n"],
                "perfectly_grounded_terminals" => ["n"],
            ),
        ),
    )
    objects = Dict{BMOPFTools.OpfModelKey,Any}(
        BMOPFTools.opf_bus_voltage_key("bus", "a") => vr_a,
        BMOPFTools.opf_bus_voltage_key("bus", "n") => vr_n,
        BMOPFTools.opf_bus_voltage_key("bus", "a"; component = :imag) => vi_a,
        BMOPFTools.opf_bus_voltage_key("bus", "n"; component = :imag) => vi_n,
    )
    context = TestBMOPFContext(model, net, objects, nothing)
    ports = NLPDiagnostics.bmopf_terminal_port_metadata(context)
    @test length(ports) == 2
    @test all(length(port.terminal_labels) == 2 for port in ports)
    @test length(NLPDiagnostics.bmopf_terminal_port_coordinate_maps(context)) == 2
    @test length(NLPDiagnostics.bmopf_terminal_port_coordinate_semantics(context)) == 2
    attachment_net = deepcopy(net)
    attachment_net["load"] = Dict{String,Any}(
        "load" => Dict{String,Any}(
            "bus" => "bus", "terminal_map" => ["a", "n"],
            "configuration" => "WYE",
        ),
    )
    attachment_context = TestBMOPFContext(model, attachment_net, objects, nothing)
    attachment_ports = NLPDiagnostics.bmopf_terminal_port_metadata(attachment_context)
    @test length(attachment_ports) == 4
    @test count(port -> port.component_type == :load, attachment_ports) == 2
    attachment_connections = NLPDiagnostics.bmopf_terminal_port_connections(attachment_context)
    @test length(attachment_connections) == 2
    @test all(size(connection.connection_matrix) == (2, 2) for connection in attachment_connections)
    @test all(connection.metadata["role"] == "attachment" for connection in attachment_connections)
    @test isempty(NLPDiagnostics.bmopf_terminal_port_report(attachment_context).findings)
    attachment_assembly = NLPDiagnostics.bmopf_terminal_port_assembly(attachment_context)
    @test attachment_assembly.available
    @test attachment_assembly.component_count == 2
    @test attachment_assembly.connected_component_count == 1
    @test isempty(NLPDiagnostics.bmopf_terminal_port_assembly_report(attachment_context).findings)
    current_laws = NLPDiagnostics.bmopf_current_law_fingerprints(attachment_context)
    @test length(current_laws) == 1
    @test only(current_laws).law_family == :constant_power
    @test length(findings(
        NLPDiagnostics.bmopf_current_law_report(attachment_context),
        :bmopf_current_law_zero_voltage_singularity,
    )) == 1
    probe_net = deepcopy(attachment_net)
    probe_net["load"]["load"] = merge(probe_net["load"]["load"], Dict{String,Any}(
        "model" => "constant_power", "p_nom" => [2.0], "q_nom" => [0.0],
    ))
    probe_context = TestBMOPFContext(
        model, probe_net, objects, (v_base = Dict("bus" => 1.0),),
    )
    saved_voltage = Dict{String,Any}(
        "bus" => Dict{String,Any}(
            "bus" => Dict{String,Any}(
                "a" => Dict{String,Any}("vr" => 1.0, "vi" => 0.0),
                "n" => Dict{String,Any}("vr" => 0.0, "vi" => 0.0),
            ),
        ),
    )
    probes = NLPDiagnostics.bmopf_current_law_operating_point_probes(
        probe_context, saved_voltage,
    )
    @test length(probes) == 1
    @test only(probes).domain_status == :finite
    @test only(probes).current_magnitude ≈ 2.0
    @test only(probes).derivative_norm !== nothing
    @test isempty(NLPDiagnostics.bmopf_current_law_operating_point_report(
        probe_context, saved_voltage,
    ).findings)
    point_source = NLPDiagnostics.EvaluationPoint(
        MOI.get(JuMP.backend(model), MOI.ListOfVariableIndices()),
        [variable == JuMP.index(vr_a) ? 1.0 :
         variable == JuMP.index(vr_n) ? 0.0 :
         variable == JuMP.index(vi_a) ? 0.0 :
         variable == JuMP.index(vi_n) ? 0.0 : 0.0
         for variable in MOI.get(JuMP.backend(model), MOI.ListOfVariableIndices())],
    )
    point_probes = NLPDiagnostics.bmopf_current_law_operating_point_probes(
        probe_context, point_source,
    )
    @test only(point_probes).domain_status == :finite
    zero_voltage = deepcopy(saved_voltage)
    zero_voltage["bus"]["bus"]["a"]["vr"] = 0.0
    zero_report = NLPDiagnostics.bmopf_current_law_operating_point_report(
        probe_context, zero_voltage,
    )
    @test length(findings(zero_report, :bmopf_current_law_operating_point_zero_voltage)) == 1
    stencil_boundary = deepcopy(saved_voltage)
    stencil_boundary["bus"]["bus"]["a"]["vr"] = 1.0e-6
    stencil_probes = NLPDiagnostics.bmopf_current_law_operating_point_probes(
        probe_context, stencil_boundary; voltage_floor = 1.0e-8,
    )
    @test only(stencil_probes).domain_status == :nonfinite
    persistence_report = NLPDiagnostics.bmopf_current_law_operating_point_persistence(
        probe_context, [saved_voltage, zero_voltage],
    )
    @test length(findings(
        persistence_report, :bmopf_current_law_operating_point_domain_status_changed,
    )) == 1
    @test persistence_report.metadata[:bmopf_current_law_operating_point_snapshot_count] == "2"
    @test persistence_report.metadata[:bmopf_current_law_operating_point_snapshot_labels] ==
          "saved_result_1,saved_result_2"
    iterate_trace_capture = NLPDiagnostics.IterationTraceCapture()
    NLPDiagnostics.capture_iteration!(
        iterate_trace_capture,
        NLPDiagnostics.SolverIterationRecord(
            :ipopt_callback, 1, 1, :regular, 0.0, 1.0, 1.0, nothing, 1.0, "iter-1",
        );
        point = point_source,
    )
    zero_point = NLPDiagnostics.EvaluationPoint(
        point_source.variables, zeros(length(point_source.variables)); label = "iter-2-zero",
    )
    NLPDiagnostics.capture_iteration!(
        iterate_trace_capture,
        NLPDiagnostics.SolverIterationRecord(
            :ipopt_callback, 2, 2, :regular, 0.0, 1.0, 1.0, nothing, 1.0, "iter-2",
        );
        point = zero_point,
    )
    iterate_trace = NLPDiagnostics.iteration_trace(iterate_trace_capture)
    current_law_trace = NLPDiagnostics.bmopf_current_law_operating_point_trace(
        probe_context, iterate_trace,
    )
    @test length(current_law_trace.bindings) == 2
    @test length(current_law_trace.probes) == 2
    @test current_law_trace.metadata["trace_selected_binding_count"] == "2"
    @test length(findings(
        current_law_trace.persistence_report,
        :bmopf_current_law_operating_point_domain_status_changed,
    )) == 1
    current_law_trace_data = NLPDiagnostics.current_law_operating_point_trace_data(
        current_law_trace,
    )
    @test current_law_trace_data["metadata"]["trace_record_count"] == "2"
    @test length(current_law_trace_data["probe_snapshots"]) == 2
    ibr_net = deepcopy(probe_net)
    ibr_net["ibr"] = Dict{String,Any}(
        "inv" => Dict{String,Any}(
            "bus" => "bus", "terminal_map" => ["a", "n"],
            "topology" => "SINGLE_PHASE", "control_profile" => "pf_profile",
        ),
    )
    ibr_net["control_profile"] = Dict{String,Any}(
        "pf_profile" => Dict{String,Any}(
            "power_factor" => Dict{String,Any}("pf" => 0.9),
        ),
    )
    ibr_laws = NLPDiagnostics.bmopf_current_law_fingerprints(
        TestBMOPFContext(model, ibr_net, objects, nothing),
    )
    ibr_fingerprint = only(filter(item -> item.component_type == :ibr, ibr_laws))
    @test ibr_fingerprint.law_family == :constant_power_factor
    @test ibr_fingerprint.differentiability == :smooth_away_from_zero
    @test ibr_fingerprint.metadata["control_mode"] == "constant_power_factor"
    device_net = deepcopy(probe_net)
    device_net["generator"] = Dict{String,Any}(
        "g" => Dict{String,Any}(
            "bus" => "bus", "terminal_map" => ["a", "n"],
            "configuration" => "WYE",
        ),
    )
    device_net["ibr"] = Dict{String,Any}(
        "inv" => Dict{String,Any}(
            "bus" => "bus", "terminal_map" => ["a", "n"],
            "topology" => "SINGLE_PHASE",
        ),
    )
    device_result = deepcopy(saved_voltage)
    device_result["generator"] = Dict{String,Any}(
        "g" => Dict{String,Any}(
            "a" => Dict{String,Any}("crg" => 1.0, "cig" => 0.0, "pg" => 1.0, "qg" => 0.0),
        ),
    )
    device_result["ibr"] = Dict{String,Any}(
        "inv" => Dict{String,Any}(
            "a" => Dict{String,Any}("cri" => 0.5, "cii" => 0.0, "pg" => 0.5, "qg" => 0.0),
        ),
    )
    device_probes = NLPDiagnostics.bmopf_current_law_operating_point_probes(
        TestBMOPFContext(model, device_net, objects, nothing), device_result;
        result_units = :pu,
    )
    generator_probe = only(filter(item -> item.component_type == :generator, device_probes))
    ibr_probe = only(filter(item -> item.component_type == :ibr, device_probes))
    @test generator_probe.domain_status == :finite
    @test generator_probe.metadata["derivative_map"] ==
          "bilinear_power_voltage_current_to_p_q"
    @test generator_probe.metadata["power_equation_residual_norm"] == "0.0"
    @test ibr_probe.domain_status == :finite
    @test ibr_probe.current_magnitude ≈ 0.5
    droop_net = deepcopy(device_net)
    droop_net["ibr"]["inv"]["control_profile"] = "droop_profile"
    droop_net["ibr"]["inv"]["s_max"] = [1.0]
    droop_net["ibr"]["inv"]["p_max"] = [1.0]
    droop_net["control_profile"] = Dict{String,Any}(
        "droop_profile" => Dict{String,Any}(
            "volt_var" => Dict{String,Any}(
                "breakpoints" => [0.90, 0.98, 1.02, 1.10],
                "q_limits" => [-1.0, 1.0],
                "q_unit" => "VA_FRACTION", "q_ref" => "VAR_MAX",
            ),
            "volt_watt" => Dict{String,Any}(
                "breakpoints" => [0.90, 1.10],
                "p_limits" => [0.0, 1.0],
                "p_unit" => "VA_FRACTION", "p_ref" => "S_MAX",
            ),
        ),
    )
    droop_result = deepcopy(device_result)
    droop_result["bus"]["bus"]["a"]["vr"] = 0.98
    droop_context = TestBMOPFContext(
        model, droop_net, objects, (v_base = Dict("bus" => 1.0),),
    )
    droop_probes = NLPDiagnostics.bmopf_current_law_operating_point_probes(
        droop_context, droop_result; result_units = :pu,
    )
    droop_probe = only(filter(item -> item.component_type == :ibr, droop_probes))
    @test droop_probe.law_family == :voltage_droop
    @test droop_probe.metadata["controller_curve_family"] == "volt_var"
    @test droop_probe.metadata["controller_curve_voltage_semantics"] == "exact_public_monitored_voltage"
    @test parse(Float64, droop_probe.metadata["controller_curve_monitored_voltage"]) ≈ 0.98
    @test droop_probe.metadata["controller_curve_monitored_voltage_quantity"] == "PN"
    @test droop_probe.metadata["controller_curve_status"] == "breakpoint_proximity"
    @test droop_probe.metadata["controller_curve_volt_watt_status"] == "finite"
    @test haskey(droop_probe.metadata, "controller_curve_volt_watt_local_slope")
    @test haskey(droop_probe.metadata, "controller_curve_volt_var_equation_residual")
    @test haskey(droop_probe.metadata, "controller_curve_volt_watt_cap")
    droop_observations = NLPDiagnostics.bmopf_controller_curve_operating_point_observations(
        droop_context, droop_result; result_units = :pu,
    )
    @test Set(observation.curve_family for observation in droop_observations) ==
          Set([:volt_var, :volt_watt])
    volt_var_observation = only(filter(
        observation -> observation.curve_family == :volt_var, droop_observations,
    ))
    @test volt_var_observation.monitor_semantics == :exact_public_monitored_voltage
    @test volt_var_observation.device_base ≈ 1.0
    @test volt_var_observation.equation_residual isa Union{Nothing,Float64}
    serialized_observations = NLPDiagnostics.controller_curve_operating_point_observation_data(
        droop_observations,
    )
    @test length(serialized_observations) == 2
    @test serialized_observations[1]["curve_family"] in ("volt_var", "volt_watt")
    @test parse(Float64, droop_probe.metadata["controller_curve_smoothing_epsilon"]) > 0.0
    @test parse(Float64, droop_probe.metadata["controller_curve_local_slope"]) isa Float64
    droop_report = NLPDiagnostics.bmopf_current_law_operating_point_report(
        droop_context, droop_result; result_units = :pu,
    )
    @test length(findings(droop_report, :bmopf_controller_curve_breakpoint_proximity)) == 1
    averaged_net = deepcopy(droop_net)
    averaged_net["control_profile"]["droop_profile"]["volt_var"]["voltage_reference"] = "PN_AVERAGED"
    averaged_context = TestBMOPFContext(
        model, averaged_net, objects, (v_base = Dict("bus" => 1.0),),
    )
    averaged_probe = only(filter(
        item -> item.component_type == :ibr,
        NLPDiagnostics.bmopf_current_law_operating_point_probes(
            averaged_context, droop_result; result_units = :pu,
        ),
    ))
    @test averaged_probe.metadata["controller_curve_monitored_voltage_aggregation"] == "AVERAGE"
    @test averaged_probe.metadata["controller_curve_monitored_voltage_phase_count"] == "1"
    droop_result_2 = deepcopy(droop_result)
    droop_result_2["bus"]["bus"]["a"]["vr"] = 1.0
    droop_persistence = NLPDiagnostics.bmopf_current_law_operating_point_persistence(
        droop_context, [droop_result, droop_result_2]; result_units = :pu,
    )
    @test parse(Int, droop_persistence.metadata[:bmopf_controller_curve_changed_status_count]) >= 1
    @test length(findings(droop_persistence, :bmopf_controller_curve_status_changed)) >= 1
    @test isempty(NLPDiagnostics.bmopf_terminal_port_report(context).findings)
    broken_attachment_net = deepcopy(attachment_net)
    broken_attachment_net["load"]["load"]["terminal_map"] = ["missing", "n"]
    broken_attachment_context = TestBMOPFContext(model, broken_attachment_net, objects, nothing)
    broken_attachment_report = NLPDiagnostics.bmopf_terminal_port_report(broken_attachment_context)
    @test length(findings(broken_attachment_report, :bmopf_terminal_attachment_port_unavailable)) == 1
    @test broken_attachment_report.metadata[:bmopf_terminal_attachment_skipped_count] == "1"
    @test broken_attachment_report.metadata[:bmopf_terminal_attachment_ports_available] == "false"
    @test broken_attachment_report.metadata[:bmopf_terminal_attachment_port_reason] ==
          "one or more BMOPFTools terminal attachment ports could not be mapped to registered bus-voltage coordinates"
    broken_attachment_data = NLPDiagnostics.report_data(broken_attachment_report)
    @test length(broken_attachment_data["unavailable_reasons"]) == 1
    @test broken_attachment_data["unavailable_reasons"][1]["code"] ==
          "bmopf_terminal_attachment_port_unavailable"
    @test broken_attachment_data["unavailable_reasons"][1]["category"] == "capability"
    @test broken_attachment_data["unavailable_reasons"][1]["stage"] ==
          "bmopf_terminal_attachment_ports"

    branch_current_model = JuMP.Model()
    JuMP.@variable(branch_current_model, crd_branch)
    JuMP.@variable(branch_current_model, cid_branch)
    branch_current_net = Dict{String,Any}(
        "bus" => Dict{String,Any}(
            "phase_bus" => Dict{String,Any}(
                "terminal_names" => ["a", "b"],
            ),
        ),
        "load" => Dict{String,Any}(
            "phase_load" => Dict{String,Any}(
                "bus" => "phase_bus",
                "terminal_map" => ["a", "b"],
                "configuration" => "SINGLE_PHASE",
            ),
        ),
    )
    branch_current_objects = Dict{BMOPFTools.OpfModelKey,Any}(
        BMOPFTools.opf_load_current_key("phase_load", 1) => crd_branch,
        BMOPFTools.opf_load_current_key(
            "phase_load", 1; component = :imag,
        ) => cid_branch,
    )
    branch_current_context = TestBMOPFContext(
        branch_current_model,
        branch_current_net,
        branch_current_objects,
        nothing,
    )
    branch_current_ports =
        NLPDiagnostics.bmopf_terminal_current_port_metadata(branch_current_context)
    @test length(branch_current_ports) == 2
    @test all(port -> port.terminal_labels == ["a", "b"], branch_current_ports)
    @test all(port -> port.mode_labels == ["branch_current_1"], branch_current_ports)
    @test all(port -> port.connection_matrix == reshape([1.0, -1.0], 2, 1),
              branch_current_ports)
    branch_current_maps =
        NLPDiagnostics.bmopf_terminal_current_port_coordinate_maps(branch_current_context)
    @test length(branch_current_maps) == 2
    @test all(map -> map.terminal_to_variable ≈ [0.5 -0.5], branch_current_maps)
    branch_current_report = NLPDiagnostics.bmopf_terminal_current_port_report(
        branch_current_context,
    )
    @test isempty(branch_current_report.findings)
    @test branch_current_report.metadata[:bmopf_terminal_current_port_available] == "true"
    @test isempty(NLPDiagnostics.report_data(branch_current_report)["unavailable_reasons"])

    transformer_model = JuMP.Model()
    JuMP.@variable(transformer_model, vr_high[1:2])
    JuMP.@variable(transformer_model, vi_high[1:2])
    JuMP.@variable(transformer_model, vr_low[1:2])
    JuMP.@variable(transformer_model, vi_low[1:2])
    JuMP.@variable(transformer_model, cr_xf_from[1:2])
    JuMP.@variable(transformer_model, ci_xf_from[1:2])
    JuMP.@variable(transformer_model, cr_xf_to[1:2])
    JuMP.@variable(transformer_model, ci_xf_to[1:2])
    JuMP.@variable(transformer_model, cr_nw[1:4])
    JuMP.@variable(transformer_model, ci_nw[1:4])
    transformer_objects = Dict{BMOPFTools.OpfModelKey,Any}(
        BMOPFTools.opf_bus_voltage_key("high", "a") => vr_high[1],
        BMOPFTools.opf_bus_voltage_key("high", "b") => vr_high[2],
        BMOPFTools.opf_bus_voltage_key("high", "a"; component = :imag) => vi_high[1],
        BMOPFTools.opf_bus_voltage_key("high", "b"; component = :imag) => vi_high[2],
        BMOPFTools.opf_bus_voltage_key("low", "a") => vr_low[1],
        BMOPFTools.opf_bus_voltage_key("low", "b") => vr_low[2],
        BMOPFTools.opf_bus_voltage_key("low", "a"; component = :imag) => vi_low[1],
        BMOPFTools.opf_bus_voltage_key("low", "b"; component = :imag) => vi_low[2],
        BMOPFTools.opf_transformer_current_key("tx", :from, 1) => cr_xf_from[1],
        BMOPFTools.opf_transformer_current_key("tx", :from, 2) => cr_xf_from[2],
        BMOPFTools.opf_transformer_current_key("tx", :to, 1) => cr_xf_to[1],
        BMOPFTools.opf_transformer_current_key("tx", :to, 2) => cr_xf_to[2],
        BMOPFTools.opf_transformer_current_key("tx", :from, 1; component = :imag) => ci_xf_from[1],
        BMOPFTools.opf_transformer_current_key("tx", :from, 2; component = :imag) => ci_xf_from[2],
        BMOPFTools.opf_transformer_current_key("tx", :to, 1; component = :imag) => ci_xf_to[1],
        BMOPFTools.opf_transformer_current_key("tx", :to, 2; component = :imag) => ci_xf_to[2],
        BMOPFTools.opf_nwinding_current_key("multi", 1, 1) => cr_nw[1],
        BMOPFTools.opf_nwinding_current_key("multi", 1, 2) => cr_nw[2],
        BMOPFTools.opf_nwinding_current_key("multi", 2, 1) => cr_nw[3],
        BMOPFTools.opf_nwinding_current_key("multi", 2, 2) => cr_nw[4],
        BMOPFTools.opf_nwinding_current_key("multi", 1, 1; component = :imag) => ci_nw[1],
        BMOPFTools.opf_nwinding_current_key("multi", 1, 2; component = :imag) => ci_nw[2],
        BMOPFTools.opf_nwinding_current_key("multi", 2, 1; component = :imag) => ci_nw[3],
        BMOPFTools.opf_nwinding_current_key("multi", 2, 2; component = :imag) => ci_nw[4],
    )
    transformer_net = Dict{String,Any}(
        "bus" => Dict{String,Any}(
            "high" => Dict{String,Any}("terminal_names" => ["a", "b"]),
            "low" => Dict{String,Any}("terminal_names" => ["a", "b"]),
        ),
        "transformer" => Dict{String,Any}(
            "wye_delta" => Dict{String,Any}(
                "tx" => Dict{String,Any}(
                    "bus_from" => "high", "bus_to" => "low",
                    "terminal_map_from" => ["a", "b"],
                    "terminal_map_to" => ["b", "a"],
                    "v_nom_from" => 12_470.0, "v_nom_to" => 480.0,
                    "s_rating" => 100_000.0,
                ),
            ),
            "n_winding" => Dict{String,Any}(
                "multi" => Dict{String,Any}(
                    "windings" => [
                        Dict{String,Any}("bus" => "high", "terminal_map" => ["a", "b"], "configuration" => "WYE"),
                        Dict{String,Any}("bus" => "low", "terminal_map" => ["a", "b"], "configuration" => "DELTA"),
                    ],
                ),
            ),
        ),
    )
    transformer_context = TestBMOPFContext(
        transformer_model, transformer_net, transformer_objects, nothing,
    )
    transformer_ports = NLPDiagnostics.bmopf_terminal_port_metadata(transformer_context)
    @test count(port -> port.component_type == :transformer, transformer_ports) == 8
    transformer_connections = NLPDiagnostics.bmopf_terminal_port_connections(transformer_context)
    @test length(transformer_connections) == 8
    @test count(connection -> connection.from_component_id == "wye_delta:tx", transformer_connections) == 4
    @test count(connection -> connection.from_component_id == "n_winding:multi", transformer_connections) == 4
    transformer_assembly = NLPDiagnostics.bmopf_terminal_port_assembly(transformer_context)
    @test transformer_assembly.component_count == 4
    @test transformer_assembly.connected_component_count == 1
    permuted = only(filter(
        connection -> connection.from_component_id == "wye_delta:tx" && connection.from_port_id == "to_real",
        transformer_connections,
    ))
    @test permuted.connection_matrix == [0.0 1.0; 1.0 0.0]
    @test isempty(NLPDiagnostics.bmopf_terminal_port_report(transformer_context).findings)
    current_ports = NLPDiagnostics.bmopf_terminal_current_port_metadata(transformer_context)
    @test length(current_ports) == 8
    @test all(port.metadata["quantity"] == "current" for port in current_ports)
    @test length(NLPDiagnostics.bmopf_terminal_current_port_coordinate_maps(transformer_context)) == 8
    @test all(item.units["current"] == "A" for item in
              NLPDiagnostics.bmopf_terminal_current_port_coordinate_semantics(transformer_context))
    @test isempty(NLPDiagnostics.bmopf_terminal_current_port_report(transformer_context).findings)
    physical_modes = NLPDiagnostics.bmopf_terminal_port_nullspace_modes(transformer_context)
    @test length(physical_modes) == 4
    @test all(mode.name == :delta_common_mode for mode in physical_modes)
    @test all(length(mode.direction) == 2 for mode in physical_modes)
    physical_mode_semantics = NLPDiagnostics.bmopf_terminal_port_nullspace_mode_semantics(transformer_context)
    @test length(physical_mode_semantics) == 4
    @test all(item.category == :delta_common_mode for item in physical_mode_semantics)
    physical_mode_report = NLPDiagnostics.bmopf_terminal_port_nullspace_mode_report(transformer_context)
    @test physical_mode_report.metadata[:bmopf_terminal_port_expected_mode_count] == "4"
    @test isempty(findings(physical_mode_report, :component_port_nullspace_mode_semantics_unaligned))
    constitutive_maps = NLPDiagnostics.bmopf_terminal_constitutive_maps(transformer_context)
    @test length(constitutive_maps) == 6
    @test all(map.metadata["map_role"] == "constitutive" for map in constitutive_maps)
    @test all(size(map.matrix, 2) == sum(length, map.port_terminal_labels; init = 0) for map in constitutive_maps)
    fixed_map = only(filter(map -> map.component_id == "wye_delta:tx" && map.map_id == "ideal_winding_coupling_real", constitutive_maps))
    @test size(fixed_map.matrix) == (2, 4)
    @test fixed_map.metadata["vector_group"] == "WYE_DELTA"
    @test fixed_map.metadata["phase_shift_applied"] == "false"
    @test isempty(NLPDiagnostics.bmopf_terminal_constitutive_map_report(transformer_context).findings)
    complex_maps = NLPDiagnostics.bmopf_terminal_complex_constitutive_maps(transformer_context)
    @test length(complex_maps) == 1
    complex_map = only(complex_maps)
    @test size(complex_map.matrix) == (4, 8)
    @test complex_map.metadata["map_role"] == "constitutive_complex"
    @test complex_map.metadata["phase_shift_applied"] == "true"
    @test isempty(NLPDiagnostics.bmopf_terminal_complex_constitutive_map_report(transformer_context).findings)
    @test maximum(abs, complex_map.matrix[1:2, 5:8]) > 0.0
    @test maximum(abs, complex_map.matrix[1:2, 7:8]) == 0.0
    transformer_net["transformer"]["wye_delta"]["tx"]["phase_shift_degrees"] = 30.0
    shifted_report = NLPDiagnostics.bmopf_terminal_constitutive_map_report(transformer_context)
    @test length(findings(shifted_report, :bmopf_terminal_constitutive_map_phase_shift_unrepresented)) == 1
    @test shifted_report.metadata[:bmopf_terminal_constitutive_map_phase_shift_count] == "2"
    shifted_complex_map = only(NLPDiagnostics.bmopf_terminal_complex_constitutive_maps(transformer_context))
    @test maximum(abs, shifted_complex_map.matrix[1:2, 7:8]) > 0.0
    delete!(transformer_net["transformer"]["wye_delta"]["tx"], "phase_shift_degrees")
    passive_current_maps = NLPDiagnostics.bmopf_passive_network_current_maps(transformer_context)
    @test length(passive_current_maps) == 1
    @test passive_current_maps[1].metadata["map_role"] == "passive_network_current"
    @test size(passive_current_maps[1].matrix, 1) == size(passive_current_maps[1].matrix, 2)
    passive_map_report = NLPDiagnostics.bmopf_passive_network_current_map_report(transformer_context)
    @test isempty(passive_map_report.findings)
    @test passive_map_report.metadata[:bmopf_passive_network_current_map_available] == "true"
    @test isempty(NLPDiagnostics.report_data(passive_map_report)["unavailable_reasons"])
    pu_transformer_context = TestBMOPFContext(
        transformer_model, transformer_net, transformer_objects,
        (v_base = Dict("high" => 100.0, "low" => 10.0),
         i_base = Dict("high" => 10.0, "low" => 1.0)),
    )
    pu_passive_maps = NLPDiagnostics.bmopf_passive_network_current_maps(
        pu_transformer_context; basis = :model,
    )
    @test length(pu_passive_maps) == 1
    @test pu_passive_maps[1].metadata["units"] == "p.u._current_from_p.u._voltage"
    @test isempty(NLPDiagnostics.bmopf_passive_network_current_map_report(
        pu_transformer_context; basis = :model,
    ).findings)
    @test_throws DimensionMismatch NLPDiagnostics.PortConstitutiveMap(
        :transformer, "tx", "bad_map", ["from_real"], [["a", "b"]],
        zeros(1, 1);
        equation_labels = ["equation"],
    )
    malformed_constitutive_map = NLPDiagnostics.PortConstitutiveMap{Float64}(
        :transformer, "tx", "malformed_map", ["high"], [["a"]],
        [1.0 0.0], ["equation"], Dict{String,String}(),
    )
    malformed_constitutive_map_report =
        NLPDiagnostics._component_port_constitutive_map_findings(
            [malformed_constitutive_map],
        )
    @test length(findings(
        malformed_constitutive_map_report,
        :component_port_constitutive_map_dimension_mismatch,
    )) == 1
    malformed_constitutive_map_reason = only(filter(
        item -> item["code"] == "component_port_constitutive_map_unavailable",
        NLPDiagnostics.report_data(malformed_constitutive_map_report)[
            "unavailable_reasons"
        ],
    ))
    @test malformed_constitutive_map_reason["category"] == "input"
    @test malformed_constitutive_map_reason["stage"] ==
          "component_port_constitutive_map"
    per_unit_context = TestBMOPFContext(
        model, net, objects, (v_base = Dict("bus" => 230.0),),
    )
    per_unit_ports = NLPDiagnostics.bmopf_terminal_port_metadata(per_unit_context)
    @test all(port.metadata["physical_voltage_base_V"] == "230.0" for port in per_unit_ports)
    per_unit_semantics = NLPDiagnostics.bmopf_terminal_port_coordinate_semantics(per_unit_context)
    @test all(isnothing(item.nominal_scale) for item in per_unit_semantics)
    @test all(item.units["voltage"] == "p.u." for item in per_unit_semantics)
    @test all(occursin("230.0 V", item.description) for item in per_unit_semantics)
    @test all(length(item.terminal_semantics) == 2 for item in per_unit_semantics)
    @test all(item.terminal_semantics[1].role == :phase for item in per_unit_semantics)
    @test all(item.terminal_semantics[1].nominal_scale == 1.0 for item in per_unit_semantics)
    @test all(item.terminal_semantics[2].role == :ground_reference for item in per_unit_semantics)
    @test all(item.terminal_semantics[2].expected_value == 0.0 for item in per_unit_semantics)
    @test all(isnothing(item.terminal_semantics[2].nominal_scale) for item in per_unit_semantics)
    coordinate_point = NLPDiagnostics.EvaluationPoint(
        JuMP.index.([vr_a, vr_n, vi_a, vi_n]), [1.0, 0.0, 0.0, 0.0],
    )
    scale_report = NLPDiagnostics.bmopf_terminal_port_coordinate_scale_report(
        per_unit_context, coordinate_point,
    )
    @test isempty(scale_report.findings)
    @test scale_report.metadata[:bmopf_terminal_port_coordinate_scale_basis] ==
          "per-unit model coordinates (nominal coordinate one)"
    bad_ground_point = NLPDiagnostics.EvaluationPoint(
        JuMP.index.([vr_a, vr_n, vi_a, vi_n]), [1.0, 1.0e-4, 0.0, 0.0],
    )
    bad_ground_report = NLPDiagnostics.bmopf_terminal_port_coordinate_scale_report(
        per_unit_context, bad_ground_point,
    )
    @test length(findings(
        bad_ground_report, :component_port_expected_coordinate_value_mismatch,
    )) == 1
    floating_neutral_net = deepcopy(net)
    empty!(floating_neutral_net["bus"]["bus"]["perfectly_grounded_terminals"])
    floating_neutral_context = TestBMOPFContext(
        model, floating_neutral_net, objects, (v_base = Dict("bus" => 230.0),),
    )
    floating_neutral_semantics =
        NLPDiagnostics.bmopf_terminal_port_coordinate_semantics(
            floating_neutral_context,
        )
    @test all(item.terminal_semantics[2].role == :neutral
              for item in floating_neutral_semantics)
    @test all(isnothing(item.terminal_semantics[2].expected_value)
              for item in floating_neutral_semantics)
    floating_neutral_point = NLPDiagnostics.EvaluationPoint(
        JuMP.index.([vr_a, vr_n, vi_a, vi_n]), [1.0, 1.0e-12, 0.0, -0.2],
    )
    floating_neutral_report =
        NLPDiagnostics.bmopf_terminal_port_coordinate_scale_report(
            floating_neutral_context, floating_neutral_point,
        )
    @test isempty(findings(
        floating_neutral_report, :component_port_nominal_scale_mismatch,
    ))
    @test isempty(findings(
        floating_neutral_report,
        :component_port_expected_coordinate_value_mismatch,
    ))
    differentiability_report = NLPDiagnostics.bmopf_opf_differentiability_report(context)
    @test differentiability_report.metadata[:bmopf_opf_differentiability_available] == "false"
    @test differentiability_report.metadata[:bmopf_opf_differentiability_reason] ==
          "BMOPFTools' JuMP/IPOPT OPF extension is not loaded for this context"
    differentiability_data = NLPDiagnostics.report_data(differentiability_report)
    @test length(differentiability_data["unavailable_reasons"]) == 1
    @test differentiability_data["unavailable_reasons"][1]["code"] ==
          "bmopf_opf_differentiability_unavailable"
    @test differentiability_data["unavailable_reasons"][1]["category"] == "dependency"
    @test differentiability_data["unavailable_reasons"][1]["stage"] ==
          "bmopf_opf_differentiability"
    @test length(findings(differentiability_report, :bmopf_opf_differentiability_unavailable)) == 1
    registry_report = NLPDiagnostics.bmopf_opf_registry_report(context)
    @test registry_report.metadata[:bmopf_opf_registry_direct_variable_count] == "4"
    @test registry_report.metadata[:bmopf_opf_registry_unregistered_model_variable_count] == "4"
    @test occursin("vr_load_a=1", registry_report.metadata[:bmopf_opf_registry_unregistered_name_group_counts])
    @test length(findings(registry_report, :bmopf_opf_registry_unregistered_model_variables)) == 1
    @test length(findings(registry_report, :bmopf_opf_registry_unregistered_name_group)) == 4
    components = NLPDiagnostics.bmopf_component_metadata(context)
    @test length(components) == 2
    @test sort!([component.component_id for component in components]) == ["vi", "vr"]
    @test length(NLPDiagnostics.bmopf_component_coordinate_semantics(context)) == 2
    component_report = NLPDiagnostics.bmopf_component_report(context)
    @test isempty(component_report.findings)
    @test component_report.metadata[:bmopf_component_expected_rank_declared_count] == "0"
    @test component_report.metadata[:bmopf_component_expected_rank_unavailable_count] == "2"
    @test component_report.metadata[:bmopf_component_expected_rank_coverage] == "0.0"
    rank_capability_report = NLPDiagnostics.bmopf_component_rank_capability_report(context)
    @test rank_capability_report.metadata[:stage] == "bmopf_component_rank_capability"
    @test rank_capability_report.metadata[:bmopf_component_expected_rank_available] == "false"
    @test rank_capability_report.metadata[:bmopf_component_expected_rank_reason] ==
          "one or more BMOPFTools component metadata entries omit expected_rank"
    rank_capability_data = NLPDiagnostics.report_data(rank_capability_report)
    @test length(rank_capability_data["unavailable_reasons"]) == 1
    @test rank_capability_data["unavailable_reasons"][1]["code"] ==
          "bmopf_component_expected_rank_unavailable"
    @test rank_capability_data["unavailable_reasons"][1]["category"] == "capability"
    @test rank_capability_data["unavailable_reasons"][1]["stage"] ==
          "bmopf_component_rank_capability"
    @test length(findings(rank_capability_report, :bmopf_component_expected_rank_unavailable)) == 1
    source_schema_report = NLPDiagnostics.bmopf_source_schema_report(context)
    @test source_schema_report.metadata[:stage] == "bmopf_source_schema"
    @test source_schema_report.metadata[:bmopf_source_schema_warning_count] == "0"
    @test isempty(source_schema_report.findings)
    source_metadata_net = deepcopy(net)
    source_metadata_net["_meta"] = Dict{String,Any}(
        "powerio_source" => "synthetic.dss",
        "powerio_source_metadata" => Dict{String,Any}(
            "fields" => ["kv", "model", "mystery"],
        ),
        "powerio_source_mapped_fields" => ["kv"],
        "powerio_source_mapping" => Dict{String,Any}(
            "by_field" => Dict{String,Any}(
                "kv" => Dict{String,Any}(
                    "status" => "mapped",
                    "target" => "load.v_nom",
                ),
            ),
        ),
        "powerio_source_semantics" => Dict{String,Any}(
            "load_voltage_thresholds" => [Dict{String,Any}(
                "scope" => "load:d12",
                "vminpu" => 0.5,
                "vmaxpu" => 1.1,
                "status" => "observed_ordered",
            )],
            "voltage_source_models" => Any[],
        ),
        "powerio_warnings" => [
            "linecode 4w: `units` has no place in BMOPF schema; dropped",
            "load d12: `kv` is not represented in BMOPF schema; dropped",
            "device d: `model` is not represented in BMOPF schema; dropped",
            "device d: `mystery` is not represented in BMOPF schema; dropped",
        ],
    )
    source_metadata_report = NLPDiagnostics.bmopf_source_schema_report(
        TestBMOPFContext(model, source_metadata_net, objects, nothing),
    )
    @test source_metadata_report.metadata[:bmopf_source_schema_warning_count] == "4"
    @test source_metadata_report.metadata[:bmopf_source_schema_physical_blocking_count] == "2"
    @test source_metadata_report.metadata[:bmopf_source_schema_resolved_warning_count] == "1"
    @test source_metadata_report.metadata[:bmopf_source_schema_unresolved_warning_count] == "3"
    @test source_metadata_report.metadata[:bmopf_source_schema_representational_count] == "1"
    @test source_metadata_report.metadata[:bmopf_source_schema_device_semantics_count] == "1"
    @test source_metadata_report.metadata[:bmopf_source_schema_unclassified_count] == "1"
    @test source_metadata_report.metadata[:bmopf_source_schema_warning_field_counts] ==
          "kv=1,model=1,mystery=1,units=1"
    @test source_metadata_report.metadata[:bmopf_source_schema_warning_impact_counts] ==
          "device_semantics=1,physical_or_operating_point=1,representational=1,unknown=1"
    @test source_metadata_report.metadata[:bmopf_source_schema_provenance_available] == "true"
    @test source_metadata_report.metadata[:bmopf_source_schema_provenance_field_count] == "3"
    @test source_metadata_report.metadata[:bmopf_source_schema_provenance_warning_field_count] == "3"
    @test source_metadata_report.metadata[:bmopf_source_schema_mapped_fields] == "kv"
    @test source_metadata_report.metadata[:bmopf_source_schema_mapped_warning_field_count] == "1"
    @test source_metadata_report.metadata[:bmopf_source_schema_mapping_targets] == "kv=>load.v_nom"
    @test source_metadata_report.metadata[:bmopf_source_schema_restoration_ready] == "false"
    @test isempty(findings(source_metadata_report, :bmopf_source_schema_physical_metadata_loss))
    @test length(findings(source_metadata_report, :bmopf_source_schema_device_semantics_loss)) == 1
    @test length(findings(source_metadata_report, :bmopf_source_schema_representational_loss)) == 1
    @test length(findings(source_metadata_report, :bmopf_source_schema_unclassified_loss)) == 1
    mapped_source_metadata_report = NLPDiagnostics.bmopf_source_schema_report(
        TestBMOPFContext(model, source_metadata_net, objects, nothing);
        mapped_fields = ["kv", "model", "mystery"],
    )
    @test mapped_source_metadata_report.metadata[:bmopf_source_schema_mapped_field_count] == "3"
    @test mapped_source_metadata_report.metadata[:bmopf_source_schema_mapped_warning_field_count] == "3"
    @test mapped_source_metadata_report.metadata[:bmopf_source_schema_restoration_ready] == "true"
    @test mapped_source_metadata_report.metadata[:bmopf_source_schema_resolved_warning_count] == "3"
    @test mapped_source_metadata_report.metadata[:bmopf_source_schema_unresolved_warning_count] == "1"
    @test isempty(findings(mapped_source_metadata_report,
        :bmopf_source_schema_device_semantics_loss))
    @test isempty(findings(mapped_source_metadata_report,
        :bmopf_source_schema_unclassified_loss))
    source_metadata_net["load"] = Dict{String,Any}(
        "d12" => Dict{String,Any}(
            "bus" => "load",
            "terminal_map" => ["a", "n"],
            "v_nom" => [240.0],
        ),
    )
    original_variable_count = JuMP.num_variables(model)
    auxiliary = NLPDiagnostics.bmopf_source_behavior_auxiliary_model(
        TestBMOPFContext(model, source_metadata_net, objects, nothing),
    )
    @test auxiliary["status"] == "materialized"
    @test auxiliary["constraint_pair_count"] == 1
    @test auxiliary["variable_count"] == 4
    @test auxiliary["original_model_mutated"] == false
    @test auxiliary["original_model_variable_count"] == original_variable_count
    @test only(auxiliary["records"])["materialization"] == "auxiliary_model_only"
    @test JuMP.num_variables(auxiliary["model"]) == 4
    source_contract = Dict{String,Any}(
        "contract_version" => "test/source-behavior/v1",
        "auxiliary_constraint_candidates" => [Dict{String,Any}(
            "scope" => "load:d12",
            "status" => "candidate",
            "bus" => "load",
            "terminal_map" => ["a", "n"],
            "nominal_voltage" => [240.0],
            "vminpu" => 0.0,
            "vmaxpu" => 2.0,
        )],
    )
    pu_behavior_context = TestBMOPFContext(
        model, source_metadata_net, deepcopy(objects),
        (v_base = Dict("load" => 240.0),),
    )
    pu_auxiliary = NLPDiagnostics.bmopf_source_behavior_auxiliary_model(
        pu_behavior_context; source_contract,
    )
    @test only(pu_auxiliary["records"])["nominal_voltage_V"] == 240.0
    @test only(pu_auxiliary["records"])["nominal_voltage_model"] == 1.0
    @test only(pu_auxiliary["records"])["model_coordinate_units"] == "per-unit"
    behavior_objects = deepcopy(objects)
    behavior_objects[BMOPFTools.opf_bus_voltage_key("load", "a")] = vr_load_a
    behavior_objects[BMOPFTools.opf_bus_voltage_key("load", "n")] = vr_load_n
    behavior_objects[BMOPFTools.opf_bus_voltage_key("load", "a"; component = :imag)] = vi_load_a
    behavior_objects[BMOPFTools.opf_bus_voltage_key("load", "n"; component = :imag)] = vi_load_n
    behavior_context = TestBMOPFContext(model, source_metadata_net, behavior_objects, nothing)
    behavior_point = NLPDiagnostics.EvaluationPoint(
        JuMP.index.([vr_load_a, vr_load_n, vi_load_a, vi_load_n]),
        [0.0, 0.0, 0.0, 0.0],
        label = "synthetic-source-behavior-point",
    )
    behavior_report = NLPDiagnostics.bmopf_source_behavior_report(
        behavior_context, behavior_point,
    )
    @test behavior_report.report.metadata[:bmopf_source_behavior_checked_count] == "1"
    @test behavior_report.report.metadata[:bmopf_source_behavior_below_vminpu_count] == "1"
    @test length(findings(behavior_report.report, :bmopf_source_behavior_threshold_violation)) == 1
    behavior_comparison = NLPDiagnostics.bmopf_source_behavior_solver_comparison(
        behavior_context, behavior_point;
        solver_name = "Ipopt",
        termination_status = "Infeasible_Problem_Detected",
        feasible = false,
    )
    @test behavior_comparison.comparison["classification"] ==
          "solver_failure_aligned_with_source_domain_violation"
    @test length(findings(behavior_comparison.report,
        :bmopf_source_behavior_solver_failure_aligned)) == 1
    successful_behavior_comparison =
        NLPDiagnostics.bmopf_source_behavior_solver_comparison(
            behavior_context, behavior_point;
            solver_name = "Ipopt",
            termination_status = "LOCALLY_SOLVED",
            feasible = true,
        )
    @test successful_behavior_comparison.comparison["classification"] ==
          "solver_success_outside_source_domain"
    @test NLPDiagnostics.bmopf_source_behavior_auxiliary_solve(auxiliary)["status"] ==
          "unavailable"
    if isdefined(Main, :Ipopt)
        solved_auxiliary = NLPDiagnostics.bmopf_source_behavior_auxiliary_solve(
            auxiliary; optimizer = Ipopt.Optimizer,
            optimizer_attributes = Dict("max_iter" => 5),
        )
        @test solved_auxiliary["status"] in ("solved", "unsolved")
        @test JuMP.num_variables(model) == original_variable_count
    end
    @test isnothing(NLPDiagnostics.bmopf_initialization_point(context))
    @test_throws ArgumentError NLPDiagnostics.bmopf_set_start_values!(context)
    @test_throws UndefKeywordError NLPDiagnostics.bmopf_start_completion_point(context)
    completed_starts = NLPDiagnostics.bmopf_start_completion_point(
        context;
        missing_value = 0.0,
    )
    @test completed_starts.label == "bmopf-partial-starts-completed"
    @test completed_starts.values == zeros(8)
    @test completed_starts.provenance.kind ==
          NLPDiagnostics.CompletedInitializationPoint
    @test completed_starts.provenance.metadata["filled_coordinate_count"] == "8"
    saved_result = Dict{String,Any}(
        "bus" => Dict{String,Any}(
            "bus" => Dict{String,Any}(
                "a" => Dict{String,Any}("vr" => 230.0, "vi" => 0.0),
                "n" => Dict{String,Any}("vr" => 0.0, "vi" => 0.0),
            ),
        ),
    )
    saved_point = NLPDiagnostics.bmopf_result_voltage_point(
        per_unit_context, saved_result;
        fallback_value = -7.0,
    )
    @test saved_point.point.label == "bmopf-result-voltage-partial"
    @test saved_point.mapped_coordinate_count == 4
    @test saved_point.mapped_voltage_coordinate_count == 4 # compatibility alias
    @test saved_point.fallback_coordinate_count == 4
    @test saved_point.registered_coordinate_count == 4
    @test saved_point.unregistered_model_coordinate_count == 4
    @test saved_point.unmapped_registered_coordinate_count == 0
    @test saved_point.mapped_registered_coordinate_fraction == 1.0
    @test saved_point.mapped_coordinate_counts_by_family == Dict(
        "vr" => 2, "vi" => 2,
    )
    @test isempty(saved_point.unresolved_saved_coordinate_counts_by_family)
    @test saved_point.point.values == [1.0, 0.0, 0.0, 0.0, -7.0, -7.0, -7.0, -7.0]
    pu_result = Dict{String,Any}(
        "bus" => Dict{String,Any}(
            "bus" => Dict{String,Any}(
                "a" => Dict{String,Any}("vr" => 1.0, "vi" => 0.0),
                "n" => Dict{String,Any}("vr" => 0.0, "vi" => 0.0),
            ),
        ),
    )
    pu_point = NLPDiagnostics.bmopf_result_voltage_point(
        per_unit_context, pu_result; result_units = :pu, fallback_value = -7.0,
    )
    @test pu_point.point.values == saved_point.point.values
    @test pu_point.result_units == :pu
    mixed_policy_point = NLPDiagnostics.bmopf_result_voltage_point(
        per_unit_context, pu_result;
        result_units = :si,
        field_units = Dict(:bus_voltage => :pu),
        fallback_value = -7.0,
    )
    @test mixed_policy_point.point.values == pu_point.point.values
    @test mixed_policy_point.field_units[:bus_voltage] == :pu
    @test mixed_policy_point.field_units[:line_current] == :si
    @test_throws ArgumentError NLPDiagnostics.bmopf_result_voltage_point(
        per_unit_context, pu_result; field_units = Dict(:not_a_family => :pu),
    )
    saved_mapping_report = NLPDiagnostics.bmopf_result_mapping_report(saved_point)
    @test saved_mapping_report.metadata[:stage] == "bmopf_saved_result_mapping"
    @test saved_mapping_report.metadata[:bmopf_saved_result_fallback_coordinate_count] == "4"
    @test occursin("bus_voltage=si", saved_mapping_report.metadata[:bmopf_saved_result_field_units])
    @test length(findings(saved_mapping_report, :bmopf_saved_result_mapping_coverage)) == 1
    @test length(findings(saved_mapping_report, :bmopf_saved_result_unregistered_model_coordinates)) == 1
    @test only(findings(saved_mapping_report, :bmopf_saved_result_mapping_coverage)).domain ==
          NLPDiagnostics.RepresentationalIssue
    projected_mapping = merge(saved_point, (
        projected_saved_coordinate_counts_by_family = Dict(
            "cr_to" => 2, "ci_to" => 2,
        ),
        saved_result_projection_contracts = Dict(
            "cr_to" => "derived to-side export",
            "ci_to" => "derived to-side export",
        ),
    ))
    projected_mapping_report =
        NLPDiagnostics.bmopf_result_mapping_report(projected_mapping)
    @test projected_mapping_report.metadata[
        :bmopf_saved_result_projected_record_count
    ] == "4"
    @test projected_mapping_report.metadata[
        :bmopf_saved_result_projected_families
    ] == "ci_to,cr_to"
    @test length(findings(
        projected_mapping_report,
        :bmopf_saved_result_projection_contract_applied,
    )) == 1
    @test isempty(findings(
        projected_mapping_report, :bmopf_saved_result_unresolved_records,
    ))
    @test_throws ArgumentError NLPDiagnostics.bmopf_result_mapping_report((;))
    saved_case = NLPDiagnostics.bmopf_saved_result_profile_case(
        "saved-result-test", per_unit_context, saved_result;
        fallback_value = -7.0,
    )
    @test saved_case.case.name == "saved-result-test"
    @test saved_case.case.initialization == "saved_result"
    @test saved_case.mapping.point.values == saved_point.point.values
    @test saved_case.mapping_report.metadata[:stage] == "bmopf_saved_result_mapping"
    @test saved_case.mapping_report.metadata[
        :bmopf_saved_result_unit_fingerprint_count] == "1"
    @test saved_case.mapping_report.metadata[
        :bmopf_saved_result_unit_fingerprint_zero_magnitude_count] == "1"
    @test isempty(findings(saved_case.mapping_report, :bmopf_saved_result_unit_scale_suspicious))
    mixed_saved_case = NLPDiagnostics.bmopf_saved_result_profile_case(
        "mixed-unit-result-test", per_unit_context, pu_result;
        result_units = :si,
        field_units = Dict(:bus_voltage => :pu),
        fallback_value = -7.0,
    )
    @test mixed_saved_case.case.metadata["saved_result_field_units"] isa AbstractString
    @test occursin("bus_voltage=pu", mixed_saved_case.mapping_report.metadata[:bmopf_saved_result_field_units])
    mislabelled_pu_case = NLPDiagnostics.bmopf_saved_result_profile_case(
        "mislabelled-pu-result-test", per_unit_context, saved_result;
        result_units = :pu,
    )
    @test length(findings(mislabelled_pu_case.mapping_report,
                          :bmopf_saved_result_unit_scale_suspicious)) == 1
    mislabelled_case = NLPDiagnostics.bmopf_saved_result_profile_case(
        "mislabelled-result-test", per_unit_context, saved_result;
        result_units = :model,
    )
    @test length(findings(mislabelled_case.mapping_report,
                          :bmopf_saved_result_unit_scale_suspicious)) == 1
    saved_profile = NLPDiagnostics.bmopf_profile_saved_result(
        per_unit_context, "saved-result-profile-test", saved_result;
        case_kwargs = (fallback_value = -7.0,),
        profile_kwargs = (include_initialization = false,),
    )
    @test saved_profile.profile.context_report.metadata[:bmopf_saved_result_profile] == "true"
    @test length(findings(saved_profile.profile.context_report,
                          :bmopf_saved_result_mapping_coverage)) == 1
    field_catalog = NLPDiagnostics.bmopf_result_field_catalog()
    @test field_catalog["catalog_version"] == "bmopf-result-field-catalog-v1"
    @test field_catalog["families"]["bus_voltage"]["base_kind"] == "voltage"
    @test field_catalog["families"]["generator_current"]["physical_unit"] == "A"
    @test field_catalog["families"]["generator_power"]["base_kind"] == "power"
    @test field_catalog["families"]["ibr_power"]["physical_unit"] == "W"
    feasibility_attribution = NLPDiagnostics.bmopf_constraint_feasibility_field_attribution(
        per_unit_context, saved_profile.profile; mapping = saved_profile.mapping,
    )
    @test feasibility_attribution.metadata[:stage] ==
          "bmopf_constraint_feasibility_field_attribution"
    @test haskey(feasibility_attribution.metadata,
                 :bmopf_feasibility_attribution_violation_count)
    @test haskey(feasibility_attribution.metadata,
                 :bmopf_feasibility_attribution_field_instance_counts)
    @test haskey(feasibility_attribution.metadata,
                 :bmopf_feasibility_attribution_device_counts)
    @test haskey(feasibility_attribution.metadata,
                 :bmopf_feasibility_attribution_power_base)
    @test haskey(feasibility_attribution.metadata,
                 :bmopf_feasibility_attribution_constraint_family_row_counts)
    @test haskey(feasibility_attribution.metadata,
                 :bmopf_feasibility_attribution_unregistered_constraint_row_count)
    @test haskey(feasibility_attribution.metadata,
                 :bmopf_feasibility_attribution_model_constraint_row_count)
    @test haskey(feasibility_attribution.metadata,
                 :bmopf_feasibility_attribution_model_constraint_family_row_counts)
    @test haskey(feasibility_attribution.metadata,
                 :bmopf_feasibility_attribution_component_candidate_counts)
    semantic_rows = NLPDiagnostics.bmopf_constraint_semantic_row_map(
        per_unit_context, saved_profile.profile.profile.evaluation,
    )
    @test length(semantic_rows) == length(saved_profile.profile.profile.evaluation.constraint_sources)
    @test all(haskey(value, "constraint_family") for value in values(semantic_rows))
    registered_constraint_signatures = Dict{Tuple{Int,String,String},String}()
    for key in BMOPFTools.opf_object_keys(per_unit_context; kind = :constraint)
        object = try
            BMOPFTools.opf_object(per_unit_context, key)
        catch
            nothing
        end
        object isa JuMP.ConstraintRef || continue
        index = JuMP.index(object)
        index isa MOI.ConstraintIndex || continue
        function_type, set_type = string.(typeof(index).parameters)
        registered_constraint_signatures[(index.value, function_type, set_type)] =
            string(key.family)
    end
    matched_registered_signatures = Set{Tuple{Int,String,String}}()
    for (row, source) in enumerate(
        saved_profile.profile.profile.evaluation.constraint_sources,
    )
        isnothing(source.function_type) && continue
        isnothing(source.set_type) && continue
        signature = (source.index, source.function_type, source.set_type)
        haskey(registered_constraint_signatures, signature) || continue
        push!(matched_registered_signatures, signature)
        @test semantic_rows[string(row)]["constraint_family"] ==
              registered_constraint_signatures[signature]
    end
    @test matched_registered_signatures == Set(keys(registered_constraint_signatures))
    @test all(
        haskey(value, "constraint_function_type") &&
        haskey(value, "constraint_set_type") &&
        haskey(value, "constraint_name") for value in values(semantic_rows)
    )
    unregistered_semantic_rows = [
        value for value in values(semantic_rows)
        if get(value, "registered", false) != true
    ]
    @test length(unregistered_semantic_rows) == 1
    @test only(unregistered_semantic_rows)["constraint_family"] ==
          "unregistered_constraint"
    @test only(unregistered_semantic_rows)["constraint_name"] == ""
    registry_coverage = NLPDiagnostics.bmopf_constraint_registry_coverage_report(
        per_unit_context, saved_profile.profile.profile.evaluation,
    )
    @test registry_coverage.metadata[:stage] ==
          "bmopf_constraint_registry_coverage"
    @test registry_coverage.metadata[
        :bmopf_constraint_registry_unregistered_row_count] == "1"
    @test only(findings(registry_coverage,
                        :bmopf_constraint_registry_coverage)).severity ==
          NLPDiagnostics.SeverityWarning
    registered_objects = copy(objects)
    registered_objects[BMOPFTools.OpfModelKey(
        :constraint, :test_voltage_reference, ("bus", "a"))] = test_constraint
    registered_context = TestBMOPFContext(
        model, net, registered_objects, (v_base = Dict("bus" => 230.0),),
    )
    complete_registry_coverage =
        NLPDiagnostics.bmopf_constraint_registry_coverage_report(
            registered_context, saved_profile.profile.profile.evaluation,
        )
    @test complete_registry_coverage.metadata[
        :bmopf_constraint_registry_unregistered_row_count] == "0"
    @test only(findings(complete_registry_coverage,
                        :bmopf_constraint_registry_coverage)).severity ==
          NLPDiagnostics.SeverityInfo
    complete_registry_data = NLPDiagnostics.report_data(
        complete_registry_coverage,
    )
    @test complete_registry_data["metadata"][
        "bmopf_constraint_registry_unregistered_row_count"] == "0"
    @test only(complete_registry_data["findings"])["code"] ==
          "bmopf_constraint_registry_coverage"
    @test only(complete_registry_data["findings"])["confidence"] == "certain"
    @test only(complete_registry_data["findings"])["basis"] ==
          "structural_proof"
    semantic_perturbation_report =
        NLPDiagnostics.bmopf_analyze_jacobian_row_family_perturbations(
            per_unit_context, saved_profile.profile.profile.evaluation;
            max_dense_entries = 1,
        )
    @test semantic_perturbation_report.metadata[:stage] ==
          "jacobian_row_family_perturbations"
    @test semantic_perturbation_report.metadata[:bmopf_semantic_row_count] ==
          string(length(semantic_rows))
    semantic_scale_attribution =
        NLPDiagnostics.bmopf_jacobian_row_family_scale_attribution(
            per_unit_context, saved_profile.profile.profile.evaluation,
        )
    @test semantic_scale_attribution["row_count"] == length(semantic_rows)
    @test semantic_scale_attribution["family_count"] == length(unique(
        value["constraint_family"] for value in values(semantic_rows)
    ))
    @test semantic_scale_attribution["label_source"] ==
          "BMOPFTools public constraint registry"
    @test semantic_scale_attribution["unclassified_family_count"] == 0
    @test all(
        haskey(data, "component_family") for
        data in values(semantic_scale_attribution["families"])
    )
    if isdefined(BMOPFTools, :opf_ibr_voltage_magnitude_key)
        magnitude_model = JuMP.Model()
        JuMP.@variable(magnitude_model, m_vr_a)
        JuMP.@variable(magnitude_model, m_vr_n)
        JuMP.@variable(magnitude_model, m_vi_a)
        JuMP.@variable(magnitude_model, m_vi_n)
        JuMP.@variable(magnitude_model, u_pg)
        JuMP.@variable(magnitude_model, u_diff)
        magnitude_objects = Dict{BMOPFTools.OpfModelKey,Any}(
            BMOPFTools.opf_bus_voltage_key("bus", "a") => m_vr_a,
            BMOPFTools.opf_bus_voltage_key("bus", "n") => m_vr_n,
            BMOPFTools.opf_bus_voltage_key("bus", "a"; component = :imag) => m_vi_a,
            BMOPFTools.opf_bus_voltage_key("bus", "n"; component = :imag) => m_vi_n,
        )
        magnitude_objects[BMOPFTools.opf_ibr_voltage_magnitude_key(
            "ibr", 1; reference = :single_pg, controller = :single,
        )] = u_pg
        magnitude_objects[BMOPFTools.opf_ibr_voltage_magnitude_key(
            "ibr", 1; reference = :single_diff, controller = :single,
        )] = u_diff
        magnitude_net = deepcopy(net)
        magnitude_net["ibr"] = Dict{String,Any}(
            "ibr" => Dict{String,Any}(
                "bus" => "bus", "topology" => "SINGLE_PHASE",
                "terminal_map" => ["a", "n"],
            ),
        )
        magnitude_context = TestBMOPFContext(
            magnitude_model, magnitude_net, magnitude_objects,
            (v_base = Dict("bus" => 230.0),),
        )
        magnitude_point = NLPDiagnostics.bmopf_result_voltage_point(
            magnitude_context, saved_result; fallback_value = -7.0,
        )
        @test magnitude_point.mapped_coordinate_counts_by_family["u_ibr"] == 2
        @test magnitude_point.point.values[end-1:end] == [1.0, 1.0]
    end
    coordinate_probe = NLPDiagnostics.bmopf_coordinate_probe_point(context)
    @test coordinate_probe.label == "bmopf-zero-coordinate-probe"
    @test coordinate_probe.values == zeros(8)
    @test_throws ArgumentError NLPDiagnostics.bmopf_coordinate_probe_point(context; value = Inf)
    initialization_report = NLPDiagnostics.bmopf_analyze_initialization(context)
    @test initialization_report.metadata[:bmopf_terminal_coordinate_scales_at_initialization] == "false"
    @test initialization_report.metadata[:bmopf_floating_neutral_candidate_modes_included] == "false"
    for (variable, value) in zip(
        (vr_a, vr_n, vi_a, vi_n, vr_load_a, vr_load_n, vi_load_a, vi_load_n),
        (1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0),
    )
        JuMP.set_start_value(variable, value)
    end
    @test !isnothing(NLPDiagnostics.bmopf_initialization_point(context))
    complete_initialization_report = NLPDiagnostics.bmopf_analyze_initialization(context)
    @test complete_initialization_report.metadata[
        :bmopf_terminal_coordinate_scales_at_initialization
    ] == "true"
    numerical_point = NLPDiagnostics.EvaluationPoint(
        MOI.get(JuMP.backend(model), MOI.ListOfVariableIndices()), zeros(8);
        label = "bmopf-staged-test",
    )
    benchmark_case = NLPDiagnostics.ProfileCase(
        "bmopf-staged-test", numerical_point;
        task = "adapter regression", formulation = "BMOPF IVR", scale = "SI",
    )
    benchmark_result = NLPDiagnostics.bmopf_profile_case(
        context, benchmark_case; include_initialization = false,
    )
    @test benchmark_result isa NLPDiagnostics.BMOPFProfileResult
    @test benchmark_result.context_report.metadata[:bmopf_opf_context] ==
          "BMOPFTools staged OPF context"
    @test benchmark_result.context_report.metadata[
        :bmopf_opf_differentiability_available
    ] == "false"
    @test benchmark_result.context_report.metadata[
        :bmopf_component_rank_capability_checked
    ] == "true"
    @test benchmark_result.context_report.metadata[
        :bmopf_component_expected_rank_declared_count
    ] == "0"
    @test benchmark_result.context_report.metadata[
        :bmopf_component_expected_rank_unavailable_count
    ] == "2"
    @test benchmark_result.context_report.metadata[
        :bmopf_component_rank_capability_finding_count
    ] == "1"
    benchmark_data = NLPDiagnostics.profile_result_data(benchmark_result)
    @test haskey(benchmark_data, "profile")
    @test haskey(benchmark_data, "bmopf_context_report")
    @test haskey(benchmark_data["profile"]["case"], "point_trust")
    @test benchmark_data["profile"]["case"]["point_trust"]["metadata"]["selected_count"] == "0"
    capability_data = benchmark_data["bmopf_component_rank_capability"]
    @test capability_data["checked"] == true
    @test capability_data["component_count"] == 2
    @test capability_data["expected_rank_declared_count"] == 0
    @test capability_data["expected_rank_unavailable_count"] == 2
    @test capability_data["expected_rank_coverage"] == 0.0
    @test capability_data["finding_count"] == 1
    degeneracy_report = NLPDiagnostics.bmopf_analyze_degeneracy(context, numerical_point)
    @test degeneracy_report.metadata[:bmopf_floating_neutral_candidate_modes_included] == "false"
    active_set_report = NLPDiagnostics.bmopf_analyze_active_set(context, numerical_point)
    @test active_set_report.metadata[:bmopf_floating_neutral_candidate_modes_applied] == "0"
    persistence_report = NLPDiagnostics.bmopf_analyze_jacobian_rank_persistence(
        context, [numerical_point, numerical_point],
    )
    @test persistence_report.metadata[:bmopf_floating_neutral_candidate_modes_included] == "false"
    sparse_qr_persistence_report =
        NLPDiagnostics.bmopf_analyze_sparse_qr_nullspace_persistence(
            context, [numerical_point, numerical_point],
        )
    @test sparse_qr_persistence_report.metadata[:stage] ==
        "sparse_qr_nullspace_persistence"
    component_persistence_report = NLPDiagnostics.bmopf_analyze_component_rank_persistence(
        context, [numerical_point, numerical_point],
    )
    @test component_persistence_report.metadata[:bmopf_floating_neutral_candidate_modes_applied] == "0"
    report = NLPDiagnostics.bmopf_analyze_opf(context)
    @test report.metadata[:bmopf_opf_context] == "BMOPFTools staged OPF context"
    @test report.metadata[:bmopf_opf_lifecycle] == "kcl_finalized"
    @test occursin("bmopf_terminal_ports", report.metadata[:stages])
    @test occursin("bmopf_terminal_complex_constitutive_maps", report.metadata[:stages])

    floating_net = Dict{String,Any}(
        "bus" => Dict{String,Any}(
            "bus" => Dict{String,Any}("terminal_names" => ["a", "n"]),
            "load" => Dict{String,Any}("terminal_names" => ["a", "n"]),
        ),
        "line" => Dict{String,Any}(
            "line" => Dict{String,Any}(
                "bus_from" => "bus", "bus_to" => "load",
                "terminal_map_from" => ["a", "n"],
                "terminal_map_to" => ["a", "n"],
            ),
        ),
        "load" => Dict{String,Any}(
            "load" => Dict{String,Any}(
                "bus" => "load", "terminal_map" => ["a", "n"],
                "configuration" => "WYE",
            ),
        ),
    )
    floating_objects = copy(objects)
    merge!(floating_objects, Dict{BMOPFTools.OpfModelKey,Any}(
        BMOPFTools.opf_bus_voltage_key("load", "a") => vr_load_a,
        BMOPFTools.opf_bus_voltage_key("load", "n") => vr_load_n,
        BMOPFTools.opf_bus_voltage_key("load", "a"; component = :imag) => vi_load_a,
        BMOPFTools.opf_bus_voltage_key("load", "n"; component = :imag) => vi_load_n,
    ))
    floating_context = TestBMOPFContext(model, floating_net, floating_objects, nothing)
    candidate_modes = NLPDiagnostics.bmopf_floating_neutral_candidate_modes(floating_context)
    @test length(candidate_modes) == 2
    @test all(length(mode.variables) == 4 for mode in candidate_modes)
    candidate_report = NLPDiagnostics.bmopf_floating_neutral_candidate_report(floating_context)
    @test length(findings(candidate_report, :bmopf_floating_neutral_candidate_mode)) == 1
    @test isempty(NLPDiagnostics.bmopf_opf_lifecycle_report(floating_context).findings)
    floating_analysis = NLPDiagnostics.bmopf_analyze_opf(
        floating_context; include_floating_neutral_candidates = true,
    )
    @test floating_analysis.metadata[:bmopf_floating_neutral_candidates_enabled] == "true"
    @test floating_analysis.metadata[:bmopf_floating_neutral_candidate_modes_applied] == "2"
end
end

function evidence_details(finding)
    return Dict(finding.evidence[1].details)
end

@testset "profiling corpus input validation" begin
    point = NLPDiagnostics.EvaluationPoint(MOI.VariableIndex[], Float64[])
    first_case = NLPDiagnostics.ProfileCase("first", point)
    @test_throws ArgumentError NLPDiagnostics.profile_cases_repeated(
        MOI.ModelLike[],
        [first_case],
    )
    @test isempty(NLPDiagnostics.profile_cases_repeated(MOI.ModelLike[], NLPDiagnostics.ProfileCase[]))
    stability_models, stability_cases = NLPDiagnostics.synthetic_stability_profile_corpus()
    @test length(stability_models) == length(stability_cases) == 5
    @test [case.name for case in stability_cases] == [
        "stability_log1mexp_composite",
        "stability_logcosh_composite",
        "stability_complementary_logistic",
        "stability_logsumexp_composite",
        "stability_logdiffexp_composite",
    ]
    stability_aggregates = NLPDiagnostics.profile_synthetic_stability_corpus(
        repetitions = 1, warmup = false,
    )
    @test Set(keys(stability_aggregates)) == Set(case.name for case in stability_cases)
    for aggregate in values(stability_aggregates)
        run = only(aggregate.runs)
        @test haskey(run.stage_seconds, :static)
        @test haskey(run.stage_seconds, :expressions)
        @test haskey(run.stage_seconds, :reformulation)
        @test !isempty(run.expression_report.findings)
        @test length(findings(run.reformulation_report, :stable_reformulation_candidate)) == 1
    end
    stability_data = NLPDiagnostics.profile_aggregate_data(
        stability_aggregates["stability_log1mexp_composite"],
    )
    @test stability_data["case"]["name"] == "stability_log1mexp_composite"
    @test haskey(stability_data["stage_timing"], "expressions")
    @test only(stability_data["runs"])["reports"]["reformulation"]["metadata"]["stage"] ==
          "stable_reformulation_plan"
    stability_comparison = NLPDiagnostics.compare_profiles(
        stability_aggregates["stability_log1mexp_composite"],
        stability_aggregates["stability_logcosh_composite"],
    )
    stability_comparison_data = NLPDiagnostics.profile_comparison_data(
        stability_comparison,
    )
    @test stability_comparison_data["baseline_case"]["name"] ==
          "stability_log1mexp_composite"
    @test any(
        item -> item["stage"] == "expressions",
        stability_comparison_data["stage_comparisons"],
    )
    stability_markdown = NLPDiagnostics.markdown_profile_aggregate(
        stability_aggregates["stability_log1mexp_composite"],
    )
        @test occursin("# NLPDiagnostics profile: stability_log1mexp_composite", stability_markdown)
        @test occursin("## Expected evidence", stability_markdown)
        @test occursin("## Numerical observations", stability_markdown)
        @test occursin("`jacobian_rank`", stability_markdown)
    @test occursin("`expressions`", stability_markdown)
    stability_comparison_markdown = NLPDiagnostics.markdown_profile_comparison(
        stability_comparison,
    )
    @test occursin("# NLPDiagnostics profile comparison", stability_comparison_markdown)
    @test occursin("Baseline: `stability_log1mexp_composite`", stability_comparison_markdown)
    @test occursin("## Numerical metric comparison", stability_comparison_markdown)
    boundary_models, boundary_cases =
        NLPDiagnostics.synthetic_derivative_boundary_profile_corpus()
    @test length(boundary_models) == length(boundary_cases) == 8
    @test all(
        case -> case.expected_evidence == [:strict_domain_derivative_amplification],
        boundary_cases,
    )
    boundary_aggregates = NLPDiagnostics.profile_synthetic_derivative_boundary_corpus(
        repetitions = 1, warmup = false,
    )
    @test Set(keys(boundary_aggregates)) == Set(case.name for case in boundary_cases)
    @test all(
        aggregate -> only(aggregate.expected_evidence).fraction == 1.0,
        values(boundary_aggregates),
    )
    float32_models, float32_cases =
        NLPDiagnostics.synthetic_float32_derivative_overflow_profile_corpus()
    @test length(float32_models) == length(float32_cases) == 2
    float32_aggregates =
        NLPDiagnostics.profile_synthetic_float32_derivative_overflow_corpus(
            repetitions = 1, warmup = false,
        )
    @test all(
        aggregate -> only(aggregate.expected_evidence).fraction == 1.0,
        values(float32_aggregates),
    )
    @test all(
        aggregate -> any(
            finding -> finding.code == :strict_domain_derivative_amplification &&
                       finding.severity == NLPDiagnostics.SeverityError,
            only(aggregate.runs).expression_report.findings,
        ),
        values(float32_aggregates),
    )
    coupled_cone_models, coupled_cone_cases =
        NLPDiagnostics.synthetic_coupled_cone_profile_corpus()
    @test length(coupled_cone_models) == length(coupled_cone_cases) == 17
    coupled_cone_aggregates = NLPDiagnostics.profile_synthetic_coupled_cone_corpus(
        repetitions = 1, warmup = false,
    )
    @test Set(keys(coupled_cone_aggregates)) == Set(case.name for case in coupled_cone_cases)
    @test all(
        aggregate -> all(summary -> summary.fraction == 1.0,
                         aggregate.expected_evidence),
        values(coupled_cone_aggregates),
    )
    geometry_models, geometry_cases =
        NLPDiagnostics.synthetic_quadratic_geometry_profile_corpus()
    @test length(geometry_models) == length(geometry_cases) == 8
    @test [case.name for case in geometry_cases] == [
        "quadratic_nonunit_circle",
        "nonlinear_nonunit_circle",
        "quadratic_shifted_ellipsoid",
        "nonlinear_shifted_ellipsoid",
        "quadratic_zero_radius",
        "quadratic_negative_radius_squared",
        "quadratic_implied_bound_conflict",
        "quadratic_minimum_level_inequality",
    ]
    geometry_aggregates = NLPDiagnostics.profile_synthetic_quadratic_geometry_corpus(
        repetitions = 1, warmup = false,
    )
    @test all(
        aggregate -> all(item -> item.fraction == 1.0, aggregate.expected_evidence),
        values(geometry_aggregates),
    )
    @test Set(item.code for item in geometry_aggregates["quadratic_zero_radius"].expected_evidence) ==
          Set([:zero_radius_circular_constraint, :nonregular_zero_radius_quadratic_fixing])
    @test Set(item.code for item in geometry_aggregates["quadratic_minimum_level_inequality"].expected_evidence) ==
          Set([
              :minimum_level_diagonal_quadratic_constraint,
              :nonregular_minimum_level_diagonal_quadratic_inequality,
          ])
    duplicate = NLPDiagnostics.ProfileCase("first", point)
    @test_throws ArgumentError NLPDiagnostics.profile_cases_repeated(
        MOI.ModelLike[],
        [first_case, duplicate],
    )
end

@testset "BMOPF point calibration benchmark contracts" begin
    repository_root = normpath(joinpath(@__DIR__, ".."))
    benchmark_directory = joinpath(repository_root, "benchmarks")
    benchmark_environment_module = Module(:NLPDiagnosticsBenchmarkEnvironmentContract)
    Base.include(benchmark_environment_module,
        joinpath(benchmark_directory, "benchmark_environment.jl"))
    git_state = getfield(benchmark_environment_module, :_benchmark_git_state)(repository_root)
    @test git_state["revision"] isa AbstractString
    @test !isempty(git_state["revision"])
    @test git_state["dirty"] isa Bool
    @test git_state["dirty"] ? git_state["diff_fingerprint"] isa String :
          isnothing(git_state["diff_fingerprint"])
    benchmark_environment = getfield(
        benchmark_environment_module, :_benchmark_environment,
    )()
    @test haskey(benchmark_environment, "git_dirty")
    @test haskey(benchmark_environment, "git_diff_fingerprint")
    @test haskey(benchmark_environment, "package_source_states")
    @test haskey(benchmark_environment["package_source_states"], "NLPDiagnostics")
    scripts = (
        "launch_bmopf_point_calibration.jl",
        "summarize_bmopf_point_calibration.jl",
        "validate_bmopf_campaign.jl",
        "bmopf_solver_trace.jl",
        "launch_bmopf_solver_trace.jl",
        "summarize_bmopf_solver_trace.jl",
        "bmopf_magnitude_scaling_campaign.jl",
        "bmopf_acdc_scaling_campaign.jl",
        "bmopf_acdc_base_grid_campaign.jl",
        "bmopf_acdc_multiconverter_campaign.jl",
        "bmopf_acdc_multiconverter_madnlp_campaign.jl",
        "sweep_bmopf_solver_options.jl",
        "summarize_bmopf_solver_sweep.jl",
        "summarize_bmopf_endpoint_triangulation.jl",
        "compare_bmopf_multiconductor_points.jl",
        "compare_bmopf_multiconductor_crosschecks.jl",
        "compare_bmopf_formulation_interventions.jl",
        "summarize_bmopf_evidence_ledger.jl",
        "launch_bmopf_source_solver_matrix.jl",
        "compare_bmopf_source_solver_matrices.jl",
        "correlate_bmopf_structural_family_omission.jl",
        "summarize_bmopf_sparse_corpus.jl",
        "summarize_bmopf_medium_calibration.jl",
        "validate_bmopf_residual_trends.jl",
        "summarize_bmopf_restoration_campaign.jl",
        "launch_bmopf_solver_option_perturbations.jl",
        "summarize_bmopf_solver_option_perturbations.jl",
        "calibrate_restarted_smallest_singular.jl",
        "calibrate_randomized_rank_oracles.jl",
    )
    for script in scripts
        source = read(joinpath(benchmark_directory, script), String)
        @test Meta.parseall(source) isa Expr
    end
    launcher = read(
        joinpath(benchmark_directory, "launch_bmopf_point_calibration.jl"),
        String,
    )
    summary = read(
        joinpath(benchmark_directory, "summarize_bmopf_point_calibration.jl"),
        String,
    )
    @test occursin("bmopf-point-calibration-launcher-v2", launcher)
    @test occursin("NLPDIAGNOSTICS_BMOPF_RANK_MAX_DENSE_ENTRIES\"] = \"0\"", launcher)
    @test occursin("expected_child_count", launcher)
    @test occursin("case_isolation", launcher)
    @test occursin("NLPDIAGNOSTICS_BMOPF_CALIBRATION_RESUME", launcher)
    @test occursin("resume-skip", launcher)
    @test occursin("previous_attempts", launcher)
    @test occursin("elapsed_seconds", launcher)
    @test occursin("NLPDIAGNOSTICS_BMOPF_CALIBRATION_MAX_RSS_MIB", launcher)
    @test occursin("process_memory_limit", launcher)
    @test occursin("child_case_failure", launcher)
    @test occursin("child_cases_empty", launcher)
    @test occursin("bmopf-point-calibration-v2", summary)
    @test occursin("point_invariant_stage_stability", summary)
    @test occursin("same_point_fingerprint_stability", summary)
    @test occursin("same_point_finding_stability", summary)
    @test occursin("same_point_metric_stability", summary)
    @test occursin("saved_result_mapping_complete", summary)
    @test occursin("cross_case_change_recurrence", summary)
    @test occursin("cross_case_metric_change_recurrence", summary)
    @test occursin("cross_case_metric_persistence", summary)
    @test occursin("row_family_scale_attribution", summary)
    @test occursin("same_point_row_family_scale_stability", summary)
    @test occursin("cross_case_row_family_scale_recurrence", summary)
    @test occursin("cross_case_row_family_scale_direction_recurrence", summary)
    @test occursin("cross_case_row_family_scale_persistence", summary)
    @test occursin("_metric_available", summary)
    @test occursin("stratum_case_counts", summary)
    corpus = read(
        joinpath(benchmark_directory, "bmopf_draft_corpus.jl"), String,
    )
    @test occursin("bmopf_jacobian_row_family_scale_attribution", corpus)
    validator = read(
        joinpath(benchmark_directory, "validate_bmopf_campaign.jl"), String,
    )
    @test occursin("point_calibration_row_family_scale_attribution_missing", validator)
    @test occursin("row_family_scaling_experiment", summary)
    @test occursin("cross_case_row_family_scaling_experiment_summary", summary)
    @test occursin("point_calibration_row_family_scaling_experiment_missing", validator)
    solver_trace = read(
        joinpath(benchmark_directory, "bmopf_solver_trace.jl"), String,
    )
    @test occursin("bmopf_jacobian_row_family_scale_attribution", solver_trace)
    @test occursin("evaluate_numerical", solver_trace)
    @test occursin("profile_stage", solver_trace)
    @test occursin("bmopf_jacobian_row_family_scaling_experiment", solver_trace)
    @test occursin("_IPOPT_REAL_OPTIONS", solver_trace)
    @test occursin("profile_started", solver_trace)
    @test occursin("solver_complete", solver_trace)
    @test occursin("PROFILE_MAX_VARIABLES", solver_trace)
    @test occursin("PROFILE_STAGE", solver_trace)
    @test occursin("context", solver_trace)
    @test occursin("numerical", solver_trace)
    @test occursin("ok_solver_trace_numerical_profile", solver_trace)
    @test occursin("ok_solver_trace_profile_skipped", solver_trace)
    solver_trace_launcher = read(
        joinpath(benchmark_directory, "launch_bmopf_solver_trace.jl"), String,
    )
    @test occursin("family_scaling_experiment_families", solver_trace_launcher)
    @test occursin("_checkpoint_data", solver_trace_launcher)
    @test occursin("profile_max_variables", solver_trace_launcher)
    @test occursin("profile_stage", solver_trace_launcher)
    solver_trace_summary = read(
        joinpath(benchmark_directory, "summarize_bmopf_solver_trace.jl"), String,
    )
    @test occursin("family_scaling_experiment_coverage", solver_trace_summary)
    @test occursin("bmopf_jacobian_row_family_scale_attribution", solver_trace_summary)
    @test occursin("profile_incomplete_after_solver", solver_trace_summary)
    @test occursin("profile_completeness", solver_trace_summary)
    @test occursin("checkpoint_phase", solver_trace_summary)
    @test occursin("solver_trace_case_count", solver_trace_summary)
    @test occursin("iteration_trace_campaign_summary", solver_trace_summary)
    @test occursin("_trace_summary", solver_trace_summary)
    @test occursin("profile_stage", solver_trace_summary)
    @test occursin("_solver_log_termination", solver_trace_summary)
    @test occursin("haskey(trace, \"record_count\")", solver_trace_summary)
    solver_trace_comparison = read(
        joinpath(benchmark_directory, "compare_bmopf_solver_traces.jl"),
        String,
    )
    @test occursin("iteration_trace_policy_comparison", solver_trace_comparison)
    @test occursin("trace_coverage_comparison", solver_trace_comparison)
    @test occursin("trace_comparison_readiness", solver_trace_comparison)
    @test occursin("telemetry_crosswalk", solver_trace_comparison)
    @test occursin("_trace_summary_for_comparison", solver_trace_comparison)
    truth_label_validation = read(
        joinpath(benchmark_directory, "validate_bmopf_trace_truth_labels.jl"),
        String,
    )
    @test occursin("EXPECTED_CASES", truth_label_validation)
    @test occursin("positive_control", truth_label_validation)
    @test occursin("negative_control", truth_label_validation)
    @test occursin("30bus_LG", truth_label_validation)
    @test occursin("99bus_LG", truth_label_validation)
    @test occursin("99bus_LN_t25", truth_label_validation)
    @test occursin("99bus_LG_t25", truth_label_validation)
    @test occursin("EXPECTED_UNAVAILABLE_CASES", truth_label_validation)
    @test occursin("unavailable_control", truth_label_validation)
    @test occursin("EXPECTED_SCOPE_CASES", truth_label_validation)
    @test occursin("reviewed_truth_cases", truth_label_validation)
    @test occursin("real_99bus_phase_only_kkt_failure_summary.json", truth_label_validation)
    @test occursin("scope_comparison_paths", truth_label_validation)
    @test occursin("trace_available_on_both_sides", truth_label_validation)
    combined_scaling_probe = read(
        joinpath(benchmark_directory, "bmopf_combined_mv_lv_scaling_probe.jl"),
        String,
    )
    @test occursin("Master.dss", combined_scaling_probe)
    @test occursin("combined_mv_lv_local", combined_scaling_probe)
    @test occursin("max_dense_entries = 0", combined_scaling_probe)
    series_voltage_matrix_script = read(
        joinpath(benchmark_directory, "bmopf_voltage_level_series_case_matrix.jl"),
        String,
    )
    @test Meta.parseall(series_voltage_matrix_script) isa Expr
    @test occursin("voltage_levels", series_voltage_matrix_script)
    @test occursin("single_phase", series_voltage_matrix_script)
    @test occursin("series_8level_230kV_208V", series_voltage_matrix_script)
    @test occursin("comparison_qualified", series_voltage_matrix_script)
    series_voltage_matrix_summary = JSON.parse(read(
        joinpath(repository_root, "docs", "bmopf_voltage_level_series_case_matrix_summary.json"),
        String,
    ))
    @test series_voltage_matrix_summary["schema_version"] ==
          "nlpdiagnostics-bmopf-voltage-level-series-case-matrix-v1"
    @test series_voltage_matrix_summary["case_count"] == 3
    @test series_voltage_matrix_summary["covariance_gate_passed_count"] == 3
    @test series_voltage_matrix_summary["geometry_gate_passed_count"] == 3
    @test series_voltage_matrix_summary["records"][end]["transformer_count"] == 7
    @test series_voltage_matrix_summary["records"][end]["model_variable_count"] == 134
    series_voltage_solver_script = read(
        joinpath(benchmark_directory, "bmopf_voltage_level_series_solver_campaign.jl"),
        String,
    )
    @test Meta.parseall(series_voltage_solver_script) isa Expr
    @test occursin("matched-start", series_voltage_solver_script)
    @test occursin("series_voltage_local", series_voltage_solver_script)
    @test occursin("Ipopt", series_voltage_solver_script)
    series_voltage_solver_summary = JSON.parse(read(
        joinpath(repository_root, "docs", "bmopf_voltage_level_series_solver_campaign_summary.json"),
        String,
    ))
    @test series_voltage_solver_summary["schema_version"] ==
          "nlpdiagnostics-bmopf-voltage-level-series-solver-campaign-v1"
    @test series_voltage_solver_summary["case_count"] == 3
    @test series_voltage_solver_summary["campaign_qualified_count"] == 2
    @test series_voltage_solver_summary["records"][end]["campaign_qualified"] == false
    @test occursin("ITERATION_LIMIT", string(series_voltage_solver_summary["records"][end]))
    series_voltage_solver_budget_summary = JSON.parse(read(
        joinpath(repository_root, "docs", "bmopf_voltage_level_series_solver_campaign_maxiter60_summary.json"),
        String,
    ))
    @test series_voltage_solver_budget_summary["budgets"]["max_iter"] == 60
    @test series_voltage_solver_budget_summary["records"][end]["campaign_qualified"] == false
    @test occursin("LOCALLY_INFEASIBLE", string(series_voltage_solver_budget_summary["records"][end]))
    series_voltage_madnlp_script = read(
        joinpath(benchmark_directory, "bmopf_voltage_level_series_madnlp_campaign.jl"),
        String,
    )
    @test Meta.parseall(series_voltage_madnlp_script) isa Expr
    @test occursin("MadNLP", series_voltage_madnlp_script)
    @test occursin("0.25", series_voltage_madnlp_script)
    series_voltage_madnlp_summary = JSON.parse(read(
        joinpath(repository_root, "docs", "bmopf_voltage_level_series_madnlp_campaign_summary.json"),
        String,
    ))
    @test series_voltage_madnlp_summary["schema_version"] ==
          "nlpdiagnostics-bmopf-voltage-level-series-madnlp-campaign-v1"
    @test series_voltage_madnlp_summary["solver"] == "MadNLP"
    @test series_voltage_madnlp_summary["campaign_qualified_count"] == 1
    @test occursin("LOCALLY_SOLVED", string(series_voltage_madnlp_summary["records"][end]))
    series_feasibility_sweep_script = read(
        joinpath(benchmark_directory, "bmopf_voltage_level_series_feasibility_sweep.jl"),
        String,
    )
    @test Meta.parseall(series_feasibility_sweep_script) isa Expr
    @test occursin("load_multiplier", series_feasibility_sweep_script)
    @test occursin("0.25", series_feasibility_sweep_script)
    series_feasibility_sweep_summary = JSON.parse(read(
        joinpath(repository_root, "docs", "bmopf_voltage_level_series_feasibility_sweep_summary.json"),
        String,
    ))
    @test series_feasibility_sweep_summary["schema_version"] ==
          "nlpdiagnostics-bmopf-voltage-level-series-feasibility-sweep-v1"
    @test series_feasibility_sweep_summary["load_multiplier_count"] == 4
    @test series_feasibility_sweep_summary["campaign_qualified_count"] == 0
    @test series_feasibility_sweep_summary["records"][end]["load_multiplier"] == 0.25
    @test occursin("LOCALLY_SOLVED", string(series_feasibility_sweep_summary["records"][end]))
    practical_application_script = read(
        joinpath(benchmark_directory, "summarize_bmopf_practical_application_success.jl"),
        String,
    )
    @test Meta.parseall(practical_application_script) isa Expr
    @test occursin("LV1_14bus", practical_application_script)
    @test occursin("LV13_58bus", practical_application_script)
    @test occursin("fragility_value", practical_application_script)
    practical_application_summary = JSON.parse(read(
        joinpath(repository_root, "docs", "bmopf_practical_application_success_summary.json"),
        String,
    ))
    @test practical_application_summary["schema_version"] ==
          "nlpdiagnostics-bmopf-practical-application-success-v1"
    @test practical_application_summary["application_count"] == 6
    @test practical_application_summary["successful_application_count"] == 6
    series_application_bridge_script = read(
        joinpath(benchmark_directory, "summarize_bmopf_series_application_bridge.jl"),
        String,
    )
    @test Meta.parseall(series_application_bridge_script) isa Expr
    @test occursin("direct_physical_equivalence", series_application_bridge_script)
    series_application_bridge_summary = JSON.parse(read(
        joinpath(repository_root, "docs", "bmopf_series_application_bridge_summary.json"),
        String,
    ))
    @test series_application_bridge_summary["schema_version"] ==
          "nlpdiagnostics-bmopf-series-application-bridge-v1"
    @test series_application_bridge_summary["status"] == "procedural_bridge_complete"
    @test length(series_application_bridge_summary["evidence_rows"]) == 9
    @test series_application_bridge_summary["shared_contracts"]["direct_physical_equivalence"] == false
    @test series_application_bridge_summary["uprated_fixture"]["rating_multiplier"] == 2.5
    @test series_application_bridge_summary["uprated_fixture"]["campaigns_qualified"] == true
    @test "MadNLP" in series_application_bridge_summary["solver_coverage"]["LV1_14bus"]["solvers"]
    @test !("MadNLP" in series_application_bridge_summary["solver_coverage"]["LV13_58bus"]["solvers"])
    @test series_application_bridge_summary["transfer_gaps"][1]["missing_solver"] == "MadNLP"
    @test series_application_bridge_summary["lv13_madnlp_guard"]["status"] == "resource_guard_validated"
    @test series_application_bridge_summary["lv13_madnlp_result"]["status"] == "awaiting_artifact"
    @test series_application_bridge_summary["transfer_gaps"][1]["result_status"] == "awaiting_artifact"
    lv13_madnlp_guard_script = read(
        joinpath(benchmark_directory, "summarize_bmopf_lv13_madnlp_transfer_guard.jl"),
        String,
    )
    @test Meta.parseall(lv13_madnlp_guard_script) isa Expr
    @test occursin("snapshot_size_guarded", lv13_madnlp_guard_script)
    lv13_madnlp_guard_summary = JSON.parse(read(
        joinpath(repository_root, "docs", "bmopf_lv13_madnlp_transfer_guard_summary.json"),
        String,
    ))
    @test lv13_madnlp_guard_summary["schema_version"] ==
          "nlpdiagnostics-bmopf-lv13-madnlp-transfer-guard-v1"
    @test lv13_madnlp_guard_summary["status"] == "resource_guard_validated"
    @test lv13_madnlp_guard_summary["observed"]["solver_runs"] == 0
    @test lv13_madnlp_guard_summary["isolated_run_plan"]["timeout_seconds"] == 900
    @test lv13_madnlp_guard_summary["isolated_run_plan"]["proposed_max_variables"] == 5000
    lv13_madnlp_plan_script = read(
        joinpath(benchmark_directory, "plan_bmopf_lv13_madnlp_isolated_run.jl"),
        String,
    )
    @test Meta.parseall(lv13_madnlp_plan_script) isa Expr
    @test occursin("external isolated-process launcher", lv13_madnlp_plan_script)
    lv13_madnlp_plan_summary = JSON.parse(read(
        joinpath(repository_root, "docs", "bmopf_lv13_madnlp_isolated_run_plan.json"),
        String,
    ))
    @test lv13_madnlp_plan_summary["schema_version"] ==
          "nlpdiagnostics-bmopf-lv13-madnlp-isolated-run-plan-v1"
    @test lv13_madnlp_plan_summary["status"] == "isolated_run_ready"
    @test lv13_madnlp_plan_summary["execution"]["approval_required"] == true
    @test lv13_madnlp_plan_summary["resource_envelope"]["max_variables"] == 5000
    lv13_madnlp_result_script = read(
        joinpath(benchmark_directory, "summarize_bmopf_lv13_madnlp_isolated_result.jl"),
        String,
    )
    @test Meta.parseall(lv13_madnlp_result_script) isa Expr
    @test occursin("awaiting_artifact", lv13_madnlp_result_script)
    lv13_madnlp_result_summary = JSON.parse(read(
        joinpath(repository_root, "docs", "bmopf_lv13_madnlp_isolated_result_summary.json"),
        String,
    ))
    @test lv13_madnlp_result_summary["schema_version"] ==
          "nlpdiagnostics-bmopf-lv13-madnlp-isolated-result-v1"
    @test lv13_madnlp_result_summary["status"] == "awaiting_artifact"
    @test lv13_madnlp_result_summary["checks"]["artifact_present"] == false
    complete_fixture = joinpath(
        repository_root, "test", "fixtures", "bmopf_lv13_madnlp_isolated_result_complete.json",
    )
    mktempdir() do directory
        complete_output = joinpath(directory, "complete-summary.json")
        complete_environment = copy(ENV)
        complete_environment["NLPDIAGNOSTICS_LV13_MADNLP_ISOLATED_RESULT_INPUT"] = complete_fixture
        complete_environment["NLPDIAGNOSTICS_LV13_MADNLP_ISOLATED_RESULT_OUTPUT"] = complete_output
        complete_command = `$(Base.julia_cmd()) --compiled-modules=no --startup-file=no --project=$(joinpath(repository_root, "work", "benchmark-environment")) $(joinpath(benchmark_directory, "summarize_bmopf_lv13_madnlp_isolated_result.jl"))`
        run(setenv(complete_command, complete_environment))
        complete_summary = JSON.parse(read(complete_output, String))
        @test complete_summary["status"] == "isolated_result_complete"
        @test all(values(complete_summary["checks"]))
    end
    lv13_madnlp_environment_script = read(
        joinpath(benchmark_directory, "validate_bmopf_lv13_madnlp_isolated_environment.jl"),
        String,
    )
    @test Meta.parseall(lv13_madnlp_environment_script) isa Expr
    @test occursin("environment_ready", lv13_madnlp_environment_script)
    lv13_madnlp_environment_summary = JSON.parse(read(
        joinpath(repository_root, "docs", "bmopf_lv13_madnlp_isolated_environment_summary.json"),
        String,
    ))
    @test lv13_madnlp_environment_summary["schema_version"] ==
          "nlpdiagnostics-bmopf-lv13-madnlp-isolated-environment-v1"
    @test lv13_madnlp_environment_summary["status"] == "environment_ready"
    @test lv13_madnlp_environment_summary["checks"]["madnlp_loadable"] == true
    lv13_madnlp_resource_script = read(
        joinpath(benchmark_directory, "assess_bmopf_lv13_madnlp_resource_envelope.jl"),
        String,
    )
    @test Meta.parseall(lv13_madnlp_resource_script) isa Expr
    @test occursin("current_free_memory_meets_envelope", lv13_madnlp_resource_script)
    lv13_madnlp_resource_summary = JSON.parse(read(
        joinpath(repository_root, "docs", "bmopf_lv13_madnlp_resource_envelope_summary.json"),
        String,
    ))
    @test lv13_madnlp_resource_summary["schema_version"] ==
          "nlpdiagnostics-bmopf-lv13-madnlp-resource-envelope-v1"
    @test lv13_madnlp_resource_summary["checks"]["host_capacity_meets_envelope"] == true
    @test lv13_madnlp_resource_summary["observed"]["capacity_margin_mb"] > 0
    @test lv13_madnlp_resource_summary["observed"]["additional_free_memory_required_mb"] > 0
    @test lv13_madnlp_resource_summary["status"] in [
        "resource_envelope_ready",
        "resource_capacity_available_but_current_free_memory_insufficient",
    ]
    lv13_madnlp_handoff_script = read(
        joinpath(benchmark_directory, "summarize_bmopf_lv13_madnlp_handoff.jl"),
        String,
    )
    @test Meta.parseall(lv13_madnlp_handoff_script) isa Expr
    @test occursin("blocked_current_memory_pressure", lv13_madnlp_handoff_script)
    lv13_madnlp_handoff_summary = JSON.parse(read(
        joinpath(repository_root, "docs", "bmopf_lv13_madnlp_handoff_summary.json"),
        String,
    ))
    @test lv13_madnlp_handoff_summary["schema_version"] ==
          "nlpdiagnostics-bmopf-lv13-madnlp-handoff-v1"
    @test lv13_madnlp_handoff_summary["status"] == "blocked_current_memory_pressure"
    @test lv13_madnlp_handoff_summary["blockers"] == [
        "current_free_memory_below_declared_envelope",
    ]
    lv13_madnlp_launcher_script = read(
        joinpath(benchmark_directory, "run_bmopf_lv13_madnlp_isolated.jl"),
        String,
    )
    @test Meta.parseall(lv13_madnlp_launcher_script) isa Expr
    @test occursin("NLPDIAGNOSTICS_LV13_MADNLP_EXECUTE", lv13_madnlp_launcher_script)
    @test occursin("preflight_ready", lv13_madnlp_launcher_script)
    lv13_madnlp_launch_summary = JSON.parse(read(
        joinpath(repository_root, "docs", "bmopf_lv13_madnlp_launch_summary.json"),
        String,
    ))
    @test lv13_madnlp_launch_summary["schema_version"] ==
          "nlpdiagnostics-bmopf-lv13-madnlp-launch-v1"
    @test lv13_madnlp_launch_summary["status"] == "approval_required"
    @test lv13_madnlp_launch_summary["approval"]["execute_requested"] == false
    @test lv13_madnlp_launch_summary["preflight"]["preflight_ready"] == true
    series_capacity_boundary_script = read(
        joinpath(benchmark_directory, "analyze_bmopf_series_nominal_capacity_boundary.jl"),
        String,
    )
    @test Meta.parseall(series_capacity_boundary_script) isa Expr
    @test occursin("necessary_capacity_multiplier", series_capacity_boundary_script)
    series_capacity_boundary_summary = JSON.parse(read(
        joinpath(repository_root, "docs", "bmopf_series_nominal_capacity_boundary_summary.json"),
        String,
    ))
    @test series_capacity_boundary_summary["schema_version"] ==
          "nlpdiagnostics-bmopf-series-nominal-capacity-boundary-v1"
    @test series_capacity_boundary_summary["status"] == "capacity_boundary_aligned"
    @test series_capacity_boundary_summary["records"][1]["capacity_gate_passed"] == false
    @test series_capacity_boundary_summary["records"][end]["capacity_gate_passed"] == true
    series_uprated_nominal_script = read(
        joinpath(benchmark_directory, "bmopf_voltage_level_series_uprated_nominal_campaign.jl"),
        String,
    )
    @test Meta.parseall(series_uprated_nominal_script) isa Expr
    @test occursin("rating_multiplier", series_uprated_nominal_script)
    @test occursin("MadNLP", series_uprated_nominal_script)
    series_uprated_nominal_summary = JSON.parse(read(
        joinpath(repository_root, "docs", "bmopf_voltage_level_series_uprated_nominal_campaign_summary.json"),
        String,
    ))
    @test series_uprated_nominal_summary["schema_version"] ==
          "nlpdiagnostics-bmopf-voltage-level-series-uprated-nominal-campaign-v1"
    @test series_uprated_nominal_summary["status"] == "uprated_nominal_campaign_complete"
    @test series_uprated_nominal_summary["rating_multiplier"] == 2.5
    @test length(series_uprated_nominal_summary["campaigns"]) == 2
    @test all(item -> item["record"]["campaign_qualified"], series_uprated_nominal_summary["campaigns"])
    combined_scaling_campaign = read(
        joinpath(benchmark_directory, "bmopf_combined_mv_lv_scaling_campaign.jl"),
        String,
    )
    @test occursin("max_variables", combined_scaling_campaign)
    @test occursin("max_cpu_seconds", combined_scaling_campaign)
    @test occursin("skipped_solver_size_guard", combined_scaling_campaign)
    @test occursin("combined_mv_lv_local", combined_scaling_campaign)
    combined_scaling_summary = read(
        joinpath(repository_root, "docs", "bmopf_combined_mv_lv_scaling_readiness_summary.json"),
        String,
    )
    @test occursin("structural_readiness_complete_solver_campaign_pending", combined_scaling_summary)
    @test occursin("transformer_interface_count", combined_scaling_summary)
    @test occursin("solver_work_claim_supported", combined_scaling_summary)
    combined_scaling_campaign_summary = read(
        joinpath(repository_root, "docs", "bmopf_combined_mv_lv_scaling_campaign_summary.json"),
        String,
    )
    @test occursin("bounded_solver_campaign_size_guarded", combined_scaling_campaign_summary)
    @test occursin("56142", combined_scaling_campaign_summary)
    @test occursin("model_variable_count", combined_scaling_campaign_summary)
    combined_snapshot_campaign = read(
        joinpath(benchmark_directory, "bmopf_combined_mv_lv_snapshot_campaign.jl"),
        String,
    )
    @test occursin("MV21_328bus", combined_snapshot_campaign)
    @test occursin("LV1_14bus", combined_snapshot_campaign)
    @test occursin("_run_policy", combined_snapshot_campaign)
    @test occursin("matched-start", combined_snapshot_campaign)
    @test occursin("baseline_repeat", combined_snapshot_campaign)
    @test occursin("endpoint_gates", combined_snapshot_campaign)
    @test occursin("SNAPSHOT_TOL", combined_snapshot_campaign)
    @test occursin("endpoint_diagnostics", combined_snapshot_campaign)
    combined_snapshot_summary = read(
        joinpath(repository_root, "docs", "bmopf_combined_mv_lv_snapshot_campaign_summary.json"),
        String,
    )
    @test occursin("endpoint_gated_ipopt_madnlp_campaigns_complete", combined_snapshot_summary)
    @test occursin("4180", combined_snapshot_summary)
    @test occursin("campaign_qualified", combined_snapshot_summary)
    @test occursin("MadNLP", combined_snapshot_summary)
    @test occursin("0.0028511005", combined_snapshot_summary)
    @test occursin("LV13_58bus", combined_snapshot_summary)
    @test occursin("1.915395841933787e-9", combined_snapshot_summary)
    perturbed_start_campaign = read(
        joinpath(benchmark_directory, "bmopf_combined_mv_lv_perturbed_start_campaign.jl"),
        String,
    )
    @test occursin("plus_1pct", perturbed_start_campaign)
    @test occursin("minus_1pct", perturbed_start_campaign)
    @test occursin("matrix_gates", perturbed_start_campaign)
    @test occursin("perturbed_start_matrix", combined_snapshot_summary)
    @test occursin("3.637978807091713e-12", combined_snapshot_summary)
    @test occursin("perturbed_start_lv13_matrix", combined_snapshot_summary)
    @test occursin("7.784467015881091e-6", combined_snapshot_summary)
    @test occursin("perturbed_start_madnlp_matrix", combined_snapshot_summary)
    @test occursin("solver-diverse descriptive", combined_snapshot_summary)
    @test occursin("voltage_only_start_matrix", combined_snapshot_summary)
    @test occursin("2082", combined_snapshot_summary)
    @test occursin("voltage_only", perturbed_start_campaign)
    release_gate_summary = read(
        joinpath(repository_root, "docs", "calibration_release_gate_summary.json"),
        String,
    )
    @test occursin("combined_mv_lv_scaling_start_robustness", release_gate_summary)
    @test occursin("bmopf_voltage_level_series_scaling_readiness", release_gate_summary)
    @test occursin("bmopf_practical_application_success", release_gate_summary)
    @test occursin("bmopf_voltage_level_series_solver_campaign", release_gate_summary)
    @test occursin("bmopf_voltage_level_series_feasibility_sweep", release_gate_summary)
    @test occursin("bmopf_lv13_madnlp_isolated_run_plan", release_gate_summary)
    @test occursin("bmopf_lv13_madnlp_isolated_environment", release_gate_summary)
    @test occursin("bmopf_lv13_madnlp_resource_envelope", release_gate_summary)
    @test occursin("bmopf_lv13_madnlp_handoff", release_gate_summary)
    @test occursin("bmopf_lv13_madnlp_guarded_launcher", release_gate_summary)
    @test occursin("bmopf_lv13_madnlp_isolated_result", release_gate_summary)
    @test occursin("\"blocking\": false", release_gate_summary)
    release_report = read(
        joinpath(repository_root, "docs", "calibration_release_report.md"),
        String,
    )
    @test occursin("combined_mv_lv_scaling_start_robustness", release_report)
    @test occursin("bmopf_voltage_level_series_scaling_readiness", release_report)
    @test occursin("bmopf_practical_application_success", release_report)
    @test occursin("bmopf_voltage_level_series_solver_campaign", release_report)
    @test occursin("bmopf_voltage_level_series_feasibility_sweep", release_report)
    release_gate_builder = read(
        joinpath(benchmark_directory, "build_calibration_release_gate_summary.jl"),
        String,
    )
    @test occursin("combined_mv_lv_scaling_start_robustness", release_gate_builder)
    @test occursin("bmopf_voltage_level_series_scaling_readiness", release_gate_builder)
    @test occursin("bmopf_practical_application_success", release_gate_builder)
    @test occursin("bmopf_voltage_level_series_solver_campaign", release_gate_builder)
    @test occursin("bmopf_voltage_level_series_feasibility_sweep", release_gate_builder)
    @test occursin("api_migration_queue_summary.json", release_gate_builder)
    @test occursin("api_advanced_candidate_summary.json", release_gate_builder)
    release_action_script = read(
        joinpath(benchmark_directory, "summarize_release_gate_actions.jl"),
        String,
    )
    @test Meta.parseall(release_action_script) isa Expr
    @test occursin("closure_condition", release_action_script)
    release_action_summary = JSON.parse(read(
        joinpath(repository_root, "docs", "release_gate_action_summary.json"),
        String,
    ))
    @test release_action_summary["schema_version"] == "nlpdiagnostics-release-gate-actions-v1"
    @test release_action_summary["blocking_gate_count"] == 5
    @test release_action_summary["all_blocking_gates_mapped"] == true
    @test release_action_summary["recommended_order"][1] == "numerical_rank_false_positive_negative_statistics"
    @test occursin("Recommended blocker order", release_report)
    @test occursin("release_gate_action_summary.json", release_gate_summary)
    analyze_scaling_script = read(
        joinpath(benchmark_directory, "profile_analyze_scaling.jl"),
        String,
    )
    @test occursin("stage_attribution", analyze_scaling_script)
    @test occursin("analyze_static", analyze_scaling_script)
    analyze_scaling_summary = read(
        joinpath(repository_root, "docs", "analyze_runtime_scaling_summary.json"),
        String,
    )
    @test occursin("nlpdiagnostics-analyze-runtime-scaling-v3", analyze_scaling_summary)
    @test occursin("\"stage_attribution\"", analyze_scaling_summary)
    @test occursin("reuse_domain_interval_state", analyze_scaling_summary)
    @test occursin("evidence_stable_across_repetitions", analyze_scaling_summary)
    @test occursin("sparse_nonlinear_chain", analyze_scaling_summary)
    @test occursin("workload_comparisons", analyze_scaling_summary)
    @test occursin("process_maxrss_increment_bytes", analyze_scaling_summary)
    @test occursin("memory_measurement", analyze_scaling_summary)
    analyze_trend_script = read(
        joinpath(benchmark_directory, "summarize_analyze_runtime_trends.jl"),
        String,
    )
    @test Meta.parseall(analyze_trend_script) isa Expr
    @test occursin("log_log_slope", analyze_trend_script)
    analyze_trend_summary = read(
        joinpath(repository_root, "docs", "analyze_runtime_trend_summary.json"),
        String,
    )
    analyze_trend_data = JSON.parse(analyze_trend_summary)
    @test analyze_trend_data["schema_version"] == "nlpdiagnostics-analyze-runtime-trend-v1"
    @test analyze_trend_data["affine_chain"]["point_count"] == 3
    @test analyze_trend_data["affine_chain"]["evidence_stable"] == true
    @test analyze_trend_data["affine_chain"]["dominant_stage_at_largest_dimension"] == "static"
    analyze_resource_script = read(
        joinpath(benchmark_directory, "summarize_analyze_runtime_resources.jl"),
        String,
    )
    @test Meta.parseall(analyze_resource_script) isa Expr
    @test occursin("dominant_allocation_stage_at_largest_dimension", analyze_resource_script)
    analyze_resource_summary = read(
        joinpath(repository_root, "docs", "analyze_runtime_resource_summary.json"),
        String,
    )
    @test occursin("nlpdiagnostics-analyze-runtime-resource-v1", analyze_resource_summary)
    analyze_resource_data = JSON.parse(analyze_resource_summary)
    @test analyze_resource_data["workload_count"] == 2
    @test all(workload["point_count"] == 3 for workload in analyze_resource_data["workloads"])
    @test all(workload["evidence_stable"] for workload in analyze_resource_data["workloads"])
    @test all(workload["dominant_allocation_stage_at_largest_dimension"]["stage"] == "static" for workload in analyze_resource_data["workloads"])
    @test all(workload["runtime_repeatability_at_largest_dimension"]["sample_count"] == 3 for workload in analyze_resource_data["workloads"])
    @test all(workload["stage_timing_repeatability_at_largest_dimension"]["stage_count"] == 7 for workload in analyze_resource_data["workloads"])
    @test all(workload["runtime_repeatability_at_largest_dimension"]["coefficient_of_variation"] < 0.1 for workload in analyze_resource_data["workloads"])
    @test occursin("analyze_runtime_resource_summary.json", read(
        joinpath(benchmark_directory, "build_calibration_release_gate_summary.jl"),
        String,
    ))
    @test occursin("runtime_repeatability_at_largest_dimension", read(
        joinpath(benchmark_directory, "build_calibration_release_gate_summary.jl"),
        String,
    ))
    analyze_readiness_script = read(
        joinpath(benchmark_directory, "summarize_analyze_scaling_readiness.jl"),
        String,
    )
    @test Meta.parseall(analyze_readiness_script) isa Expr
    @test occursin("static_stage_candidate_selection", analyze_readiness_script)
    analyze_readiness_summary = read(
        joinpath(repository_root, "docs", "analyze_scaling_readiness_summary.json"),
        String,
    )
    analyze_readiness_data = JSON.parse(analyze_readiness_summary)
    @test analyze_readiness_data["schema_version"] == "nlpdiagnostics-analyze-scaling-readiness-v1"
    @test analyze_readiness_data["workload_count"] == 2
    @test analyze_readiness_data["open_gap_count"] == 1
    @test all(workload["point_count"] == 3 for workload in analyze_readiness_data["workloads"])
    @test all(workload["evidence_stable"] for workload in analyze_readiness_data["workloads"])
    @test all(workload["dominant_elapsed_stage_at_largest_dimension"] == "static" for workload in analyze_readiness_data["workloads"])
    @test analyze_readiness_data["adapter_profile"]["measured_count"] == 3
    @test analyze_readiness_data["adapter_profile"]["guarded_count"] == 2
    @test analyze_readiness_data["static_optimization_ab"]["record_count"] == 3
    @test analyze_readiness_data["static_optimization_ab"]["equivalence_passed"] == true
    @test analyze_readiness_data["static_optimization_ab"]["candidate_not_slower_at_every_dimension"] == false
    @test analyze_readiness_data["static_optimization_generalization"]["workload_count"] == 2
    @test analyze_readiness_data["static_optimization_generalization"]["record_count"] == 6
    @test analyze_readiness_data["static_optimization_generalization"]["equivalence_passed"] == true
    @test analyze_readiness_data["static_optimization_target_terms"]["record_count"] == 6
    @test analyze_readiness_data["static_optimization_target_terms"]["equivalence_passed"] == true
    @test analyze_readiness_data["static_optimization_target_terms"]["candidate_not_slower_at_every_workload"] == false
    @test analyze_readiness_data["isolated_adapter_memory"]["record_count"] == 10
    @test analyze_readiness_data["isolated_adapter_memory"]["measured_count"] == 6
    @test analyze_readiness_data["isolated_adapter_memory"]["guarded_count"] == 4
    @test analyze_readiness_data["isolated_adapter_memory"]["stable_case_count"] == 3
    @test analyze_readiness_data["isolated_adapter_memory"]["all_measured_cases_stable"] == true
    @test analyze_readiness_data["portability_contract"]["baseline_status"] == "valid"
    @test analyze_readiness_data["portability_contract"]["comparison_status"] == "candidate_requires_review"
    @test analyze_readiness_data["portability_contract"]["comparison_environment_distinct"] == true
    @test analyze_readiness_data["portability_contract"]["comparison_mismatch_count"] == 0
    @test analyze_readiness_data["portability_contract"]["semantic_comparison_status"] == "semantics_match"
    @test analyze_readiness_data["portability_contract"]["semantic_comparison_mismatch_count"] == 0
    @test analyze_readiness_data["portability_contract"]["semantic_comparison_matched_record_count"] == 6
    @test analyze_readiness_data["portability_contract"]["resource_comparison_status"] == "descriptive_only"
    @test analyze_readiness_data["portability_contract"]["resource_comparison_matched_record_count"] == 6
    @test analyze_readiness_data["portability_contract"]["resource_comparison_nonzero_difference_count"] == 6
    @test analyze_readiness_data["portability_contract"]["comparison_required_for_portable_claim"] == true
    @test analyze_readiness_data["bmopf_combined_mv_lv_analyze"]["feeder_count"] == 4
    @test analyze_readiness_data["bmopf_combined_mv_lv_analyze"]["record_count"] == 12
    @test analyze_readiness_data["bmopf_combined_mv_lv_analyze"]["measured_count"] == 9
    @test analyze_readiness_data["bmopf_combined_mv_lv_analyze"]["stable_measured_count"] == 9
    analyze_combined_script = read(
        joinpath(benchmark_directory, "profile_bmopf_combined_mv_lv_analyze_scaling.jl"),
        String,
    )
    @test Meta.parseall(analyze_combined_script) isa Expr
    @test occursin("combined_mv_lv_local", analyze_combined_script)
    @test occursin("NLPDIAGNOSTICS_BMOPF_COMBINED_MV_LV_ANALYZE_MAX_VARIABLES", analyze_combined_script)
    analyze_combined_summary = read(
        joinpath(repository_root, "docs", "bmopf_combined_mv_lv_analyze_scaling_summary.json"),
        String,
    )
    @test occursin("nlpdiagnostics-bmopf-combined-mv-lv-analyze-scaling-v1", analyze_combined_summary)
    @test occursin("PowerIO", read(
        joinpath(benchmark_directory, "profile_bmopf_combined_mv_lv_analyze_scaling.jl"),
        String,
    ))
    analyze_generalization_script = read(
        joinpath(benchmark_directory, "profile_analyze_static_optimization_generalization.jl"),
        String,
    )
    @test Meta.parseall(analyze_generalization_script) isa Expr
    @test occursin("mixed_density_affine_chain", analyze_generalization_script)
    @test occursin("sparse_nonlinear_chain", analyze_generalization_script)
    @test occursin("analyze_static_optimization_generalization_summary.json", read(
        joinpath(benchmark_directory, "build_calibration_release_gate_summary.jl"),
        String,
    ))
    analyze_target_terms_script = read(
        joinpath(benchmark_directory, "profile_analyze_static_target_terms.jl"),
        String,
    )
    @test Meta.parseall(analyze_target_terms_script) isa Expr
    @test occursin("cache_affine_target_terms", analyze_target_terms_script)
    @test occursin("analyze_static_target_terms_summary.json", read(
        joinpath(benchmark_directory, "summarize_analyze_scaling_readiness.jl"),
        String,
    ))
    analyze_isolated_script = read(
        joinpath(benchmark_directory, "profile_bmopf_analyze_runtime_isolated.jl"),
        String,
    )
    @test Meta.parseall(analyze_isolated_script) isa Expr
    @test occursin("isolated_process_per_case_and_repetition", analyze_isolated_script)
    @test occursin("bmopf_analyze_runtime_isolated_summary.json", analyze_isolated_script)
    analyze_isolated_summary = read(
        joinpath(repository_root, "docs", "bmopf_analyze_runtime_isolated_summary.json"),
        String,
    )
    @test occursin("nlpdiagnostics-bmopf-analyze-runtime-isolated-v1", analyze_isolated_summary)
    portability_script = read(
        joinpath(benchmark_directory, "validate_bmopf_analyze_portability.jl"),
        String,
    )
    @test Meta.parseall(portability_script) isa Expr
    @test occursin("comparison_required_for_portable_claim", portability_script)
    @test occursin("active_project", portability_script)
    @test occursin("semantic_comparison", portability_script)
    portability_summary = read(
        joinpath(repository_root, "docs", "bmopf_analyze_portability_summary.json"),
        String,
    )
    @test occursin("nlpdiagnostics-bmopf-analyze-portability-v1", portability_summary)
    portability_data = JSON.parse(portability_summary)
    @test portability_data["portable_evidence_status"] == "candidate_requires_review"
    @test portability_data["comparison"]["semantic_comparison"]["status"] == "semantics_match"
    @test portability_data["comparison"]["semantic_comparison"]["mismatch_count"] == 0
    @test portability_data["comparison"]["resource_comparison"]["status"] == "descriptive_only"
    @test portability_data["comparison"]["resource_comparison"]["matched_record_count"] == 6
    external_peak_script = read(
        joinpath(benchmark_directory, "probe_bmopf_analyze_external_peak.jl"),
        String,
    )
    @test Meta.parseall(external_peak_script) isa Expr
    @test occursin("getrusage(RUSAGE_CHILDREN)", external_peak_script)
    @test occursin("maximum resident set size", external_peak_script)
    external_peak_summary = read(
        joinpath(repository_root, "docs", "bmopf_analyze_external_peak_probe_summary.json"),
        String,
    )
    @test occursin("nlpdiagnostics-bmopf-analyze-external-peak-v1", external_peak_summary)
    external_peak_data = JSON.parse(external_peak_summary)
    @test external_peak_data["status"] in ("peak_telemetry_available", "peak_telemetry_unavailable")
    @test external_peak_data["child_status"] in ("completed", "completed_with_external_tool_error", "failed")
    if external_peak_data["status"] == "peak_telemetry_available"
        @test external_peak_data["external_peak_rss_bytes"] > 0
    end
    external_peak_clean_summary = read(
        joinpath(repository_root, "docs", "bmopf_analyze_external_peak_probe_clean_summary.json"),
        String,
    )
    @test occursin("nlpdiagnostics-bmopf-analyze-external-peak-v1", external_peak_clean_summary)
    external_peak_portability_script = read(
        joinpath(benchmark_directory, "compare_bmopf_analyze_external_peak.jl"),
        String,
    )
    @test Meta.parseall(external_peak_portability_script) isa Expr
    @test occursin("cross_environment_peak_candidate", external_peak_portability_script)
    @test occursin("comparison_required_for_portable_claim", external_peak_portability_script)
    external_peak_portability_summary = read(
        joinpath(repository_root, "docs", "bmopf_analyze_external_peak_portability_summary.json"),
        String,
    )
    @test occursin("nlpdiagnostics-bmopf-analyze-external-peak-comparison-v1", external_peak_portability_summary)
    external_peak_portability_data = JSON.parse(external_peak_portability_summary)
    @test external_peak_portability_data["status"] in ("cross_environment_peak_candidate", "candidate_requires_review")
    @test external_peak_portability_data["environment_distinct"] == true
    @test external_peak_portability_data["semantic_comparison"]["mismatch_count"] == 0
    analyze_ab_script = read(
        joinpath(benchmark_directory, "profile_analyze_static_optimization_ab.jl"),
        String,
    )
    @test Meta.parseall(analyze_ab_script) isa Expr
    @test occursin("cache_affine_coefficients", analyze_ab_script)
    @test occursin("analyze_static_optimization_ab_summary.json", read(
        joinpath(benchmark_directory, "summarize_analyze_scaling_readiness.jl"),
        String,
    ))
    static_source = read(joinpath(repository_root, "src", "analysis", "static.jl"), String)
    @test occursin("_affine_interval_rows", static_source)
    @test occursin("_affine_interval_target_rows", static_source)
    @test occursin("cache_affine_coefficients::Bool", static_source)
    @test occursin("cache_affine_target_terms::Bool", static_source)
    @test occursin("analyze_scaling_readiness_summary.json", read(
        joinpath(benchmark_directory, "build_calibration_release_gate_summary.jl"),
        String,
    ))
    isolated_runtime_script = read(
        joinpath(benchmark_directory, "profile_sparse_runtime_memory_isolated.jl"),
        String,
    )
    @test Meta.parseall(isolated_runtime_script) isa Expr
    @test occursin("isolated_process_per_dimension", isolated_runtime_script)
    @test occursin("Sys.maxrss", isolated_runtime_script)
    isolated_runtime_summary = read(
        joinpath(repository_root, "docs", "sparse_runtime_memory_isolated_summary.json"),
        String,
    )
    @test occursin("nlpdiagnostics-sparse-runtime-memory-isolated-v1", isolated_runtime_summary)
    @test occursin("\"isolated_process\": true", isolated_runtime_summary)
    isolated_runtime_data = JSON.parse(isolated_runtime_summary)
    @test isolated_runtime_data["record_count"] == 15
    @test isolated_runtime_data["source"]["dimensions"] == [16, 32, 64, 128, 256]
    @test occursin("sparse_runtime_memory_isolated_summary.json", read(
        joinpath(benchmark_directory, "build_calibration_release_gate_summary.jl"),
        String,
    ))
    sparse_runtime_trend_script = read(
        joinpath(benchmark_directory, "summarize_sparse_runtime_trends.jl"),
        String,
    )
    @test Meta.parseall(sparse_runtime_trend_script) isa Expr
    @test occursin("log_log_slopes", sparse_runtime_trend_script)
    sparse_runtime_trend_summary = read(
        joinpath(repository_root, "docs", "sparse_runtime_trend_summary.json"),
        String,
    )
    @test occursin("nlpdiagnostics-sparse-runtime-trend-v1", sparse_runtime_trend_summary)
    sparse_runtime_trend_data = JSON.parse(sparse_runtime_trend_summary)
    @test sparse_runtime_trend_data["workload_count"] == 3
    @test all(workload["point_count"] == 5 for workload in sparse_runtime_trend_data["workloads"])
    @test all(workload["repetitions_complete"] for workload in sparse_runtime_trend_data["workloads"])
    @test all(workload["dominant_stage_at_largest_dimension"]["stage"] == "static" for workload in sparse_runtime_trend_data["workloads"])
    @test all(workload["timing_repeatability_at_largest_dimension"]["stage_count"] > 0 for workload in sparse_runtime_trend_data["workloads"])
    @test all(workload["allocation_repeatability_at_largest_dimension"]["stage_count"] > 0 for workload in sparse_runtime_trend_data["workloads"])
    @test all(workload["timing_repeatability_at_largest_dimension"]["maximum_coefficient_of_variation"] < 0.5 for workload in sparse_runtime_trend_data["workloads"])
    @test occursin("sparse_runtime_trend_summary.json", read(
        joinpath(benchmark_directory, "build_calibration_release_gate_summary.jl"),
        String,
    ))
    @test occursin("timing_repeatability_at_largest_dimension", read(
        joinpath(benchmark_directory, "build_calibration_release_gate_summary.jl"),
        String,
    ))
    runtime_readiness_script = read(
        joinpath(benchmark_directory, "summarize_runtime_scaling_readiness.jl"),
        String,
    )
    @test Meta.parseall(runtime_readiness_script) isa Expr
    @test occursin("open_gaps", runtime_readiness_script)
    runtime_readiness_summary = JSON.parse(read(
        joinpath(repository_root, "docs", "runtime_scaling_readiness_summary.json"),
        String,
    ))
    @test runtime_readiness_summary["schema_version"] == "nlpdiagnostics-runtime-scaling-readiness-v1"
    @test runtime_readiness_summary["coverage_count"] == 5
    @test runtime_readiness_summary["open_gap_count"] == 3
    @test runtime_readiness_summary["coverage"][4]["measured_count"] == 3
    @test runtime_readiness_summary["coverage"][4]["guarded_count"] == 2
    solver_scaling_script = read(
        joinpath(benchmark_directory, "summarize_bmopf_solver_scaling_readiness.jl"),
        String,
    )
    @test Meta.parseall(solver_scaling_script) isa Expr
    @test occursin("full combined MV/LV model exceeds", solver_scaling_script)
    solver_scaling_summary = JSON.parse(read(
        joinpath(repository_root, "docs", "bmopf_solver_scaling_readiness_summary.json"),
        String,
    ))
    @test solver_scaling_summary["schema_version"] ==
          "nlpdiagnostics-bmopf-solver-scaling-readiness-v1"
    @test solver_scaling_summary["record_count"] == 5
    @test solver_scaling_summary["measured_count"] == 4
    @test solver_scaling_summary["guarded_count"] == 1
    @test solver_scaling_summary["dimensions"] == [4180, 4902, 56142]
    @test occursin("bmopf_solver_scaling_readiness_summary.json", read(
        joinpath(benchmark_directory, "build_calibration_release_gate_summary.jl"),
        String,
    ))
    solver_scaling_plan_script = read(
        joinpath(benchmark_directory, "plan_bmopf_solver_scaling_extension.jl"), String,
    )
    @test Meta.parseall(solver_scaling_plan_script) isa Expr
    @test occursin("expected_model_variable_count", solver_scaling_plan_script)
    solver_scaling_plan = JSON.parse(read(
        joinpath(repository_root, "docs", "bmopf_solver_scaling_extension_plan.json"), String,
    ))
    @test solver_scaling_plan["schema_version"] ==
          "nlpdiagnostics-bmopf-solver-scaling-extension-plan-v1"
    @test solver_scaling_plan["status"] == "ready_for_review"
    @test solver_scaling_plan["current_measured_count"] == 4
    @test length(solver_scaling_plan["planned_cases"]) == 2
    @test all(case["expected_model_variable_count"] == 11028 for case in solver_scaling_plan["planned_cases"])
    @test solver_scaling_plan["guards"]["child_process"] == true
    @test occursin("bmopf_solver_scaling_extension_plan.json", read(
        joinpath(benchmark_directory, "build_calibration_release_gate_summary.jl"),
        String,
    ))
    solver_scaling_extension_script = read(
        joinpath(benchmark_directory, "summarize_bmopf_solver_scaling_extension.jl"), String,
    )
    @test Meta.parseall(solver_scaling_extension_script) isa Expr
    @test occursin("locally_solved_trace", solver_scaling_extension_script)
    solver_scaling_extension = JSON.parse(read(
        joinpath(repository_root, "docs", "bmopf_solver_scaling_extension_summary.json"), String,
    ))
    @test solver_scaling_extension["schema_version"] ==
          "nlpdiagnostics-bmopf-solver-scaling-extension-v1"
    @test solver_scaling_extension["record_count"] == 2
    @test solver_scaling_extension["solved_count"] == 2
    @test solver_scaling_extension["timeout_count"] == 0
    @test solver_scaling_extension["incomplete_count"] == 0
    @test solver_scaling_extension["model_variable_counts"] == [11028]
    @test solver_scaling_extension["all_processes_completed"] == true
    @test solver_scaling_extension["all_trace_points_complete"] == true
    @test occursin("bmopf_solver_scaling_extension_summary.json", read(
        joinpath(benchmark_directory, "build_calibration_release_gate_summary.jl"),
        String,
    ))
    @test occursin("runtime_scaling_readiness_summary.json", read(
        joinpath(benchmark_directory, "build_calibration_release_gate_summary.jl"),
        String,
    ))
    solver_scaling_madnlp = JSON.parse(read(
        joinpath(repository_root, "docs", "bmopf_solver_scaling_extension_madnlp_summary.json"), String,
    ))
    @test solver_scaling_madnlp["schema_version"] ==
          "nlpdiagnostics-bmopf-solver-scaling-extension-v1"
    @test solver_scaling_madnlp["record_count"] == 2
    @test solver_scaling_madnlp["solved_count"] == 2
    @test solver_scaling_madnlp["timeout_count"] == 0
    @test solver_scaling_madnlp["incomplete_count"] == 0
    @test all(record["solver"] == "madnlp" for record in solver_scaling_madnlp["records"])
    cross_solver_script = read(
        joinpath(benchmark_directory, "summarize_bmopf_solver_scaling_cross_solver.jl"), String,
    )
    @test Meta.parseall(cross_solver_script) isa Expr
    @test occursin("Pair by exact snapshot path", cross_solver_script)
    cross_solver_summary = JSON.parse(read(
        joinpath(repository_root, "docs", "bmopf_solver_scaling_cross_solver_summary.json"), String,
    ))
    @test cross_solver_summary["schema_version"] ==
          "nlpdiagnostics-bmopf-solver-scaling-cross-solver-v1"
    @test cross_solver_summary["snapshot_pair_count"] == 2
    @test cross_solver_summary["both_solved_pair_count"] == 2
    @test cross_solver_summary["timeout_pair_count"] == 0
    @test occursin("bmopf_solver_scaling_cross_solver_summary.json", read(
        joinpath(benchmark_directory, "build_calibration_release_gate_summary.jl"), String,
    ))
    combined_large_probe_script = read(
        joinpath(benchmark_directory, "summarize_bmopf_combined_mv_lv_large_probe.jl"), String,
    )
    @test Meta.parseall(combined_large_probe_script) isa Expr
    @test occursin("one-iteration full-case solver startup", combined_large_probe_script)
    combined_large_probe = JSON.parse(read(
        joinpath(repository_root, "docs", "bmopf_combined_mv_lv_large_probe_summary.json"), String,
    ))
    @test combined_large_probe["schema_version"] ==
          "nlpdiagnostics-bmopf-combined-mv-lv-large-probe-v1"
    @test combined_large_probe["model_variable_count"] == 56142
    @test combined_large_probe["policy_count"] == 3
    @test combined_large_probe["all_reached_solver"] == true
    @test combined_large_probe["all_iteration_limited"] == true
    @test occursin("bmopf_combined_mv_lv_large_probe_summary.json", read(
        joinpath(benchmark_directory, "build_calibration_release_gate_summary.jl"), String,
    ))
    combined_budget_extension_script = read(
        joinpath(benchmark_directory, "summarize_bmopf_combined_mv_lv_budget_extension.jl"), String,
    )
    @test Meta.parseall(combined_budget_extension_script) isa Expr
    @test occursin("reviewed ten-iteration", combined_budget_extension_script)
    combined_budget_extension = JSON.parse(read(
        joinpath(repository_root, "docs", "bmopf_combined_mv_lv_budget_extension_summary.json"), String,
    ))
    @test combined_budget_extension["schema_version"] ==
          "nlpdiagnostics-bmopf-combined-mv-lv-budget-extension-v1"
    @test combined_budget_extension["model_variable_count"] == 56142
    @test combined_budget_extension["budgets"]["max_iter"] == 10
    @test combined_budget_extension["policy_count"] == 3
    @test combined_budget_extension["all_reached_solver"] == true
    @test combined_budget_extension["all_iteration_limited"] == true
    @test occursin("bmopf_combined_mv_lv_budget_extension_summary.json", read(
        joinpath(benchmark_directory, "build_calibration_release_gate_summary.jl"), String,
    ))
    combined_50iter_probe_script = read(
        joinpath(benchmark_directory, "summarize_bmopf_combined_mv_lv_50iter_probe.jl"), String,
    )
    @test Meta.parseall(combined_50iter_probe_script) isa Expr
    @test occursin("reviewed fifty-iteration", combined_50iter_probe_script)
    @test occursin("start_point_applied", read(
        joinpath(benchmark_directory, "bmopf_combined_mv_lv_scaling_campaign.jl"), String,
    ))
    @test occursin("bound_aware_missing_values", read(
        joinpath(benchmark_directory, "bmopf_combined_mv_lv_scaling_campaign.jl"), String,
    ))
    combined_50iter_probe = JSON.parse(read(
        joinpath(repository_root, "docs", "bmopf_combined_mv_lv_50iter_probe_summary.json"), String,
    ))
    @test combined_50iter_probe["schema_version"] ==
          "nlpdiagnostics-bmopf-combined-mv-lv-50iter-probe-v1"
    @test combined_50iter_probe["model_variable_count"] == 56142
    @test combined_50iter_probe["budgets"]["max_iter"] == 50
    @test combined_50iter_probe["policy_count"] == 3
    @test combined_50iter_probe["all_reached_solver"] == true
    @test combined_50iter_probe["all_iteration_limited"] == true
    @test combined_50iter_probe["all_infeasible_points"] == true
    @test combined_50iter_probe["all_starts_applied"] == true
    @test all(record["start_completion_policy"] ==
              "native_starts_plus_bound_aware_missing_values" for record in combined_50iter_probe["records"])
    @test all(record["start_values_bound_aware_count"] == 29064 for record in combined_50iter_probe["records"])
    @test all(record["start_values_native_count"] == 27078 for record in combined_50iter_probe["records"])
    @test all(record["start_values_missing_count"] == 29064 for record in combined_50iter_probe["records"])
    @test combined_50iter_probe["all_starts_applied"] == true
    @test occursin("bmopf_combined_mv_lv_50iter_probe_summary.json", read(
        joinpath(benchmark_directory, "build_calibration_release_gate_summary.jl"), String,
    ))
    feasibility_probe_script = read(
        joinpath(benchmark_directory, "bmopf_combined_mv_lv_feasibility_probe.jl"), String,
    )
    @test Meta.parseall(feasibility_probe_script) isa Expr
    @test occursin("solve_feasibility_opf", feasibility_probe_script)
    @test occursin("hard_kcl_zero_slack", feasibility_probe_script)
    feasibility_probe = JSON.parse(read(
        joinpath(repository_root, "docs", "bmopf_combined_mv_lv_feasibility_probe_summary.json"), String,
    ))
    @test feasibility_probe["schema_version"] ==
          "nlpdiagnostics-bmopf-combined-mv-lv-feasibility-probe-v1"
    @test feasibility_probe["status"] == "relaxed_feasibility_solved"
    @test feasibility_probe["network_shape"]["bus_count"] == 3409
    @test feasibility_probe["termination_status"] == "LOCALLY_SOLVED"
    @test feasibility_probe["relaxed_feasible"] == true
    @test feasibility_probe["hard_kcl_zero_slack"] == false
    @test feasibility_probe["initialization"]["finite_scalar_count"] == 53236
    @test feasibility_probe["total_slack_magnitude_A"] > 0.0
    @test occursin("bmopf_combined_mv_lv_feasibility_probe_summary.json", read(
        joinpath(benchmark_directory, "build_calibration_release_gate_summary.jl"), String,
    ))
    transfer_probe_script = read(
        joinpath(benchmark_directory, "bmopf_combined_mv_lv_feasibility_start_transfer.jl"), String,
    )
    @test Meta.parseall(transfer_probe_script) isa Expr
    @test occursin("feasibility_voltage_transfer", transfer_probe_script)
    @test occursin("solve_allocated_bytes", transfer_probe_script)
    @test occursin("allocator_stage_telemetry", transfer_probe_script)
    transfer_probe = JSON.parse(read(
        joinpath(repository_root, "docs", "bmopf_combined_mv_lv_feasibility_start_transfer_summary.json"), String,
    ))
    @test transfer_probe["schema_version"] ==
          "nlpdiagnostics-bmopf-combined-mv-lv-feasibility-start-transfer-v1"
    @test transfer_probe["status"] == "bounded_hard_opf_start_transfer"
    @test length(transfer_probe["records"]) == 2
    @test transfer_probe["records"][1]["termination_status"] == "ITERATION_LIMIT"
    @test transfer_probe["records"][2]["termination_status"] == "ITERATION_LIMIT"
    @test transfer_probe["records"][2]["transfer_applied"] == true
    @test transfer_probe["records"][2]["transferred_voltage_start_count"] == 13309
    @test transfer_probe["records"][2]["transferred_voltage_start_skipped_count"] == 0
    @test transfer_probe["records"][1]["solve_allocated_bytes"] > 0
    @test transfer_probe["records"][2]["solve_allocated_bytes"] > 0
    @test transfer_probe["relaxed_initialization"]["allocator_stage_telemetry"]["available"] == true
    @test all(haskey(record["allocator_stage_telemetry"], stage) for record in transfer_probe["records"] for stage in ("model_build", "start_application", "solve"))
    @test all(record["allocator_stage_telemetry"]["solve"]["available"] == true for record in transfer_probe["records"])
    @test occursin("bmopf_combined_mv_lv_feasibility_start_transfer_summary.json", read(
        joinpath(benchmark_directory, "build_calibration_release_gate_summary.jl"), String,
    ))
    isolated_transfer_script = read(
        joinpath(benchmark_directory, "profile_bmopf_combined_mv_lv_feasibility_start_transfer_isolated.jl"), String,
    )
    @test Meta.parseall(isolated_transfer_script) isa Expr
    @test occursin("Sys.maxrss", isolated_transfer_script)
    child_transfer_script = read(
        joinpath(benchmark_directory, "run_bmopf_combined_mv_lv_feasibility_start_transfer_child.jl"), String,
    )
    @test Meta.parseall(child_transfer_script) isa Expr
    isolated_transfer = JSON.parse(read(
        joinpath(repository_root, "docs", "bmopf_combined_mv_lv_feasibility_start_transfer_isolated_summary.json"), String,
    ))
    @test isolated_transfer["schema_version"] ==
          "nlpdiagnostics-bmopf-combined-mv-lv-feasibility-start-transfer-isolated-v1"
    @test isolated_transfer["record_count"] == 2
    @test isolated_transfer["measured_count"] == 2
    @test length(isolated_transfer["peak_rss_bytes_range"]) == 2
    @test isolated_transfer["allocator_peak_available_count"] == 0
    @test length(isolated_transfer["allocator_size_allocated_delta_bytes_range"]) == 2
    @test all(record["allocator_telemetry"]["after"]["available"] == true for record in isolated_transfer["records"])
    @test all(record["allocator_telemetry"]["peak_available"] == false for record in isolated_transfer["records"])
    @test all(record["relaxed_initialization"]["allocator_stage_telemetry"]["available"] == true for record in isolated_transfer["records"])
    @test all(record["records"][1]["allocator_stage_telemetry"]["solve"]["available"] == true for record in isolated_transfer["records"])
    @test all(record["records"][2]["allocator_stage_telemetry"]["solve"]["available"] == true for record in isolated_transfer["records"])
    @test all(record["isolated_process"] == true for record in isolated_transfer["records"])
    @test all(record["child_peak_rss_bytes"] > 0 for record in isolated_transfer["records"])
    @test all(record["status"] == "bounded_hard_opf_start_transfer" for record in isolated_transfer["records"])
    @test occursin("bmopf_combined_mv_lv_feasibility_start_transfer_isolated_summary.json", read(
        joinpath(benchmark_directory, "build_calibration_release_gate_summary.jl"), String,
    ))
    rank_perturbation_script = read(
        joinpath(benchmark_directory, "calibrate_rank_perturbation_sweep.jl"),
        String,
    )
    @test Meta.parseall(rank_perturbation_script) isa Expr
    @test occursin("threshold_sensitive", rank_perturbation_script)
    rank_perturbation_summary = read(
        joinpath(repository_root, "docs", "rank_perturbation_sweep_summary.json"),
        String,
    )
    @test occursin("nlpdiagnostics-rank-perturbation-sweep-v1", rank_perturbation_summary)
    @test occursin("\"record_count\": 40", rank_perturbation_summary)
    @test occursin("\"hard_control_mismatch_count\": 0", rank_perturbation_summary)
    @test occursin("\"unavailable_count\": 0", rank_perturbation_summary)
    rank_statistics_script = read(
        joinpath(benchmark_directory, "summarize_rank_calibration_statistics.jl"),
        String,
    )
    @test Meta.parseall(rank_statistics_script) isa Expr
    @test occursin("threshold_sensitive_controls", rank_statistics_script)
    rank_statistics_summary = read(
        joinpath(repository_root, "docs", "rank_calibration_statistics_summary.json"),
        String,
    )
    @test occursin("nlpdiagnostics-rank-calibration-statistics-v2", rank_statistics_summary)
    rank_statistics_data = JSON.parse(rank_statistics_summary)
    @test rank_statistics_data["hard_controls"]["record_count"] == 49
    @test rank_statistics_data["hard_controls"]["mismatch_count"] == 0
    @test rank_statistics_data["hard_controls"]["unavailable_count"] == 0
    @test rank_statistics_data["finite_sample_uncertainty"]["sample_count"] == 49
    @test rank_statistics_data["finite_sample_uncertainty"]["confidence_level"] == 0.95
    @test rank_statistics_data["finite_sample_uncertainty"]["zero_event_upper_bound"] > 0.05
    @test rank_statistics_data["finite_sample_uncertainty"]["zero_event_upper_bound"] < 0.07
    @test rank_statistics_data["threshold_sensitive_controls"]["record_count"] == 26
    @test rank_statistics_data["threshold_sensitive_controls"]["backend_disagreement_count"] == 9
    @test rank_statistics_data["large_sparse_sparse_only"]["record_count"] == 20
    @test rank_statistics_data["large_sparse_sparse_only"]["sparse_mismatch_count"] == 0
    @test occursin("cross_backend_calibration_matrix", rank_statistics_script)
    cross_backend_matrix = rank_statistics_data["cross_backend_calibration_matrix"]
    rank_adversarial_script = read(
        joinpath(benchmark_directory, "calibrate_rank_adversarial_extensions.jl"),
        String,
    )
    @test Meta.parseall(rank_adversarial_script) isa Expr
    @test occursin("duplicate_column_rank_deficient", rank_adversarial_script)
    rank_adversarial_summary = JSON.parse(read(
        joinpath(repository_root, "docs", "rank_adversarial_extension_summary.json"),
        String,
    ))
    @test rank_adversarial_summary["record_count"] == 8
    @test rank_adversarial_summary["hard_control_count"] == 6
    @test rank_adversarial_summary["hard_control_mismatch_count"] == 0
    @test rank_adversarial_summary["unavailable_count"] == 0
    @test length(cross_backend_matrix["corpus_rows"]) == 4
    @test cross_backend_matrix["hard_control_relation"]["agreement_count"] == 49
    @test cross_backend_matrix["threshold_relation"]["disagreement_count"] == 9
    @test cross_backend_matrix["sparse_only_relation"]["match_count"] == 20
    rank_third_backend_script = read(
        joinpath(benchmark_directory, "validate_rank_third_backend.jl"),
        String,
    )
    @test Meta.parseall(rank_third_backend_script) isa Expr
    @test occursin("adapter_registered", rank_third_backend_script)
    rank_third_backend_summary = JSON.parse(read(
        joinpath(repository_root, "docs", "rank_third_backend_capability_summary.json"),
        String,
    ))
    @test rank_third_backend_summary["schema_version"] ==
          "nlpdiagnostics-rank-third-backend-capability-v1"
    @test rank_third_backend_summary["status"] == "available_for_calibration"
    @test rank_third_backend_summary["adapter_status"] == "registered_internal_normal_eigen"
    @test rank_third_backend_summary["vetted_backend_count"] == 1
    @test rank_third_backend_summary["campaign_valid"] == true
    normal_eigen_script = read(
        joinpath(benchmark_directory, "calibrate_normal_eigen_rank_backend.jl"),
        String,
    )
    @test Meta.parseall(normal_eigen_script) isa Expr
    @test occursin("squares the condition number", normal_eigen_script)
    normal_eigen_summary = JSON.parse(read(
        joinpath(repository_root, "docs", "normal_eigen_rank_calibration_summary.json"),
        String,
    ))
    @test normal_eigen_summary["schema_version"] ==
          "nlpdiagnostics-normal-eigen-rank-calibration-v1"
    @test normal_eigen_summary["record_count"] == 20
    @test normal_eigen_summary["hard_control_count"] == 15
    @test normal_eigen_summary["hard_control_mismatch_count"] == 0
    @test normal_eigen_summary["threshold_backend_disagreement_count"] == 4
    @test rank_statistics_data["third_backend_capability"]["status"] == "available_for_calibration"
    @test rank_statistics_data["normal_eigen_calibration"]["record_count"] == 20
    normal_eigen_persistence_script = read(
        joinpath(benchmark_directory, "calibrate_normal_eigen_policy_persistence.jl"),
        String,
    )
    @test Meta.parseall(normal_eigen_persistence_script) isa Expr
    @test occursin("principal_cosine", normal_eigen_persistence_script)
    normal_eigen_persistence_summary = JSON.parse(read(
        joinpath(repository_root, "docs", "normal_eigen_policy_persistence_summary.json"),
        String,
    ))
    @test normal_eigen_persistence_summary["schema_version"] ==
          "nlpdiagnostics-normal-eigen-policy-persistence-v1"
    @test normal_eigen_persistence_summary["case_count"] == 3
    @test normal_eigen_persistence_summary["policy_record_count"] == 12
    @test normal_eigen_persistence_summary["unavailable_count"] == 0
    @test normal_eigen_persistence_summary["repeatability_failure_count"] == 3
    @test rank_statistics_data["normal_eigen_policy_persistence"]["policy_record_count"] == 12
    bmopf_normal_eigen_script = read(
        joinpath(benchmark_directory, "bmopf_normal_eigen_jacobian_validation.jl"),
        String,
    )
    @test Meta.parseall(bmopf_normal_eigen_script) isa Expr
    @test occursin("trusted BMOPF endpoints", bmopf_normal_eigen_script)
    @test occursin("size-guarded before optimization", bmopf_normal_eigen_script)
    bmopf_normal_eigen_summary = JSON.parse(read(
        joinpath(repository_root, "docs", "bmopf_normal_eigen_jacobian_validation_summary.json"),
        String,
    ))
    @test bmopf_normal_eigen_summary["schema_version"] ==
          "nlpdiagnostics-bmopf-normal-eigen-jacobian-validation-v1"
    @test bmopf_normal_eigen_summary["snapshot_count"] == 4
    @test bmopf_normal_eigen_summary["successful_snapshot_count"] == 3
    @test bmopf_normal_eigen_summary["size_guarded_snapshot_count"] == 1
    @test bmopf_normal_eigen_summary["policy_record_count"] == 12
    @test bmopf_normal_eigen_summary["all_policy_records_available"] == false
    @test bmopf_normal_eigen_summary["cross_backend_agreement_count"] == 8
    @test bmopf_normal_eigen_summary["cross_backend_disagreement_count"] == 0
    @test bmopf_normal_eigen_summary["cross_backend_unavailable_count"] == 4
    large_sparse_screen_script = read(
        joinpath(benchmark_directory, "summarize_bmopf_large_sparse_rank_screen.jl"),
        String,
    )
    @test Meta.parseall(large_sparse_screen_script) isa Expr
    @test occursin("synthetic coordinate probe", large_sparse_screen_script)
    large_sparse_screen_summary = JSON.parse(read(
        joinpath(repository_root, "docs", "bmopf_large_sparse_rank_screen_summary.json"),
        String,
    ))
    @test large_sparse_screen_summary["schema_version"] ==
          "nlpdiagnostics-bmopf-large-sparse-rank-screen-v1"
    @test large_sparse_screen_summary["status"] == "ok"
    @test large_sparse_screen_summary["model_variable_count"] == 11028
    @test large_sparse_screen_summary["sparse_qr"]["comparison"]["unscaled_rank"] == 9849
    @test large_sparse_screen_summary["sparse_qr"]["comparison"]["row_column_rank"] == 9850
    @test large_sparse_screen_summary["sparse_qr"]["comparison"]["scaling_sensitive"] == true
    @test rank_statistics_data["large_sparse_bmopf_screen"]["scaling_sensitive"] == true
    large_sparse_saved_summary = JSON.parse(read(
        joinpath(repository_root, "docs", "bmopf_large_sparse_rank_screen_saved_result_summary.json"),
        String,
    ))
    @test large_sparse_saved_summary["status"] == "ok"
    @test large_sparse_saved_summary["evaluation"]["point_provenance_kind"] == "SolverResultPoint"
    @test large_sparse_saved_summary["evaluation"]["point_provenance_complete"] == true
    @test large_sparse_saved_summary["sparse_qr"]["comparison"]["unscaled_rank"] == 11028
    @test large_sparse_saved_summary["sparse_qr"]["comparison"]["row_column_rank"] == 11028
    @test large_sparse_saved_summary["sparse_qr"]["comparison"]["scaling_sensitive"] == false
    @test rank_statistics_data["large_sparse_bmopf_saved_result_screen"]["point_provenance_complete"] == true
    saved_result_campaign_script = read(
        joinpath(benchmark_directory, "summarize_bmopf_saved_result_sparse_rank_campaign.jl"),
        String,
    )
    @test Meta.parseall(saved_result_campaign_script) isa Expr
    merged_campaign_script = read(
        joinpath(benchmark_directory, "merge_bmopf_saved_result_sparse_rank_campaign.jl"),
        String,
    )
    @test Meta.parseall(merged_campaign_script) isa Expr
    saved_result_campaign_summary = JSON.parse(read(
        joinpath(repository_root, "docs", "bmopf_saved_result_sparse_rank_campaign_summary.json"),
        String,
    ))
    @test saved_result_campaign_summary["schema_version"] ==
          "nlpdiagnostics-bmopf-saved-result-sparse-rank-campaign-v1"
    @test saved_result_campaign_summary["record_count"] == 102
    @test saved_result_campaign_summary["result_units"] == ["pu", "si"]
    @test saved_result_campaign_summary["all_point_provenance_complete"] == true
    @test saved_result_campaign_summary["all_sparse_estimates_available"] == true
    @test saved_result_campaign_summary["scaling_sensitive_count"] == 0
    @test saved_result_campaign_summary["scaling_stable_count"] == 102
    saved_result_endpoint_spans = saved_result_campaign_summary["endpoint_span_diagnostics"]
    @test saved_result_endpoint_spans["overall"]["rank_delta"]["range"] == 0
    @test saved_result_endpoint_spans["by_result_units"]["pu"]["record_count"] == 50
    @test saved_result_endpoint_spans["by_result_units"]["si"]["record_count"] == 52
    @test saved_result_endpoint_spans["by_result_units"]["pu"]["spans"]["unscaled_condition_proxy"]["max"] > 1.0e9
    t15_t16_tranche_script = read(
        joinpath(benchmark_directory, "summarize_bmopf_t15t16_tranche.jl"), String,
    )
    @test Meta.parseall(t15_t16_tranche_script) isa Expr
    @test occursin("nlpdiagnostics-bmopf-t15-t16-tranche-v1", t15_t16_tranche_script)
    t15_t16_tranche_summary = JSON.parse(read(
        joinpath(repository_root, "docs", "bmopf_t15_t16_tranche_summary.json"), String,
    ))
    @test t15_t16_tranche_summary["schema_version"] ==
          "nlpdiagnostics-bmopf-t15-t16-tranche-v1"
    @test t15_t16_tranche_summary["endpoint_count"] == 8
    @test t15_t16_tranche_summary["snapshot_count"] == 4
    @test t15_t16_tranche_summary["paired_snapshot_count"] == 4
    @test t15_t16_tranche_summary["mapping_complete_endpoint_count"] == 8
    @test t15_t16_tranche_summary["unit_dependent_rank_outcome_count"] == 0
    @test t15_t16_tranche_summary["scaling_sensitive_endpoint_count"] == 0
    @test t15_t16_tranche_summary["all_mapping_complete"] == true
    @test t15_t16_tranche_summary["all_sparse_estimates_available"] == true
    threshold_disagreement_script = read(
        joinpath(benchmark_directory, "summarize_rank_threshold_disagreements.jl"), String,
    )
    @test Meta.parseall(threshold_disagreement_script) isa Expr
    threshold_disagreement_summary = JSON.parse(read(
        joinpath(repository_root, "docs", "rank_threshold_disagreement_summary.json"), String,
    ))
    @test threshold_disagreement_summary["schema_version"] ==
          "nlpdiagnostics-rank-threshold-disagreement-v1"
    @test threshold_disagreement_summary["corpus_count"] == 3
    @test threshold_disagreement_summary["hard_control_mismatch_count"] == 0
    @test threshold_disagreement_summary["hard_control_unavailable_count"] == 0
    @test threshold_disagreement_summary["threshold_sensitive_count"] == 26
    @test threshold_disagreement_summary["threshold_backend_disagreement_count"] == 9
    calibration_results = read(joinpath(repository_root, "docs", "calibration_results.md"), String)
    @test occursin("declared numerical-rank policy boundary", calibration_results)
    @test occursin("threshold_policy_sensitivity", calibration_results)
    threshold_policy_review_script = read(
        joinpath(benchmark_directory, "review_rank_threshold_policy.jl"), String,
    )
    @test Meta.parseall(threshold_policy_review_script) isa Expr
    threshold_policy_review = JSON.parse(read(
        joinpath(repository_root, "docs", "rank_threshold_policy_review_summary.json"), String,
    ))
    @test threshold_policy_review["schema_version"] ==
          "nlpdiagnostics-rank-threshold-policy-review-v1"
    @test threshold_policy_review["status"] == "review_required"
    @test threshold_policy_review["evidence_consistent"] == true
    @test threshold_policy_review["decision"] === nothing
    sensitive_saved_records = filter(
        record -> record["scaling_sensitive"] == true,
        saved_result_campaign_summary["records"],
    )
    @test isempty(sensitive_saved_records)
    scaling_diagnostics_script = read(
        joinpath(benchmark_directory, "summarize_bmopf_saved_result_scaling_diagnostics.jl"),
        String,
    )
    @test Meta.parseall(scaling_diagnostics_script) isa Expr
    scaling_diagnostics_summary = JSON.parse(read(
        joinpath(repository_root, "docs", "bmopf_saved_result_scaling_diagnostics_summary.json"),
        String,
    ))
    @test scaling_diagnostics_summary["schema_version"] ==
          "nlpdiagnostics-bmopf-saved-result-scaling-diagnostics-v1"
    @test scaling_diagnostics_summary["campaign_record_count"] == 102
    @test scaling_diagnostics_summary["paired_snapshot_count"] == 50
    @test scaling_diagnostics_summary["unit_dependent_rank_outcome_count"] == 0
    @test scaling_diagnostics_summary["incomplete_provenance_sensitive_record_count"] == 0
    @test scaling_diagnostics_summary["incomplete_provenance_record_count"] == 0
    @test scaling_diagnostics_summary["sensitive_mapping_fallback_coordinate_counts"] == []
    @test rank_statistics_data["saved_result_bmopf_campaign"]["scaling_sensitive_count"] == 0
    @test rank_statistics_data["saved_result_bmopf_campaign"]["scaling_stable_count"] == 102
    time_coverage_summary = JSON.parse(read(
        joinpath(repository_root, "docs", "bmopf_538bus_saved_result_time_coverage_summary.json"),
        String,
    ))
    @test time_coverage_summary["schema_version"] ==
          "nlpdiagnostics-bmopf-538bus-saved-result-time-coverage-v1"
    @test time_coverage_summary["snapshot_count"] == 50
    @test time_coverage_summary["available_endpoint_count"] == 100
    @test time_coverage_summary["profiled_endpoint_count"] == 100
    @test time_coverage_summary["unprofiled_endpoint_count"] == 0
    @test time_coverage_summary["available_unit_counts"] == Dict("pu" => 50, "si" => 50)
    saved_result_quality_script = read(
        joinpath(benchmark_directory, "summarize_bmopf_saved_result_quality.jl"),
        String,
    )
    @test Meta.parseall(saved_result_quality_script) isa Expr
    saved_result_quality_summary = JSON.parse(read(
        joinpath(repository_root, "docs", "bmopf_saved_result_quality_summary.json"),
        String,
    ))
    @test saved_result_quality_summary["schema_version"] ==
          "nlpdiagnostics-bmopf-saved-result-quality-v1"
    @test saved_result_quality_summary["endpoint_count"] == 100
    @test saved_result_quality_summary["available_endpoint_count"] == 100
    @test saved_result_quality_summary["usable_solver_endpoint_count"] == 100
    @test saved_result_quality_summary["nonfinite_or_unsolved_endpoint_count"] == 0
    @test saved_result_quality_summary["missing_endpoint_count"] == 0
    @test saved_result_quality_summary["termination_status_counts"]["LOCALLY_SOLVED"] == 100
    @test !haskey(saved_result_quality_summary["termination_status_counts"], "ITERATION_LIMIT")
    saved_result_rerun_script = read(
        joinpath(benchmark_directory, "summarize_bmopf_si_rerun.jl"),
        String,
    )
    @test Meta.parseall(saved_result_rerun_script) isa Expr
    saved_result_rerun_summary = JSON.parse(read(
        joinpath(repository_root, "docs", "bmopf_si_bounded_rerun_summary.json"),
        String,
    ))
    @test saved_result_rerun_summary["schema_version"] ==
          "nlpdiagnostics-bmopf-si-bounded-rerun-v1"
    @test saved_result_rerun_summary["case_count"] == 7
    @test saved_result_rerun_summary["bounded_success_count"] == 7
    @test saved_result_rerun_summary["bounded_failure_count"] == 0
    @test saved_result_rerun_summary["all_bounded_successes"] == true
    @test all(record["solver_log_evidence"]["optimal_solution"] === true
              for record in saved_result_rerun_summary["records"])
    rerun_candidate_validator = read(
        joinpath(benchmark_directory, "validate_bmopf_rerun_candidates.jl"),
        String,
    )
    @test Meta.parseall(rerun_candidate_validator) isa Expr
    rerun_candidate_summary = JSON.parse(read(
        joinpath(repository_root, "docs", "bmopf_si_rerun_candidate_validation_summary.json"),
        String,
    ))
    @test rerun_candidate_summary["schema_version"] ==
          "nlpdiagnostics-bmopf-rerun-candidate-validation-v1"
    @test rerun_candidate_summary["candidate_count"] == 7
    @test rerun_candidate_summary["candidate_available_count"] == 7
    @test rerun_candidate_summary["candidate_usable_solver_endpoint_count"] == 7
    @test rerun_candidate_summary["candidate_nonfinite_or_unsolved_count"] == 0
    @test rerun_candidate_summary["all_candidates_usable"] == true
    promoted_sparse_script = read(
        joinpath(benchmark_directory, "summarize_bmopf_promoted_sparse_rank.jl"),
        String,
    )
    @test Meta.parseall(promoted_sparse_script) isa Expr
    promoted_sparse_summary = JSON.parse(read(
        joinpath(repository_root, "docs", "bmopf_promoted_sparse_rank_summary.json"),
        String,
    ))
    @test promoted_sparse_summary["schema_version"] ==
          "nlpdiagnostics-bmopf-promoted-sparse-rank-v1"
    @test promoted_sparse_summary["record_count"] == 7
    @test promoted_sparse_summary["before_incomplete_provenance_count"] == 7
    @test promoted_sparse_summary["after_incomplete_mapping_count"] == 0
    @test promoted_sparse_summary["before_scaling_sensitive_count"] == 4
    @test promoted_sparse_summary["after_scaling_sensitive_count"] == 0
    @test promoted_sparse_summary["all_after_mappings_complete"] == true
    smallest_singular_script = read(
        joinpath(benchmark_directory, "summarize_smallest_singular_calibration.jl"),
        String,
    )
    @test Meta.parseall(smallest_singular_script) isa Expr
    @test occursin("dense_free_crosscheck", smallest_singular_script)
    smallest_singular_summary = JSON.parse(read(
        joinpath(repository_root, "docs", "smallest_singular_calibration_summary.json"),
        String,
    ))
    @test smallest_singular_summary["schema_version"] == "nlpdiagnostics-smallest-singular-calibration-v1"
    @test smallest_singular_summary["case_count"] == 10
    @test smallest_singular_summary["all_expectations_matched"] == true
    @test smallest_singular_summary["dense_free_crosscheck"]["agreement_count"] == 7
    @test smallest_singular_summary["dense_free_crosscheck"]["adverse_relation_count"] == 3
    @test occursin("rank_calibration_statistics_summary.json", read(
        joinpath(benchmark_directory, "build_calibration_release_gate_summary.jl"),
        String,
    ))
    @test occursin("finite-sample", read(
        joinpath(benchmark_directory, "build_calibration_release_gate_summary.jl"),
        String,
    ))
    @test occursin("smallest_singular_calibration_summary.json", read(
        joinpath(benchmark_directory, "build_calibration_release_gate_summary.jl"),
        String,
    ))
    kkt_stability_script = read(
        joinpath(benchmark_directory, "summarize_real_99bus_kkt_stability.jl"),
        String,
    )
    @test Meta.parseall(kkt_stability_script) isa Expr
    @test occursin("strict_kkt_qualified", kkt_stability_script)
    kkt_stability_summary = read(
        joinpath(repository_root, "docs", "real_99bus_kkt_stability_summary.json"),
        String,
    )
    @test occursin("nlpdiagnostics-real-99bus-kkt-stability-v1", kkt_stability_summary)
    @test occursin("\"profile_count\": 20", kkt_stability_summary)
    @test occursin("\"qualified_profile_count\": 14", kkt_stability_summary)
    @test occursin("\"strict_acceptance_count_is_stable\": true", kkt_stability_summary)
    kkt_margin_script = read(
        joinpath(benchmark_directory, "summarize_real_99bus_kkt_margin.jl"),
        String,
    )
    @test Meta.parseall(kkt_margin_script) isa Expr
    @test occursin("required_tolerance", kkt_margin_script)
    @test occursin("does_not_establish", kkt_margin_script)
    kkt_margin_summary = read(
        joinpath(repository_root, "docs", "real_99bus_kkt_margin_summary.json"),
        String,
    )
    @test occursin("nlpdiagnostics-real-99bus-kkt-margin-v1", kkt_margin_summary)
    kkt_margin_data = JSON.parse(kkt_margin_summary)
    @test kkt_margin_data["profile_count"] == 6
    @test kkt_margin_data["strict_failed_snapshot_count"] == 4
    @test kkt_margin_data["strict_passed_snapshot_count"] == 2
    @test kkt_margin_data["maximum_required_tolerance"] > 1.0e-5
    @test kkt_margin_data["maximum_required_tolerance"] < 1.2e-5
    @test kkt_margin_data["required_tolerance_quantiles"]["paired_endpoint_maximum"]["count"] == 6
    @test kkt_margin_data["required_tolerance_quantiles"]["paired_endpoint_maximum"]["p95"] > 1.1e-5
    @test kkt_margin_data["required_tolerance_quantiles"]["paired_endpoint_maximum"]["p95"] < 1.2e-5
    @test occursin("real_99bus_kkt_margin_summary.json", read(
        joinpath(benchmark_directory, "build_calibration_release_gate_summary.jl"),
        String,
    ))
    @test occursin("paired-endpoint p95", read(
        joinpath(benchmark_directory, "build_calibration_release_gate_summary.jl"),
        String,
    ))
    kkt_distribution_script = read(
        joinpath(benchmark_directory, "summarize_real_99bus_kkt_residual_distributions.jl"),
        String,
    )
    @test Meta.parseall(kkt_distribution_script) isa Expr
    @test occursin("failed_side_residuals", kkt_distribution_script)
    kkt_distribution_summary = read(
        joinpath(repository_root, "docs", "real_99bus_kkt_residual_distribution_summary.json"),
        String,
    )
    @test occursin("nlpdiagnostics-real-99bus-kkt-residual-distribution-v1", kkt_distribution_summary)
    kkt_distribution_data = JSON.parse(kkt_distribution_summary)
    @test kkt_distribution_data["profile_count"] == 6
    @test kkt_distribution_data["reference_strict_acceptance_count"] == 2
    @test kkt_distribution_data["phase_only_strict_acceptance_count"] == 2
    @test length(kkt_distribution_data["paired_maximum_residual_ratio_range"]) == 2
    @test maximum(kkt_distribution_data["paired_maximum_residual_ratio_range"]) < 1.000001
    @test minimum(kkt_distribution_data["paired_maximum_residual_ratio_range"]) > 0.999999
    @test occursin("real_99bus_kkt_residual_distribution_summary.json", read(
        joinpath(benchmark_directory, "build_calibration_release_gate_summary.jl"),
        String,
    ))
    kkt_policy_script = read(
        joinpath(benchmark_directory, "summarize_real_99bus_kkt_tolerance_policies.jl"),
        String,
    )
    @test Meta.parseall(kkt_policy_script) isa Expr
    @test occursin("first_observed_full_paired_acceptance_policy", kkt_policy_script)
    kkt_policy_summary = read(
        joinpath(repository_root, "docs", "real_99bus_kkt_tolerance_policy_summary.json"),
        String,
    )
    @test occursin("nlpdiagnostics-real-99bus-kkt-tolerance-policy-v1", kkt_policy_summary)
    kkt_policy_data = JSON.parse(kkt_policy_summary)
    @test kkt_policy_data["run_count"] == 6
    @test kkt_policy_data["policy_count"] == 5
    @test kkt_policy_data["strict_reference_acceptance_count"] == 2
    @test kkt_policy_data["strict_phase_only_acceptance_count"] == 2
    @test kkt_policy_data["first_observed_full_paired_acceptance_policy"] == "1.2e-5"
    @test occursin("real_99bus_kkt_tolerance_policy_summary.json", read(
        joinpath(benchmark_directory, "build_calibration_release_gate_summary.jl"),
        String,
    ))
    kkt_endpoint_script = read(
        joinpath(benchmark_directory, "summarize_real_99bus_kkt_endpoint_matrix.jl"),
        String,
    )
    @test Meta.parseall(kkt_endpoint_script) isa Expr
    @test occursin("paired_strict_tolerance_ratio", kkt_endpoint_script)
    kkt_endpoint_summary = JSON.parse(read(
        joinpath(repository_root, "docs", "real_99bus_kkt_endpoint_matrix_summary.json"),
        String,
    ))
    @test kkt_endpoint_summary["schema_version"] == "nlpdiagnostics-real-99bus-kkt-endpoint-matrix-v1"
    @test kkt_endpoint_summary["endpoint_count"] == 6
    @test kkt_endpoint_summary["strict_paired_acceptance_count"] == 2
    @test kkt_endpoint_summary["strict_paired_failure_count"] == 4
    @test kkt_endpoint_summary["all_failures_localized"] == true
    @test occursin("real_99bus_kkt_endpoint_matrix_summary.json", read(
        joinpath(benchmark_directory, "build_calibration_release_gate_summary.jl"),
        String,
    ))
    kkt_boundary_review_script = read(
        joinpath(benchmark_directory, "review_real_99bus_kkt_boundary.jl"), String,
    )
    @test Meta.parseall(kkt_boundary_review_script) isa Expr
    @test occursin("retain_strict_gate", kkt_boundary_review_script)
    kkt_boundary_review = JSON.parse(read(
        joinpath(repository_root, "docs", "real_99bus_kkt_boundary_review_summary.json"), String,
    ))
    @test kkt_boundary_review["schema_version"] ==
          "nlpdiagnostics-real-99bus-kkt-boundary-review-v1"
    @test kkt_boundary_review["status"] == "review_required"
    @test kkt_boundary_review["evidence_consistent"] == true
    @test kkt_boundary_review["strict_tolerance"] == 1.0e-5
    @test kkt_boundary_review["strict_paired_acceptance_count"] == 2
    @test kkt_boundary_review["strict_paired_failure_count"] == 4
    @test kkt_boundary_review["decision"] === nothing
    @test occursin("real_99bus_kkt_boundary_review_summary.json", read(
        joinpath(benchmark_directory, "build_calibration_release_gate_summary.jl"),
        String,
    ))
    kkt_gate_validation_script = read(
        joinpath(benchmark_directory, "validate_real_99bus_kkt_gate.jl"),
        String,
    )
    @test Meta.parseall(kkt_gate_validation_script) isa Expr
    @test occursin("strict_acceptance_matches_distribution", kkt_gate_validation_script)
    kkt_gate_validation_summary = JSON.parse(read(
        joinpath(repository_root, "docs", "real_99bus_kkt_gate_validation_summary.json"),
        String,
    ))
    @test kkt_gate_validation_summary["schema_version"] ==
          "nlpdiagnostics-real-99bus-kkt-gate-validation-v1"
    @test kkt_gate_validation_summary["status"] == "consistent_partial"
    @test kkt_gate_validation_summary["all_checks_passed"] == true
    @test kkt_gate_validation_summary["strict_gate"]["paired_pass_count"] == 2
    @test kkt_gate_validation_summary["strict_gate"]["paired_failure_count"] == 4
    @test occursin("real_99bus_kkt_gate_validation_summary.json", read(
        joinpath(benchmark_directory, "build_calibration_release_gate_summary.jl"),
        String,
    ))
    bmopf_analyze_profile_script = read(
        joinpath(benchmark_directory, "profile_bmopf_analyze_runtime.jl"),
        String,
    )
    @test Meta.parseall(bmopf_analyze_profile_script) isa Expr
    @test occursin("skipped_size_guard", bmopf_analyze_profile_script)
    @test occursin("powerio_warning_count", bmopf_analyze_profile_script)
    bmopf_analyze_profile_summary = read(
        joinpath(repository_root, "docs", "bmopf_analyze_runtime_profile_summary.json"),
        String,
    )
    @test occursin("nlpdiagnostics-bmopf-analyze-runtime-profile-v2", bmopf_analyze_profile_summary)
    @test occursin("pf_1ph_line.dss", bmopf_analyze_profile_summary)
    @test occursin("pf_cap_wye.dss", bmopf_analyze_profile_summary)
    @test occursin("skipped_size_guard", bmopf_analyze_profile_summary)
    @test occursin("warmup_analyze_seconds", bmopf_analyze_profile_summary)
    @test occursin("\"static\"", analyze_scaling_summary)
    @test occursin("\"expressions\"", analyze_scaling_summary)
    @test occursin("Stage attribution is now recorded", read(
        joinpath(benchmark_directory, "build_calibration_release_gate_summary.jl"),
        String,
    ))
    consolidation_summary = read(
        joinpath(repository_root, "docs", "api_test_benchmark_consolidation_summary.json"),
        String,
    )
    @test occursin("\"benchmark_script_count\": 165", consolidation_summary)
    @test occursin("\"shared_benchmark_helper_user_count\": 162", consolidation_summary)
    @test occursin("\"json_schema_file_count\": 107", consolidation_summary)
    @test occursin("\"unclassified_non_helper_benchmark_paths\": []", consolidation_summary)
    active_bmopf_contract = read(
        joinpath(repository_root, "docs", "bmopf_api_contract_summary.json"),
        String,
    )
    clean_bmopf_contract = read(
        joinpath(repository_root, "docs", "bmopf_api_contract_clean_main_summary.json"),
        String,
    )
    handoff_summary = read(
        joinpath(repository_root, "docs", "bmopf_pr_handoff_summary.json"),
        String,
    )
    checkout_validation_summary = read(
        joinpath(repository_root, "docs", "bmopf_checkout_validation_summary.json"),
        String,
    )
    @test occursin("\"status\": \"pass\"", active_bmopf_contract)
    @test occursin("\"status\": \"pass\"", clean_bmopf_contract)
    @test occursin("\"handoff_passed\": true", handoff_summary)
    @test occursin("\"status\": \"pass\"", checkout_validation_summary)
    @test occursin("\"suite_passed\": 1801", checkout_validation_summary)
    voltage_start_api_script = read(
        joinpath(benchmark_directory, "audit_bmopf_voltage_start_api.jl"), String,
    )
    @test Meta.parseall(voltage_start_api_script) isa Expr
    @test occursin("set_opf_voltage_start_values!", voltage_start_api_script)
    voltage_start_api = JSON.parse(read(
        joinpath(repository_root, "docs", "bmopf_voltage_start_api_summary.json"), String,
    ))
    @test voltage_start_api["schema_version"] ==
          "nlpdiagnostics-bmopf-voltage-start-api-v1"
    @test voltage_start_api["status"] == "proposal_required"
    @test voltage_start_api["current_workaround"]["uses_internal_context_variable_ledger"] == true
    @test voltage_start_api["current_workaround"]["stable_api_ready"] == false
    @test voltage_start_api["existing_public_symbols"]["build_opf_model"] == true
    @test length(voltage_start_api["proposal_missing_symbols"]) == 2
    @test voltage_start_api["proposal_document"]["exists"] == true
    @test voltage_start_api["proposal_document"]["ready_for_upstream_review"] == true
    @test occursin("bmopf_voltage_start_api_proposal.md", read(
        joinpath(benchmark_directory, "build_calibration_release_gate_summary.jl"), String,
    ))
    @test occursin("bmopf_voltage_start_api_summary.json", read(
        joinpath(benchmark_directory, "build_calibration_release_gate_summary.jl"), String,
    ))
    ownership_review_script = read(
        joinpath(benchmark_directory, "review_api_ownership_decisions.jl"),
        String,
    )
    @test Meta.parseall(ownership_review_script) isa Expr
    @test occursin("retain_root_compatibility", ownership_review_script)
    ownership_review_summary = JSON.parse(read(
        joinpath(repository_root, "docs", "api_ownership_decision_summary.json"),
        String,
    ))
    @test ownership_review_summary["schema_version"] ==
          "nlpdiagnostics-api-ownership-decisions-v1"
    @test ownership_review_summary["reviewed_count"] == 92
    @test ownership_review_summary["root_compatibility_retained_count"] == 44
    @test ownership_review_summary["advanced_candidate_count"] == 48
    @test ownership_review_summary["migration_allowed_count"] == 0
    @test ownership_review_summary["batch_summary"]["prior_reviewed_count"] == 68
    @test ownership_review_summary["batch_summary"]["next_batch_count"] == 24
    @test ownership_review_summary["batch_summary"]["next_batch_reviewed_count"] == 24
    @test occursin("api_ownership_decision_summary.json", read(
        joinpath(benchmark_directory, "build_calibration_release_gate_summary.jl"),
        String,
    ))
    checkout_validator = read(
        joinpath(benchmark_directory, "validate_bmopf_checkout.jl"),
        String,
    )
    @test occursin("--compiled-modules=no", checkout_validator)
    consolidation_audit = read(
        joinpath(benchmark_directory, "audit_api_test_benchmark_consolidation.jl"),
        String,
    )
    @test occursin("uses_shared_helper", consolidation_audit)
    magnitude_campaign = read(
        joinpath(
            benchmark_directory, "bmopf_magnitude_scaling_campaign.jl",
        ),
        String,
    )
    @test occursin("bmopf-magnitude-scaling-campaign-v1", magnitude_campaign)
    @test occursin("bmopf_transport_scaling_point", magnitude_campaign)
    @test occursin("physical_endpoint_equivalence_report", magnitude_campaign)
    @test occursin("scaling_solver_experiment_campaign_data", magnitude_campaign)
    @test occursin("provenance_mismatch_rejected", magnitude_campaign)
    acdc_campaign = read(
        joinpath(
            benchmark_directory, "bmopf_acdc_scaling_campaign.jl",
        ),
        String,
    )
    @test occursin("bmopf-acdc-scaling-campaign-v1", acdc_campaign)
    @test occursin("bmopf_acdc_scaling_contract_data", acdc_campaign)
    @test occursin("acdc_scaling_contract_gate", acdc_campaign)
    @test occursin("bmopf_stratified_scaling_campaign.jl", acdc_campaign)
    @test occursin("scaling_solver_experiment_stratified_campaign_data",
        acdc_campaign)
    @test occursin("policy_ranking_performed", acdc_campaign)
    @test occursin("require_canonical_voltage_pattern=false", acdc_campaign)
    @test occursin("require_phasor_transport=true", acdc_campaign)
    @test occursin("NLPDIAGNOSTICS_ACDC_PERTURBATION", acdc_campaign)
    @test occursin("reactive_converter_power_fixed", acdc_campaign)
    @test occursin("at least one perturbed-start seed", acdc_campaign)
    acdc_grid_campaign = read(
        joinpath(
            benchmark_directory, "bmopf_acdc_base_grid_campaign.jl",
        ),
        String,
    )
    @test occursin("bmopf-acdc-base-grid-campaign-v1", acdc_grid_campaign)
    @test occursin("full 2^3 two-level factorial", acdc_grid_campaign)
    @test occursin("_ACDC_GRID_EFFECT_SPECS", acdc_grid_campaign)
    @test occursin("factorial_analysis_gates_passed", acdc_grid_campaign)
    @test occursin("effect_direction_summary", acdc_grid_campaign)
    @test occursin("policy_ranking_performed", acdc_grid_campaign)
    @test occursin("log10 candidate-to-classic ratios", acdc_grid_campaign)
    @test occursin("native_acdc_contract_required", acdc_grid_campaign)
    acdc_multi_campaign = read(
        joinpath(
            benchmark_directory, "bmopf_acdc_multiconverter_campaign.jl",
        ),
        String,
    )
    @test occursin("bmopf-acdc-multiconverter-campaign-v1",
        acdc_multi_campaign)
    @test occursin("full 2^4 two-level factorial", acdc_multi_campaign)
    @test occursin("three-converter-droop-sharing", acdc_multi_campaign)
    @test occursin("trajectory_attribution_gates_passed",
        acdc_multi_campaign)
    @test occursin("factorization_work_available_count", acdc_multi_campaign)
    @test occursin("absence_is_not_a_qualification_failure",
        acdc_multi_campaign)
    @test occursin("joint_geometry_and_factorization_attribution_available",
        acdc_multi_campaign)
    acdc_multi_madnlp_campaign = read(
        joinpath(
            benchmark_directory,
            "bmopf_acdc_multiconverter_madnlp_campaign.jl",
        ),
        String,
    )
    @test occursin("bmopf-acdc-multiconverter-madnlp-campaign-v1",
        acdc_multi_madnlp_campaign)
    @test occursin("factorization_count_cumulative",
        acdc_multi_madnlp_campaign)
    @test occursin("linear_solver_time_seconds_cumulative",
        acdc_multi_madnlp_campaign)
    @test occursin("linear_work_attribution_gates_passed",
        acdc_multi_madnlp_campaign)
    @test occursin("primal_iterate_geometry_available",
        acdc_multi_madnlp_campaign)
    @test occursin("unsupported_factorization_numerics_truthfully_unavailable",
        acdc_multi_madnlp_campaign)
    @test occursin("linear_work_effect_direction_summary",
        acdc_multi_madnlp_campaign)
    @test occursin("joint_same_run_geometry_and_factorization_work",
        acdc_multi_madnlp_campaign)
    @test occursin("potential_multiplier_normalization_mismatch",
        acdc_multi_madnlp_campaign)
    @test occursin("multiplier_normalization_is_not_a_linear_work_gate",
        acdc_multi_madnlp_campaign)
    @test occursin("fixed_variable_dual_completion_available_count",
        acdc_multi_madnlp_campaign)
    @test occursin("public_and_completed_representatives_retained",
        acdc_multi_madnlp_campaign)
    @test occursin("qualified_linear_work_effect_direction_summary",
        acdc_multi_madnlp_campaign)
    acdc_feeder_campaign = read(
        joinpath(
            benchmark_directory,
            "bmopf_acdc_feeder_policy_campaign.jl",
        ),
        String,
    )
    @test occursin("bmopf-acdc-feeder-policy-campaign-v1",
        acdc_feeder_campaign)
    @test occursin("factorial_a2_high_only", acdc_feeder_campaign)
    @test occursin("factorial_all_low", acdc_feeder_campaign)
    @test occursin("max_dense_entries=0", acdc_feeder_campaign)
    @test occursin("maximum_trace_jacobian_entry_evaluations",
        acdc_feeder_campaign)
    @test occursin("cross_solver_start_gate_passed",
        acdc_feeder_campaign)
    @test occursin("public_multiplier_endpoint_accepted",
        acdc_feeder_campaign)
    @test occursin("stratum_complete", acdc_feeder_campaign)
    @test occursin("_acdc_feeder_compact_stratified_campaign",
        acdc_feeder_campaign)
    @test occursin("temporary_path", acdc_feeder_campaign)
    source_matrix_launcher = read(
        joinpath(benchmark_directory, "launch_bmopf_source_solver_matrix.jl"), String,
    )
    @test occursin("solver_size_guard_skipped", source_matrix_launcher)
    @test occursin("checkpoint_phase", source_matrix_launcher)
    @test occursin("model_variable_count", source_matrix_launcher)
    @test occursin("SOURCE_SOLVER_PROFILE_STAGE", source_matrix_launcher)
    @test occursin("SOURCE_SOLVER_RANK_MAX_DENSE_ENTRIES", source_matrix_launcher)
    source_matrix_comparison = read(
        joinpath(benchmark_directory, "compare_bmopf_source_solver_matrices.jl"), String,
    )
    @test occursin("trace_by_policy", source_matrix_comparison)
    @test occursin("active_set_changed", source_matrix_comparison)
    @test occursin("row_family_residual_by_policy", source_matrix_comparison)
    @test occursin("family_residual_trend", source_matrix_comparison)
    @test occursin("SOURCE_SOLVER_CAPTURE_ROW_RESIDUALS", source_matrix_launcher)
    @test occursin("row-family residual capture requires", source_matrix_launcher)
    residual_trend_validation = read(
        joinpath(benchmark_directory, "validate_bmopf_residual_trends.jl"), String,
    )
    @test occursin("restoration_alignment", residual_trend_validation)
    @test occursin("all_residual_traces_available", residual_trend_validation)
    restoration_campaign_report = read(
        joinpath(benchmark_directory, "summarize_bmopf_restoration_campaign.jl"), String,
    )
    @test occursin("dense_rank_required", restoration_campaign_report)
    @test occursin("restoration_endpoint_failure_cooccurrence_count",
        restoration_campaign_report)
    option_launcher = read(
        joinpath(benchmark_directory, "launch_bmopf_solver_option_perturbations.jl"), String,
    )
    @test occursin("OPTION_PERTURBATIONS", option_launcher)
    option_summary = read(
        joinpath(benchmark_directory,
            "summarize_bmopf_solver_option_perturbations.jl"), String,
    )
    @test occursin("restoration_signature_changed", option_summary)
    @test occursin("row_family_residual_changed", option_summary)
    @test occursin("row_family_residual_peak_deltas", option_summary)
    @test occursin("row_family_residual_trajectory_deltas", option_summary)
    @test occursin("post_first_captured_peak", option_summary)
    @test occursin("row_family_first_captured_changed", option_summary)
    @test occursin("comparisons_between_perturbations", option_summary)
    @test occursin("between_perturbation_comparisons_available", option_summary)
    @test occursin("residual_comparison_tolerance", option_summary)
    @test occursin("baseline_comparisons_available", option_summary)
    @test occursin("model_semantic_contract_changed", option_summary)
    @test occursin("multiconductor_semantic_gate_passed", option_summary)
    restarted_calibration = read(
        joinpath(benchmark_directory,
            "calibrate_restarted_smallest_singular.jl"), String,
    )
    @test occursin("smallest-singular-cross-backend-calibration-v2",
        restarted_calibration)
    @test occursin("harmonic_relation_counts", restarted_calibration)
    @test occursin("crosscheck_relation_counts", restarted_calibration)
    @test occursin("hilbert_false_convergence_control",
        restarted_calibration)
    @test occursin("badly_scaled_full_rank_control",
        restarted_calibration)
    randomized_calibration = read(
        joinpath(benchmark_directory,
            "calibrate_randomized_rank_oracles.jl"), String,
    )
    @test occursin("seeded-randomized-rank-oracles-v1",
        randomized_calibration)
    @test occursin("threshold_backend_disagreement_count",
        randomized_calibration)
    option_summary_module = Module(:NLPDiagnosticsOptionSummaryContract)
    Base.include(option_summary_module, joinpath(
        benchmark_directory, "summarize_bmopf_solver_option_perturbations.jl",
    ))
    baseline_trace = Dict{String,Any}("rows" => Any[
        Dict("iteration" => 0, "phase" => "regular", "families" =>
            Dict("power_balance" => Dict("max_feasibility_violation" => 10.0))),
        Dict("iteration" => 1, "phase" => "regular", "families" =>
            Dict("power_balance" => Dict("max_feasibility_violation" => 1.0))),
        Dict("iteration" => 2, "phase" => "regular", "families" =>
            Dict("power_balance" => Dict("max_feasibility_violation" => 0.1))),
    ])
    perturbed_trace = Dict{String,Any}("rows" => Any[
        Dict("iteration" => 0, "phase" => "regular", "families" =>
            Dict("power_balance" => Dict("max_feasibility_violation" => 10.0))),
        Dict("iteration" => 1, "phase" => "regular", "families" =>
            Dict("power_balance" => Dict("max_feasibility_violation" => 0.8))),
        Dict("iteration" => 2, "phase" => "regular", "families" =>
            Dict("power_balance" => Dict("max_feasibility_violation" => 0.01))),
    ])
    family_trajectories = getfield(option_summary_module, :_family_trajectories)
    trajectory_deltas = getfield(option_summary_module, :_trajectory_deltas)
    peak_map = getfield(option_summary_module, :_row_peak_map)
    material_peak_change = getfield(option_summary_module, :_material_peak_change)
    baseline_trajectories = family_trajectories(baseline_trace)
    perturbed_trajectories = family_trajectories(perturbed_trace)
    deltas = trajectory_deltas(baseline_trajectories, perturbed_trajectories)
    @test !material_peak_change(peak_map(baseline_trace), peak_map(perturbed_trace))
    @test only(deltas)["trajectory_changed"]
    @test !only(deltas)["first_captured_changed"]
    @test only(deltas)["final_captured_changed"]
    semantic_contract = getfield(option_summary_module, :_model_semantic_contract)
    semantic_case = Dict{String,Any}(
        "model_variable_count" => 12,
        "bmopf_context_profile" => Dict("findings" => Any[]),
        "bmopf_context_finding_codes" => Dict("floating_neutral" => 1),
        "source_behavior_contract" => Dict("available" => true),
    )
    contract, contract_fingerprint, context_codes = semantic_contract(semantic_case)
    @test contract["context_profile_available"]
    @test contract["model_variable_count"] == 12
    @test context_codes == Dict("floating_neutral" => 1)
    @test length(contract_fingerprint) == 64
    reordered_semantic_case = Dict{String,Any}(
        "source_behavior_contract" => Dict("available" => true),
        "bmopf_context_finding_codes" => Dict("floating_neutral" => 1),
        "bmopf_context_profile" => Dict("findings" => Any[]),
        "model_variable_count" => 12,
    )
    @test semantic_contract(reordered_semantic_case)[2] == contract_fingerprint
    option_launcher_module = Module(:NLPDiagnosticsOptionLauncherContract)
    Core.eval(option_launcher_module, :(import JSON))
    Base.include(option_launcher_module, joinpath(
        benchmark_directory, "launch_bmopf_solver_option_perturbations.jl",
    ))
    specs = withenv("NLPDIAGNOSTICS_BMOPF_OPTION_PERTURBATIONS" => nothing) do
        getfield(option_launcher_module, :_specs)()
    end
    @test count(spec -> spec.label == "baseline", specs) == 1
    @test length(unique(spec.options for spec in specs)) == length(specs)
    @test all(!isempty(spec.options) for spec in specs)
    canonical_options = getfield(option_launcher_module, :_canonical_options)
    @test canonical_options("tol=1e-6,mu_strategy=adaptive") ==
          canonical_options("mu_strategy=adaptive,tol=1e-6")
    @test_throws ErrorException withenv(
        "NLPDIAGNOSTICS_BMOPF_OPTION_PERTURBATIONS" =>
            "baseline:tol=1e-6,mu_strategy=adaptive;" *
            "duplicate:mu_strategy=adaptive,tol=1e-6",
    ) do
        getfield(option_launcher_module, :_specs)()
    end
    @test_throws ErrorException canonical_options("")
    validate_option_scope = getfield(option_launcher_module,
        :_validate_campaign_scope)
    @test_throws ErrorException withenv(
        "NLPDIAGNOSTICS_BMOPF_SOURCE_SOLVER_PROFILE_STAGE" => "trace",
        "NLPDIAGNOSTICS_BMOPF_SOURCE_SOLVER_CAPTURE_POINTS" => "true",
        "NLPDIAGNOSTICS_BMOPF_SOURCE_SOLVER_CAPTURE_ROW_RESIDUALS" => "true",
    ) do
        validate_option_scope("multiconductor")
    end
    @test withenv(
        "NLPDIAGNOSTICS_BMOPF_SOURCE_SOLVER_PROFILE_STAGE" => "context",
        "NLPDIAGNOSTICS_BMOPF_SOURCE_SOLVER_CAPTURE_POINTS" => "true",
        "NLPDIAGNOSTICS_BMOPF_SOURCE_SOLVER_CAPTURE_ROW_RESIDUALS" => "true",
    ) do
        isnothing(validate_option_scope("multiconductor"))
    end
    write_option_manifest = getfield(option_launcher_module, :_write_manifest)
    mktempdir() do directory
        path = joinpath(directory, "manifest.json")
        write_option_manifest(
            path,
            directory,
            [Dict{String,Any}("status" => "ok")],
            specs,
            ["none", "zero"];
            status = "running",
        )
        manifest = getfield(option_launcher_module, :JSON).parsefile(path)
        @test manifest["report_version"] == "bmopf-option-perturbation-manifest-v3"
        @test manifest["campaign_status"] == "running"
        @test manifest["completed_entry_count"] == 1
        @test manifest["expected_entry_count"] == 2 * length(specs)
        @test manifest["campaign_scope"] == "generic"
        @test !isfile("$path.tmp")
    end
    evidence_ledger_summary = read(
        joinpath(benchmark_directory, "summarize_bmopf_evidence_ledger.jl"), String,
    )
    @test occursin("solver_option_row_family_trajectory_stability", evidence_ledger_summary)
    @test occursin("solver_option_legacy_smoke_observation", evidence_ledger_summary)
    @test occursin("solver_option_incomplete_trajectory_observation", evidence_ledger_summary)
    @test occursin("solver_option_perturbation_pair_stability", evidence_ledger_summary)
    @test occursin("solver_option_classification_sensitivity", evidence_ledger_summary)
    @test occursin("solver_option_multiconductor_semantic_invariance", evidence_ledger_summary)
    @test occursin("solver_option_bmopf_context_sensitivity", evidence_ledger_summary)
    evidence_ledger_module = Module(:NLPDiagnosticsEvidenceLedgerContract)
    Base.include(evidence_ledger_module, joinpath(
        benchmark_directory, "summarize_bmopf_evidence_ledger.jl",
    ))
    append_option_evidence = getfield(
        evidence_ledger_module, :_append_solver_option_evidence!,
    )
    trusted_option_report = Dict{String,Any}(
        "report_version" => "bmopf-solver-option-perturbation-v3",
        "readiness" => Dict(
            "all_matrix_files_present" => true,
            "baseline_comparisons_available" => true,
            "all_manifest_entries_completed" => true,
            "manifest_entry_count_complete" => true,
            "all_nonbaseline_observations_compared" => true,
            "all_row_family_residual_traces_available" => true,
            "all_row_family_trajectories_nonempty" => true,
            "trajectory_comparisons_available" => true,
            "distinct_option_sets_declared" => true,
        ),
        "comparisons_vs_baseline" => Any[Dict(
            "row_family_trajectory_changed" => false,
            "row_family_global_peak_changed" => false,
            "row_family_first_captured_changed" => false,
            "restoration_signature_changed" => false,
            "classification_changed" => false,
        )],
    )
    trusted_option_records = Dict{String,Any}[]
    append_option_evidence(
        trusted_option_records, trusted_option_report, "trusted-option.json",
    )
    @test only(trusted_option_records)["code"] ==
          "solver_option_row_family_trajectory_stability"
    legacy_option_report = deepcopy(trusted_option_report)
    legacy_option_report["report_version"] = "bmopf-solver-option-perturbation-v2"
    legacy_option_records = Dict{String,Any}[]
    append_option_evidence(
        legacy_option_records, legacy_option_report, "legacy-option.json",
    )
    @test only(legacy_option_records)["code"] ==
          "solver_option_legacy_smoke_observation"
    incomplete_option_report = deepcopy(trusted_option_report)
    incomplete_option_report["readiness"][
        "all_row_family_residual_traces_available"
    ] = false
    incomplete_option_records = Dict{String,Any}[]
    append_option_evidence(
        incomplete_option_records, incomplete_option_report, "incomplete-option.json",
    )
    @test only(incomplete_option_records)["code"] ==
          "solver_option_incomplete_trajectory_observation"
    paired_option_report = deepcopy(trusted_option_report)
    paired_option_report["readiness"][
        "between_perturbation_comparisons_available"
    ] = true
    paired_option_report["comparisons_between_perturbations"] = Any[Dict(
        "reference_profile" => "adaptive_filter",
        "candidate_profile" => "adaptive_free",
        "row_family_trajectory_changed" => false,
        "classification_changed" => false,
        "trace_record_count_delta" => 0,
    )]
    paired_option_records = Dict{String,Any}[]
    append_option_evidence(
        paired_option_records, paired_option_report, "paired-option.json",
    )
    @test Set(record["code"] for record in paired_option_records) == Set([
        "solver_option_row_family_trajectory_stability",
        "solver_option_perturbation_pair_stability",
    ])
    multiconductor_option_report = deepcopy(trusted_option_report)
    multiconductor_option_report["report_version"] =
        "bmopf-solver-option-perturbation-v4"
    multiconductor_option_report["campaign_scope"] = "multiconductor"
    multiconductor_option_report["readiness"][
        "model_semantic_contracts_available"
    ] = true
    multiconductor_option_report["readiness"][
        "model_semantic_invariance"
    ] = true
    multiconductor_records = Dict{String,Any}[]
    append_option_evidence(
        multiconductor_records,
        multiconductor_option_report,
        "multiconductor-option.json",
    )
    @test Set(record["code"] for record in multiconductor_records) == Set([
        "solver_option_multiconductor_semantic_invariance",
        "solver_option_row_family_trajectory_stability",
    ])
    failed_semantic_report = deepcopy(multiconductor_option_report)
    failed_semantic_report["readiness"]["model_semantic_invariance"] = false
    failed_semantic_records = Dict{String,Any}[]
    append_option_evidence(
        failed_semantic_records,
        failed_semantic_report,
        "failed-multiconductor-option.json",
    )
    @test only(failed_semantic_records)["code"] ==
        "solver_option_multiconductor_semantic_gate_failed"
    structural_family_correlation = read(
        joinpath(benchmark_directory,
            "correlate_bmopf_structural_family_omission.jl"), String,
    )
    @test occursin("endpoint_change_and_load_sensitivity_cooccur",
        structural_family_correlation)
    @test occursin("not causality", structural_family_correlation)
    sparse_corpus_summary = read(
        joinpath(benchmark_directory, "summarize_bmopf_sparse_corpus.jl"), String,
    )
    @test occursin("large_models_stopped_before_dense_solver_work", sparse_corpus_summary)
    @test occursin("solver_size_guard_skipped_count", sparse_corpus_summary)
    @test occursin("solver_trace_endpoint_conditioned_semantics", read(
        joinpath(benchmark_directory, "validate_bmopf_campaign.jl"), String,
    ))
    @test occursin("solver_repeat_row_family_delta_not_stable", read(
        joinpath(benchmark_directory, "validate_bmopf_campaign.jl"), String,
    ))
    solver_option_sweep = read(
        joinpath(benchmark_directory, "sweep_bmopf_solver_options.jl"), String,
    )
    @test occursin("NLPDIAGNOSTICS_BMOPF_SWEEP", solver_option_sweep)
    @test occursin("common_options", solver_option_sweep)
    @test occursin("effective_options", solver_option_sweep)
    @test occursin("_write_manifest", solver_option_sweep)
    solver_option_sweep_summary = read(
        joinpath(benchmark_directory, "summarize_bmopf_solver_sweep.jl"),
        String,
    )
    @test occursin("bmopf-solver-sweep-v1", solver_option_sweep_summary)
    @test occursin("environment_fingerprints_match", solver_option_sweep_summary)
    @test occursin("case_matrix", solver_option_sweep_summary)
    @test occursin("condition_proxy_ratio_delta", solver_option_sweep_summary)
    @test occursin("numerical_profile", solver_option_sweep_summary)
    @test occursin("sparse_qr_rank", solver_option_sweep_summary)
    @test occursin("dense_rank_unavailable", solver_option_sweep_summary)
    @test occursin("rank_budget_source", solver_option_sweep_summary)
    @test occursin("numerical_stage_coverage", solver_option_sweep_summary)
    solver_option_repeats = read(
        joinpath(benchmark_directory, "summarize_bmopf_solver_repeats.jl"),
        String,
    )
    @test occursin("bmopf-solver-repeats-v1", solver_option_repeats)
    @test occursin("termination_stable", solver_option_repeats)
    @test occursin("sparse_qr_rank_delta", solver_option_repeats)
    @test occursin("sparse_qr_condition_proxy_delta", solver_option_repeats)
    @test occursin("row_family_scale_ratio_delta", solver_option_repeats)
    @test occursin("row_family_scale_ratio_delta_stable", solver_option_repeats)
    @test occursin("_stable_delta_by_case", solver_option_repeats)
    @test occursin("numerical_readiness_change_count", solver_option_repeats)
    @test occursin("final_primal_residual_delta", solver_option_repeats)
    @test occursin("semantic_family_change_count", solver_option_repeats)
    @test occursin("semantic_finding_change_count", solver_option_repeats)
    endpoint_triangulation = read(
        joinpath(benchmark_directory, "summarize_bmopf_endpoint_triangulation.jl"),
        String,
    )
    @test occursin("bmopf-endpoint-triangulation-v1", endpoint_triangulation)
    @test occursin("successful_matches_engine_start", endpoint_triangulation)
    @test occursin("endpoint_conditioned", endpoint_triangulation)
    @test occursin("_semantic_only_codes", endpoint_triangulation)
    @test occursin("NLPDIAGNOSTICS_BMOPF_TRIANGULATION_CALIBRATIONS", endpoint_triangulation)
    point_comparison = read(
        joinpath(benchmark_directory, "compare_bmopf_multiconductor_points.jl"),
        String,
    )
    @test occursin("bmopf-multiconductor-point-comparison-v1", point_comparison)
    @test occursin("successful_case_overlap", point_comparison)
    @test occursin("distinct_point_policies", point_comparison)
    @test occursin("dense_rank_pair_available", point_comparison)
    @test occursin("dense_rank_change_count", point_comparison)
    @test occursin("alignment_pair_available", point_comparison)
    @test occursin("rank_change_classification", point_comparison)
    @test occursin("voltage_alignment_changed", point_comparison)
    @test occursin("current_alignment_changed", point_comparison)
    @test occursin("port_map_alignment_pair_complete", point_comparison)
    @test occursin("mode_projection_pair_available", point_comparison)
    @test occursin("mode_match_pair_available", point_comparison)
    @test occursin("mode_projection_policy_compatible", point_comparison)
    @test occursin("mode_tangent_policy_compatible", point_comparison)
    @test occursin("smallest_crosscheck_pair_available", point_comparison)
    @test occursin("feasibility_violations_eliminated", point_comparison)
    @test occursin("sparse_qr_condition_proxy_delta", point_comparison)
    @test occursin("inactive_stationary_quadratic_rows_eliminated",
        point_comparison)
    @test occursin("candidate_solver_results_feasible", point_comparison)
    campaign_validator = read(
        joinpath(benchmark_directory, "validate_bmopf_campaign.jl"), String,
    )
    @test occursin("multiconductor_point_numerical_profile_overlap_incomplete",
        campaign_validator)
    @test occursin("multiconductor_point_initialization_profile_overlap_incomplete",
        campaign_validator)
    @test occursin("multiconductor_point_solver_result_overlap_incomplete",
        campaign_validator)
    @test occursin("multiconductor_point_solver_results_not_feasible",
        campaign_validator)
    @test occursin("smallest_crosscheck_relation_changed", point_comparison)
    @test occursin("smallest_crosscheck_minimum_principal_cosine_delta",
        point_comparison)
    crosscheck_comparison = read(joinpath(
        benchmark_directory, "compare_bmopf_multiconductor_crosschecks.jl"), String)
    @test occursin("bmopf-multiconductor-crosscheck-comparison-v1",
        crosscheck_comparison)
    @test occursin("restarted_convergence_gain_count", crosscheck_comparison)
    @test occursin("harmonic_convergence_gain_count", crosscheck_comparison)
    @test occursin("agreement_gain_count", crosscheck_comparison)
    @test occursin("distinct_work_policy", crosscheck_comparison)
    @test occursin("scaling_intervention_only", crosscheck_comparison)
    sparse_qr_comparison = read(joinpath(
        benchmark_directory, "compare_bmopf_sparse_qr_nullspaces.jl"), String)
    @test occursin("bmopf-sparse-qr-nullspace-comparison-v1",
        sparse_qr_comparison)
    @test occursin("dense_calibration_pair_available", sparse_qr_comparison)
    @test occursin("rank_change_count", sparse_qr_comparison)
    @test occursin("maximum_relative_residual_delta", sparse_qr_comparison)
    @test occursin("scaling_intervention_only", sparse_qr_comparison)
    formulation_comparison = read(joinpath(
        benchmark_directory, "compare_bmopf_formulation_interventions.jl"), String)
    @test occursin("bmopf-formulation-intervention-comparison-v1",
        formulation_comparison)
    @test occursin("dimension_change_matches_removed_nullity",
        formulation_comparison)
    @test occursin("causal_interpretation_ready", formulation_comparison)
    bmopf_smoke = read(joinpath(benchmark_directory, "bmopf_smoke.jl"), String)
    multiconductor_summary = read(joinpath(
        benchmark_directory, "summarize_bmopf_multiconductor_smoke.jl"), String)
    @test occursin("NLPDIAGNOSTICS_BMOPF_SMALLEST_CROSSCHECK_DIMENSION",
        bmopf_smoke)
    @test occursin("NLPDIAGNOSTICS_BMOPF_SMALLEST_CROSSCHECK_DENSE_CALIBRATION",
        bmopf_smoke)
    @test occursin("NLPDIAGNOSTICS_BMOPF_SMALLEST_CROSSCHECK_SCALING",
        bmopf_smoke)
    @test occursin("NLPDIAGNOSTICS_BMOPF_SPARSE_QR_NULLSPACE",
        bmopf_smoke)
    @test occursin("NLPDIAGNOSTICS_BMOPF_SPARSE_QR_PERSISTENCE_REPEAT_COUNT",
        bmopf_smoke)
    @test occursin("NLPDIAGNOSTICS_BMOPF_SPARSE_QR_PERSISTENCE_RADII",
        bmopf_smoke)
    @test occursin("NLPDIAGNOSTICS_BMOPF_POINT_SOLVER_MAX_ITERATIONS",
        bmopf_smoke)
    @test occursin("bmopf-ipopt-solver-result", bmopf_smoke)
    @test occursin("solver_result_point_feasible", multiconductor_summary)
    @test occursin("bmopf_analyze_sparse_qr_nullspace_persistence",
        bmopf_smoke)
    @test occursin("numerical_profile", multiconductor_summary)
    @test occursin("initialization_profile", multiconductor_summary)
    @test occursin("maximum_initialization_feasibility_violation",
        multiconductor_summary)
    @test occursin("active_zero_jacobian_row_count", multiconductor_summary)
    @test occursin("no_active_zero_jacobian_rows", multiconductor_summary)
    @test occursin("inactive_stationary_diagonal_quadratic_row_count",
        multiconductor_summary)
    @test occursin("no_active_stationary_diagonal_quadratic_rows",
        multiconductor_summary)
    @test occursin("multiconductor_initialization_infeasible", read(
        joinpath(benchmark_directory, "validate_bmopf_campaign.jl"), String))
    @test occursin("smallest_singular_backend_crosscheck_max_basis_entries",
        bmopf_smoke)
    @test occursin("smallest_singular_crosscheck_relation_counts",
        multiconductor_summary)
    @test occursin("smallest_singular_backend_crosscheck_agreement",
        multiconductor_summary)
    @test occursin("smallest_singular_backend_crosscheck_scaling",
        multiconductor_summary)
    @test occursin("smallest_singular_backend_crosscheck_original_audit_available",
        multiconductor_summary)
    @test occursin("smallest_singular_backend_original_coordinate_audit",
        multiconductor_summary)
    @test occursin("sparse_qr_nullspace_dense_relation_counts",
        multiconductor_summary)
    @test occursin("sparse_qr_nullspace_persistence_nearby_stable_case_count",
        multiconductor_summary)
    @test occursin("sparse_qr_nullspace_repeatability",
        multiconductor_summary)
    @test occursin("restarted_smallest_singular_dense_relation_counts",
        multiconductor_summary)
    @test occursin("harmonic_smallest_singular_dense_relation_counts",
        multiconductor_summary)
    @test occursin("physical_mode_projections", read(
        joinpath(benchmark_directory, "bmopf_smoke.jl"), String,
    ))
    @test occursin("NLPDIAGNOSTICS_BMOPF_EXPECTED_MODE_FREE_COORDINATE_POLICY",
        read(joinpath(benchmark_directory, "bmopf_smoke.jl"), String))
    @test occursin("NLPDIAGNOSTICS_BMOPF_EXPECTED_MODE_TANGENT_POLICY",
        read(joinpath(benchmark_directory, "bmopf_smoke.jl"), String))
    @test occursin("bmopf_expected_mode_tangent_policy",
        read(joinpath(repository_root, "src", "analysis", "degeneracy.jl"), String))
    @test occursin("_bmopf_expected_mode_tangent_policy",
        read(joinpath(repository_root, "ext", "BMOPFToolsJuMPExt.jl"), String))
    @test occursin("bmopf_source_schema_report",
        read(joinpath(repository_root, "src", "analysis", "degeneracy.jl"), String))
    @test occursin("_bmopf_source_schema_report",
        read(joinpath(repository_root, "ext", "BMOPFToolsJuMPExt.jl"), String))
    @test occursin("bmopf_source_schema_physical_metadata_loss",
        read(joinpath(repository_root, "ext", "BMOPFToolsJuMPExt.jl"), String))
    @test occursin("expected_nullspace_mode_tangent_observed",
        read(joinpath(repository_root, "src", "analysis", "degeneracy.jl"), String))
    @test occursin("multiconductor_mode_tangent_policy_unavailable", read(
        joinpath(benchmark_directory, "validate_bmopf_campaign.jl"), String,
    ))
    tangent_comparison = read(
        joinpath(benchmark_directory, "compare_bmopf_tangent_policies.jl"), String,
    )
    @test occursin("tangent_policy_rank_change_observed", tangent_comparison)
    @test occursin("comparison_available", tangent_comparison)
    @test occursin("free_coordinate_policy_compatible", tangent_comparison)
    @test occursin("tangent_rows", tangent_comparison)
    tangent_launcher = read(
        joinpath(benchmark_directory, "launch_bmopf_tangent_calibration.jl"), String,
    )
    @test occursin("NLPDIAGNOSTICS_BMOPF_TANGENT_CALIBRATION_POLICIES", tangent_launcher)
    @test occursin("compare_bmopf_tangent_policies.jl", tangent_launcher)
    @test occursin("expected_nullspace_mode_free_projection_observed",
        read(joinpath(repository_root, "src", "analysis", "degeneracy.jl"), String))
    @test occursin("multiconductor_point_successful_overlap_empty", read(
        joinpath(benchmark_directory, "validate_bmopf_campaign.jl"), String,
    ))
    @test occursin("multiconductor_point_dense_rank_overlap_empty", read(
        joinpath(benchmark_directory, "validate_bmopf_campaign.jl"), String,
    ))
    @test occursin("multiconductor_point_rank_alignment_ambiguous", read(
        joinpath(benchmark_directory, "validate_bmopf_campaign.jl"), String,
    ))
    @test occursin("multiconductor_smallest_singular_crosscheck_disagreement", read(
        joinpath(benchmark_directory, "validate_bmopf_campaign.jl"), String,
    ))
    @test occursin("multiconductor_point_smallest_crosscheck_overlap_incomplete", read(
        joinpath(benchmark_directory, "validate_bmopf_campaign.jl"), String,
    ))
    @test occursin("multiconductor_crosscheck_work_policy_not_distinct", read(
        joinpath(benchmark_directory, "validate_bmopf_campaign.jl"), String,
    ))
    ledger = read(
        joinpath(benchmark_directory, "summarize_bmopf_evidence_ledger.jl"),
        String,
    )
    @test occursin("solver_repeats", ledger)
    @test occursin("solver_repeat_row_family_delta_recurrence", ledger)
    @test occursin("dense_sparse_rank_agreement", ledger)
    @test occursin("multiconductor_point_dense_rank_checkpoint", ledger)
    @test occursin("multiconductor_point_rank_alignment_boundary", ledger)
    @test occursin("multiconductor_point_port_alignment_coverage", ledger)
    @test occursin("multiconductor_point_port_map_alignment_incomplete", ledger)
    @test occursin("multiconductor_point_mode_projection_visibility", ledger)
    @test occursin("multiconductor_point_mode_jacobian_match", ledger)
    @test occursin("multiconductor_mode_jacobian_match_unavailable", read(
        joinpath(benchmark_directory, "validate_bmopf_campaign.jl"), String,
    ))
    @test occursin("source_schema_context_report_available", read(
        joinpath(benchmark_directory, "summarize_bmopf_multiconductor_smoke.jl"), String,
    ))
    @test occursin("multiconductor_source_schema_mapping_incomplete", read(
        joinpath(benchmark_directory, "validate_bmopf_campaign.jl"), String,
    ))
    @test occursin("multiconductor_smoke_source_schema_warnings_accounted", read(
        joinpath(benchmark_directory, "validate_bmopf_campaign.jl"), String,
    ))
    @test occursin("multiconductor_mode_projection_policy_unavailable", read(
        joinpath(benchmark_directory, "validate_bmopf_campaign.jl"), String,
    ))
    @test occursin("record_kind", ledger)
    @test occursin("\"evaluation_points\"", ledger)
    @test occursin("\"basis_counts\"", ledger)
    @test occursin("\"domain_counts\"", ledger)
end

@testset "renderer-neutral report data" begin
    entity = NLPDiagnostics.EntityRef(
        :constraint,
        3;
        subindex = 2,
        name = "balance",
        function_type = "ScalarNonlinearFunction",
        set_type = "EqualTo",
    )
    finding = NLPDiagnostics.Finding(
        :example;
        severity = NLPDiagnostics.SeverityWarning,
        domain = NLPDiagnostics.NumericalIssue,
        basis = NLPDiagnostics.NumericalObservation,
        confidence = NLPDiagnostics.ConfidenceHigh,
        observation = "Example finding.",
        why_it_matters = "Example evidence serialization.",
        evidence = [NLPDiagnostics.Evidence("Example"; details = ["margin" => "1e-6"])],
        suggested_actions = ["Inspect the source row."],
        affected = [entity],
    )
    report = NLPDiagnostics.DiagnosticReport([finding], Dict(:stage => "test"))
    data = NLPDiagnostics.report_data(report)
    @test data["metadata"] == Dict("stage" => "test")
    unavailable_report = NLPDiagnostics.DiagnosticReport(
        NLPDiagnostics.Finding[],
        Dict(
            :stage => "numerical",
            :sparse_qr_rank_available => "false",
            :sparse_qr_rank_reason => "dense work guard exceeded",
        ),
    )
    unavailable_data = NLPDiagnostics.report_data(unavailable_report)
    @test only(unavailable_data["unavailable_reasons"])["code"] ==
        "sparse_qr_rank_unavailable"
    @test only(unavailable_data["unavailable_reasons"])["stage"] == "numerical"
    @test only(unavailable_data["unavailable_reasons"])["reason_key"] ==
        "sparse_qr_rank_reason"
    native_unavailable_report = NLPDiagnostics.DiagnosticReport(
        NLPDiagnostics.Finding[],
        Dict(
            :stage => "iterative_right_nullspace_probe",
            :iterative_probe_native_operator_unavailable_reason =>
                "native JacVec callback unavailable",
        ),
    )
    native_unavailable_data = NLPDiagnostics.report_data(native_unavailable_report)
    @test only(native_unavailable_data["unavailable_reasons"])["code"] ==
        "iterative_probe_native_operator_unavailable"
    finding_data = only(data["findings"])
    @test finding_data["severity"] == "warning"
    @test finding_data["domain"] == "numerical"
    @test finding_data["basis"] == "numerical_observation"
    @test only(finding_data["evidence"])["details"] == Dict("margin" => "1e-6")
    @test only(finding_data["affected"])["subindex"] == 2
    @test NLPDiagnostics.findings(
        report;
        code = :example,
        severity = NLPDiagnostics.SeverityWarning,
        domain = NLPDiagnostics.NumericalIssue,
    ) == [finding]
    @test isempty(NLPDiagnostics.findings(report; severity = NLPDiagnostics.SeverityError))
    @test NLPDiagnostics.finding_code_counts(report) == Dict(:example => 1)
    @test data["finding_code_counts"] == Dict("example" => 1)
    markdown = NLPDiagnostics.markdown_report(report)
    @test occursin("# NLPDiagnostics report", markdown)
    @test occursin("## WARNING · numerical · `example`", markdown)
    @test occursin("### Evidence", markdown)
    @test occursin("`constraint[3/2] (balance)`", markdown)
    @test sprint(show, MIME"text/markdown"(), report) == markdown

    info_one = NLPDiagnostics.Finding(
        :repeated_info;
        severity = NLPDiagnostics.SeverityInfo,
        domain = NLPDiagnostics.RepresentationalIssue,
        basis = NLPDiagnostics.StructuralProof,
        confidence = NLPDiagnostics.ConfidenceCertain,
        observation = "First informational record.",
        why_it_matters = "Family aggregation should preserve detail.",
    )
    info_two = NLPDiagnostics.Finding(
        :repeated_info;
        severity = NLPDiagnostics.SeverityInfo,
        domain = NLPDiagnostics.RepresentationalIssue,
        basis = NLPDiagnostics.StructuralProof,
        confidence = NLPDiagnostics.ConfidenceCertain,
        observation = "Second informational record.",
        why_it_matters = "Family aggregation should preserve detail.",
    )
    mixed = NLPDiagnostics.DiagnosticReport([finding, info_one, info_two], Dict{Symbol,String}())
    mixed_data = NLPDiagnostics.report_data(mixed)
    @test length(mixed_data["findings"]) == 3
    repeated_family = only(filter(
        family -> family["code"] == "repeated_info",
        mixed_data["finding_families"],
    ))
    @test repeated_family["count"] == 2
    @test repeated_family["distinct_observation_count"] == 2
    text = NLPDiagnostics.text_report(mixed)
    @test occursin("[WARNING] example", text)
    @test occursin("INFO summary: `repeated_info` (2 occurrences)", text)
    @test !occursin("First informational record", text)
    @test occursin("First informational record", NLPDiagnostics.text_report(
        mixed; minimum_severity = NLPDiagnostics.SeverityInfo,
    ))
    truncated_text = NLPDiagnostics.text_report(mixed; maximum_findings = 0)
    @test occursin("1 finding omitted by maximum_findings=0", truncated_text)
end

@testset "component metadata plugin boundary" begin
    model = MOIU.Model{Float64}()
    @test isempty(NLPDiagnostics.component_metadata(model))
    @test isempty(NLPDiagnostics.component_port_metadata(model))
    @test NLPDiagnostics.analyze_static(model).metadata[:component_metadata_count] == "0"
    @test NLPDiagnostics.analyze(model).metadata[:component_metadata_count] == "0"
    metadata = NLPDiagnostics.ComponentMetadata(
        :line,
        "line_1";
        variables = MOI.VariableIndex[MOI.VariableIndex(1)],
        constraints = [NLPDiagnostics.EntityRef(:constraint, 1)],
        units = Dict(:voltage => "kV"),
        expected_rank = 2,
    )
    @test metadata.units[:voltage] == "kV"
    @test metadata.variables == MOI.VariableIndex[MOI.VariableIndex(1)]
    @test metadata.constraints == [NLPDiagnostics.EntityRef(:constraint, 1)]
    @test metadata.expected_rank == 2
    port = NLPDiagnostics.ComponentPortMetadata(
        :line,
        "line_1",
        "from";
        terminal_labels = ["a", "b"],
        mode_labels = ["phase_a", "phase_b"],
        variables = MOI.VariableIndex[MOI.VariableIndex(1)],
        connection_matrix = [1.0 0.0; 0.0 1.0],
        metadata = Dict("connection" => "wye"),
    )
    @test port.connection_matrix == [1.0 0.0; 0.0 1.0]
    @test port.terminal_labels == ["a", "b"]
    port_report = NLPDiagnostics._component_port_metadata_findings(
        [port]; model_variables = MOI.VariableIndex[MOI.VariableIndex(1)],
    )
    @test isempty(port_report.findings)
    malformed_port = NLPDiagnostics.ComponentPortMetadata{Float64}(
        :line, "line_1", "from", ["a"], ["a", "b"],
        MOI.VariableIndex[MOI.VariableIndex(2), MOI.VariableIndex(2)],
        reshape([NaN], 1, 1), Dict{String,String}(),
    )
    malformed_port_report = NLPDiagnostics._component_port_metadata_findings(
        [malformed_port]; model_variables = MOI.VariableIndex[MOI.VariableIndex(1)],
    )
    @test length(findings(
        malformed_port_report,
        :component_port_metadata_connection_dimension_mismatch,
    )) == 1
    @test length(findings(
        malformed_port_report,
        :component_port_metadata_nonfinite_connection,
    )) == 1
    @test length(findings(
        malformed_port_report,
        :component_port_metadata_duplicate_variables,
    )) == 1
    @test length(findings(
        malformed_port_report,
        :component_port_metadata_unknown_variable,
    )) == 1
    @test malformed_port_report.metadata[
        :component_port_metadata_scope_unavailable_count
    ] == "2"
    port_scope_reason = only(filter(
        item -> item["code"] == "component_port_metadata_scope_unavailable",
        NLPDiagnostics.report_data(malformed_port_report)["unavailable_reasons"],
    ))
    @test port_scope_reason["category"] == "input"
    @test port_scope_reason["stage"] == "component_port_metadata_scope_validation"
    @test length(findings(
        malformed_port_report, :component_port_metadata_scope_unavailable,
    )) == 1
    rank_deficient_port = NLPDiagnostics.ComponentPortMetadata(
        :transformer, "tx_1", "high";
        terminal_labels = ["a", "b"], mode_labels = ["a", "b"],
        connection_matrix = [1.0 0.0; 0.0 0.0],
    )
    rank_deficient_port_report = NLPDiagnostics._component_port_metadata_findings(
        [rank_deficient_port],
    )
    @test length(findings(
        rank_deficient_port_report,
        :component_port_metadata_connection_rank_deficient,
    )) == 1
    observed_port_mode = NLPDiagnostics.PortNullspaceMode(
        :transformer, "tx_1", "high", :mode, [0.0, 1.0],
    )
    unobserved_port_mode = NLPDiagnostics.PortNullspaceMode(
        :transformer, "tx_1", "high", :mode, [1.0, 0.0],
    )
    port_mode_report = NLPDiagnostics._component_port_nullspace_mode_findings(
        [rank_deficient_port], [observed_port_mode, unobserved_port_mode],
    )
    @test length(findings(
        port_mode_report,
        :component_port_expected_nullspace_mode_observed,
    )) == 1
    @test length(findings(
        port_mode_report,
        :component_port_expected_nullspace_mode_not_observed,
    )) == 1
    unaligned_port_mode_report = NLPDiagnostics._component_port_nullspace_mode_findings(
        NLPDiagnostics.ComponentPortMetadata[], [observed_port_mode],
    )
    @test length(findings(
        unaligned_port_mode_report,
        :component_port_expected_nullspace_mode_unaligned,
    )) == 1
    unaligned_port_mode_reason = only(filter(
        item -> item["code"] ==
            "component_port_expected_nullspace_mode_unavailable",
        NLPDiagnostics.report_data(unaligned_port_mode_report)[
            "unavailable_reasons"
        ],
    ))
    @test unaligned_port_mode_reason["category"] == "input"
    @test unaligned_port_mode_reason["stage"] ==
          "component_port_expected_nullspace_mode"
    second_port = NLPDiagnostics.ComponentPortMetadata(
        :transformer, "tx_1", "low";
        terminal_labels = ["a", "b"], mode_labels = ["a", "b"],
        connection_matrix = [1.0 0.0; 0.0 1.0],
    )
    connection = NLPDiagnostics.PortConnectionMetadata(
        :transformer, "tx_1", "high", :transformer, "tx_1", "low";
        connection_matrix = [1.0 0.0; 0.0 1.0],
    )
    connection_report = NLPDiagnostics._component_port_connection_findings(
        [rank_deficient_port, second_port], [connection],
    )
    @test isempty(connection_report.findings)
    bad_connection = NLPDiagnostics.PortConnectionMetadata(
        :transformer, "tx_1", "missing", :transformer, "tx_1", "low";
        connection_matrix = reshape([1.0], 1, 1),
    )
    bad_connection_report = NLPDiagnostics._component_port_connection_findings(
        [rank_deficient_port, second_port], [bad_connection],
    )
    @test length(findings(
        bad_connection_report,
        :component_port_connection_unaligned,
    )) == 1
    bad_connection_reason = only(filter(
        item -> item["code"] == "component_port_connection_unavailable",
        NLPDiagnostics.report_data(bad_connection_report)["unavailable_reasons"],
    ))
    @test bad_connection_reason["category"] == "input"
    @test bad_connection_reason["stage"] == "component_port_connection"
    isolated_port = NLPDiagnostics.ComponentPortMetadata(
        :load, "load_1", "terminal";
        terminal_labels = ["a"], mode_labels = ["a"],
        connection_matrix = reshape([1.0], 1, 1),
    )
    topology_report = NLPDiagnostics._component_port_topology_findings(
        [rank_deficient_port, second_port, isolated_port], [connection],
    )
    @test length(findings(
        topology_report,
        :component_port_topology_isolated_port,
    )) == 1
    topology_nullspace = NLPDiagnostics.port_topology_nullspace(
        [rank_deficient_port, second_port], [connection],
    )
    @test topology_nullspace.available
    @test topology_nullspace.rank == 2
    @test size(topology_nullspace.nullspace) == (4, 2)
    coordinate_map = NLPDiagnostics.PortCoordinateMap(
        :transformer, "tx_1", "high", MOI.VariableIndex[MOI.VariableIndex(1)];
        terminal_to_variable = reshape([1.0, 0.0], 1, 2),
    )
    @test size(coordinate_map.terminal_to_variable) == (1, 2)
    coordinate_map_report = NLPDiagnostics._component_port_coordinate_map_findings(
        [rank_deficient_port], [coordinate_map];
        model_variables = MOI.VariableIndex[MOI.VariableIndex(1)],
    )
    @test isempty(coordinate_map_report.findings)
    port_semantics = NLPDiagnostics.PortCoordinateSemantics(
        :transformer, "tx_1", "high";
        quantity = :voltage, representation = :polar,
        units = Dict("voltage" => "p.u."),
    )
    scaled_port_semantics = NLPDiagnostics.PortCoordinateSemantics(
        :transformer, "tx_1", "high";
        quantity = :voltage, representation = :polar,
        units = Dict("voltage" => "p.u."), nominal_scale = 1.0,
    )
    port_scale_report = NLPDiagnostics._port_coordinate_scale_findings(
        [scaled_port_semantics], [coordinate_map],
        NLPDiagnostics.EvaluationPoint(MOI.VariableIndex[MOI.VariableIndex(1)], [1.0e4]);
        mismatch_factor = 1.0e3,
    )
    @test length(findings(
        port_scale_report, :component_port_nominal_scale_mismatch,
    )) == 1
    equivalent_port_scale = NLPDiagnostics.PortCoordinateSemantics(
        :transformer, "tx_1", "low";
        quantity = :voltage, representation = :polar,
        units = Dict("voltage" => "p.u."), nominal_scale = 2.0,
    )
    equivalent_port_scale_map = NLPDiagnostics.PortCoordinateMap(
        :transformer, "tx_1", "low", MOI.VariableIndex[MOI.VariableIndex(1)];
        terminal_to_variable = reshape([0.5, 0.0], 1, 2),
    )
    deduplicated_port_scale_report = NLPDiagnostics._port_coordinate_scale_findings(
        [scaled_port_semantics, equivalent_port_scale],
        [coordinate_map, equivalent_port_scale_map],
        NLPDiagnostics.EvaluationPoint(MOI.VariableIndex[MOI.VariableIndex(1)], [1.0e4]);
        mismatch_factor = 1.0e3,
    )
    @test length(findings(
        deduplicated_port_scale_report, :component_port_nominal_scale_mismatch,
    )) == 1
    @test occursin("transformer:tx_1:high", Dict(
        only(findings(deduplicated_port_scale_report,
                      :component_port_nominal_scale_mismatch)).evidence[1].details,
    )["ports"])
    unmapped_port_scale_report = NLPDiagnostics._port_coordinate_scale_findings(
        [scaled_port_semantics], NLPDiagnostics.PortCoordinateMap[],
        NLPDiagnostics.EvaluationPoint(MOI.VariableIndex[], Float64[]),
    )
    @test length(findings(
        unmapped_port_scale_report,
        :component_port_nominal_scale_projection_unavailable,
    )) == 1
    unmapped_port_scale_reason = only(filter(
        item -> item["code"] ==
            "component_port_nominal_scale_projection_unavailable",
        NLPDiagnostics.report_data(unmapped_port_scale_report)[
            "unavailable_reasons"
        ],
    ))
    @test unmapped_port_scale_reason["category"] == "capability"
    @test unmapped_port_scale_reason["stage"] ==
          "component_port_nominal_scale_projection"
    @test_throws ArgumentError NLPDiagnostics.PortCoordinateSemantics(
        :transformer, "tx_1", "high"; quantity = :voltage, nominal_scale = 0.0,
    )
    neutral_coordinate = NLPDiagnostics.PortTerminalCoordinateSemantics(
        "n"; role = :neutral,
    )
    phase_coordinate = NLPDiagnostics.PortTerminalCoordinateSemantics(
        "a"; role = :phase, nominal_scale = 1.0,
    )
    grounded_coordinate = NLPDiagnostics.PortTerminalCoordinateSemantics(
        "g"; role = :ground_reference, expected_value = 0.0,
        absolute_tolerance = 1.0e-8,
    )
    terminal_semantics = NLPDiagnostics.PortCoordinateSemantics(
        :transformer, "tx_1", "high";
        quantity = :voltage, representation = :rectangular_real,
        units = Dict("voltage" => "p.u."), nominal_scale = 1.0,
        terminal_semantics = [neutral_coordinate, phase_coordinate],
    )
    neutral_map = NLPDiagnostics.PortCoordinateMap(
        :transformer, "tx_1", "high",
        MOI.VariableIndex[MOI.VariableIndex(1)];
        terminal_to_variable = reshape([1.0, 0.0], 1, 2),
    )
    neutral_scale_report = NLPDiagnostics._port_coordinate_scale_findings(
        [terminal_semantics], [neutral_map],
        NLPDiagnostics.EvaluationPoint(
            MOI.VariableIndex[MOI.VariableIndex(1)], [1.0e-12],
        ); mismatch_factor = 1.0e3,
    )
    @test isempty(findings(
        neutral_scale_report, :component_port_nominal_scale_mismatch,
    ))
    @test neutral_scale_report.metadata[
        :component_port_intentionally_unscaled_coordinate_count
    ] == "1"
    grounded_semantics = NLPDiagnostics.PortCoordinateSemantics(
        :transformer, "tx_1", "high";
        quantity = :voltage, representation = :rectangular_real,
        terminal_semantics = [grounded_coordinate, phase_coordinate],
    )
    grounded_value_report = NLPDiagnostics._port_coordinate_scale_findings(
        [grounded_semantics], [neutral_map],
        NLPDiagnostics.EvaluationPoint(
            MOI.VariableIndex[MOI.VariableIndex(1)], [1.0e-5],
        ),
    )
    @test length(findings(
        grounded_value_report,
        :component_port_expected_coordinate_value_mismatch,
    )) == 1
    @test_throws ArgumentError NLPDiagnostics.PortTerminalCoordinateSemantics(
        "n"; expected_value = 0.0,
    )
    @test_throws ArgumentError NLPDiagnostics.PortTerminalCoordinateSemantics(
        "n"; nominal_scale = 0.0,
    )
    mismatched_terminal_semantics = NLPDiagnostics.PortCoordinateSemantics(
        :transformer, "tx_1", "high";
        quantity = :voltage, terminal_semantics = [neutral_coordinate],
    )
    mismatched_terminal_report =
        NLPDiagnostics._component_port_coordinate_semantics_findings(
            [rank_deficient_port], [mismatched_terminal_semantics], [coordinate_map],
        )
    @test length(findings(
        mismatched_terminal_report,
        :component_port_terminal_semantics_dimension_mismatch,
    )) == 1
    @test NLPDiagnostics.PortCoordinateSemantics(
        :transformer, "tx_1", "angle";
        quantity = :angle, representation = :polar,
        units = Dict("angle" => "rad"),
    ).quantity == :angle
    unmapped_semantics_report =
        NLPDiagnostics._component_port_coordinate_semantics_findings(
            [rank_deficient_port], [port_semantics],
        )
    @test length(findings(
        unmapped_semantics_report,
        :component_port_coordinate_semantics_unmapped,
    )) == 1
    orphan_semantics = NLPDiagnostics.PortCoordinateSemantics(
        :transformer, "tx_1", "missing";
        quantity = :voltage, representation = :polar,
        units = Dict("voltage" => "p.u."),
    )
    orphan_semantics_report = NLPDiagnostics._component_port_coordinate_semantics_findings(
        [rank_deficient_port], [orphan_semantics],
    )
    @test length(findings(
        orphan_semantics_report,
        :component_port_coordinate_semantics_unaligned,
    )) == 1
    orphan_semantics_reason = only(filter(
        item -> item["code"] == "component_port_coordinate_semantics_unavailable",
        NLPDiagnostics.report_data(orphan_semantics_report)["unavailable_reasons"],
    ))
    @test orphan_semantics_reason["category"] == "input"
    @test orphan_semantics_reason["stage"] ==
          "component_port_coordinate_semantics"
    mapped_semantics_report =
        NLPDiagnostics._component_port_coordinate_semantics_findings(
            [rank_deficient_port], [port_semantics], [coordinate_map],
        )
    @test isempty(mapped_semantics_report.findings)
    second_coordinate_map = NLPDiagnostics.PortCoordinateMap(
        :transformer, "tx_1", "low", MOI.VariableIndex[MOI.VariableIndex(1)];
        terminal_to_variable = reshape([1.0, 0.0], 1, 2),
    )
    conflicting_port_semantics = NLPDiagnostics.PortCoordinateSemantics(
        :transformer, "tx_1", "low";
        quantity = :current, representation = :rectangular,
        units = Dict("current" => "p.u."),
    )
    conflicting_port_semantics_report =
        NLPDiagnostics._component_port_coordinate_semantics_findings(
            [rank_deficient_port, second_port],
            [port_semantics, conflicting_port_semantics],
            [coordinate_map, second_coordinate_map],
        )
    @test length(findings(
        conflicting_port_semantics_report,
        :component_port_coordinate_semantics_variable_conflict,
    )) == 1
    conflicting_port_scale_semantics = NLPDiagnostics.PortCoordinateSemantics(
        :transformer, "tx_1", "low";
        quantity = :voltage, representation = :polar,
        units = Dict("voltage" => "p.u."), nominal_scale = 2.0,
    )
    conflicting_port_scale_report =
        NLPDiagnostics._component_port_coordinate_semantics_findings(
            [rank_deficient_port, second_port],
            [scaled_port_semantics, conflicting_port_scale_semantics],
            [coordinate_map, second_coordinate_map],
        )
    @test length(findings(
        conflicting_port_scale_report,
        :component_port_coordinate_nominal_scale_conflict,
    )) == 1
    map_adjusted_second_coordinate_map = NLPDiagnostics.PortCoordinateMap(
        :transformer, "tx_1", "low", MOI.VariableIndex[MOI.VariableIndex(1)];
        terminal_to_variable = reshape([0.5, 0.0], 1, 2),
    )
    map_adjusted_port_scale_report =
        NLPDiagnostics._component_port_coordinate_semantics_findings(
            [rank_deficient_port, second_port],
            [scaled_port_semantics, conflicting_port_scale_semantics],
            [coordinate_map, map_adjusted_second_coordinate_map],
        )
    @test isempty(findings(
        map_adjusted_port_scale_report,
        :component_port_coordinate_nominal_scale_conflict,
    ))
    mixed_scale_coordinate_map = NLPDiagnostics.PortCoordinateMap(
        :transformer, "tx_1", "high", MOI.VariableIndex[MOI.VariableIndex(2)];
        terminal_to_variable = reshape([1.0, -1.0], 1, 2),
    )
    mixed_port_scale_report =
        NLPDiagnostics._component_port_coordinate_semantics_findings(
            [rank_deficient_port], [scaled_port_semantics], [mixed_scale_coordinate_map],
        )
    @test length(findings(
        mixed_port_scale_report,
        :component_port_coordinate_nominal_scale_mixed_projection,
    )) == 1
    cross_layer_component_semantics = NLPDiagnostics.ComponentCoordinateSemantics(
        :bus, "bus_1", MOI.VariableIndex[MOI.VariableIndex(1)];
        quantity = :angle, representation = :polar,
        units = Dict("angle" => "rad"),
    )
    component_port_semantics_report =
        NLPDiagnostics._component_port_coordinate_semantics_cross_layer_findings(
            [cross_layer_component_semantics], [port_semantics], [coordinate_map],
        )
    @test length(findings(
        component_port_semantics_report,
        :component_port_coordinate_semantics_cross_layer_conflict,
    )) == 1
    aligned_component_port_semantics = NLPDiagnostics.ComponentCoordinateSemantics(
        :bus, "bus_1", MOI.VariableIndex[MOI.VariableIndex(1)];
        quantity = :voltage, representation = :polar,
        units = Dict("voltage" => "p.u."),
    )
    @test isempty(NLPDiagnostics._component_port_coordinate_semantics_cross_layer_findings(
        [aligned_component_port_semantics], [port_semantics], [coordinate_map],
    ).findings)
    component_port_scale_conflict = NLPDiagnostics.ComponentCoordinateSemantics(
        :bus, "bus_1", MOI.VariableIndex[MOI.VariableIndex(1)];
        quantity = :voltage, representation = :polar,
        units = Dict("voltage" => "p.u."), nominal_scale = 2.0,
    )
    cross_layer_scale_report =
        NLPDiagnostics._component_port_coordinate_semantics_cross_layer_findings(
            [component_port_scale_conflict], [scaled_port_semantics], [coordinate_map],
        )
    @test length(findings(
        cross_layer_scale_report,
        :component_port_coordinate_nominal_scale_cross_layer_conflict,
    )) == 1
    aligned_component_port_scale = NLPDiagnostics.ComponentCoordinateSemantics(
        :bus, "bus_1", MOI.VariableIndex[MOI.VariableIndex(1)];
        quantity = :voltage, representation = :polar,
        units = Dict("voltage" => "p.u."), nominal_scale = 1.0,
    )
    @test isempty(NLPDiagnostics._component_port_coordinate_semantics_cross_layer_findings(
        [aligned_component_port_scale], [scaled_port_semantics], [coordinate_map],
    ).findings)
    scaled_coordinate_map = NLPDiagnostics.PortCoordinateMap(
        :transformer, "tx_1", "high", MOI.VariableIndex[MOI.VariableIndex(1)];
        terminal_to_variable = reshape([2.0, 0.0], 1, 2),
    )
    map_adjusted_component_scale = NLPDiagnostics.ComponentCoordinateSemantics(
        :bus, "bus_1", MOI.VariableIndex[MOI.VariableIndex(1)];
        quantity = :voltage, representation = :polar,
        units = Dict("voltage" => "p.u."), nominal_scale = 2.0,
    )
    @test isempty(NLPDiagnostics._component_port_coordinate_semantics_cross_layer_findings(
        [map_adjusted_component_scale], [scaled_port_semantics], [scaled_coordinate_map],
    ).findings)
    unadjusted_component_scale = NLPDiagnostics.ComponentCoordinateSemantics(
        :bus, "bus_1", MOI.VariableIndex[MOI.VariableIndex(1)];
        quantity = :voltage, representation = :polar,
        units = Dict("voltage" => "p.u."), nominal_scale = 1.0,
    )
    @test length(findings(
        NLPDiagnostics._component_port_coordinate_semantics_cross_layer_findings(
            [unadjusted_component_scale], [scaled_port_semantics], [scaled_coordinate_map],
        ),
        :component_port_coordinate_nominal_scale_cross_layer_conflict,
    )) == 1
    missing_port_scale_report =
        NLPDiagnostics._component_port_coordinate_semantics_cross_layer_findings(
            [aligned_component_port_scale], [port_semantics], [coordinate_map],
        )
    @test length(findings(
        missing_port_scale_report,
        :component_port_coordinate_nominal_scale_cross_layer_conflict,
    )) == 1
    unitless_semantics = NLPDiagnostics.PortCoordinateSemantics(
        :transformer, "tx_1", "high"; quantity = :current,
    )
    unitless_semantics_report =
        NLPDiagnostics._component_port_coordinate_semantics_findings(
            [rank_deficient_port], [unitless_semantics], [coordinate_map],
        )
    @test length(findings(
        unitless_semantics_report,
        :component_port_coordinate_semantics_units_unspecified,
    )) == 1
    @test_throws ArgumentError NLPDiagnostics.PortCoordinateSemantics(
        :transformer, "tx_1", "high"; quantity = :temperature,
    )
    @test_throws ArgumentError NLPDiagnostics.PortCoordinateSemantics(
        :transformer, "tx_1", "high";
        quantity = :voltage, units = Dict("voltage" => " "),
    )
    component_angle_semantics = NLPDiagnostics.ComponentCoordinateSemantics(
        :bus, "bus_1", MOI.VariableIndex[MOI.VariableIndex(1)];
        quantity = :angle, representation = :polar,
        units = Dict("angle" => "rad"),
    )
    legacy_component_semantics = NLPDiagnostics.ComponentCoordinateSemantics(
        :bus, "bus_legacy", MOI.VariableIndex[MOI.VariableIndex(1)],
        :angle, :polar, Dict("angle" => "rad"), "legacy positional record",
    )
    @test isnothing(legacy_component_semantics.nominal_scale)
    constraint_scale_reference = NLPDiagnostics.EntityRef(:constraint, 1)
    constraint_scale_semantics = NLPDiagnostics.ComponentConstraintScaleSemantics(
        :bus, "bus_1", [constraint_scale_reference];
        quantity = :power_balance, units = Dict("power" => "p.u."), nominal_scale = 1.0,
    )
    @test constraint_scale_semantics.nominal_scale == 1.0
    @test_throws ArgumentError NLPDiagnostics.ComponentConstraintScaleSemantics(
        :bus, "bus_1", [constraint_scale_reference, constraint_scale_reference];
        nominal_scale = 1.0,
    )
    @test_throws ArgumentError NLPDiagnostics.ComponentConstraintScaleSemantics(
        :bus, "bus_1", [NLPDiagnostics.EntityRef(:variable, 1)]; nominal_scale = 1.0,
    )
    empty_constraint_scale_model = MOIU.Model{Float64}()
    empty_constraint_scale_report = NLPDiagnostics.analyze_component_constraint_scales(
        empty_constraint_scale_model,
        NLPDiagnostics.EvaluationPoint(MOI.VariableIndex[], Float64[]),
    )
    @test empty_constraint_scale_report.metadata[
        :component_constraint_scale_declaration_count
    ] == "0"
    @test empty_constraint_scale_report.metadata[
        :component_constraint_scale_source_count
    ] == "0"
    unknown_constraint_scale = NLPDiagnostics.ComponentConstraintScaleSemantics(
        :bus, "bus_unknown", [NLPDiagnostics.EntityRef(:constraint, 2)]; nominal_scale = 1.0,
    )
    constraint_scale_scope_report =
        NLPDiagnostics._component_constraint_scale_semantics_findings(
            [unknown_constraint_scale], [constraint_scale_reference],
        )
    @test length(findings(
        constraint_scale_scope_report, :component_constraint_scale_unknown_source,
    )) == 1
    nlp_constraint_scale = NLPDiagnostics.ComponentConstraintScaleSemantics(
        :bus, "bus_nlp", [NLPDiagnostics.EntityRef(:nlp_constraint, 1)]; nominal_scale = 1.0,
    )
    nlp_constraint_scale_scope_report =
        NLPDiagnostics._component_constraint_scale_semantics_findings(
            [nlp_constraint_scale], [constraint_scale_reference],
        )
    @test length(findings(
        nlp_constraint_scale_scope_report,
        :component_constraint_scale_nlp_source_runtime_only,
    )) == 1
    constraint_scale_point = NLPDiagnostics.EvaluationPoint(
        MOI.VariableIndex[], Float64[]; label = "constraint-scale fixture",
    )
    constraint_scale_activity = NLPDiagnostics.ConstraintActivity{Float64}(
        1, constraint_scale_reference, 10.0, 0.0, 0.0, 10.0, -10.0, 10.0,
        false, false, :violated,
    )
    constraint_scale_summary = NLPDiagnostics.ConstraintFeasibilitySummary{Float64}(
        constraint_scale_point, [constraint_scale_activity], 1.0e-8, 1.0e-8,
        true, nothing,
    )
    constraint_scale_report = NLPDiagnostics.analyze_component_constraint_scales(
        [constraint_scale_semantics], constraint_scale_summary;
        mismatch_factor = 2.0,
    )
    @test length(findings(
        constraint_scale_report, :component_constraint_nominal_scale_mismatch,
    )) == 1
    @test constraint_scale_report.metadata[:component_constraint_scale_missing_source_count] == "0"
    @test constraint_scale_report.metadata[:component_constraint_scale_unavailable_residual_count] == "0"
    @test constraint_scale_report.metadata[:component_constraint_scale_source_count] == "1"
    stale_constraint_scale = NLPDiagnostics.ComponentConstraintScaleSemantics(
        :bus, "bus_stale", [NLPDiagnostics.EntityRef(:constraint, 2)]; nominal_scale = 1.0,
    )
    stale_constraint_scale_report = NLPDiagnostics.analyze_component_constraint_scales(
        [stale_constraint_scale], constraint_scale_summary; mismatch_factor = 2.0,
    )
    @test stale_constraint_scale_report.metadata[
        :component_constraint_scale_missing_source_count
    ] == "1"
    @test length(findings(
        stale_constraint_scale_report, :component_constraint_scale_alignment_unavailable,
    )) == 1
    stale_constraint_scale_reason = only(filter(
        item -> item["code"] ==
            "component_constraint_scale_alignment_unavailable",
        NLPDiagnostics.report_data(stale_constraint_scale_report)[
            "unavailable_reasons"
        ],
    ))
    @test stale_constraint_scale_reason["category"] == "capability"
    @test stale_constraint_scale_reason["stage"] ==
          "component_constraint_scale_alignment"
    unavailable_scalar_activity = NLPDiagnostics.ConstraintActivity{Float64}(
        1, constraint_scale_reference, missing, 0.0, 0.0, nothing, nothing,
        nothing, false, false, :unavailable,
    )
    unavailable_scalar_summary = NLPDiagnostics.ConstraintFeasibilitySummary{Float64}(
        constraint_scale_point, [unavailable_scalar_activity], 1.0e-8, 1.0e-8,
        false, "unavailable scalar residual fixture",
    )
    unavailable_scalar_scale_report = NLPDiagnostics.analyze_component_constraint_scales(
        [constraint_scale_semantics], unavailable_scalar_summary; mismatch_factor = 2.0,
    )
    @test unavailable_scalar_scale_report.metadata[
        :component_constraint_scale_unavailable_residual_count
    ] == "1"
    conflicting_constraint_scale = NLPDiagnostics.ComponentConstraintScaleSemantics(
        :controller, "ctl_1", [constraint_scale_reference]; nominal_scale = 2.0,
    )
    conflicting_constraint_scale_report =
        NLPDiagnostics.analyze_component_constraint_scales(
            [constraint_scale_semantics, conflicting_constraint_scale],
            constraint_scale_summary; mismatch_factor = 2.0,
        )
    @test length(findings(
        conflicting_constraint_scale_report,
        :component_constraint_nominal_scale_conflict,
    )) == 1
    coupled_scale_activity = NLPDiagnostics.CoupledSetActivity{Float64}(
        constraint_scale_reference, :second_order_cone, Union{Missing,Float64}[0.0, 10.0],
        -10.0, 10.0, false, :violated, nothing,
    )
    coupled_scale_summary = NLPDiagnostics.CoupledSetFeasibilitySummary{Float64}(
        constraint_scale_point, [coupled_scale_activity],
        NLPDiagnostics.CoupledSetTangentEvidence{Float64}[], 1.0e-8, 1.0e-8,
        true, nothing,
    )
    coupled_scale_report = NLPDiagnostics.analyze_component_constraint_scales(
        [constraint_scale_semantics], coupled_scale_summary; mismatch_factor = 2.0,
    )
    @test length(findings(
        coupled_scale_report, :component_coupled_constraint_nominal_scale_mismatch,
    )) == 1
    @test coupled_scale_report.metadata[
        :component_coupled_constraint_scale_missing_source_count
    ] == "0"
    @test coupled_scale_report.metadata[
        :component_coupled_constraint_scale_unsupported_geometry_count
    ] == "0"
    @test coupled_scale_report.metadata[
        :component_coupled_constraint_scale_source_count
    ] == "1"
    @test coupled_scale_report.metadata[
        :component_coupled_constraint_scale_supported_geometry_count
    ] == "1"
    stale_coupled_scale_report = NLPDiagnostics.analyze_component_constraint_scales(
        [stale_constraint_scale], coupled_scale_summary; mismatch_factor = 2.0,
    )
    @test stale_coupled_scale_report.metadata[
        :component_coupled_constraint_scale_missing_source_count
    ] == "1"
    @test length(findings(
        stale_coupled_scale_report,
        :component_coupled_constraint_scale_alignment_unavailable,
    )) == 1
    stale_coupled_scale_reason = only(filter(
        item -> item["code"] ==
            "component_coupled_constraint_scale_alignment_unavailable",
        NLPDiagnostics.report_data(stale_coupled_scale_report)[
            "unavailable_reasons"
        ],
    ))
    @test stale_coupled_scale_reason["category"] == "capability"
    @test stale_coupled_scale_reason["stage"] ==
          "component_coupled_constraint_scale_alignment"
    unsupported_coupled_activity = NLPDiagnostics.CoupledSetActivity{Float64}(
        constraint_scale_reference, :plugin_coupled_set,
        Union{Missing,Float64}[0.0], nothing, 1.0, false, :violated, nothing,
    )
    unsupported_coupled_summary = NLPDiagnostics.CoupledSetFeasibilitySummary{Float64}(
        constraint_scale_point, [unsupported_coupled_activity],
        NLPDiagnostics.CoupledSetTangentEvidence{Float64}[], 1.0e-8, 1.0e-8,
        false, "unsupported geometry fixture",
    )
    unsupported_coupled_scale_report = NLPDiagnostics.analyze_component_constraint_scales(
        [constraint_scale_semantics], unsupported_coupled_summary; mismatch_factor = 2.0,
    )
    @test unsupported_coupled_scale_report.metadata[
        :component_coupled_constraint_scale_unsupported_geometry_count
    ] == "1"
    @test length(findings(
        unsupported_coupled_scale_report,
        :component_coupled_constraint_scale_alignment_unavailable,
    )) == 1
    unavailable_soc_activity = NLPDiagnostics.CoupledSetActivity{Float64}(
        constraint_scale_reference, :second_order_cone,
        Union{Missing,Float64}[missing, missing], nothing, nothing, false,
        :unavailable, "non-finite fixture",
    )
    unavailable_soc_summary = NLPDiagnostics.CoupledSetFeasibilitySummary{Float64}(
        constraint_scale_point, [unavailable_soc_activity],
        NLPDiagnostics.CoupledSetTangentEvidence{Float64}[], 1.0e-8, 1.0e-8,
        false, "unavailable residual fixture",
    )
    unavailable_soc_scale_report = NLPDiagnostics.analyze_component_constraint_scales(
        [constraint_scale_semantics], unavailable_soc_summary; mismatch_factor = 2.0,
    )
    @test unavailable_soc_scale_report.metadata[
        :component_coupled_constraint_scale_unavailable_residual_count
    ] == "1"
    coupled_conflict_report = NLPDiagnostics.analyze_component_constraint_scales(
        [constraint_scale_semantics, conflicting_constraint_scale], coupled_scale_summary;
        mismatch_factor = 2.0,
    )
    @test length(findings(
        coupled_conflict_report, :component_coupled_constraint_nominal_scale_conflict,
    )) == 1
    scale_semantics = NLPDiagnostics.ComponentCoordinateSemantics(
        :bus, "bus_1", MOI.VariableIndex[MOI.VariableIndex(1)];
        quantity = :voltage, representation = :rectangular,
        units = Dict("voltage" => "p.u."), nominal_scale = 1.0,
    )
    scale_report = NLPDiagnostics.analyze_component_coordinate_scales(
        [scale_semantics],
        NLPDiagnostics.EvaluationPoint(MOI.VariableIndex[MOI.VariableIndex(1)], [1.0e4]);
        mismatch_factor = 1.0e3,
    )
    @test scale_report.metadata[:component_coordinate_nominal_scale_checked_variable_count] == "1"
    @test length(findings(
        scale_report, :component_coordinate_nominal_scale_mismatch,
    )) == 1
    duplicate_scale_semantics = NLPDiagnostics.ComponentCoordinateSemantics(
        :controller, "ctl_1", MOI.VariableIndex[MOI.VariableIndex(1)];
        quantity = :voltage, representation = :rectangular,
        units = Dict("voltage" => "p.u."), nominal_scale = 1.0,
    )
    deduplicated_scale_report = NLPDiagnostics.analyze_component_coordinate_scales(
        [scale_semantics, duplicate_scale_semantics],
        NLPDiagnostics.EvaluationPoint(MOI.VariableIndex[MOI.VariableIndex(1)], [1.0e4]);
        mismatch_factor = 1.0e3,
    )
    @test length(findings(
        deduplicated_scale_report, :component_coordinate_nominal_scale_mismatch,
    )) == 1
    @test occursin("bus:bus_1", Dict(
        only(findings(deduplicated_scale_report,
                      :component_coordinate_nominal_scale_mismatch)).evidence[1].details,
    )["components"])
    unscaled_component_numerical_report = NLPDiagnostics.analyze_numerical(
        MOIU.Model{Float64}(),
        NLPDiagnostics.EvaluationPoint(MOI.VariableIndex[], Float64[]),
    )
    @test unscaled_component_numerical_report.metadata[
        :component_coordinate_nominal_scale_declaration_count
    ] == "0"
    @test_throws ArgumentError NLPDiagnostics.ComponentCoordinateSemantics(
        :bus, "bus_1", MOI.VariableIndex[MOI.VariableIndex(1)];
        quantity = :voltage, nominal_scale = 0.0,
    )
    @test isempty(NLPDiagnostics._component_coordinate_semantics_findings(
        [component_angle_semantics], MOI.VariableIndex[MOI.VariableIndex(1)],
        components = [NLPDiagnostics.ComponentMetadata(
            :bus, "bus_1"; variables = MOI.VariableIndex[MOI.VariableIndex(1)],
        )],
    ).findings)
    duplicate_component_semantics = NLPDiagnostics.ComponentCoordinateSemantics(
        :bus, "bus_1", MOI.VariableIndex[MOI.VariableIndex(1)]; quantity = :voltage,
    )
    duplicate_component_semantics_report =
        NLPDiagnostics._component_coordinate_semantics_findings(
            [component_angle_semantics, duplicate_component_semantics],
            MOI.VariableIndex[MOI.VariableIndex(1)],
        )
    @test length(findings(
        duplicate_component_semantics_report,
        :duplicate_component_coordinate_semantics,
    )) == 1
    conflicting_component_semantics = NLPDiagnostics.ComponentCoordinateSemantics(
        :controller, "ctl_1", MOI.VariableIndex[MOI.VariableIndex(1)];
        quantity = :voltage, representation = :rectangular,
        units = Dict("voltage" => "p.u."),
    )
    conflicting_component_semantics_report =
        NLPDiagnostics._component_coordinate_semantics_findings(
            [component_angle_semantics, conflicting_component_semantics],
            MOI.VariableIndex[MOI.VariableIndex(1)],
        )
    @test length(findings(
        conflicting_component_semantics_report,
        :component_coordinate_semantics_variable_conflict,
    )) == 1
    conflicting_component_scale = NLPDiagnostics.ComponentCoordinateSemantics(
        :controller, "ctl_2", MOI.VariableIndex[MOI.VariableIndex(1)];
        quantity = :voltage, representation = :rectangular,
        units = Dict("voltage" => "p.u."), nominal_scale = 2.0,
    )
    conflicting_component_scale_report =
        NLPDiagnostics._component_coordinate_semantics_findings(
            [scale_semantics, conflicting_component_scale],
            MOI.VariableIndex[MOI.VariableIndex(1)],
        )
    @test length(findings(
        conflicting_component_scale_report,
        :component_coordinate_semantics_variable_conflict,
    )) == 1
    out_of_scope_component_semantics = NLPDiagnostics.ComponentCoordinateSemantics(
        :bus, "bus_1", MOI.VariableIndex[MOI.VariableIndex(2)];
        quantity = :angle, representation = :polar, units = Dict("angle" => "rad"),
    )
    out_of_scope_component_semantics_report =
        NLPDiagnostics._component_coordinate_semantics_findings(
            [out_of_scope_component_semantics],
            MOI.VariableIndex[MOI.VariableIndex(1), MOI.VariableIndex(2)],
            components = [NLPDiagnostics.ComponentMetadata(
                :bus, "bus_1"; variables = MOI.VariableIndex[MOI.VariableIndex(1)],
            )],
        )
    @test length(findings(
        out_of_scope_component_semantics_report,
        :component_coordinate_semantics_scope_outside_component,
    )) == 1
    terminal_port_mode = NLPDiagnostics.PortNullspaceMode(
        :transformer, "tx_1", "high", :terminal, [0.0, 1.0],
    )
    named_terminal_port_mode = NLPDiagnostics.PortNullspaceMode(
        :transformer, "tx_1", "high", :terminal, [0.0, 1.0];
        name = :floating_neutral,
        description = "Plugin-defined physical identifier only.",
    )
    @test named_terminal_port_mode.name == :floating_neutral
    named_mode_semantics = NLPDiagnostics.PortNullspaceModeSemantics(
        :transformer, "tx_1", "high", :floating_neutral;
        category = :floating_neutral,
        description = "Plugin-owned physical label.",
    )
    @test named_mode_semantics.category == :floating_neutral
    named_mode_semantic_report = NLPDiagnostics._component_port_nullspace_mode_semantic_findings(
        [named_terminal_port_mode], [named_mode_semantics],
    )
    @test length(findings(
        named_mode_semantic_report,
        :component_port_nullspace_mode_semantics_declared,
    )) == 1
    @test named_mode_semantic_report.metadata[
        :component_port_nullspace_mode_semantics_aligned_count
    ] == "1"
    unaligned_mode_semantics = NLPDiagnostics.PortNullspaceModeSemantics(
        :transformer, "tx_1", "high", :missing_mode;
        category = :floating_neutral,
    )
    @test length(findings(
        NLPDiagnostics._component_port_nullspace_mode_semantic_findings(
            [named_terminal_port_mode], [unaligned_mode_semantics],
        ),
        :component_port_nullspace_mode_semantics_unaligned,
    )) == 1
    unaligned_mode_semantics_report =
        NLPDiagnostics._component_port_nullspace_mode_semantic_findings(
            [named_terminal_port_mode], [unaligned_mode_semantics],
        )
    unaligned_mode_semantics_reason = only(filter(
        item -> item["code"] ==
            "component_port_nullspace_mode_semantics_unavailable",
        NLPDiagnostics.report_data(unaligned_mode_semantics_report)[
            "unavailable_reasons"
        ],
    ))
    @test unaligned_mode_semantics_reason["category"] == "input"
    @test unaligned_mode_semantics_reason["stage"] ==
          "component_port_nullspace_mode_semantics"
    visible_coordinate_map = NLPDiagnostics.PortCoordinateMap(
        :transformer, "tx_1", "high", MOI.VariableIndex[MOI.VariableIndex(1)];
        terminal_to_variable = reshape([0.0, 1.0], 1, 2),
    )
    port_mode_coordinate_report =
        NLPDiagnostics._component_port_mode_coordinate_projection_findings(
            [rank_deficient_port], [terminal_port_mode], [visible_coordinate_map],
        )
    @test length(findings(
        port_mode_coordinate_report,
        :component_port_mode_coordinate_projection_available,
    )) == 1
    missing_port_mode_coordinate_report =
        NLPDiagnostics._component_port_mode_coordinate_projection_findings(
            [rank_deficient_port], [terminal_port_mode], NLPDiagnostics.PortCoordinateMap[],
        )
    @test length(findings(
        missing_port_mode_coordinate_report,
        :component_port_mode_coordinate_projection_unavailable,
    )) == 1
    missing_port_mode_reason = only(filter(
        item -> item["code"] ==
            "component_port_mode_coordinate_projection_unavailable",
        NLPDiagnostics.report_data(missing_port_mode_coordinate_report)[
            "unavailable_reasons"
        ],
    ))
    @test missing_port_mode_reason["category"] == "input"
    @test missing_port_mode_reason["stage"] ==
          "component_port_mode_coordinate_projection"
    component_projected_modes = NLPDiagnostics.port_component_expected_nullspace_modes(
        [rank_deficient_port], [terminal_port_mode], [visible_coordinate_map],
    )
    @test length(component_projected_modes) == 1
    @test component_projected_modes[1].name ==
          :component_port_candidate_mode_transformer_tx_1_high_1
    @test only(NLPDiagnostics.port_component_expected_nullspace_modes(
        [rank_deficient_port], [named_terminal_port_mode], [visible_coordinate_map],
    )).name == :component_port_candidate_mode_transformer_tx_1_high_floating_neutral
    duplicate_terminal_port_mode = NLPDiagnostics.PortNullspaceMode(
        :transformer, "tx_1", "high", :terminal, [0.0, 2.0],
    )
    dependent_component_modes = NLPDiagnostics.port_component_expected_nullspace_modes(
        [rank_deficient_port], [terminal_port_mode, duplicate_terminal_port_mode],
        [visible_coordinate_map],
    )
    dependent_component_mode_report =
        NLPDiagnostics._port_expected_mode_span_findings(dependent_component_modes)
    @test length(findings(
        dependent_component_mode_report,
        :port_expected_nullspace_candidate_span_dependent,
    )) == 1
    @test dependent_component_mode_report.metadata[
        :port_expected_nullspace_candidate_span_rank
    ] == "1"
    dependent_component_mode_summary = NLPDiagnostics.port_expected_nullspace_summary(
        dependent_component_modes,
    )
    @test dependent_component_mode_summary.variables ==
          MOI.VariableIndex[MOI.VariableIndex(1)]
    @test dependent_component_mode_summary.candidate_names == [
        :component_port_candidate_mode_transformer_tx_1_high_1,
        :component_port_candidate_mode_transformer_tx_1_high_2,
    ]
    @test dependent_component_mode_summary.candidate_origins == [:component, :component]
    @test all(occursin("component-port null direction", description) for
              description in dependent_component_mode_summary.candidate_descriptions)
    @test size(dependent_component_mode_summary.directions) == (1, 2)
    @test dependent_component_mode_summary.rank == 1
    @test NLPDiagnostics.port_expected_nullspace_summary(
        [rank_deficient_port], [terminal_port_mode],
        NLPDiagnostics.PortConnectionMetadata{Float64}[], [visible_coordinate_map],
    ).rank == 1
    @test NLPDiagnostics.port_expected_nullspace_summary(
        NLPDiagnostics.ExpectedNullspaceMode[],
    ).rank == 0
    @test_throws ArgumentError NLPDiagnostics.ExpectedNullspaceMode(
        :nonfinite, MOI.VariableIndex[MOI.VariableIndex(1)], [NaN],
    )
    @test_throws ArgumentError NLPDiagnostics.PortNullspaceMode(
        :transformer, "tx_1", "high", :terminal, [NaN],
    )
    unaligned_coordinate_map = NLPDiagnostics.PortCoordinateMap(
        :transformer, "tx_1", "missing", MOI.VariableIndex[MOI.VariableIndex(1)];
        terminal_to_variable = reshape([1.0], 1, 1),
    )
    unaligned_coordinate_map_report = NLPDiagnostics._component_port_coordinate_map_findings(
        [rank_deficient_port], [unaligned_coordinate_map];
        model_variables = MOI.VariableIndex[MOI.VariableIndex(1)],
    )
    @test length(findings(
        unaligned_coordinate_map_report,
        :component_port_coordinate_map_unaligned,
    )) == 1
    unaligned_coordinate_map_reason = only(filter(
        item -> item["code"] == "component_port_coordinate_map_unavailable",
        NLPDiagnostics.report_data(unaligned_coordinate_map_report)[
            "unavailable_reasons"
        ],
    ))
    @test unaligned_coordinate_map_reason["category"] == "input"
    @test unaligned_coordinate_map_reason["stage"] ==
          "component_port_coordinate_map"
    coordinate_projection = NLPDiagnostics.port_topology_coordinate_projection(
        [rank_deficient_port, second_port], [connection],
        [coordinate_map, NLPDiagnostics.PortCoordinateMap(
            :transformer, "tx_1", "low", MOI.VariableIndex[MOI.VariableIndex(2)];
            terminal_to_variable = reshape([1.0, 0.0], 1, 2),
        )],
    )
    @test coordinate_projection.available
    @test coordinate_projection.variables == MOI.VariableIndex[MOI.VariableIndex(1), MOI.VariableIndex(2)]
    @test size(coordinate_projection.projected_nullspace) == (2, 2)
    isolated_coordinate_map = NLPDiagnostics.PortCoordinateMap(
        :load, "load_1", "terminal", MOI.VariableIndex[MOI.VariableIndex(3)];
        terminal_to_variable = reshape([1.0], 1, 1),
    )
    @test isempty(NLPDiagnostics.port_topology_expected_nullspace_modes(
        [isolated_port], NLPDiagnostics.PortConnectionMetadata{Float64}[],
        [isolated_coordinate_map],
    ))
    projected_modes = NLPDiagnostics.port_topology_expected_nullspace_modes(
        [rank_deficient_port, second_port], [connection],
        [coordinate_map, NLPDiagnostics.PortCoordinateMap(
            :transformer, "tx_1", "low", MOI.VariableIndex[MOI.VariableIndex(2)];
            terminal_to_variable = reshape([1.0, 0.0], 1, 2),
        )],
    )
    @test length(projected_modes) == 1
    @test projected_modes[1].name == :port_topology_candidate_mode_1
    @test occursin("transformer:tx_1:high", projected_modes[1].description)
    coordinate_projection_report = NLPDiagnostics._component_port_topology_coordinate_projection_findings(
        [rank_deficient_port, second_port], [connection],
        [coordinate_map, NLPDiagnostics.PortCoordinateMap(
            :transformer, "tx_1", "low", MOI.VariableIndex[MOI.VariableIndex(2)];
            terminal_to_variable = reshape([1.0, 0.0], 1, 2),
        )],
    )
    @test length(findings(
        coordinate_projection_report,
        :component_port_topology_model_projection_available,
    )) == 1
    unavailable_coordinate_projection_report =
        NLPDiagnostics._component_port_topology_coordinate_projection_findings(
            [rank_deficient_port, second_port], [connection],
            [unaligned_coordinate_map],
        )
    unavailable_coordinate_projection_reason = only(filter(
        item -> item["code"] ==
            "component_port_topology_model_projection_unavailable",
        NLPDiagnostics.report_data(unavailable_coordinate_projection_report)[
            "unavailable_reasons"
        ],
    ))
    @test unavailable_coordinate_projection_reason["category"] == "input"
    @test unavailable_coordinate_projection_reason["stage"] ==
          "component_port_topology_model_projection"
    @test_throws DimensionMismatch NLPDiagnostics.PortCoordinateMap(
        :transformer, "tx_1", "high", MOI.VariableIndex[MOI.VariableIndex(1)];
        terminal_to_variable = [1.0 0.0; 0.0 1.0],
    )
    topology_nullspace_report = NLPDiagnostics._component_port_topology_nullspace_findings(
        [rank_deficient_port, second_port], [connection],
    )
    @test length(findings(
        topology_nullspace_report,
        :component_port_topology_expected_nullspace,
    )) == 1
    unavailable_topology_nullspace_report =
        NLPDiagnostics._component_port_topology_nullspace_findings(
            [rank_deficient_port, second_port], [bad_connection],
        )
    unavailable_topology_nullspace_reason = only(filter(
        item -> item["code"] == "component_port_topology_nullspace_unavailable",
        NLPDiagnostics.report_data(unavailable_topology_nullspace_report)[
            "unavailable_reasons"
        ],
    ))
    @test unavailable_topology_nullspace_reason["category"] == "input"
    @test unavailable_topology_nullspace_reason["stage"] ==
          "component_port_topology_nullspace"
    @test_throws DimensionMismatch NLPDiagnostics.ComponentPortMetadata(
        :line, "line_1", "bad";
        terminal_labels = ["a"], mode_labels = ["a", "b"],
        connection_matrix = [1.0],
    )
    @test_throws ArgumentError NLPDiagnostics.ComponentMetadata(Symbol(""), "line")
    @test_throws ArgumentError NLPDiagnostics.ComponentMetadata(:line, " ")
    @test_throws ArgumentError NLPDiagnostics.ComponentMetadata(:line, "bad"; expected_rank = -1)
    @test_throws ArgumentError NLPDiagnostics.ComponentMetadata(
        :line,
        "bad";
        units = Dict(Symbol("") => "kV"),
    )
    @test_throws ArgumentError NLPDiagnostics.ComponentMetadata(
        :line,
        "bad";
        variables = MOI.VariableIndex[MOI.VariableIndex(1), MOI.VariableIndex(1)],
    )
    @test_throws ArgumentError NLPDiagnostics.ComponentMetadata(
        :line,
        "bad";
        variables = MOI.VariableIndex[MOI.VariableIndex(1)],
        expected_rank = 2,
    )
    @test_throws ArgumentError NLPDiagnostics.ComponentMetadata(
        :line,
        "bad";
        constraints = [NLPDiagnostics.EntityRef(:constraint, 1)],
        expected_rank = 2,
    )
    generic_capability_report = NLPDiagnostics.component_rank_capability_report([
        NLPDiagnostics.ComponentMetadata(
            :line, "declared";
            variables = MOI.VariableIndex[MOI.VariableIndex(1)],
            expected_rank = 1,
        ),
        NLPDiagnostics.ComponentMetadata(:line, "undeclared"),
    ]; source = "test plugin")
    @test generic_capability_report.metadata[:component_metadata_count] == "2"
    @test generic_capability_report.metadata[:component_expected_rank_declared_count] == "1"
    @test generic_capability_report.metadata[:component_expected_rank_unavailable_count] == "1"
    @test generic_capability_report.metadata[:component_expected_rank_coverage] == "0.5"
    @test generic_capability_report.metadata[:component_expected_rank_available] == "false"
    @test generic_capability_report.metadata[:component_expected_rank_reason] ==
          "one or more component metadata entries omit expected_rank"
    generic_capability_data = NLPDiagnostics.report_data(generic_capability_report)
    @test length(generic_capability_data["unavailable_reasons"]) == 1
    @test generic_capability_data["unavailable_reasons"][1]["code"] ==
          "component_expected_rank_unavailable"
    @test generic_capability_data["unavailable_reasons"][1]["category"] == "capability"
    @test generic_capability_data["unavailable_reasons"][1]["stage"] ==
          "component_rank_capability"
    @test length(findings(generic_capability_report,
                          :component_expected_rank_unavailable)) == 1
    complete_capability_report = NLPDiagnostics.component_rank_capability_report([
        NLPDiagnostics.ComponentMetadata(
            :line, "declared";
            variables = MOI.VariableIndex[MOI.VariableIndex(1)],
            expected_rank = 1,
        ),
    ])
    @test isempty(complete_capability_report.findings)
    @test complete_capability_report.metadata[:component_expected_rank_available] == "true"
    malformed = NLPDiagnostics.ComponentMetadata[
        NLPDiagnostics.ComponentMetadata(Symbol(""), "", MOI.VariableIndex[MOI.VariableIndex(2), MOI.VariableIndex(2)], NLPDiagnostics.EntityRef[], Dict(Symbol("") => " "), -1, Dict{String,String}()),
        NLPDiagnostics.ComponentMetadata(:line, "duplicate", MOI.VariableIndex[], NLPDiagnostics.EntityRef[], Dict{Symbol,String}(), nothing, Dict{String,String}()),
        NLPDiagnostics.ComponentMetadata(:line, "duplicate", MOI.VariableIndex[], NLPDiagnostics.EntityRef[], Dict{Symbol,String}(), nothing, Dict{String,String}()),
        NLPDiagnostics.ComponentMetadata(:generator, "rank", MOI.VariableIndex[MOI.VariableIndex(3)], NLPDiagnostics.EntityRef[], Dict{Symbol,String}(), 2, Dict{String,String}()),
        NLPDiagnostics.ComponentMetadata(:branch, "constraints", MOI.VariableIndex[], [NLPDiagnostics.EntityRef(:constraint, 4), NLPDiagnostics.EntityRef(:constraint, 4), NLPDiagnostics.EntityRef(:variable, 1)], Dict{Symbol,String}(), 2, Dict{String,String}()),
    ]
    metadata_report = NLPDiagnostics._component_metadata_findings(
        malformed;
        model_variables = MOI.VariableIndex[MOI.VariableIndex(1)],
        model_constraints = [NLPDiagnostics.EntityRef(:constraint, 1)],
    )
    @test length(findings(metadata_report, :invalid_component_metadata_identity)) == 1
    @test length(findings(metadata_report, :invalid_component_metadata_units)) == 1
    @test length(findings(metadata_report, :invalid_component_metadata_expected_rank)) == 1
    @test length(findings(metadata_report, :duplicate_component_metadata)) == 1
    @test length(findings(metadata_report, :component_metadata_duplicate_variables)) == 1
    @test length(findings(metadata_report, :component_metadata_unknown_variable)) == 2
    @test length(findings(metadata_report, :component_metadata_expected_rank_exceeds_scope)) == 2
    @test length(findings(metadata_report, :component_metadata_duplicate_constraints)) == 1
    @test length(findings(metadata_report, :invalid_component_metadata_constraint_reference)) == 1
    @test length(findings(metadata_report, :component_metadata_unknown_constraint)) == 1
    @test metadata_report.metadata[:component_metadata_scope_unavailable_count] == "6"
    metadata_scope_reason = only(filter(
        item -> item["code"] == "component_metadata_scope_unavailable",
        NLPDiagnostics.report_data(metadata_report)["unavailable_reasons"],
    ))
    @test metadata_scope_reason["category"] == "input"
    @test metadata_scope_reason["stage"] == "component_metadata_scope_validation"
    @test length(findings(metadata_report, :component_metadata_scope_unavailable)) == 1

    rank_model = MOIU.Model{Float64}()
    x = MOI.add_variable(rank_model)
    constraint = MOI.add_constraint(rank_model, x, MOI.EqualTo(0.0))
    point = NLPDiagnostics.evaluation_point(rank_model, [0.0])
    evaluation = NLPDiagnostics.evaluate_numerical(rank_model, point)
    aligned = NLPDiagnostics.ComponentMetadata(
        :line,
        "aligned";
        variables = [x],
        constraints = [NLPDiagnostics.EntityRef(:constraint, constraint.value)],
        expected_rank = 1,
    )
    undeclared_component = NLPDiagnostics.ComponentMetadata(:line, "undeclared")
    rank_report = NLPDiagnostics.analyze_component_ranks(
        rank_model,
        evaluation;
        components = [aligned, undeclared_component],
    )
    @test rank_report.metadata[:component_rank_declared_count] == "1"
    @test rank_report.metadata[:component_rank_comparison_count] == "1"
    @test rank_report.metadata[:component_rank_unavailable_count] == "0"
    @test rank_report.metadata[:component_rank_capability_checked] == "true"
    @test rank_report.metadata[:component_expected_rank_declared_count] == "1"
    @test rank_report.metadata[:component_expected_rank_unavailable_count] == "1"
    @test rank_report.metadata[:component_expected_rank_coverage] == "0.5"
    @test rank_report.metadata[:component_rank_expected_nullity_observed_count] == "0"
    @test rank_report.metadata[:component_rank_unexpected_additional_nullity_count] == "0"
    @test rank_report.metadata[:component_rank_unobserved_declared_nullity_count] == "0"
    @test isempty(findings(rank_report, :component_expected_rank_mismatch))
    mismatched = NLPDiagnostics.ComponentMetadata(
        :line,
        "mismatched";
        variables = [x],
        constraints = [NLPDiagnostics.EntityRef(:constraint, constraint.value)],
        expected_rank = 0,
    )
    mismatch_report = NLPDiagnostics.analyze_component_ranks(
        rank_model,
        evaluation;
        components = [mismatched],
    )
    @test length(findings(mismatch_report, :component_expected_rank_mismatch)) == 1
    @test mismatch_report.metadata[:component_rank_unexpected_additional_nullity_count] == "0"
    @test mismatch_report.metadata[:component_rank_unobserved_declared_nullity_count] == "1"

    y = MOI.add_variable(rank_model)
    freedom = MOI.add_constraint(
        rank_model,
        MOI.ScalarAffineFunction([MOI.ScalarAffineTerm(1.0, x)], 0.0),
        MOI.EqualTo(0.0),
    )
    freedom_evaluation = NLPDiagnostics.evaluate_numerical(
        rank_model,
        NLPDiagnostics.evaluation_point(rank_model, [0.0, 0.0]),
    )
    freedom_component = NLPDiagnostics.ComponentMetadata(
        :floating_device,
        "one_expected_mode";
        variables = [x, y],
        constraints = [NLPDiagnostics.EntityRef(:constraint, freedom.value)],
        expected_rank = 1,
    )
    freedom_report = NLPDiagnostics.analyze_component_ranks(
        rank_model,
        freedom_evaluation;
        components = [freedom_component],
    )
    @test freedom_report.metadata[:component_rank_expected_nullity_observed_count] == "1"
    @test length(findings(freedom_report, :component_expected_right_nullity_observed)) == 1
    @test isempty(findings(freedom_report, :component_expected_rank_mismatch))

    extra_mode_component = NLPDiagnostics.ComponentMetadata(
        :floating_device,
        "unexpected_mode";
        variables = [x, y],
        constraints = [
            NLPDiagnostics.EntityRef(:constraint, constraint.value),
            NLPDiagnostics.EntityRef(:constraint, freedom.value),
        ],
        expected_rank = 2,
    )
    extra_mode_report = NLPDiagnostics.analyze_component_ranks(
        rank_model,
        freedom_evaluation;
        components = [extra_mode_component],
    )
    @test extra_mode_report.metadata[:component_rank_unexpected_additional_nullity_count] == "1"
    @test extra_mode_report.metadata[:component_rank_unobserved_declared_nullity_count] == "0"

    persistent_component_report = NLPDiagnostics.analyze_component_rank_persistence(
        rank_model,
        [
            NLPDiagnostics.evaluate_numerical(
                rank_model,
                NLPDiagnostics.evaluation_point(rank_model, [0.0, 0.0]; label = "first"),
            ),
            NLPDiagnostics.evaluate_numerical(
                rank_model,
                NLPDiagnostics.evaluation_point(rank_model, [0.0, 0.0]; label = "second"),
            ),
        ];
        components = [freedom_component, undeclared_component],
    )
    @test length(findings(
        persistent_component_report, :component_expected_rank_persistent,
    )) == 1
    @test persistent_component_report.metadata[:component_rank_persistent_count] == "1"
    @test persistent_component_report.metadata[:component_rank_capability_checked] == "true"
    @test persistent_component_report.metadata[:component_expected_rank_declared_count] == "1"
    @test persistent_component_report.metadata[:component_expected_rank_unavailable_count] == "1"
    @test length(findings(
        persistent_component_report,
        :component_expected_right_nullspace_persistent,
    )) == 1
    @test persistent_component_report.metadata[
        :component_right_nullspace_persistent_count
    ] == "1"
    persistent_component_point_report =
        NLPDiagnostics.analyze_component_rank_persistence(
            rank_model,
            [
                NLPDiagnostics.evaluation_point(rank_model, [0.0, 0.0]; label = "first"),
                NLPDiagnostics.evaluation_point(rank_model, [0.0, 0.0]; label = "second"),
            ];
            components = [freedom_component],
        )
    @test length(findings(
        persistent_component_point_report,
        :component_expected_right_nullspace_persistent,
    )) == 1
    local_free_mode = NLPDiagnostics.ExpectedNullspaceMode(
        :local_free_coordinate,
        [x, y],
        [0.0, 1.0],
    )
    local_fixed_mode = NLPDiagnostics.ExpectedNullspaceMode(
        :locally_fixed_coordinate,
        [x, y],
        [1.0, 0.0],
    )
    component_mode_report = NLPDiagnostics.analyze_component_rank_persistence(
        rank_model,
        [
            NLPDiagnostics.evaluation_point(rank_model, [0.0, 0.0]; label = "first"),
            NLPDiagnostics.evaluation_point(rank_model, [0.0, 0.0]; label = "second"),
        ];
        components = [freedom_component],
        expected_modes = [local_free_mode, local_fixed_mode],
    )
    @test length(findings(
        component_mode_report, :component_persistent_expected_mode_observed,
    )) == 1
    @test length(findings(
        component_mode_report, :component_persistent_expected_mode_not_observed,
    )) == 1

    @testset "expected-mode free-coordinate projection preserves fixed components" begin
        projected_model = MOIU.Model{Float64}()
        fixed = MOI.add_variable(projected_model)
        y_projected = MOI.add_variable(projected_model)
        z_projected = MOI.add_variable(projected_model)
        MOI.add_constraint(projected_model, fixed, MOI.EqualTo(0.0))
        MOI.add_constraint(
            projected_model,
            MOI.ScalarAffineFunction(
                [
                    MOI.ScalarAffineTerm(1.0, y_projected),
                    MOI.ScalarAffineTerm(1.0, z_projected),
                ],
                0.0,
            ),
            MOI.EqualTo(0.0),
        )
        projected_evaluation = NLPDiagnostics.evaluate_numerical(
            projected_model,
            NLPDiagnostics.evaluation_point(projected_model, [0.0, 0.0, 0.0]),
        )
        projected_mode = NLPDiagnostics.ExpectedNullspaceMode(
            :fixed_plus_free_mode,
            [fixed, y_projected, z_projected],
            [1.0, 1.0, -1.0],
        )
        strict_projection_report = NLPDiagnostics.analyze_degeneracy(
            projected_model,
            projected_evaluation;
            expected_modes = [projected_mode],
        )
        strict_finding = only(findings(
            strict_projection_report,
            :expected_nullspace_mode_unaligned,
        ))
        @test evidence_details(strict_finding)["nonfree_variable_indices"] ==
              string(fixed.value)
        free_projection_report = NLPDiagnostics.analyze_degeneracy(
            projected_model,
            projected_evaluation;
            expected_modes = [projected_mode],
            expected_mode_free_coordinate_policy = :project_free,
        )
        projected_finding = only(findings(
            free_projection_report,
            :expected_nullspace_mode_free_projection_observed,
        ))
        projected_details = evidence_details(projected_finding)
        @test projected_details["projection_policy"] == "project_free"
        @test projected_details["nonfree_variable_indices"] == string(fixed.value)
        @test projected_details["unaligned_coefficient_norm"] == "1.0"
        @test length(findings(
            free_projection_report,
            :expected_nullspace_mode_span_free_projection,
        )) == 1
        @test free_projection_report.metadata[
            :expected_mode_free_coordinate_projection_enabled
        ] == "true"

        tangent_policy = NLPDiagnostics.ExpectedNullspaceTangentPolicy(
            :fixed_reference,
            [fixed];
            description = "retain the fixed reference coordinate for a local tangent check",
            metadata = Dict("source" => "synthetic regression"),
        )
        tangent_report = NLPDiagnostics.analyze_degeneracy(
            projected_model,
            projected_evaluation;
            expected_modes = [projected_mode],
            expected_mode_tangent_policy = tangent_policy,
        )
        tangent_finding = only(findings(
            tangent_report,
            :expected_nullspace_mode_tangent_observed,
        ))
        @test evidence_details(tangent_finding)["tangent_policy"] ==
              "fixed_reference"
        @test tangent_report.metadata[:expected_mode_tangent_policy] ==
              "fixed_reference"
        @test tangent_report.metadata[:expected_mode_tangent_policy_variable_count] ==
              "1"
        @test tangent_report.metadata[:expected_mode_tangent_policy_source] ==
              "synthetic regression"
        @test_throws ArgumentError NLPDiagnostics.ExpectedNullspaceTangentPolicy(
            :empty_scope,
            MOI.VariableIndex[];
            description = "invalid",
        )
    end

    stationary_component_model = MOIU.Model{Float64}()
    stationary_variable = MOI.add_variable(stationary_component_model)
    stationary_constraint = MOI.add_constraint(
        stationary_component_model,
        MOI.ScalarNonlinearFunction(:^, Any[stationary_variable, 2]),
        MOI.EqualTo(0.0),
    )
    stationary_component = NLPDiagnostics.ComponentMetadata(
        :test_device,
        "stationary";
        variables = [stationary_variable],
        constraints = [NLPDiagnostics.EntityRef(
            :constraint, stationary_constraint.value,
        )],
        expected_rank = 1,
    )
    changing_component_report = NLPDiagnostics.analyze_component_rank_persistence(
        stationary_component_model,
        [
            NLPDiagnostics.evaluate_numerical(
                stationary_component_model,
                NLPDiagnostics.evaluation_point(
                    stationary_component_model, [0.0]; label = "stationary",
                ),
            ),
            NLPDiagnostics.evaluate_numerical(
                stationary_component_model,
                NLPDiagnostics.evaluation_point(
                    stationary_component_model, [1.0]; label = "away",
                ),
            ),
        ];
        components = [stationary_component],
    )
    @test length(findings(
        changing_component_report, :component_local_rank_not_persistent,
    )) == 1
    @test changing_component_report.metadata[:component_rank_changing_count] == "1"
end

@testset "elastic feasibility planning is non-mutating and explicit" begin
    model = MOIU.Model{Float64}()
    x, y = MOI.add_variables(model, 2)
    affine = MOI.add_constraint(
        model,
        MOI.ScalarAffineFunction([MOI.ScalarAffineTerm(1.0, x)], 0.0),
        MOI.LessThan(1.0),
    )
    nonlinear = MOI.add_constraint(
        model,
        MOI.VectorOfVariables([x, y]),
        MOI.SecondOrderCone(2),
    )
    before = length(MOI.get(model, MOI.ListOfConstraintIndices{MOI.ScalarAffineFunction{Float64},MOI.LessThan{Float64}}()))
    plan = NLPDiagnostics.elastic_feasibility_plan(model)
    @test plan.relaxation_count == 2
    @test plan.slack_count == 2
    @test Set(reference.index for reference in plan.relaxable_constraints) ==
          Set([affine.value, nonlinear.value])
    @test isempty(plan.unsupported_constraints)
    plan_report = NLPDiagnostics.analyze_elastic_feasibility_plan(plan)
    @test plan_report.metadata[:unsupported_constraint_count] == "0"
    @test isempty(findings(plan_report, :elastic_unsupported_constraints))
    direct_plan_report = NLPDiagnostics.analyze_elastic_feasibility_plan(model)
    @test direct_plan_report.metadata[:relaxation_count] == "2"
    @test direct_plan_report.metadata[:unsupported_constraint_count] == "0"
    selected_plan = NLPDiagnostics.elastic_feasibility_plan(
        model;
        selected_constraints = [plan.relaxable_constraints[1]],
    )
    @test selected_plan.relaxation_count == 1
    selected_report = NLPDiagnostics.analyze_elastic_feasibility_plan(selected_plan)
    @test selected_report.metadata[:excluded_constraint_count] == "1"
    @test_throws ArgumentError NLPDiagnostics.elastic_feasibility_plan(
        model;
        selected_constraints = [NLPDiagnostics.EntityRef(:constraint, 99)],
    )
    @test_throws ArgumentError NLPDiagnostics.elastic_feasibility_plan(
        model;
        selected_constraints = [plan.relaxable_constraints[1], plan.relaxable_constraints[1]],
    )
    focused_model = MOIU.Model{Float64}()
    u, v = MOI.add_variables(focused_model, 2)
    MOI.add_constraint(
        focused_model,
        MOI.ScalarAffineFunction([MOI.ScalarAffineTerm(1.0, u)], 0.0),
        MOI.LessThan(1.0),
    )
    MOI.add_constraint(
        focused_model,
        MOI.ScalarAffineFunction([MOI.ScalarAffineTerm(1.0, v)], 0.0),
        MOI.GreaterThan(0.0),
    )
    full_focused_plan = NLPDiagnostics.elastic_feasibility_plan(focused_model)
    focused_plan = NLPDiagnostics.elastic_feasibility_plan(
        focused_model;
        selected_constraints = [full_focused_plan.relaxable_constraints[1]],
    )
    @test focused_plan.relaxation_count == 1
    @test length(focused_plan.excluded_constraints) == 1
    @test length(findings(
        NLPDiagnostics.analyze_elastic_feasibility_plan(focused_plan),
        :elastic_constraints_excluded,
    )) == 1
    @test length(MOI.get(model, MOI.ListOfConstraintIndices{MOI.ScalarAffineFunction{Float64},MOI.LessThan{Float64}}())) == before
    auxiliary = NLPDiagnostics.build_elastic_feasibility_model(model)
    @test auxiliary.plan.relaxation_count == plan.relaxation_count
    @test auxiliary.model isa MOIU.UniversalFallback
    @test length(auxiliary.relaxations) == 2
    @test all(length(relaxation.slacks) == 1 for relaxation in auxiliary.relaxations)
    @test auxiliary.source_variable_map[x] isa MOI.VariableIndex
    @test auxiliary.source_variable_map[y] isa MOI.VariableIndex
    @test all(haskey(auxiliary.relaxed_constraint_map, source) for source in plan.relaxable_constraints)
    @test MOI.get(auxiliary.model, MOI.ObjectiveSense()) == MOI.MIN_SENSE
    @test length(MOI.get(auxiliary.model, MOI.ListOfVariableIndices())) == 4
    affine_reference = only(filter(
        item -> item.function_type == string(MOI.ScalarAffineFunction{Float64}),
        plan.relaxable_constraints,
    ))
    relaxation = only(filter(item -> item.source == affine_reference, auxiliary.relaxations))
    slack_values = Dict(
        slack => (slack == only(relaxation.slacks) ? 0.25 : 0.0)
        for item in auxiliary.relaxations for slack in item.slacks
    )
    observed = NLPDiagnostics.elastic_relaxation_values(auxiliary, slack_values)
    affine_observation = only(filter(item -> item.source == affine_reference, observed))
    @test affine_observation.total == 0.25
    @test affine_observation.weighted_total == 0.25
    @test affine_observation.kind == :upper_bound
    @test NLPDiagnostics.elastic_objective_value(auxiliary, slack_values) == 0.25
    report = NLPDiagnostics.analyze_elastic_relaxations(auxiliary, slack_values)
    @test report.metadata[:positive_elastic_relaxation_count] == "1"
    relaxation_finding = only(findings(report, :elastic_constraint_relaxed))
    @test evidence_details(relaxation_finding)["weighted_slack_magnitude"] == "0.25"
    @test evidence_details(relaxation_finding)["geometry"] == "scalar residual relaxation"
    @test_throws ArgumentError NLPDiagnostics.elastic_relaxation_values(auxiliary, Dict{MOI.VariableIndex,Float64}())
    @test_throws ArgumentError NLPDiagnostics.elastic_relaxation_values(auxiliary)
    weighted = NLPDiagnostics.build_elastic_feasibility_model(
        model;
        weights = Dict(plan.relaxable_constraints[1] => 2.5),
    )
    objective = MOI.get(
        weighted.model,
        MOI.ObjectiveFunction{MOI.ScalarAffineFunction{Float64}}(),
    )
    @test any(term -> term.coefficient == 2.5, objective.terms)
    weighted_slack_values = NLPDiagnostics.elastic_relaxation_values(
        weighted,
        Dict(
            slack => (slack == only(weighted.relaxations[1].slacks) ? 0.25 : 0.0)
            for item in weighted.relaxations for slack in item.slacks
        ),
    )
    @test only(filter(item -> item.source == affine_reference, weighted_slack_values)).weighted_total == 0.625
    @test_throws ArgumentError NLPDiagnostics.build_elastic_feasibility_model(
        model;
        weights = Dict(plan.relaxable_constraints[1] => 0.0),
    )
    linf_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(
        model;
        objective_norm = :linf,
    )
    @test linf_auxiliary.objective_norm == :linf
    @test !isnothing(linf_auxiliary.epigraph_variable)
    linf_relaxation = linf_auxiliary.relaxations[1]
    @test NLPDiagnostics.elastic_objective_value(
        linf_auxiliary,
        Dict(
            slack => (slack == only(linf_relaxation.slacks) ? 0.4 : 0.0)
            for item in linf_auxiliary.relaxations for slack in item.slacks
        ),
    ) == 0.4
    @test_throws ArgumentError NLPDiagnostics.build_elastic_feasibility_model(
        model;
        objective_norm = :unsupported,
    )
    @test_throws ArgumentError NLPDiagnostics.build_elastic_feasibility_model(
        model;
        weights = Dict(NLPDiagnostics.EntityRef(:constraint, 99) => 1.0),
    )

    equality_model = MOIU.Model{Float64}()
    z = MOI.add_variable(equality_model)
    equality = MOI.add_constraint(
        equality_model,
        MOI.ScalarAffineFunction([MOI.ScalarAffineTerm(1.0, z)], 0.0),
        MOI.EqualTo(1.0),
    )
    equality_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(equality_model)
    @test equality_auxiliary.plan.slack_count == 2
    equality_relaxation = only(equality_auxiliary.relaxations)
    @test equality_relaxation.source.index == equality.value
    @test length(equality_relaxation.slacks) == 2
    equality_values = Dict(
        equality_relaxation.slacks[1] => 0.2,
        equality_relaxation.slacks[2] => 0.05,
    )
    equality_observation = only(NLPDiagnostics.elastic_relaxation_values(
        equality_auxiliary,
        equality_values,
    ))
    @test equality_observation.values == [0.2, 0.05]
    @test equality_observation.total == 0.25
    @test equality_observation.kind == :equality

    quadratic_model = MOIU.Model{Float64}()
    q = MOI.add_variable(quadratic_model)
    quadratic = MOI.add_constraint(
        quadratic_model,
        MOI.ScalarQuadraticFunction(
            [MOI.ScalarQuadraticTerm(1.0, q, q)],
            MOI.ScalarAffineTerm{Float64}[],
            0.0,
        ),
        MOI.LessThan(1.0),
    )
    quadratic_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(quadratic_model)
    @test only(quadratic_auxiliary.relaxations).source.index == quadratic.value
    @test length(only(quadratic_auxiliary.relaxations).slacks) == 1

    nonlinear_model = MOIU.Model{Float64}()
    n = MOI.add_variable(nonlinear_model)
    nonlinear_constraint = MOI.add_constraint(
        nonlinear_model,
        MOI.ScalarNonlinearFunction(:sin, Any[n]),
        MOI.LessThan(1.0),
    )
    nonlinear_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(nonlinear_model)
    @test only(nonlinear_auxiliary.relaxations).source.index == nonlinear_constraint.value
    @test length(only(nonlinear_auxiliary.relaxations).slacks) == 1

    cone_model = MOIU.Model{Float64}()
    t, w = MOI.add_variables(cone_model, 2)
    cone = MOI.add_constraint(cone_model, MOI.VectorOfVariables([t, w]), MOI.SecondOrderCone(2))
    cone_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(cone_model)
    @test only(cone_auxiliary.relaxations).source.index == cone.value
    @test length(only(cone_auxiliary.relaxations).slacks) == 1
    @test only(cone_auxiliary.relaxations).kind == :second_order_cone

    spectral_elastic_model = MOIU.Model{Float64}()
    spectral_elastic_entries = MOI.add_variables(spectral_elastic_model, 5)
    MOI.add_constraint(
        spectral_elastic_model,
        MOI.VectorOfVariables(spectral_elastic_entries),
        MOI.NormSpectralCone(2, 2),
    )
    spectral_elastic_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(
        spectral_elastic_model,
    )
    @test only(spectral_elastic_auxiliary.relaxations).kind == :norm_spectral_cone
    @test length(only(spectral_elastic_auxiliary.relaxations).slacks) == 1

    nuclear_elastic_model = MOIU.Model{Float64}()
    nuclear_elastic_entries = MOI.add_variables(nuclear_elastic_model, 5)
    MOI.add_constraint(
        nuclear_elastic_model,
        MOI.VectorOfVariables(nuclear_elastic_entries),
        MOI.NormNuclearCone(2, 2),
    )
    nuclear_elastic_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(
        nuclear_elastic_model,
    )
    @test only(nuclear_elastic_auxiliary.relaxations).kind == :norm_nuclear_cone

    power_elastic_model = MOIU.Model{Float64}()
    power_elastic_entries = MOI.add_variables(power_elastic_model, 3)
    MOI.add_constraint(
        power_elastic_model,
        MOI.VectorOfVariables(power_elastic_entries),
        MOI.PowerCone(0.25),
    )
    power_elastic_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(
        power_elastic_model,
    )
    power_elastic_relaxation = only(power_elastic_auxiliary.relaxations)
    @test power_elastic_relaxation.kind == :power_cone
    power_relaxed_function = MOI.get(
        power_elastic_auxiliary.model,
        MOI.ConstraintFunction(),
        only(values(power_elastic_auxiliary.relaxed_constraint_map)),
    )
    power_slack = only(power_elastic_relaxation.slacks)
    @test sort([(term.output_index, term.scalar_term.coefficient) for
                term in power_relaxed_function.terms if
                term.scalar_term.variable == power_slack]) == [(1, 1.0), (2, 1.0)]
    power_report = NLPDiagnostics.analyze_elastic_relaxations(
        power_elastic_auxiliary, Dict(power_slack => 0.1),
    )
    @test evidence_details(only(findings(power_report, :elastic_constraint_relaxed)))["geometry"] ==
          "both positive power-cone coordinates increased by the same slack"

    dual_power_elastic_model = MOIU.Model{Float64}()
    dual_power_elastic_entries = MOI.add_variables(dual_power_elastic_model, 3)
    MOI.add_constraint(
        dual_power_elastic_model,
        MOI.VectorOfVariables(dual_power_elastic_entries),
        MOI.DualPowerCone(0.25),
    )
    dual_power_elastic_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(
        dual_power_elastic_model,
    )
    dual_power_elastic_relaxation = only(dual_power_elastic_auxiliary.relaxations)
    @test dual_power_elastic_relaxation.kind == :dual_power_cone
    dual_power_relaxed_function = MOI.get(
        dual_power_elastic_auxiliary.model,
        MOI.ConstraintFunction(),
        only(values(dual_power_elastic_auxiliary.relaxed_constraint_map)),
    )
    dual_power_slack = only(dual_power_elastic_relaxation.slacks)
    @test sort([(term.output_index, term.scalar_term.coefficient) for
                term in dual_power_relaxed_function.terms if
                term.scalar_term.variable == dual_power_slack]) == [(1, 0.25), (2, 0.75)]

    exponential_elastic_model = MOIU.Model{Float64}()
    exponential_elastic_entries = MOI.add_variables(exponential_elastic_model, 3)
    exponential_elastic = MOI.add_constraint(
        exponential_elastic_model,
        MOI.VectorOfVariables(exponential_elastic_entries),
        MOI.ExponentialCone(),
    )
    exponential_elastic_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(
        exponential_elastic_model,
    )
    exponential_elastic_relaxation = only(exponential_elastic_auxiliary.relaxations)
    @test exponential_elastic_relaxation.kind == :exponential_cone
    exponential_relaxed_function = MOI.get(
        exponential_elastic_auxiliary.model,
        MOI.ConstraintFunction(),
        exponential_elastic_auxiliary.relaxed_constraint_map[
            exponential_elastic_relaxation.source
        ],
    )
    @test only([term.scalar_term.coefficient for term in exponential_relaxed_function.terms if
                term.output_index == 3 &&
                term.scalar_term.variable == only(exponential_elastic_relaxation.slacks)]) == 1.0

    dual_exponential_elastic_model = MOIU.Model{Float64}()
    dual_exponential_elastic_entries = MOI.add_variables(dual_exponential_elastic_model, 3)
    MOI.add_constraint(
        dual_exponential_elastic_model,
        MOI.VectorOfVariables(dual_exponential_elastic_entries),
        MOI.DualExponentialCone(),
    )
    dual_exponential_elastic_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(
        dual_exponential_elastic_model,
    )
    @test only(dual_exponential_elastic_auxiliary.relaxations).kind ==
          :dual_exponential_cone

    geometric_elastic_model = MOIU.Model{Float64}()
    geometric_elastic_entries = MOI.add_variables(geometric_elastic_model, 3)
    MOI.add_constraint(
        geometric_elastic_model,
        MOI.VectorOfVariables(geometric_elastic_entries),
        MOI.GeometricMeanCone(3),
    )
    geometric_elastic_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(
        geometric_elastic_model,
    )
    geometric_elastic_relaxation = only(geometric_elastic_auxiliary.relaxations)
    @test geometric_elastic_relaxation.kind == :geometric_mean_cone
    geometric_relaxed_function = MOI.get(
        geometric_elastic_auxiliary.model,
        MOI.ConstraintFunction(),
        only(values(geometric_elastic_auxiliary.relaxed_constraint_map)),
    )
    @test only([term.scalar_term.coefficient for term in geometric_relaxed_function.terms if
                term.output_index == 1 &&
                term.scalar_term.variable == only(geometric_elastic_relaxation.slacks)]) == -1.0

    entropy_elastic_model = MOIU.Model{Float64}()
    entropy_elastic_entries = MOI.add_variables(entropy_elastic_model, 3)
    MOI.add_constraint(
        entropy_elastic_model,
        MOI.VectorOfVariables(entropy_elastic_entries),
        MOI.RelativeEntropyCone(3),
    )
    entropy_elastic_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(
        entropy_elastic_model,
    )
    @test only(entropy_elastic_auxiliary.relaxations).kind == :relative_entropy_cone

    logdet_elastic_model = MOIU.Model{Float64}()
    logdet_elastic_entries = MOI.add_variables(logdet_elastic_model, 5)
    MOI.add_constraint(
        logdet_elastic_model,
        MOI.VectorOfVariables(logdet_elastic_entries),
        MOI.LogDetConeTriangle(2),
    )
    logdet_elastic_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(
        logdet_elastic_model,
    )
    logdet_elastic_relaxation = only(logdet_elastic_auxiliary.relaxations)
    @test logdet_elastic_relaxation.kind == :logdet_cone_triangle
    logdet_relaxed_function = MOI.get(
        logdet_elastic_auxiliary.model,
        MOI.ConstraintFunction(),
        logdet_elastic_auxiliary.relaxed_constraint_map[
            logdet_elastic_relaxation.source
        ],
    )
    logdet_slack = only(logdet_elastic_relaxation.slacks)
    @test only([term.scalar_term.coefficient for term in
                logdet_relaxed_function.terms if
                term.output_index == 1 && term.scalar_term.variable == logdet_slack]) == -1.0

    logdet_square_elastic_model = MOIU.Model{Float64}()
    logdet_square_elastic_entries = MOI.add_variables(logdet_square_elastic_model, 6)
    MOI.add_constraint(
        logdet_square_elastic_model,
        MOI.VectorOfVariables(logdet_square_elastic_entries),
        MOI.LogDetConeSquare(2),
    )
    logdet_square_elastic_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(
        logdet_square_elastic_model,
    )
    logdet_square_elastic_relaxation = only(logdet_square_elastic_auxiliary.relaxations)
    @test logdet_square_elastic_relaxation.kind == :logdet_cone_square

    rootdet_square_elastic_model = MOIU.Model{Float64}()
    rootdet_square_elastic_entries = MOI.add_variables(rootdet_square_elastic_model, 5)
    MOI.add_constraint(
        rootdet_square_elastic_model,
        MOI.VectorOfVariables(rootdet_square_elastic_entries),
        MOI.RootDetConeSquare(2),
    )
    rootdet_square_elastic_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(
        rootdet_square_elastic_model,
    )
    @test only(rootdet_square_elastic_auxiliary.relaxations).kind ==
          :rootdet_cone_square

    scaled_logdet_elastic_model = MOIU.UniversalFallback(MOIU.Model{Float64}())
    scaled_logdet_elastic_entries = MOI.add_variables(scaled_logdet_elastic_model, 5)
    MOI.add_constraint(
        scaled_logdet_elastic_model,
        MOI.VectorOfVariables(scaled_logdet_elastic_entries),
        MOI.Scaled(MOI.LogDetConeTriangle(2)),
    )
    scaled_logdet_elastic_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(
        scaled_logdet_elastic_model,
    )
    @test only(scaled_logdet_elastic_auxiliary.relaxations).kind ==
          :scaled_logdet_cone_triangle

    scaled_rootdet_elastic_model = MOIU.UniversalFallback(MOIU.Model{Float64}())
    scaled_rootdet_elastic_entries = MOI.add_variables(scaled_rootdet_elastic_model, 4)
    MOI.add_constraint(
        scaled_rootdet_elastic_model,
        MOI.VectorOfVariables(scaled_rootdet_elastic_entries),
        MOI.Scaled(MOI.RootDetConeTriangle(2)),
    )
    scaled_rootdet_elastic_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(
        scaled_rootdet_elastic_model,
    )
    @test only(scaled_rootdet_elastic_auxiliary.relaxations).kind ==
          :scaled_rootdet_cone_triangle

    psd_elastic_model = MOIU.Model{Float64}()
    psd_a, psd_b, psd_c = MOI.add_variables(psd_elastic_model, 3)
    psd_elastic = MOI.add_constraint(
        psd_elastic_model,
        MOI.VectorOfVariables([psd_a, psd_b, psd_c]),
        MOI.PositiveSemidefiniteConeTriangle(2),
    )
    psd_elastic_plan = NLPDiagnostics.elastic_feasibility_plan(psd_elastic_model)
    @test psd_elastic_plan.relaxation_count == 1
    @test psd_elastic_plan.slack_count == 1
    psd_elastic_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(
        psd_elastic_model,
    )
    psd_elastic_relaxation = only(psd_elastic_auxiliary.relaxations)
    @test psd_elastic_relaxation.source.index == psd_elastic.value
    @test psd_elastic_relaxation.kind == :positive_semidefinite_cone_triangle
    @test length(psd_elastic_relaxation.slacks) == 1
    psd_relaxed_function = MOI.get(
        psd_elastic_auxiliary.model,
        MOI.ConstraintFunction(),
        psd_elastic_auxiliary.relaxed_constraint_map[
            psd_elastic_relaxation.source
        ],
    )
    psd_slack = only(psd_elastic_relaxation.slacks)
    @test sort([term.output_index for term in psd_relaxed_function.terms if
                term.scalar_term.variable == psd_slack]) == [1, 3]

    scaled_psd_elastic_model = MOIU.Model{Float64}()
    scaled_psd_elastic_entries = MOI.add_variables(scaled_psd_elastic_model, 3)
    MOI.add_constraint(
        scaled_psd_elastic_model,
        MOI.VectorOfVariables(scaled_psd_elastic_entries),
        MOI.Scaled(MOI.PositiveSemidefiniteConeTriangle(2)),
    )
    scaled_psd_elastic_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(
        scaled_psd_elastic_model,
    )
    @test only(scaled_psd_elastic_auxiliary.relaxations).kind ==
          :scaled_positive_semidefinite_cone_triangle

    hermitian_psd_elastic_model = MOIU.UniversalFallback(MOIU.Model{Float64}())
    hermitian_psd_elastic_entries = MOI.add_variables(hermitian_psd_elastic_model, 4)
    MOI.add_constraint(
        hermitian_psd_elastic_model,
        MOI.VectorOfVariables(hermitian_psd_elastic_entries),
        MOI.HermitianPositiveSemidefiniteConeTriangle(2),
    )
    hermitian_psd_elastic_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(
        hermitian_psd_elastic_model,
    )
    hermitian_psd_elastic_relaxation = only(hermitian_psd_elastic_auxiliary.relaxations)
    @test hermitian_psd_elastic_relaxation.kind ==
          :hermitian_positive_semidefinite_cone_triangle
    hermitian_psd_relaxed_function = MOI.get(
        hermitian_psd_elastic_auxiliary.model,
        MOI.ConstraintFunction(),
        only(values(hermitian_psd_elastic_auxiliary.relaxed_constraint_map)),
    )
    hermitian_psd_slack = only(hermitian_psd_elastic_relaxation.slacks)
    @test sort([term.output_index for term in hermitian_psd_relaxed_function.terms if
                term.scalar_term.variable == hermitian_psd_slack]) == [1, 3]

    scaled_hermitian_psd_elastic_model = MOIU.UniversalFallback(MOIU.Model{Float64}())
    scaled_hermitian_psd_elastic_entries = MOI.add_variables(
        scaled_hermitian_psd_elastic_model, 4,
    )
    MOI.add_constraint(
        scaled_hermitian_psd_elastic_model,
        MOI.VectorOfVariables(scaled_hermitian_psd_elastic_entries),
        MOI.Scaled(MOI.HermitianPositiveSemidefiniteConeTriangle(2)),
    )
    scaled_hermitian_psd_elastic_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(
        scaled_hermitian_psd_elastic_model,
    )
    @test only(scaled_hermitian_psd_elastic_auxiliary.relaxations).kind ==
          :scaled_hermitian_positive_semidefinite_cone_triangle

    psd_square_elastic_model = MOIU.Model{Float64}()
    psd_square_elastic_entries = MOI.add_variables(psd_square_elastic_model, 4)
    MOI.add_constraint(
        psd_square_elastic_model,
        MOI.VectorOfVariables(psd_square_elastic_entries),
        MOI.PositiveSemidefiniteConeSquare(2),
    )
    psd_square_elastic_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(
        psd_square_elastic_model,
    )
    psd_square_elastic_relaxation = only(psd_square_elastic_auxiliary.relaxations)
    @test psd_square_elastic_relaxation.kind == :positive_semidefinite_cone_square
    psd_square_relaxed_function = MOI.get(
        psd_square_elastic_auxiliary.model,
        MOI.ConstraintFunction(),
        psd_square_elastic_auxiliary.relaxed_constraint_map[
            psd_square_elastic_relaxation.source
        ],
    )
    psd_square_slack = only(psd_square_elastic_relaxation.slacks)
    @test sort([term.output_index for term in psd_square_relaxed_function.terms if
                term.scalar_term.variable == psd_square_slack]) == [1, 4]

    affine_cone_model = MOIU.Model{Float64}()
    a, b = MOI.add_variables(affine_cone_model, 2)
    affine_cone = MOI.add_constraint(
        affine_cone_model,
        MOI.VectorAffineFunction(
            [
                MOI.VectorAffineTerm(1, MOI.ScalarAffineTerm(1.0, a)),
                MOI.VectorAffineTerm(2, MOI.ScalarAffineTerm(1.0, b)),
            ],
            [0.0, 0.0],
        ),
        MOI.SecondOrderCone(2),
    )
    affine_cone_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(affine_cone_model)
    @test only(affine_cone_auxiliary.relaxations).source.index == affine_cone.value

    rotated_cone_model = MOIU.Model{Float64}()
    r1, r2 = MOI.add_variables(rotated_cone_model, 2)
    rotated_cone = MOI.add_constraint(
        rotated_cone_model,
        MOI.VectorOfVariables([r1, r2]),
        MOI.RotatedSecondOrderCone(2),
    )
    rotated_cone_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(rotated_cone_model)
    @test only(rotated_cone_auxiliary.relaxations).source.index == rotated_cone.value

    nonnegative_model = MOIU.Model{Float64}()
    g, h = MOI.add_variables(nonnegative_model, 2)
    nonnegative = MOI.add_constraint(
        nonnegative_model,
        MOI.VectorOfVariables([g, h]),
        MOI.Nonnegatives(2),
    )
    nonnegative_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(nonnegative_model)
    nonnegative_relaxation = only(nonnegative_auxiliary.relaxations)
    @test nonnegative_relaxation.source.index == nonnegative.value
    @test nonnegative_relaxation.kind == :nonnegatives
    @test length(nonnegative_relaxation.slacks) == 2

    nonpositive_model = MOIU.Model{Float64}()
    m, n = MOI.add_variables(nonpositive_model, 2)
    nonpositive = MOI.add_constraint(
        nonpositive_model,
        MOI.VectorOfVariables([m, n]),
        MOI.Nonpositives(2),
    )
    nonpositive_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(nonpositive_model)
    nonpositive_relaxation = only(nonpositive_auxiliary.relaxations)
    @test nonpositive_relaxation.source.index == nonpositive.value
    @test nonpositive_relaxation.kind == :nonpositives
    @test length(nonpositive_relaxation.slacks) == 2

    zero_model = MOIU.Model{Float64}()
    p, q = MOI.add_variables(zero_model, 2)
    zeros_constraint = MOI.add_constraint(zero_model, MOI.VectorOfVariables([p, q]), MOI.Zeros(2))
    zero_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(zero_model)
    zero_relaxation = only(zero_auxiliary.relaxations)
    @test zero_relaxation.source.index == zeros_constraint.value
    @test zero_relaxation.kind == :zeros
    @test length(zero_relaxation.slacks) == 4

    subset_reference = affine_reference
    positive_subset = NLPDiagnostics.ElasticSubsetSearch(
        NLPDiagnostics.ElasticSubsetProbe(
            [subset_reference], 1.0, true, "LOCALLY_INFEASIBLE", "FEASIBLE_POINT",
        ),
        NLPDiagnostics.ElasticSubsetProbe[],
        [subset_reference],
        NLPDiagnostics.EntityRef[],
        1e-8,
    )
    subset_report = NLPDiagnostics.analyze_local_elastic_subset_search(positive_subset)
    @test length(findings(subset_report, :elastic_subset_local_explanation)) == 1
    consensus_ensemble = NLPDiagnostics.ElasticSubsetEnsemble(
        [positive_subset, positive_subset], [subset_reference], [subset_reference],
    )
    @test length(findings(
        NLPDiagnostics.analyze_local_elastic_subset_ensemble(consensus_ensemble),
        :elastic_subset_order_consensus,
    )) == 1
    sensitive_ensemble = NLPDiagnostics.ElasticSubsetEnsemble(
        [positive_subset, positive_subset], NLPDiagnostics.EntityRef[], [subset_reference],
    )
    @test length(findings(
        NLPDiagnostics.analyze_local_elastic_subset_ensemble(sensitive_ensemble),
        :elastic_subset_order_sensitive,
    )) == 1
    minimum_search = NLPDiagnostics.ElasticMinimumRelaxationSearch(
        [subset_reference], 1, [positive_subset.baseline], 3, false, 1e-8,
    )
    @test length(findings(
        NLPDiagnostics.analyze_minimum_elastic_relaxation_search(minimum_search),
        :elastic_minimum_relaxation_support,
    )) == 1
    truncated_minimum_search = NLPDiagnostics.ElasticMinimumRelaxationSearch(
        [subset_reference], nothing, NLPDiagnostics.ElasticSubsetProbe[], 2, true, 1e-8,
    )
    @test length(findings(
        NLPDiagnostics.analyze_minimum_elastic_relaxation_search(truncated_minimum_search),
        :elastic_minimum_relaxation_truncated,
    )) == 1
    conflict_model = MOIU.Model{Float64}()
    conflict_variable = MOI.add_variable(conflict_model)
    conflict_constraint = MOI.add_constraint(
        conflict_model,
        MOI.ScalarAffineFunction([MOI.ScalarAffineTerm(1.0, conflict_variable)], 0.0),
        MOI.LessThan(0.0),
    )
    conflict_optimizer = MOIU.MockOptimizer()
    conflict_optimizer.optimize! = function (mock)
        MOI.set(mock, MOI.ConflictStatus(), MOI.CONFLICT_FOUND)
        copied_constraint = only(MOI.get(
            mock,
            MOI.ListOfConstraintIndices{MOI.ScalarAffineFunction{Float64},MOI.LessThan{Float64}}(),
        ))
        MOI.set(mock, MOI.ConstraintConflictStatus(), copied_constraint, MOI.IN_CONFLICT)
    end
    conflict_result = NLPDiagnostics.compute_solver_conflict!(
        conflict_optimizer, conflict_model,
    )
    @test conflict_result.error === nothing
    @test conflict_result.source_variable_count == 1
    @test conflict_result.source_constraint_count == 1
    @test only(only(conflict_result.conflicts)).index == conflict_constraint.value
    conflict_report = NLPDiagnostics.analyze_solver_conflict(conflict_result)
    @test conflict_report.metadata[:solver_conflict_source_variable_count] == "1"
    @test conflict_report.metadata[:solver_conflict_source_constraint_count] == "1"
    @test length(findings(
        conflict_report,
        :solver_conflict_membership,
    )) == 1
    conflict_reference = only(
        NLPDiagnostics.elastic_feasibility_plan(conflict_model).relaxable_constraints,
    )
    conflict_subset = NLPDiagnostics.ElasticSubsetSearch(
        NLPDiagnostics.ElasticSubsetProbe(
            [conflict_reference], 1.0, true, "LOCALLY_INFEASIBLE", "FEASIBLE_POINT",
        ),
        NLPDiagnostics.ElasticSubsetProbe[],
        [conflict_reference],
        NLPDiagnostics.EntityRef[],
        1e-8,
    )
    @test length(findings(
        NLPDiagnostics.analyze_solver_conflict_crosscheck(conflict_result, conflict_subset),
        :solver_conflict_elastic_overlap,
    )) == 1
    zero_subset = NLPDiagnostics.ElasticSubsetSearch(
        NLPDiagnostics.ElasticSubsetProbe(
            [subset_reference], 0.0, true, "OPTIMAL", "FEASIBLE_POINT",
        ),
        NLPDiagnostics.ElasticSubsetProbe[],
        NLPDiagnostics.EntityRef[],
        [subset_reference],
        1e-8,
    )
    @test length(findings(
        NLPDiagnostics.analyze_local_elastic_subset_search(zero_subset),
        :elastic_subset_no_positive_residual,
    )) == 1
    @test_throws ArgumentError NLPDiagnostics.local_elastic_subset_search(
        model, () -> nothing,
    )

    domain_guard_model = MOIU.Model{Float64}()
    guarded = MOI.add_variable(domain_guard_model)
    MOI.add_constraint(domain_guard_model, guarded, MOI.LessThan(-1.0))
    guarded_constraint = MOI.add_constraint(
        domain_guard_model,
        MOI.ScalarNonlinearFunction(:log, Any[guarded]),
        MOI.LessThan(0.0),
    )
    guard_plan = NLPDiagnostics.elastic_domain_guard_plan(domain_guard_model)
    @test guard_plan.selected_constraint_count == 1
    @test length(guard_plan.guards) == 1
    @test only(guard_plan.guards).source.index == guarded_constraint.value
    @test only(guard_plan.guards).materializable
    guard_report = NLPDiagnostics.analyze_elastic_domain_guard_plan(guard_plan)
    @test length(findings(guard_report, :elastic_proven_domain_guard_violation)) == 1
    direct_guard_report = NLPDiagnostics.analyze_elastic_domain_guard_plan(
        domain_guard_model,
    )
    @test direct_guard_report.metadata[:elastic_domain_guard_count] == "1"
    @test length(findings(
        direct_guard_report, :elastic_proven_domain_guard_violation,
    )) == 1
    guarded_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(
        domain_guard_model;
        domain_guard_margin = 1e-6,
    )
    @test length(guarded_auxiliary.domain_guards) == 1
    @test guarded_auxiliary.domain_guard_margin == 1e-6
    mapped_guarded = guarded_auxiliary.source_variable_map[guarded]
    guard_constraints = MOI.get(
        guarded_auxiliary.model,
        MOI.ListOfConstraintIndices{MOI.ScalarAffineFunction{Float64},MOI.GreaterThan{Float64}}(),
    )
    @test any(
        index ->
            only(MOI.get(guarded_auxiliary.model, MOI.ConstraintFunction(), index).terms).variable == mapped_guarded &&
            MOI.get(guarded_auxiliary.model, MOI.ConstraintSet(), index).lower == 1e-6,
        guard_constraints,
    )
    @test_throws ArgumentError NLPDiagnostics.build_elastic_feasibility_model(
        domain_guard_model;
        domain_guard_margin = 0.0,
    )

    log1mexp_guard_model = MOIU.Model{Float64}()
    log1mexp_argument = MOI.add_variable(log1mexp_guard_model)
    MOI.add_constraint(
        log1mexp_guard_model,
        MOI.ScalarNonlinearFunction(:log1mexp, Any[log1mexp_argument]),
        MOI.LessThan(0.0),
    )
    log1mexp_plan = NLPDiagnostics.elastic_domain_guard_plan(log1mexp_guard_model)
    @test length(log1mexp_plan.guards) == 1
    @test only(log1mexp_plan.guards).materializable
    log1mexp_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(
        log1mexp_guard_model;
        domain_guard_margin = 1e-5,
    )
    mapped_log1mexp = log1mexp_auxiliary.source_variable_map[log1mexp_argument]
    log1mexp_guards = MOI.get(
        log1mexp_auxiliary.model,
        MOI.ListOfConstraintIndices{MOI.ScalarAffineFunction{Float64},MOI.LessThan{Float64}}(),
    )
    @test any(
        index ->
            only(MOI.get(log1mexp_auxiliary.model, MOI.ConstraintFunction(), index).terms).variable == mapped_log1mexp &&
            MOI.get(log1mexp_auxiliary.model, MOI.ConstraintSet(), index).upper == -1e-5,
        log1mexp_guards,
    )

    logdiffexp_guard_model = MOIU.Model{Float64}()
    logdiffexp_a, logdiffexp_b = MOI.add_variables(logdiffexp_guard_model, 2)
    MOI.add_constraint(
        logdiffexp_guard_model,
        MOI.ScalarNonlinearFunction(:logdiffexp, Any[logdiffexp_a, logdiffexp_b]),
        MOI.LessThan(0.0),
    )
    logdiffexp_plan = NLPDiagnostics.elastic_domain_guard_plan(logdiffexp_guard_model)
    @test length(logdiffexp_plan.guards) == 1
    @test only(logdiffexp_plan.guards).materializable
    @test only(logdiffexp_plan.guards).related_argument == 2
    logdiffexp_guard_report = NLPDiagnostics.analyze_elastic_domain_guard_plan(
        logdiffexp_plan,
    )
    @test Dict(only(logdiffexp_guard_report.findings).evidence[1].details)["related_argument"] == "2"
    logdiffexp_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(
        logdiffexp_guard_model;
        domain_guard_margin = 1e-5,
    )
    mapped_logdiffexp_a = logdiffexp_auxiliary.source_variable_map[logdiffexp_a]
    mapped_logdiffexp_b = logdiffexp_auxiliary.source_variable_map[logdiffexp_b]
    logdiffexp_guards = MOI.get(
        logdiffexp_auxiliary.model,
        MOI.ListOfConstraintIndices{MOI.ScalarAffineFunction{Float64},MOI.GreaterThan{Float64}}(),
    )
    @test any(logdiffexp_guards) do index
        function_value = MOI.get(logdiffexp_auxiliary.model, MOI.ConstraintFunction(), index)
        coefficients = Dict(term.variable => term.coefficient for term in function_value.terms)
        MOI.get(logdiffexp_auxiliary.model, MOI.ConstraintSet(), index).lower == 1e-5 &&
        get(coefficients, mapped_logdiffexp_a, 0.0) == 1.0 &&
        get(coefficients, mapped_logdiffexp_b, 0.0) == -1.0
    end

    reciprocal_guard_model = MOIU.Model{Float64}()
    reciprocal = MOI.add_variable(reciprocal_guard_model)
    MOI.add_constraint(reciprocal_guard_model, reciprocal, MOI.GreaterThan(0.0))
    MOI.add_constraint(
        reciprocal_guard_model,
        MOI.ScalarNonlinearFunction(:inv, Any[reciprocal]),
        MOI.LessThan(2.0),
    )
    reciprocal_plan = NLPDiagnostics.elastic_domain_guard_plan(reciprocal_guard_model)
    @test length(reciprocal_plan.guards) == 1
    @test only(reciprocal_plan.guards).materializable
    reciprocal_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(
        reciprocal_guard_model;
        domain_guard_margin = 1e-5,
    )
    mapped_reciprocal = reciprocal_auxiliary.source_variable_map[reciprocal]
    reciprocal_guards = MOI.get(
        reciprocal_auxiliary.model,
        MOI.ListOfConstraintIndices{MOI.ScalarAffineFunction{Float64},MOI.GreaterThan{Float64}}(),
    )
    @test any(
        index ->
            only(MOI.get(reciprocal_auxiliary.model, MOI.ConstraintFunction(), index).terms).variable == mapped_reciprocal &&
            MOI.get(reciprocal_auxiliary.model, MOI.ConstraintSet(), index).lower == 1e-5,
        reciprocal_guards,
    )

    atanh_guard_model = MOIU.Model{Float64}()
    hyperbolic_argument = MOI.add_variable(atanh_guard_model)
    MOI.add_constraint(
        atanh_guard_model,
        MOI.ScalarNonlinearFunction(:atanh, Any[hyperbolic_argument]),
        MOI.LessThan(2.0),
    )
    atanh_plan = NLPDiagnostics.elastic_domain_guard_plan(atanh_guard_model)
    @test length(atanh_plan.guards) == 1
    @test only(atanh_plan.guards).materializable
    atanh_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(
        atanh_guard_model;
        domain_guard_margin = 1e-5,
    )
    mapped_hyperbolic = atanh_auxiliary.source_variable_map[hyperbolic_argument]
    atanh_lower_guards = MOI.get(
        atanh_auxiliary.model,
        MOI.ListOfConstraintIndices{MOI.ScalarAffineFunction{Float64},MOI.GreaterThan{Float64}}(),
    )
    atanh_upper_guards = MOI.get(
        atanh_auxiliary.model,
        MOI.ListOfConstraintIndices{MOI.ScalarAffineFunction{Float64},MOI.LessThan{Float64}}(),
    )
    @test any(
        index ->
            only(MOI.get(atanh_auxiliary.model, MOI.ConstraintFunction(), index).terms).variable == mapped_hyperbolic &&
            MOI.get(atanh_auxiliary.model, MOI.ConstraintSet(), index).lower == -0.99999,
        atanh_lower_guards,
    )
    @test any(
        index ->
            only(MOI.get(atanh_auxiliary.model, MOI.ConstraintFunction(), index).terms).variable == mapped_hyperbolic &&
            MOI.get(atanh_auxiliary.model, MOI.ConstraintSet(), index).upper == 0.99999,
        atanh_upper_guards,
    )

    periodic_guard_model = MOIU.Model{Float64}()
    periodic_argument = MOI.add_variable(periodic_guard_model)
    MOI.add_constraint(periodic_guard_model, periodic_argument, MOI.Interval(0.0, Float64(pi / 2)))
    MOI.add_constraint(
        periodic_guard_model,
        MOI.ScalarNonlinearFunction(:tan, Any[periodic_argument]),
        MOI.LessThan(10.0),
    )
    periodic_plan = NLPDiagnostics.elastic_domain_guard_plan(periodic_guard_model)
    @test length(periodic_plan.guards) == 1
    @test only(periodic_plan.guards).materializable
    periodic_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(
        periodic_guard_model;
        domain_guard_margin = 1e-5,
    )
    mapped_periodic = periodic_auxiliary.source_variable_map[periodic_argument]
    periodic_guards = MOI.get(
        periodic_auxiliary.model,
        MOI.ListOfConstraintIndices{MOI.ScalarAffineFunction{Float64},MOI.LessThan{Float64}}(),
    )
    @test any(
        index ->
            only(MOI.get(periodic_auxiliary.model, MOI.ConstraintFunction(), index).terms).variable == mapped_periodic &&
            MOI.get(periodic_auxiliary.model, MOI.ConstraintSet(), index).upper ≈ Float64(pi / 2) - 1e-5,
        periodic_guards,
    )
    crossing_periodic_model = MOIU.Model{Float64}()
    crossing_argument = MOI.add_variable(crossing_periodic_model)
    MOI.add_constraint(crossing_periodic_model, crossing_argument, MOI.Interval(-1.0, 2.0))
    MOI.add_constraint(
        crossing_periodic_model,
        MOI.ScalarNonlinearFunction(:tan, Any[crossing_argument]),
        MOI.LessThan(10.0),
    )
    crossing_plan = NLPDiagnostics.elastic_domain_guard_plan(crossing_periodic_model)
    @test length(crossing_plan.guards) == 1
    @test !only(crossing_plan.guards).materializable

    asech_guard_model = MOIU.Model{Float64}()
    asech_argument = MOI.add_variable(asech_guard_model)
    MOI.add_constraint(asech_guard_model, asech_argument, MOI.Interval(0.0, 1.0))
    MOI.add_constraint(
        asech_guard_model,
        MOI.ScalarNonlinearFunction(:asech, Any[asech_argument]),
        MOI.LessThan(10.0),
    )
    asech_plan = NLPDiagnostics.elastic_domain_guard_plan(asech_guard_model)
    @test only(asech_plan.guards).materializable
    asech_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(
        asech_guard_model;
        domain_guard_margin = 1e-5,
    )
    mapped_asech = asech_auxiliary.source_variable_map[asech_argument]
    asech_lower_guards = MOI.get(
        asech_auxiliary.model,
        MOI.ListOfConstraintIndices{MOI.ScalarAffineFunction{Float64},MOI.GreaterThan{Float64}}(),
    )
    @test any(
        index ->
            only(MOI.get(asech_auxiliary.model, MOI.ConstraintFunction(), index).terms).variable == mapped_asech &&
            MOI.get(asech_auxiliary.model, MOI.ConstraintSet(), index).lower == 1e-5,
        asech_lower_guards,
    )

    acoth_guard_model = MOIU.Model{Float64}()
    acoth_argument = MOI.add_variable(acoth_guard_model)
    MOI.add_constraint(acoth_guard_model, acoth_argument, MOI.Interval(1.0, 2.0))
    MOI.add_constraint(
        acoth_guard_model,
        MOI.ScalarNonlinearFunction(:acoth, Any[acoth_argument]),
        MOI.LessThan(10.0),
    )
    acoth_plan = NLPDiagnostics.elastic_domain_guard_plan(acoth_guard_model)
    @test only(acoth_plan.guards).materializable
    acoth_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(
        acoth_guard_model;
        domain_guard_margin = 1e-5,
    )
    mapped_acoth = acoth_auxiliary.source_variable_map[acoth_argument]
    acoth_lower_guards = MOI.get(
        acoth_auxiliary.model,
        MOI.ListOfConstraintIndices{MOI.ScalarAffineFunction{Float64},MOI.GreaterThan{Float64}}(),
    )
    @test any(
        index ->
            only(MOI.get(acoth_auxiliary.model, MOI.ConstraintFunction(), index).terms).variable == mapped_acoth &&
            MOI.get(acoth_auxiliary.model, MOI.ConstraintSet(), index).lower == 1.00001,
        acoth_lower_guards,
    )
    crossing_acoth_model = MOIU.Model{Float64}()
    crossing_acoth_argument = MOI.add_variable(crossing_acoth_model)
    MOI.add_constraint(crossing_acoth_model, crossing_acoth_argument, MOI.Interval(-2.0, 2.0))
    MOI.add_constraint(
        crossing_acoth_model,
        MOI.ScalarNonlinearFunction(:acoth, Any[crossing_acoth_argument]),
        MOI.LessThan(1.0),
    )
    crossing_acoth_plan = NLPDiagnostics.elastic_domain_guard_plan(crossing_acoth_model)
    @test !only(crossing_acoth_plan.guards).materializable
    crossing_acoth_report = NLPDiagnostics.analyze_elastic_domain_guard_plan(crossing_acoth_plan)
    @test crossing_acoth_report.metadata[:elastic_domain_branch_sensitive_count] == "1"
    @test length(findings(
        crossing_acoth_report, :elastic_domain_guard_branch_selection_required,
    )) == 1

    bound_model = MOIU.Model{Float64}()
    b = MOI.add_variable(bound_model)
    bound = MOI.add_constraint(bound_model, b, MOI.GreaterThan(1.0))
    @test NLPDiagnostics.elastic_feasibility_plan(bound_model).relaxation_count == 0
    bound_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(
        bound_model;
        relax_variable_bounds = true,
    )
    @test only(bound_auxiliary.relaxations).source.index == bound.value
    @test length(only(bound_auxiliary.relaxations).slacks) == 1
end

@testset "synthetic sparse profiling corpus" begin
    @test_throws ArgumentError NLPDiagnostics.synthetic_sparse_profile_corpus(dimension = 1)
    models, cases = NLPDiagnostics.synthetic_sparse_profile_corpus(dimension = 3)
    @test length(models) == 3
    @test [case.name for case in cases] == [
        "sparse_banded_full_rank",
        "sparse_banded_rank_deficient",
        "sparse_banded_scaled",
    ]
    @test cases[3].metadata["scale"] == "1.0e8"
    result = NLPDiagnostics.profile_case(
        models[2],
        cases[2];
        rank_max_dense_entries = 1,
    )
    @test any(
        finding -> finding.code == :sparse_qr_jacobian_rank_deficiency,
        result.numerical_report.findings,
    )
    scaled_result = NLPDiagnostics.profile_case(
        models[3],
        cases[3];
        rank_max_dense_entries = 1,
    )
    @test any(
        finding -> finding.code == :large_jacobian_column_scale_spread,
        scaled_result.numerical_report.findings,
    )
    threshold_result = NLPDiagnostics.profile_case(
        models[1],
        cases[1];
        rank_max_dense_entries = 1,
        jacobian_condition_threshold = 1.0e6,
    )
    @test threshold_result.numerical_report.metadata[:jacobian_condition_threshold] == "1.0e6"
    aggregates = NLPDiagnostics.profile_cases_repeated(
        models,
        cases;
        repetitions = 1,
        warmup = false,
        rank_max_dense_entries = 1,
    )
    @test sort!(collect(keys(aggregates))) == [case.name for case in cases]
    @test all(length(aggregate.runs) == 1 for aggregate in values(aggregates))
    ladder = NLPDiagnostics.profile_synthetic_sparse_ladder(
        [3, 4];
        repetitions = 1,
        warmup = false,
        rank_max_dense_entries = 1,
    )
    @test sort!(collect(keys(ladder))) == [3, 4]
    @test all(length(aggregates_by_size) == 3 for aggregates_by_size in values(ladder))
    @test_throws ArgumentError NLPDiagnostics.profile_synthetic_sparse_ladder([3, 3])
end

function NLPDiagnostics.operator_interval(
    ::Val{:positive_output},
    arguments::Vector{NLPDiagnostics.IntervalEnclosure},
    original_arguments,
)
    return NLPDiagnostics.IntervalEnclosure(1.0, Inf, true, true)
end

function NLPDiagnostics.operator_domain_requirements(
    ::Val{:positive_only},
    original_arguments,
    intervals::Vector{NLPDiagnostics.IntervalEnclosure},
)
    interval = intervals[1]
    assessment = if interval.upper <= 0
        NLPDiagnostics.DomainProvenViolation
    elseif interval.lower <= 0
        NLPDiagnostics.DomainPossibleViolation
    else
        NLPDiagnostics.DomainSafe
    end
    return [
        NLPDiagnostics.OperatorDomainRequirement(
            1,
            assessment,
            "argument > 0 for positive_only",
        ),
    ]
end

function NLPDiagnostics.operator_derivative_requirements(
    ::Val{:positive_derivative_only},
    original_arguments,
    intervals::Vector{NLPDiagnostics.IntervalEnclosure},
)
    interval = intervals[1]
    assessment = if interval.upper <= 0
        NLPDiagnostics.DomainProvenViolation
    elseif interval.lower <= 0
        NLPDiagnostics.DomainPossibleViolation
    else
        NLPDiagnostics.DomainSafe
    end
    return [
        NLPDiagnostics.OperatorDerivativeRequirement(
            1,
            1,
            assessment,
            "argument > 0 for the registered derivative",
            interval,
        ),
    ]
end

function NLPDiagnostics.fixed_operator_value(
    ::Val{:fixed_test_operator},
    values::Vector{Any},
)
    return only(values) + 1
end

function NLPDiagnostics.coupled_set_activity(
    ::PluginCoupledSet,
    source::NLPDiagnostics.EntityRef,
    values::Vector{Union{Missing,T}},
    feasibility::T,
    active::T,
) where {T<:AbstractFloat}
    return NLPDiagnostics.CoupledSetActivity{T}(
        source,
        :test_plugin_coupled_set,
        values,
        one(T),
        zero(T),
        false,
        :interior,
    )
end

@testset "NLPDiagnostics" begin
    @testset "inconsistent bounds and disconnected variable" begin
        model = new_model()
        x = MOI.add_variable(model)
        MOI.set(model, MOI.VariableName(), x, "temperature")
        MOI.add_constraint(model, x, MOI.GreaterThan(10.0))
        MOI.add_constraint(model, x, MOI.LessThan(5.0))

        report = NLPDiagnostics.analyze(model)
        @test length(findings(report, :inconsistent_variable_bounds)) == 1
        @test length(findings(report, :disconnected_variable)) == 1
        finding = only(findings(report, :inconsistent_variable_bounds))
        @test finding.basis == NLPDiagnostics.MathematicalProof
        @test finding.confidence == NLPDiagnostics.ConfidenceCertain
        @test finding.domain == NLPDiagnostics.MathematicalIssue
    end

    @testset "fixed variable" begin
        model = new_model()
        x = MOI.add_variable(model)
        MOI.add_constraint(model, x, MOI.EqualTo(2.0))
        report = NLPDiagnostics.analyze(model)
        @test length(findings(report, :fixed_variable)) == 1
    end

    @testset "constant constraints" begin
        model = new_model()
        F = MOI.ScalarAffineFunction{Float64}
        MOI.add_constraint(model, F(MOI.ScalarAffineTerm{Float64}[], 2.0), MOI.LessThan(1.0))
        MOI.add_constraint(model, F(MOI.ScalarAffineTerm{Float64}[], 0.0), MOI.LessThan(1.0))
        report = NLPDiagnostics.analyze(model)
        @test length(findings(report, :infeasible_constant_constraint)) == 1
        @test length(findings(report, :redundant_constant_constraint)) == 1
    end

    @testset "affine and quadratic term cancellation removes false incidence" begin
        affine_model = new_model()
        x = MOI.add_variable(affine_model)
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        cancelled_affine = F([T(1.0, x), T(-1.0, x)], 2.0)
        MOI.add_constraint(affine_model, cancelled_affine, MOI.LessThan(1.0))
        affine_report = NLPDiagnostics.analyze_static(affine_model)
        @test length(findings(affine_report, :infeasible_constant_constraint)) == 1
        @test length(findings(affine_report, :disconnected_variable)) == 1

        quadratic_model = new_model()
        y = MOI.add_variable(quadratic_model)
        QT = MOI.ScalarQuadraticTerm{Float64}
        QF = MOI.ScalarQuadraticFunction{Float64}
        cancelled_quadratic = QF(
            QT[QT(2.0, y, y), QT(-2.0, y, y)],
            MOI.ScalarAffineTerm{Float64}[],
            0.0,
        )
        MOI.add_constraint(quadratic_model, cancelled_quadratic, MOI.EqualTo(0.0))
        quadratic_report = NLPDiagnostics.analyze_static(quadratic_model)
        @test length(findings(quadratic_report, :redundant_constant_constraint)) == 1
        @test length(findings(quadratic_report, :disconnected_variable)) == 1
    end

    @testset "direct nonlinear variable cancellation is folded conservatively" begin
        model = new_model()
        x = MOI.add_variable(model)
        cancelled = MOI.ScalarNonlinearFunction(:-, Any[x, x])
        expression = MOI.ScalarNonlinearFunction(:sin, Any[cancelled])
        MOI.add_constraint(model, expression, MOI.LessThan(-1.0))
        report = NLPDiagnostics.analyze_static(model)
        @test length(findings(report, :infeasible_constant_constraint)) == 1
        @test length(findings(report, :disconnected_variable)) == 1
    end

    @testset "direct zero products are folded without hiding nested operators" begin
        model = new_model()
        x = MOI.add_variable(model)
        zero_product = MOI.ScalarNonlinearFunction(:*, Any[0.0, x])
        MOI.add_constraint(model, zero_product, MOI.GreaterThan(1.0))
        report = NLPDiagnostics.analyze_static(model)
        @test length(findings(report, :infeasible_constant_constraint)) == 1
        @test length(findings(report, :disconnected_variable)) == 1

        guarded = new_model()
        y = MOI.add_variable(guarded)
        unsafe_operand = MOI.ScalarNonlinearFunction(:log, Any[y])
        guarded_product = MOI.ScalarNonlinearFunction(:*, Any[0.0, unsafe_operand])
        MOI.add_constraint(guarded, guarded_product, MOI.EqualTo(0.0))
        guarded_report = NLPDiagnostics.analyze_static(guarded)
        @test isempty(findings(guarded_report, :redundant_constant_constraint))
        @test isempty(findings(guarded_report, :disconnected_variable))
    end

    @testset "self division is identified only on a proven nonzero domain" begin
        model = new_model()
        x = MOI.add_variable(model)
        MOI.add_constraint(model, x, MOI.GreaterThan(1.0))
        identity = MOI.ScalarNonlinearFunction(:/, Any[x, x])
        MOI.add_constraint(model, identity, MOI.LessThan(2.0))
        report = NLPDiagnostics.analyze_static(model)
        finding = only(findings(report, :nonzero_self_division_identity))
        @test finding.basis == NLPDiagnostics.MathematicalProof
        @test evidence_details(finding)["lower"] == "1.0"
        @test length(
            findings(report, :redundant_nonzero_self_division_constraint),
        ) == 1

        infeasible = new_model()
        z = MOI.add_variable(infeasible)
        MOI.add_constraint(infeasible, z, MOI.GreaterThan(1.0))
        MOI.add_constraint(
            infeasible,
            MOI.ScalarNonlinearFunction(:/, Any[z, z]),
            MOI.LessThan(0.5),
        )
        infeasible_report = NLPDiagnostics.analyze_static(infeasible)
        @test length(
            findings(infeasible_report, :infeasible_nonzero_self_division_constraint),
        ) == 1

        uncertain = new_model()
        y = MOI.add_variable(uncertain)
        MOI.add_constraint(
            uncertain,
            MOI.ScalarNonlinearFunction(:/, Any[y, y]),
            MOI.LessThan(2.0),
        )
        uncertain_report = NLPDiagnostics.analyze_static(uncertain)
        @test isempty(findings(uncertain_report, :nonzero_self_division_identity))
    end

    @testset "root self-division objectives are proven constant" begin
        model = new_model()
        x = MOI.add_variable(model)
        MOI.add_constraint(model, x, MOI.GreaterThan(1.0))
        objective = MOI.ScalarNonlinearFunction(:/, Any[x, x])
        MOI.set(model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        MOI.set(model, MOI.ObjectiveFunction{MOI.ScalarNonlinearFunction}(), objective)
        report = NLPDiagnostics.analyze_static(model)
        constant = only(
            findings(report, :constant_nonzero_self_division_objective),
        )
        @test constant.basis == NLPDiagnostics.MathematicalProof
        @test evidence_details(constant)["value"] == "1"
    end

    @testset "absolute values are resolved only by declared sign bounds" begin
        model = new_model()
        x = MOI.add_variable(model)
        MOI.add_constraint(model, x, MOI.GreaterThan(0.0))
        MOI.add_constraint(
            model,
            MOI.ScalarNonlinearFunction(:abs, Any[x]),
            MOI.LessThan(2.0),
        )
        report = NLPDiagnostics.analyze_static(model)
        resolved = only(findings(report, :sign_resolved_absolute_value))
        @test resolved.basis == NLPDiagnostics.MathematicalProof
        @test evidence_details(resolved)["replacement"] == "x"

        uncertain = new_model()
        y = MOI.add_variable(uncertain)
        MOI.add_constraint(
            uncertain,
            MOI.ScalarNonlinearFunction(:abs, Any[y]),
            MOI.LessThan(2.0),
        )
        @test isempty(findings(
            NLPDiagnostics.analyze_static(uncertain),
            :sign_resolved_absolute_value,
        ))
    end

    @testset "absolute zero constraints imply a fixed variable" begin
        model = new_model()
        x = MOI.add_variable(model)
        absolute = MOI.ScalarNonlinearFunction(:abs, Any[x])
        MOI.add_constraint(model, absolute, MOI.EqualTo(0.0))
        report = NLPDiagnostics.analyze_static(model)
        fixed = only(findings(report, :absolute_zero_implies_fixed_variable))
        @test fixed.basis == NLPDiagnostics.MathematicalProof
        @test evidence_details(fixed)["implied_value"] == "0"

        interval_model = new_model()
        y = MOI.add_variable(interval_model)
        MOI.add_constraint(
            interval_model,
            MOI.ScalarNonlinearFunction(:abs, Any[y]),
            MOI.Interval(0.0, 0.0),
        )
        @test length(findings(
            NLPDiagnostics.analyze_static(interval_model),
            :absolute_zero_implies_fixed_variable,
        )) == 1

        square_model = new_model()
        z = MOI.add_variable(square_model)
        MOI.add_constraint(
            square_model,
            MOI.ScalarNonlinearFunction(:^, Any[z, 2.0]),
            MOI.EqualTo(0.0),
        )
        @test length(findings(
            NLPDiagnostics.analyze_static(square_model),
            :square_zero_implies_fixed_variable,
        )) == 1

        negative_square = new_model()
        w = MOI.add_variable(negative_square)
        MOI.add_constraint(
            negative_square,
            MOI.ScalarNonlinearFunction(:^, Any[w, 2.0]),
            MOI.LessThan(-1.0),
        )
        @test length(findings(
            NLPDiagnostics.analyze_static(negative_square),
            :infeasible_negative_square_constraint,
        )) == 1

        two_branch = new_model()
        q = MOI.add_variable(two_branch)
        MOI.add_constraint(
            two_branch,
            MOI.ScalarNonlinearFunction(:^, Any[q, 2.0]),
            MOI.EqualTo(4.0),
        )
        branch = only(findings(
            NLPDiagnostics.analyze_static(two_branch),
            :positive_square_level_set,
        ))
        @test evidence_details(branch)["root_magnitude"] == "2.0"

        signed_branch = new_model()
        r = MOI.add_variable(signed_branch)
        MOI.add_constraint(signed_branch, r, MOI.GreaterThan(0.0))
        MOI.add_constraint(signed_branch, MOI.ScalarNonlinearFunction(:^, Any[r, 2.0]), MOI.EqualTo(4.0))
        resolved = only(findings(NLPDiagnostics.analyze_static(signed_branch), :sign_resolved_square_level_set))
        @test evidence_details(resolved)["implied_value"] == "2.0"

        sqrt_model = new_model()
        s = MOI.add_variable(sqrt_model)
        MOI.add_constraint(sqrt_model, MOI.ScalarNonlinearFunction(:sqrt, Any[s]), MOI.EqualTo(0.0))
        @test length(findings(NLPDiagnostics.analyze_static(sqrt_model), :square_root_zero_implies_fixed_variable)) == 1

        negative_sqrt = new_model()
        u = MOI.add_variable(negative_sqrt)
        MOI.add_constraint(negative_sqrt, MOI.ScalarNonlinearFunction(:sqrt, Any[u]), MOI.LessThan(-1.0))
        @test length(findings(NLPDiagnostics.analyze_static(negative_sqrt), :infeasible_negative_square_root_constraint)) == 1

        nonpositive_exp = new_model()
        v = MOI.add_variable(nonpositive_exp)
        MOI.add_constraint(nonpositive_exp, MOI.ScalarNonlinearFunction(:exp, Any[v]), MOI.LessThan(0.0))
        @test length(findings(NLPDiagnostics.analyze_static(nonpositive_exp), :infeasible_nonpositive_exponential_constraint)) == 1

        for (operator, set_value) in [
            (:exp2, MOI.LessThan(0.0)),
            (:expm1, MOI.LessThan(-1.0)),
            (:log1mexp, MOI.GreaterThan(0.0)),
            (:logistic, MOI.EqualTo(1.0)),
            (:softplus, MOI.LessThan(0.0)),
            (:logcosh, MOI.LessThan(-0.1)),
            (:abs, MOI.LessThan(-0.1)),
            (:cosh, MOI.LessThan(0.9)),
            (:sin, MOI.GreaterThan(1.1)),
            (:cos, MOI.LessThan(-1.1)),
            (:sind, MOI.GreaterThan(1.1)),
            (:cosd, MOI.LessThan(-1.1)),
            (:tanh, MOI.GreaterThan(1.0)),
            (:sech, MOI.EqualTo(0.0)),
            (:sech, MOI.GreaterThan(1.1)),
            (:asin, MOI.GreaterThan(pi / 2 + 0.1)),
            (:acos, MOI.LessThan(-0.1)),
            (:acos, MOI.GreaterThan(pi + 0.1)),
            (:atan, MOI.EqualTo(pi / 2)),
            (:asind, MOI.GreaterThan(90.1)),
            (:acosd, MOI.LessThan(-0.1)),
            (:acosd, MOI.GreaterThan(180.1)),
            (:atand, MOI.EqualTo(90.0)),
            (:asec, MOI.LessThan(-0.1)),
            (:asecd, MOI.GreaterThan(180.1)),
            (:acsc, MOI.GreaterThan(pi / 2 + 0.1)),
            (:acscd, MOI.LessThan(-90.1)),
        ]
            range_model = new_model()
            range_x = MOI.add_variable(range_model)
            MOI.add_constraint(
                range_model,
                MOI.ScalarNonlinearFunction(operator, Any[range_x]),
                set_value,
            )
            range_finding = only(findings(
                NLPDiagnostics.analyze_static(range_model),
                :infeasible_unary_operator_range_constraint,
            ))
            @test range_finding.basis == NLPDiagnostics.MathematicalProof
            @test range_finding.confidence == NLPDiagnostics.ConfidenceCertain
            @test evidence_details(range_finding)["operator"] == string(operator)
        end

        boundary_cosh = new_model()
        boundary_x = MOI.add_variable(boundary_cosh)
        MOI.add_constraint(
            boundary_cosh,
            MOI.ScalarNonlinearFunction(:cosh, Any[boundary_x]),
            MOI.EqualTo(1.0),
        )
        @test isempty(findings(
            NLPDiagnostics.analyze_static(boundary_cosh),
            :infeasible_unary_operator_range_constraint,
        ))

        boundary_sech = new_model()
        boundary_sech_x = MOI.add_variable(boundary_sech)
        MOI.add_constraint(
            boundary_sech,
            MOI.ScalarNonlinearFunction(:sech, Any[boundary_sech_x]),
            MOI.EqualTo(1.0),
        )
        @test isempty(findings(
            NLPDiagnostics.analyze_static(boundary_sech),
            :infeasible_unary_operator_range_constraint,
        ))

        for (operator, endpoint, implied) in [
            (:asin, pi / 2, 1.0),
            (:acos, Float64(pi), -1.0),
            (:asec, 0.0, 1.0),
            (:acsc, -pi / 2, -1.0),
            (:asind, 90.0, 1.0),
            (:acosd, 180.0, -1.0),
            (:asecd, 0.0, 1.0),
            (:acscd, -90.0, -1.0),
        ]
            endpoint_model = new_model()
            endpoint_x = MOI.add_variable(endpoint_model)
            MOI.add_constraint(
                endpoint_model,
                MOI.ScalarNonlinearFunction(operator, Any[endpoint_x]),
                MOI.EqualTo(endpoint),
            )
            endpoint_finding = only(findings(
                NLPDiagnostics.analyze_static(endpoint_model),
                :inverse_trigonometric_endpoint_implies_fixed_variable,
            ))
            @test endpoint_finding.basis == NLPDiagnostics.MathematicalProof
            @test evidence_details(endpoint_finding)["implied_value"] == string(implied)
        end

        endpoint_bound_conflict = new_model()
        endpoint_bound_x = MOI.add_variable(endpoint_bound_conflict)
        MOI.add_constraint(endpoint_bound_conflict, endpoint_bound_x, MOI.LessThan(0.9))
        MOI.add_constraint(
            endpoint_bound_conflict,
            MOI.ScalarNonlinearFunction(:asin, Any[endpoint_bound_x]),
            MOI.EqualTo(pi / 2),
        )
        conflict = only(findings(
            NLPDiagnostics.analyze_static(endpoint_bound_conflict),
            :inconsistent_inverse_trigonometric_endpoint_variable_bound,
        ))
        @test conflict.basis == NLPDiagnostics.MathematicalProof
        @test evidence_details(conflict)["implied_value"] == "1.0"

        for (operator, endpoint, implied) in [
            (:sinh, 0.0, 0.0),
            (:tanh, 0.0, 0.0),
            (:cosh, 1.0, 0.0),
            (:sech, 1.0, 0.0),
            (:logcosh, 0.0, 0.0),
            (:acosh, 0.0, 1.0),
            (:asech, 0.0, 1.0),
        ]
            endpoint_model = new_model()
            endpoint_x = MOI.add_variable(endpoint_model)
            MOI.add_constraint(
                endpoint_model,
                MOI.ScalarNonlinearFunction(operator, Any[endpoint_x]),
                MOI.EqualTo(endpoint),
            )
            endpoint_finding = only(findings(
                NLPDiagnostics.analyze_static(endpoint_model),
                :hyperbolic_endpoint_implies_fixed_variable,
            ))
            @test endpoint_finding.basis == NLPDiagnostics.MathematicalProof
            @test evidence_details(endpoint_finding)["implied_value"] == string(implied)
        end

        hyperbolic_bound_conflict = new_model()
        hyperbolic_bound_x = MOI.add_variable(hyperbolic_bound_conflict)
        MOI.add_constraint(hyperbolic_bound_conflict, hyperbolic_bound_x, MOI.GreaterThan(0.1))
        MOI.add_constraint(
            hyperbolic_bound_conflict,
            MOI.ScalarNonlinearFunction(:cosh, Any[hyperbolic_bound_x]),
            MOI.EqualTo(1.0),
        )
        @test length(findings(
            NLPDiagnostics.analyze_static(hyperbolic_bound_conflict),
            :inconsistent_hyperbolic_endpoint_variable_bound,
        )) == 1

        for (operator, level, implied) in [
            (:exp, 1.0, 0.0),
            (:expm1, 0.0, 0.0),
            (:log, 0.0, 1.0),
            (:log1p, 0.0, 0.0),
            (:logistic, 0.5, 0.0),
            (:cbrt, 0.0, 0.0),
            (:softplus, log(2.0), 0.0),
            (:log1pexp, log(2.0), 0.0),
            (:log1exp, log(2.0), 0.0),
            (:log1mexp, -log(2.0), -log(2.0)),
        ]
            reference_model = new_model()
            reference_x = MOI.add_variable(reference_model)
            MOI.add_constraint(
                reference_model,
                MOI.ScalarNonlinearFunction(operator, Any[reference_x]),
                MOI.EqualTo(level),
            )
            reference_finding = only(findings(
                NLPDiagnostics.analyze_static(reference_model),
                :elementary_reference_level_implies_fixed_variable,
            ))
            @test reference_finding.basis == NLPDiagnostics.MathematicalProof
            @test evidence_details(reference_finding)["implied_value"] == string(implied)
        end

        elementary_bound_conflict = new_model()
        elementary_bound_x = MOI.add_variable(elementary_bound_conflict)
        MOI.add_constraint(elementary_bound_conflict, elementary_bound_x, MOI.GreaterThan(0.1))
        MOI.add_constraint(
            elementary_bound_conflict,
            MOI.ScalarNonlinearFunction(:exp, Any[elementary_bound_x]),
            MOI.EqualTo(1.0),
        )
        @test length(findings(
            NLPDiagnostics.analyze_static(elementary_bound_conflict),
            :inconsistent_elementary_reference_level_variable_bound,
        )) == 1

        for (operator, set_value) in [
            (:sec, MOI.EqualTo(0.0)),
            (:csc, MOI.Interval(-0.5, 0.5)),
            (:secd, MOI.EqualTo(0.0)),
            (:cscd, MOI.Interval(-0.5, 0.5)),
            (:acsc, MOI.EqualTo(0.0)),
            (:acscd, MOI.Interval(0.0, 0.0)),
        ]
            range_model = new_model()
            range_x = MOI.add_variable(range_model)
            MOI.add_constraint(
                range_model,
                MOI.ScalarNonlinearFunction(operator, Any[range_x]),
                set_value,
            )
            range_finding = only(findings(
                NLPDiagnostics.analyze_static(range_model),
                :infeasible_reciprocal_trigonometric_range_constraint,
            ))
            @test range_finding.basis == NLPDiagnostics.MathematicalProof
            @test range_finding.confidence == NLPDiagnostics.ConfidenceCertain
            @test evidence_details(range_finding)["operator"] == string(operator)
        end

        boundary_acos = new_model()
        boundary_acos_x = MOI.add_variable(boundary_acos)
        MOI.add_constraint(
            boundary_acos,
            MOI.ScalarNonlinearFunction(:acos, Any[boundary_acos_x]),
            MOI.Interval(0.0, Float64(pi)),
        )
        @test isempty(findings(
            NLPDiagnostics.analyze_static(boundary_acos),
            :infeasible_unary_operator_range_constraint,
        ))

        @test NLPDiagnostics.operator_interval(
            Val(:asind), [NLPDiagnostics.IntervalEnclosure(-1.0, 1.0)], Any[],
        ).lower == -90.0
        @test NLPDiagnostics.operator_interval(
            Val(:acosd), [NLPDiagnostics.IntervalEnclosure(-1.0, 1.0)], Any[],
        ).upper == 180.0
        atand_interval = NLPDiagnostics.operator_interval(
            Val(:atand), [NLPDiagnostics.IntervalEnclosure(-1.0, 1.0)], Any[],
        )
        @test atand_interval.lower == atand(-1.0)
        @test atand_interval.upper == atand(1.0)

        sinh_interval = NLPDiagnostics.operator_interval(
            Val(:sinh), [NLPDiagnostics.IntervalEnclosure(-1.0, 2.0)], Any[],
        )
        @test sinh_interval.lower == sinh(-1.0)
        @test sinh_interval.upper == sinh(2.0)
        cosh_interval = NLPDiagnostics.operator_interval(
            Val(:cosh), [NLPDiagnostics.IntervalEnclosure(-2.0, 1.0)], Any[],
        )
        @test cosh_interval.lower == 1.0
        @test cosh_interval.upper == cosh(2.0)
        atanh_interval = NLPDiagnostics.operator_interval(
            Val(:atanh), [NLPDiagnostics.IntervalEnclosure(-1.0, 0.5)], Any[],
        )
        @test atanh_interval.lower == -Inf
        @test atanh_interval.upper == atanh(0.5)
        acosh_interval = NLPDiagnostics.operator_interval(
            Val(:acosh), [NLPDiagnostics.IntervalEnclosure(0.0, 2.0)], Any[],
        )
        @test acosh_interval.lower == 0.0
        @test acosh_interval.upper == acosh(2.0)

        min_interval = NLPDiagnostics.operator_interval(
            Val(:min),
            [
                NLPDiagnostics.IntervalEnclosure(-2.0, 3.0),
                NLPDiagnostics.IntervalEnclosure(1.0, 4.0),
            ],
            Any[],
        )
        @test min_interval.lower == -2.0
        @test min_interval.upper == 3.0
        max_interval = NLPDiagnostics.operator_interval(
            Val(:max),
            [
                NLPDiagnostics.IntervalEnclosure(-2.0, 3.0),
                NLPDiagnostics.IntervalEnclosure(1.0, 4.0),
            ],
            Any[],
        )
        @test max_interval.lower == 1.0
        @test max_interval.upper == 4.0
        @test NLPDiagnostics.operator_interval(
            Val(:sign), [NLPDiagnostics.IntervalEnclosure(0.2, 1.0)], Any[],
        ).lower == 1.0
        sign_crossing = NLPDiagnostics.operator_interval(
            Val(:sign), [NLPDiagnostics.IntervalEnclosure(-1.0, 1.0)], Any[],
        )
        @test sign_crossing.lower == -1.0
        @test sign_crossing.upper == 1.0
        cbrt_interval = NLPDiagnostics.operator_interval(
            Val(:cbrt), [NLPDiagnostics.IntervalEnclosure(-8.0, 27.0)], Any[],
        )
        @test cbrt_interval.lower == -2.0
        @test cbrt_interval.upper == 3.0
        @test NLPDiagnostics.fixed_operator_value(Val(:sign), Any[-2.0]) == -1.0

        logistic_interval = NLPDiagnostics.operator_interval(
            Val(:logistic), [NLPDiagnostics.IntervalEnclosure(-2.0, 2.0)], Any[],
        )
        @test logistic_interval.lower ≈ inv(1 + exp(2.0)) atol = 1.0e-12
        @test logistic_interval.upper ≈ inv(1 + exp(-2.0)) atol = 1.0e-12

        sin_interval = NLPDiagnostics.operator_interval(
            Val(:sin), [NLPDiagnostics.IntervalEnclosure(0.1, 0.2)], Any[],
        )
        @test sin_interval.lower ≈ sin(0.1) atol = 1.0e-12
        @test sin_interval.upper ≈ sin(0.2) atol = 1.0e-12
        cos_interval = NLPDiagnostics.operator_interval(
            Val(:cos), [NLPDiagnostics.IntervalEnclosure(2.9, 3.3)], Any[],
        )
        @test cos_interval.lower == -1.0
        sind_interval = NLPDiagnostics.operator_interval(
            Val(:sind), [NLPDiagnostics.IntervalEnclosure(10.0, 20.0)], Any[],
        )
        @test sind_interval.lower ≈ sind(10.0) atol = 1.0e-12
        @test sind_interval.upper ≈ sind(20.0) atol = 1.0e-12
        tan_interval = NLPDiagnostics.operator_interval(
            Val(:tan), [NLPDiagnostics.IntervalEnclosure(0.1, 0.2)], Any[],
        )
        @test tan_interval.lower ≈ tan(0.1) atol = 1.0e-12
        @test tan_interval.upper ≈ tan(0.2) atol = 1.0e-12
        @test !NLPDiagnostics.operator_interval(
            Val(:tan), [NLPDiagnostics.IntervalEnclosure(1.4, 1.8)], Any[],
        ).informative
        sec_interval = NLPDiagnostics.operator_interval(
            Val(:sec), [NLPDiagnostics.IntervalEnclosure(0.1, 0.2)], Any[],
        )
        @test sec_interval.lower ≈ inv(cos(0.1)) atol = 1.0e-12
        @test sec_interval.upper ≈ inv(cos(0.2)) atol = 1.0e-12
        csc_interval = NLPDiagnostics.operator_interval(
            Val(:csc), [NLPDiagnostics.IntervalEnclosure(0.1, 0.2)], Any[],
        )
        @test csc_interval.lower ≈ inv(sin(0.2)) atol = 1.0e-12
        @test csc_interval.upper ≈ inv(sin(0.1)) atol = 1.0e-12
        @test NLPDiagnostics.fixed_operator_value(Val(:cot), Any[pi / 4]) ≈ 1.0
        asec_interval = NLPDiagnostics.operator_interval(
            Val(:asec), [NLPDiagnostics.IntervalEnclosure(1.0, 2.0)], Any[],
        )
        @test asec_interval.lower == 0.0
        @test asec_interval.upper ≈ acos(0.5) atol = 1.0e-12
        acsc_interval = NLPDiagnostics.operator_interval(
            Val(:acsc), [NLPDiagnostics.IntervalEnclosure(1.0, 2.0)], Any[],
        )
        @test acsc_interval.lower ≈ asin(0.5) atol = 1.0e-12
        @test acsc_interval.upper == Float64(pi) / 2
        @test !NLPDiagnostics.operator_interval(
            Val(:asec), [NLPDiagnostics.IntervalEnclosure(-2.0, 2.0)], Any[],
        ).informative
        @test NLPDiagnostics.fixed_operator_value(Val(:asecd), Any[2.0]) ≈ 60.0
        sech_interval = NLPDiagnostics.operator_interval(
            Val(:sech), [NLPDiagnostics.IntervalEnclosure(0.0, 1.0)], Any[],
        )
        @test sech_interval.lower ≈ inv(cosh(1.0)) atol = 1.0e-12
        @test sech_interval.upper == 1.0
        csch_interval = NLPDiagnostics.operator_interval(
            Val(:csch), [NLPDiagnostics.IntervalEnclosure(1.0, 2.0)], Any[],
        )
        @test csch_interval.lower ≈ inv(sinh(2.0)) atol = 1.0e-12
        @test csch_interval.upper ≈ inv(sinh(1.0)) atol = 1.0e-12
        asech_interval = NLPDiagnostics.operator_interval(
            Val(:asech), [NLPDiagnostics.IntervalEnclosure(0.5, 1.0)], Any[],
        )
        @test asech_interval.lower == 0.0
        @test asech_interval.upper ≈ acosh(2.0) atol = 1.0e-12
        @test NLPDiagnostics.fixed_operator_value(Val(:acsch), Any[2.0]) ≈ asinh(0.5)
    end

    @testset "min/max branches are resolved by declared bounds" begin
        model = new_model()
        x = MOI.add_variable(model)
        MOI.add_constraint(model, x, MOI.LessThan(1.0))
        MOI.add_constraint(
            model,
            MOI.ScalarNonlinearFunction(:min, Any[x, 2.0]),
            MOI.LessThan(3.0),
        )
        report = NLPDiagnostics.analyze_static(model)
        resolved = only(findings(report, :bound_resolved_minmax_expression))
        @test resolved.basis == NLPDiagnostics.MathematicalProof
        @test evidence_details(resolved)["replacement"] == "x"

        constant = new_model()
        y = MOI.add_variable(constant)
        MOI.add_constraint(constant, y, MOI.GreaterThan(3.0))
        MOI.add_constraint(
            constant,
            MOI.ScalarNonlinearFunction(:min, Any[y, 2.0]),
            MOI.LessThan(3.0),
        )
        constant_report = NLPDiagnostics.analyze_static(constant)
        constant_finding = only(
            findings(constant_report, :bound_resolved_minmax_expression),
        )
        @test evidence_details(constant_finding)["replacement"] == "2.0"
        @test length(
            findings(constant_report, :redundant_bound_resolved_minmax_constraint),
        ) == 1

        infeasible = new_model()
        z = MOI.add_variable(infeasible)
        MOI.add_constraint(infeasible, z, MOI.GreaterThan(3.0))
        MOI.add_constraint(
            infeasible,
            MOI.ScalarNonlinearFunction(:min, Any[z, 2.0]),
            MOI.LessThan(1.0),
        )
        infeasible_report = NLPDiagnostics.analyze_static(infeasible)
        @test length(
            findings(infeasible_report, :infeasible_bound_resolved_minmax_constraint),
        ) == 1

        objective_model = new_model()
        w = MOI.add_variable(objective_model)
        MOI.add_constraint(objective_model, w, MOI.GreaterThan(3.0))
        MOI.set(objective_model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        MOI.set(
            objective_model,
            MOI.ObjectiveFunction{MOI.ScalarNonlinearFunction}(),
            MOI.ScalarNonlinearFunction(:min, Any[w, 2.0]),
        )
        objective_report = NLPDiagnostics.analyze_static(objective_model)
        @test length(
            findings(objective_report, :constant_bound_resolved_minmax_objective),
        ) == 1
    end

    @testset "reciprocal-hyperbolic output ranges" begin
        for (operator, set_value, expected_range) in [
            (:csch, MOI.EqualTo(0.0), "(-∞, 0) ∪ (0, ∞)"),
            (:acsch, MOI.EqualTo(0.0), "(-∞, 0) ∪ (0, ∞)"),
            (:acoth, MOI.Interval(0.0, 0.0), "(-∞, 0) ∪ (0, ∞)"),
            (:coth, MOI.Interval(-1.0, 1.0), "(-∞, -1) ∪ (1, ∞)"),
        ]
            range_model = new_model()
            x = MOI.add_variable(range_model)
            MOI.add_constraint(
                range_model,
                MOI.ScalarNonlinearFunction(operator, Any[x]),
                set_value,
            )
            finding = only(findings(
                NLPDiagnostics.analyze_static(range_model),
                :infeasible_reciprocal_hyperbolic_range_constraint,
            ))
            @test finding.basis == NLPDiagnostics.MathematicalProof
            @test Dict(finding.evidence[1].details)["operator_range"] == expected_range
        end
    end

    @testset "discrete sign-function rows" begin
        infeasible = new_model()
        x = MOI.add_variable(infeasible)
        MOI.add_constraint(
            infeasible,
            MOI.ScalarNonlinearFunction(:sign, Any[x]),
            MOI.EqualTo(0.5),
        )
        infeasible_finding = only(findings(
            NLPDiagnostics.analyze_static(infeasible),
            :infeasible_sign_range_constraint,
        ))
        @test infeasible_finding.basis == NLPDiagnostics.MathematicalProof
        @test infeasible_finding.confidence == NLPDiagnostics.ConfidenceCertain
        @test evidence_details(infeasible_finding)["operator_range"] == "{-1, 0, 1}"

        fixed = new_model()
        y = MOI.add_variable(fixed)
        MOI.add_constraint(
            fixed,
            MOI.ScalarNonlinearFunction(:sign, Any[y]),
            MOI.EqualTo(0.0),
        )
        fixed_finding = only(findings(
            NLPDiagnostics.analyze_static(fixed),
            :sign_zero_implies_fixed_variable,
        ))
        @test fixed_finding.basis == NLPDiagnostics.MathematicalProof
        @test isempty(findings(
            NLPDiagnostics.analyze_static(fixed),
            :infeasible_sign_range_constraint,
        ))
    end

    @testset "fully fixed affine rows are evaluated without model mutation" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        MOI.add_constraint(model, x, MOI.EqualTo(1.0))
        MOI.add_constraint(model, y, MOI.EqualTo(2.0))
        MOI.add_constraint(
            model,
            F([T(2.0, x), T(-1.0, y)], 0.0),
            MOI.EqualTo(0.0),
        )
        report = NLPDiagnostics.analyze_static(model)
        redundant = only(findings(report, :redundant_fixed_affine_constraint))
        @test redundant.basis == NLPDiagnostics.MathematicalProof
        @test evidence_details(redundant)["evaluated_value"] == "0.0"

        infeasible = new_model()
        a, b = MOI.add_variables(infeasible, 2)
        MOI.add_constraint(infeasible, a, MOI.EqualTo(1.0))
        MOI.add_constraint(infeasible, b, MOI.EqualTo(2.0))
        MOI.add_constraint(
            infeasible,
            F([T(1.0, a), T(1.0, b)], 0.0),
            MOI.LessThan(2.0),
        )
        infeasible_report = NLPDiagnostics.analyze_static(infeasible)
        @test length(findings(infeasible_report, :infeasible_fixed_affine_constraint)) == 1
    end

    @testset "fully fixed quadratic and nonlinear expressions are evaluated" begin
        model = new_model()
        x = MOI.add_variable(model)
        Q = MOI.ScalarQuadraticFunction{Float64}
        QT = MOI.ScalarQuadraticTerm{Float64}
        MOI.add_constraint(model, x, MOI.EqualTo(2.0))
        # MOI stores the diagonal coefficient as twice the polynomial coefficient.
        MOI.add_constraint(model, Q(QT[QT(2.0, x, x)], MOI.ScalarAffineTerm{Float64}[], 0.0), MOI.EqualTo(4.0))
        report = NLPDiagnostics.analyze_static(model)
        @test length(findings(report, :redundant_fixed_expression_constraint)) == 1

        nonlinear = new_model()
        y = MOI.add_variable(nonlinear)
        MOI.add_constraint(nonlinear, y, MOI.EqualTo(-1.0))
        MOI.add_constraint(
            nonlinear,
            MOI.ScalarNonlinearFunction(:log, Any[y]),
            MOI.LessThan(0.0),
        )
        nonlinear_report = NLPDiagnostics.analyze_static(nonlinear)
        @test length(findings(nonlinear_report, :fixed_expression_domain_violation)) == 1
    end

    @testset "fixed stable nonlinear primitives avoid artificial overflow" begin
        model = new_model()
        x = MOI.add_variable(model)
        MOI.add_constraint(model, x, MOI.EqualTo(1_000.0))
        MOI.add_constraint(
            model,
            MOI.ScalarNonlinearFunction(:log1pexp, Any[x]),
            MOI.EqualTo(1_000.0),
        )
        MOI.add_constraint(
            model,
            MOI.ScalarNonlinearFunction(:logistic, Any[x]),
            MOI.Interval(0.999, 1.0),
        )
        report = NLPDiagnostics.analyze_static(model)
        @test length(findings(report, :redundant_fixed_expression_constraint)) == 2
        @test isempty(findings(report, :fixed_expression_domain_violation))
    end

    @testset "fixed objectives retain feasibility-versus-optimization evidence" begin
        model = new_model()
        x = MOI.add_variable(model)
        MOI.add_constraint(model, x, MOI.EqualTo(3.0))
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        objective = F([T(2.0, x)], 1.0)
        MOI.set(model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        MOI.set(model, MOI.ObjectiveFunction{F}(), objective)
        report = NLPDiagnostics.analyze_static(model)
        fixed = only(findings(report, :fixed_objective))
        @test fixed.basis == NLPDiagnostics.MathematicalProof
        @test evidence_details(fixed)["objective_value"] == "7.0"
    end

    @testset "constant objectives are distinguished from fixed objectives" begin
        model = new_model()
        F = MOI.ScalarAffineFunction{Float64}
        objective = F(MOI.ScalarAffineTerm{Float64}[], 4.0)
        MOI.set(model, MOI.ObjectiveSense(), MOI.MAX_SENSE)
        MOI.set(model, MOI.ObjectiveFunction{F}(), objective)
        report = NLPDiagnostics.analyze_static(model)
        constant = only(findings(report, :constant_objective))
        @test constant.basis == NLPDiagnostics.MathematicalProof
        @test evidence_details(constant)["objective_value"] == "4.0"
        @test isempty(findings(report, :fixed_objective))
    end

    @testset "disconnected affine objective variables expose conditional rays" begin
        model = new_model()
        x = MOI.add_variable(model)
        MOI.set(model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        MOI.set(model, MOI.ObjectiveFunction{MOI.VariableIndex}(), x)
        report = NLPDiagnostics.analyze_static(model)
        ray = only(findings(report, :unconstrained_affine_objective_ray))
        @test ray.basis == NLPDiagnostics.MathematicalProof
        @test evidence_details(ray)["missing_bound"] == "lower"

        bounded = new_model()
        y = MOI.add_variable(bounded)
        MOI.add_constraint(bounded, y, MOI.GreaterThan(0.0))
        MOI.set(bounded, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        MOI.set(bounded, MOI.ObjectiveFunction{MOI.VariableIndex}(), y)
        bounded_report = NLPDiagnostics.analyze_static(bounded)
        @test isempty(findings(bounded_report, :unconstrained_affine_objective_ray))

        free_row = new_model()
        z = MOI.add_variable(free_row)
        MOI.add_constraint(free_row, MOI.VectorOfVariables([z]), MOI.Reals(1))
        MOI.set(free_row, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        MOI.set(free_row, MOI.ObjectiveFunction{MOI.VariableIndex}(), z)
        free_row_report = NLPDiagnostics.analyze_static(free_row)
        @test length(
            findings(free_row_report, :unconstrained_affine_objective_ray),
        ) == 1
    end

    @testset "disconnected quadratic objective curvature exposes conditional rays" begin
        model = new_model()
        x = MOI.add_variable(model)
        Q = MOI.ScalarQuadraticFunction{Float64}
        QT = MOI.ScalarQuadraticTerm{Float64}
        objective = Q(QT[QT(-2.0, x, x)], MOI.ScalarAffineTerm{Float64}[], 0.0)
        MOI.set(model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        MOI.set(model, MOI.ObjectiveFunction{Q}(), objective)
        report = NLPDiagnostics.analyze_static(model)
        ray = only(findings(report, :unconstrained_quadratic_objective_ray))
        @test ray.basis == NLPDiagnostics.MathematicalProof
        @test evidence_details(ray)["polynomial_coefficient"] == "-1.0"

        bounded = new_model()
        y = MOI.add_variable(bounded)
        MOI.add_constraint(bounded, y, MOI.Interval(-1.0, 1.0))
        bounded_objective = Q(
            QT[QT(-2.0, y, y)],
            MOI.ScalarAffineTerm{Float64}[],
            0.0,
        )
        MOI.set(bounded, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        MOI.set(bounded, MOI.ObjectiveFunction{Q}(), bounded_objective)
        bounded_report = NLPDiagnostics.analyze_static(bounded)
        @test isempty(findings(bounded_report, :unconstrained_quadratic_objective_ray))
    end

    @testset "quadratic objectives retain purely affine disconnected rays" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        Q = MOI.ScalarQuadraticFunction{Float64}
        QT = MOI.ScalarQuadraticTerm{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        objective = Q(QT[QT(2.0, y, y)], T[T(1.0, x)], 0.0)
        MOI.set(model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        MOI.set(model, MOI.ObjectiveFunction{Q}(), objective)
        report = NLPDiagnostics.analyze_static(model)
        @test length(findings(report, :unconstrained_affine_objective_ray)) == 1
        @test isempty(findings(report, :unconstrained_quadratic_objective_ray))
    end

    @testset "fixed custom operator evaluation is explicit and extensible" begin
        @test NLPDiagnostics.fixed_operator_value(
            Val(:fixed_test_operator), [1.0],
        ) == 2.0
        @test isfinite(NLPDiagnostics.fixed_operator_value(
            Val(:logsumexp), [1_000.0, 999.0],
        ))
        unavailable = new_model()
        x = MOI.add_variable(unavailable)
        MOI.add_constraint(unavailable, x, MOI.EqualTo(1.0))
        MOI.add_constraint(
            unavailable,
            MOI.ScalarNonlinearFunction(:unavailable_fixed_operator, Any[x]),
            MOI.EqualTo(0.0),
        )
        unavailable_report = NLPDiagnostics.analyze_static(unavailable)
        @test length(
            findings(unavailable_report, :fixed_expression_evaluation_unavailable),
        ) == 1

        extended = new_model()
        y = MOI.add_variable(extended)
        MOI.add_constraint(extended, y, MOI.EqualTo(1.0))
        MOI.add_constraint(
            extended,
            MOI.ScalarNonlinearFunction(:fixed_test_operator, Any[y]),
            MOI.EqualTo(2.0),
        )
        extended_report = NLPDiagnostics.analyze_static(extended)
        @test length(
            findings(extended_report, :redundant_fixed_expression_constraint),
        ) == 1

        overflow = new_model()
        z = MOI.add_variable(overflow)
        MOI.add_constraint(overflow, z, MOI.EqualTo(1_000.0))
        MOI.add_constraint(
            overflow,
            MOI.ScalarNonlinearFunction(:exp, Any[z]),
            MOI.LessThan(Inf),
        )
        overflow_report = NLPDiagnostics.analyze_static(overflow)
        @test length(
            findings(overflow_report, :fixed_expression_nonfinite_evaluation),
        ) == 1
    end

    @testset "fixed degree-trigonometric primitives are evaluated exactly" begin
        model = new_model()
        x = MOI.add_variable(model)
        MOI.add_constraint(model, x, MOI.EqualTo(0.0))
        MOI.add_constraint(
            model,
            MOI.ScalarNonlinearFunction(:asind, Any[x]),
            MOI.EqualTo(0.0),
        )
        report = NLPDiagnostics.analyze_static(model)
        @test length(findings(report, :redundant_fixed_expression_constraint)) == 1
        @test isempty(findings(report, :fixed_expression_evaluation_unavailable))
    end

    @testset "constant nonlinear domain violation" begin
        model = new_model()
        f = MOI.ScalarNonlinearFunction(:log, Any[-1.0])
        MOI.add_constraint(model, f, MOI.LessThan(0.0))
        report = NLPDiagnostics.analyze(model)
        @test length(findings(report, :constant_domain_violation)) == 1
    end

    @testset "duplicate affine constraints are canonicalized" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        f1 = F([T(2.0, x), T(3.0, y)], 1.0)
        f2 = F([T(1.0, x), T(3.0, y), T(1.0, x)], 1.0)
        MOI.add_constraint(model, f1, MOI.EqualTo(0.0))
        MOI.add_constraint(model, f2, MOI.EqualTo(0.0))
        report = NLPDiagnostics.analyze(model)
        @test length(findings(report, :duplicate_constraint)) == 1
        @test isempty(findings(report, :disconnected_variable))
    end

    @testset "proportional affine equalities are structurally redundant" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        MOI.add_constraint(model, F([T(1.0, x), T(-1.0, y)], 0.0), MOI.EqualTo(0.0))
        MOI.add_constraint(model, F([T(-2.0, x), T(2.0, y)], 0.0), MOI.EqualTo(0.0))
        report = NLPDiagnostics.analyze_static(model)
        @test length(
            findings(report, :proportional_affine_equality_constraints),
        ) == 1
        @test isempty(findings(report, :duplicate_constraint))
    end

    @testset "proportional affine inequalities preserve orientation" begin
        model = new_model()
        x = MOI.add_variable(model)
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        MOI.add_constraint(model, F([T(1.0, x)], 0.0), MOI.LessThan(1.0))
        MOI.add_constraint(model, F([T(2.0, x)], 0.0), MOI.LessThan(2.0))
        MOI.add_constraint(model, F([T(-1.0, x)], 0.0), MOI.GreaterThan(-1.0))
        report = NLPDiagnostics.analyze_static(model)
        @test length(
            findings(report, :proportional_affine_inequality_constraints),
        ) == 1
    end

    @testset "parallel affine inequalities expose dominated half-spaces" begin
        model = new_model()
        x = MOI.add_variable(model)
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        MOI.add_constraint(model, F([T(1.0, x)], 0.0), MOI.LessThan(1.0))
        MOI.add_constraint(model, F([T(2.0, x)], 0.0), MOI.LessThan(4.0))
        # This is x >= -3, so it is the opposite half-space and must not be
        # treated as dominated by x <= 1.
        MOI.add_constraint(model, F([T(-1.0, x)], 0.0), MOI.LessThan(3.0))
        report = NLPDiagnostics.analyze_static(model)
        dominated = only(findings(report, :dominated_affine_inequality))
        @test dominated.basis == NLPDiagnostics.MathematicalProof
        @test evidence_details(dominated)["tightest_normalized_bound"] == "1.0"
        @test evidence_details(dominated)["dominated_constraint_count"] == "1"
    end

    @testset "opposing affine inequalities prove an empty multi-variable slab" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        # x + y <= 1 and x + y >= 2; neither variable has declared bounds.
        MOI.add_constraint(model, F([T(1.0, x), T(1.0, y)], 0.0), MOI.LessThan(1.0))
        MOI.add_constraint(model, F([T(-2.0, x), T(-2.0, y)], 0.0), MOI.LessThan(-4.0))
        report = NLPDiagnostics.analyze_static(model)
        inconsistent = only(
            findings(report, :inconsistent_opposing_affine_inequalities),
        )
        @test inconsistent.basis == NLPDiagnostics.MathematicalProof
        @test evidence_details(inconsistent)["normalized_lower"] == "-1.0"
        @test evidence_details(inconsistent)["normalized_upper"] == "-2.0"
    end

    @testset "affine equalities are checked against parallel half-spaces" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        expression = F([T(1.0, x), T(1.0, y)], 0.0)
        MOI.add_constraint(model, expression, MOI.EqualTo(2.0))
        MOI.add_constraint(model, expression, MOI.LessThan(1.0))
        report = NLPDiagnostics.analyze_static(model)
        incompatible = only(findings(report, :inconsistent_affine_equality_halfspace))
        @test incompatible.basis == NLPDiagnostics.MathematicalProof
        @test evidence_details(incompatible)["normalized_upper"] == "1.0"

        parallel = new_model()
        a, b = MOI.add_variables(parallel, 2)
        parallel_expression = F([T(1.0, a), T(-1.0, b)], 0.0)
        MOI.add_constraint(parallel, parallel_expression, MOI.EqualTo(0.0))
        MOI.add_constraint(parallel, parallel_expression, MOI.EqualTo(1.0))
        parallel_report = NLPDiagnostics.analyze_static(parallel)
        @test length(findings(parallel_report, :inconsistent_parallel_affine_equalities)) == 1
    end

    @testset "reused scalar expressions retain set-intersection evidence" begin
        model = new_model()
        x = MOI.add_variable(model)
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        expression = F([T(2.0, x)], 1.0)
        MOI.add_constraint(model, expression, MOI.GreaterThan(0.0))
        MOI.add_constraint(model, expression, MOI.LessThan(3.0))
        report = NLPDiagnostics.analyze_static(model)
        @test length(findings(report, :reused_constraint_expression)) == 1

        dominated = new_model()
        z = MOI.add_variable(dominated)
        dominated_expression = F([T(1.0, z)], 0.0)
        MOI.add_constraint(dominated, dominated_expression, MOI.GreaterThan(0.0))
        MOI.add_constraint(dominated, dominated_expression, MOI.GreaterThan(1.0))
        MOI.add_constraint(dominated, dominated_expression, MOI.LessThan(3.0))
        dominated_report = NLPDiagnostics.analyze_static(dominated)
        @test length(
            findings(dominated_report, :dominated_reused_expression_set),
        ) == 1

        inconsistent = new_model()
        y = MOI.add_variable(inconsistent)
        inconsistent_expression = F([T(1.0, y)], 0.0)
        MOI.add_constraint(inconsistent, inconsistent_expression, MOI.GreaterThan(2.0))
        MOI.add_constraint(inconsistent, inconsistent_expression, MOI.LessThan(1.0))
        inconsistent_report = NLPDiagnostics.analyze_static(inconsistent)
        @test length(
            findings(inconsistent_report, :inconsistent_reused_expression_sets),
        ) == 1
    end

    @testset "one-variable affine rows imply bounds without model mutation" begin
        model = new_model()
        x = MOI.add_variable(model)
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        MOI.add_constraint(model, x, MOI.GreaterThan(0.0))
        MOI.add_constraint(model, F([T(2.0, x)], 1.0), MOI.GreaterThan(5.0))
        report = NLPDiagnostics.analyze_static(model)
        implied = only(findings(report, :affine_implied_variable_bound))
        @test evidence_details(implied)["implied_lower"] == "2.0"

        inconsistent = new_model()
        y = MOI.add_variable(inconsistent)
        MOI.add_constraint(inconsistent, F([T(2.0, y)], 0.0), MOI.GreaterThan(4.0))
        MOI.add_constraint(inconsistent, F([T(-1.0, y)], 0.0), MOI.GreaterThan(-1.0))
        inconsistent_report = NLPDiagnostics.analyze_static(inconsistent)
        @test length(
            findings(
                inconsistent_report,
                :inconsistent_affine_implied_variable_bounds,
            ),
        ) == 1
    end

    @testset "multi-variable affine rows support one-pass interval propagation" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        MOI.add_constraint(model, x, MOI.Interval(0.0, 1.0))
        MOI.add_constraint(
            model,
            F([T(1.0, x), T(1.0, y)], 0.0),
            MOI.LessThan(3.0),
        )
        report = NLPDiagnostics.analyze_static(model)
        propagated = only(findings(report, :affine_interval_propagated_variable_bound))
        @test evidence_details(propagated)["derived_upper"] == "3.0"

        inconsistent = new_model()
        u, v = MOI.add_variables(inconsistent, 2)
        MOI.add_constraint(inconsistent, u, MOI.Interval(0.0, 1.0))
        MOI.add_constraint(inconsistent, v, MOI.GreaterThan(4.0))
        MOI.add_constraint(
            inconsistent,
            F([T(1.0, u), T(1.0, v)], 0.0),
            MOI.LessThan(3.0),
        )
        inconsistent_report = NLPDiagnostics.analyze_static(inconsistent)
        @test !isempty(findings(
            inconsistent_report,
            :inconsistent_affine_interval_propagation,
        ))

        chained = new_model()
        a, b, c = MOI.add_variables(chained, 3)
        MOI.add_constraint(chained, a, MOI.Interval(0.0, 1.0))
        MOI.add_constraint(
            chained,
            F([T(1.0, a), T(1.0, b)], 0.0),
            MOI.EqualTo(3.0),
        )
        MOI.add_constraint(
            chained,
            F([T(1.0, b), T(1.0, c)], 0.0),
            MOI.LessThan(4.0),
        )
        chained_report = NLPDiagnostics.analyze_static(
            chained;
            max_affine_propagation_passes = 3,
        )
        c_finding = only(filter(
            finding -> any(ref -> ref.kind == :variable && ref.index == c.value, finding.affected),
            findings(chained_report, :affine_interval_propagated_variable_bound),
        ))
        @test evidence_details(c_finding)["derived_upper"] == "2.0"
        @test evidence_details(c_finding)["pass_count"] == "3.0"
        @test chained_report.metadata[:affine_interval_propagation_converged] == "true"
        limited_report = NLPDiagnostics.analyze_static(
            chained;
            max_affine_propagation_passes = 1,
        )
        @test length(
            findings(limited_report, :affine_interval_propagation_limit_reached),
        ) == 1
        @test limited_report.metadata[:affine_interval_propagation_converged] == "false"

        fixed = new_model()
        s, t = MOI.add_variables(fixed, 2)
        MOI.add_constraint(fixed, t, MOI.EqualTo(2.0))
        MOI.add_constraint(
            fixed,
            F([T(1.0, s), T(1.0, t)], 0.0),
            MOI.EqualTo(3.0),
        )
        fixed_report = NLPDiagnostics.analyze_static(fixed)
        derived_fixed = only(findings(
            fixed_report,
            :affine_interval_propagated_variable_fixed,
        ))
        @test evidence_details(derived_fixed)["derived_value"] == "1.0"
        @test_throws ArgumentError NLPDiagnostics.analyze_static(
            chained;
            max_affine_propagation_passes = 0,
        )
    end

    @testset "objective participation connects a variable" begin
        model = new_model()
        x = MOI.add_variable(model)
        MOI.set(model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        MOI.set(model, MOI.ObjectiveFunction{MOI.VariableIndex}(), x)
        report = NLPDiagnostics.analyze(model)
        @test isempty(findings(report, :disconnected_variable))
    end

    @testset "vector nonlinear incidence" begin
        model = new_model()
        x = MOI.add_variable(model)
        row = MOI.ScalarNonlinearFunction(:sin, Any[x])
        f = MOI.VectorNonlinearFunction([row])
        MOI.add_constraint(model, f, MOI.Nonnegatives(1))
        report = NLPDiagnostics.analyze(model)
        @test isempty(findings(report, :disconnected_variable))
        @test isempty(findings(report, :variable_incidence_analysis_unavailable))
    end

    @testset "variable support ignores exact zero coefficients" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        f = F([T(0.0, x), T(1.0, y)], 0.0)
        support = NLPDiagnostics.variable_support(f)
        @test support.complete
        @test support.variables == [y]
        MOI.add_constraint(model, f, MOI.EqualTo(0.0))
        report = NLPDiagnostics.analyze(model)
        disconnected = findings(report, :disconnected_variable)
        @test length(disconnected) == 1
        @test only(disconnected).affected[1].index == x.value
    end

    @testset "constraint incidence components and objective coupling" begin
        model = new_model()
        x, y, z = MOI.add_variables(model, 3)
        MOI.set(model, MOI.VariableName(), x, "x")
        MOI.set(model, MOI.VariableName(), y, "y")
        MOI.set(model, MOI.VariableName(), z, "z")
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        MOI.add_constraint(
            model,
            F([T(1.0, x), T(1.0, y)], 0.0),
            MOI.EqualTo(0.0),
        )
        MOI.add_constraint(
            model,
            F([T(1.0, z)], 0.0),
            MOI.EqualTo(1.0),
        )
        MOI.set(model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        MOI.set(
            model,
            MOI.ObjectiveFunction{F}(),
            F([T(1.0, x), T(1.0, z)], 0.0),
        )

        graph = NLPDiagnostics.incidence_graph(model)
        @test graph.complete
        @test length(graph.variables) == 3
        @test length(graph.constraint_nodes) == 2
        components = NLPDiagnostics.connected_components(graph)
        nontrivial = filter(
            component ->
                !isempty(component.variable_positions) &&
                !isempty(component.constraint_positions),
            components,
        )
        @test sort(
            [
                (
                    length(component.variable_positions),
                    length(component.constraint_positions),
                ) for component in nontrivial
            ],
        ) == [(1, 1), (2, 1)]

        report = NLPDiagnostics.analyze(model)
        finding = only(findings(report, :multiple_constraint_components))
        details = evidence_details(finding)
        @test details["component_sizes"] == "2v/1c, 1v/1c"
        @test details["objective_couples_components"] == "true"
        @test report.metadata[:structural_component_count] == "2"
    end

    @testset "vector constraints create scalar row vertices" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        T = MOI.ScalarAffineTerm{Float64}
        VT = MOI.VectorAffineTerm{Float64}
        f = MOI.VectorAffineFunction(
            [VT(1, T(1.0, x)), VT(2, T(1.0, y))],
            [0.0, 0.0],
        )
        MOI.add_constraint(model, f, MOI.Zeros(2))

        graph = NLPDiagnostics.incidence_graph(model)
        @test length(graph.constraint_nodes) == 2
        @test graph.constraint_to_variables == [[1], [2]]
        report = NLPDiagnostics.analyze(model)
        finding = only(findings(report, :multiple_constraint_components))
        constraint_refs = filter(ref -> ref.kind == :constraint, finding.affected)
        @test sort([something(ref.subindex) for ref in constraint_refs]) == [1, 2]
    end

    @testset "coupled vector sets remain block vertices" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        f = MOI.VectorOfVariables([x, y])
        MOI.add_constraint(model, f, MOI.SecondOrderCone(2))

        graph = NLPDiagnostics.incidence_graph(model)
        @test graph.complete
        @test length(graph.constraint_nodes) == 1
        @test graph.constraint_to_variables == [[1, 2]]
        @test isnothing(only(graph.constraint_nodes).row)
        report = NLPDiagnostics.analyze(model)
        @test isempty(findings(report, :multiple_constraint_components))
    end

    @testset "explicit structural roles" begin
        model = new_model()
        free = MOI.add_variable(model)
        fixed = MOI.add_variable(model)
        MOI.add_constraint(model, fixed, MOI.EqualTo(2.0))
        parameter, _ = MOI.add_constrained_variable(
            model,
            MOI.Parameter(3.0),
        )
        infeasible = MOI.add_variable(model)
        MOI.add_constraint(model, infeasible, MOI.GreaterThan(2.0))
        MOI.add_constraint(model, infeasible, MOI.LessThan(1.0))
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        MOI.add_constraint(
            model,
            F([T(1.0, free), T(1.0, fixed)], 0.0),
            MOI.EqualTo(0.0),
        )
        MOI.add_constraint(
            model,
            F([T(1.0, free)], 0.0),
            MOI.LessThan(1.0),
        )
        MOI.add_constraint(
            model,
            MOI.VectorOfVariables([free, parameter]),
            MOI.SecondOrderCone(2),
        )

        graph = NLPDiagnostics.incidence_graph(model)
        @test graph.variable_roles == [
            NLPDiagnostics.FreeVariable,
            NLPDiagnostics.FixedVariable,
            NLPDiagnostics.ParameterVariable,
            NLPDiagnostics.InfeasibleVariableDomain,
        ]
        roles = [node.role for node in graph.constraint_nodes]
        @test count(==(NLPDiagnostics.EqualityConstraint), roles) == 1
        @test count(==(NLPDiagnostics.InequalityConstraint), roles) == 1
        @test count(==(NLPDiagnostics.CoupledConstraint), roles) == 1
    end

    @testset "semicontinuous equal endpoints are not fixed" begin
        model = new_model()
        x = MOI.add_variable(model)
        MOI.add_constraint(model, x, MOI.Semicontinuous(2.0, 2.0))
        graph = NLPDiagnostics.incidence_graph(model)
        @test only(graph.variable_roles) == NLPDiagnostics.FreeVariable
        report = NLPDiagnostics.analyze(model)
        @test isempty(findings(report, :fixed_variable))
    end

    @testset "underdetermined equality matching and DM partition" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        MOI.set(model, MOI.VariableName(), x, "x")
        MOI.set(model, MOI.VariableName(), y, "y")
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        MOI.add_constraint(
            model,
            F([T(1.0, x), T(1.0, y)], 0.0),
            MOI.EqualTo(0.0),
        )

        graph = NLPDiagnostics.incidence_graph(model)
        matching = NLPDiagnostics.maximum_matching(graph)
        @test matching.complete
        @test NLPDiagnostics.matching_cardinality(matching) == 1
        @test matching.variable_match == [1, 0]
        @test matching.constraint_match == [1]
        partition = NLPDiagnostics.dulmage_mendelsohn(
            graph;
            matching = matching,
        )
        @test partition.complete
        @test partition.underdetermined_variables == [1, 2]
        @test partition.underdetermined_constraints == [1]
        @test isempty(partition.well_determined_variables)
        @test isempty(partition.overdetermined_constraints)

        report = NLPDiagnostics.analyze(model)
        @test length(findings(report, :unmatched_structural_variables)) == 1
        @test length(findings(report, :underdetermined_equality_partition)) == 1
        @test report.metadata[:structural_matching_cardinality] == "1"
    end

    @testset "matching uses augmenting paths" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        MOI.add_constraint(
            model,
            F([T(1.0, x), T(1.0, y)], 0.0),
            MOI.EqualTo(0.0),
        )
        MOI.add_constraint(
            model,
            F([T(1.0, x)], 0.0),
            MOI.EqualTo(1.0),
        )
        matching = NLPDiagnostics.maximum_matching(model)
        @test NLPDiagnostics.matching_cardinality(matching) == 2
        @test matching.variable_match == [2, 1]
        @test matching.constraint_match == [2, 1]
    end

    @testset "well-determined irreducible blocks" begin
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}

        diagonal = new_model()
        x, y = MOI.add_variables(diagonal, 2)
        MOI.set(diagonal, MOI.VariableName(), x, "x")
        MOI.set(diagonal, MOI.VariableName(), y, "y")
        MOI.add_constraint(
            diagonal,
            F([T(1.0, x)], 0.0),
            MOI.EqualTo(0.0),
        )
        MOI.add_constraint(
            diagonal,
            F([T(1.0, y)], 0.0),
            MOI.EqualTo(0.0),
        )
        diagonal_graph = NLPDiagnostics.incidence_graph(diagonal)
        diagonal_blocks = NLPDiagnostics.well_determined_blocks(
            diagonal_graph,
        )
        @test length(diagonal_blocks) == 2
        @test [block.variable_positions for block in diagonal_blocks] ==
              [[1], [2]]
        @test [block.constraint_positions for block in diagonal_blocks] ==
              [[1], [2]]
        diagonal_report = NLPDiagnostics.analyze(diagonal)
        @test length(
            findings(
                diagonal_report,
                :multiple_well_determined_blocks,
            ),
        ) == 1

        triangular = new_model()
        x, y = MOI.add_variables(triangular, 2)
        MOI.add_constraint(
            triangular,
            F([T(1.0, x)], 0.0),
            MOI.EqualTo(0.0),
        )
        MOI.add_constraint(
            triangular,
            F([T(1.0, x), T(1.0, y)], 0.0),
            MOI.EqualTo(0.0),
        )
        triangular_blocks = NLPDiagnostics.well_determined_blocks(
            triangular,
        )
        @test [block.constraint_positions for block in triangular_blocks] ==
              [[1], [2]]

        irreducible = new_model()
        x, y = MOI.add_variables(irreducible, 2)
        MOI.add_constraint(
            irreducible,
            F([T(1.0, x), T(1.0, y)], 0.0),
            MOI.EqualTo(0.0),
        )
        MOI.add_constraint(
            irreducible,
            F([T(2.0, x), T(3.0, y)], 0.0),
            MOI.EqualTo(0.0),
        )
        irreducible_blocks = NLPDiagnostics.well_determined_blocks(
            irreducible,
        )
        @test length(irreducible_blocks) == 1
        @test only(irreducible_blocks).variable_positions == [1, 2]
        @test only(irreducible_blocks).constraint_positions == [1, 2]
    end

    @testset "stable structural graph export" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        MOI.set(model, MOI.VariableName(), x, "source")
        MOI.set(model, MOI.VariableName(), y, "state")
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        first_constraint = MOI.add_constraint(
            model,
            F([T(1.0, x)], 0.0),
            MOI.EqualTo(0.0),
        )
        MOI.set(
            model,
            MOI.ConstraintName(),
            first_constraint,
            "reference",
        )
        MOI.add_constraint(
            model,
            F([T(1.0, x), T(1.0, y)], 0.0),
            MOI.EqualTo(0.0),
        )

        data = NLPDiagnostics.structural_graph_data(model)
        @test data.complete
        @test length(data.variables) == 2
        @test length(data.constraints) == 2
        @test length(data.edges) == 3
        @test [node.dm_region for node in data.variables] == [:well, :well]
        @test [node.block for node in data.variables] == [1, 2]
        @test count(edge -> edge.matched, data.edges) == 2

        text = NLPDiagnostics.structural_graph_text(data)
        @test occursin("Structural graph with 2 variables", text)
        @test occursin("source", text)
        @test occursin("reference", text)
        @test occursin("[matched]", text)

        dot = NLPDiagnostics.structural_graph_dot(data)
        @test startswith(dot, "graph NLPDiagnostics {")
        @test occursin("v1 -- c1", dot)
        @test occursin("penwidth=2.5", dot)
        @test occursin("DM=well", dot)
    end

    @testset "proven, possible, and safe logarithm domains" begin
        proven_model = new_model()
        x = MOI.add_variable(proven_model)
        MOI.set(proven_model, MOI.VariableName(), x, "x")
        MOI.add_constraint(proven_model, x, MOI.LessThan(-1.0))
        log_x = MOI.ScalarNonlinearFunction(:log, Any[x])
        MOI.add_constraint(proven_model, log_x, MOI.LessThan(0.0))
        proven_report = NLPDiagnostics.analyze(proven_model)
        proven = only(
            findings(
                proven_report,
                :proven_expression_domain_violation,
            ),
        )
        @test proven.severity == NLPDiagnostics.SeverityError
        @test evidence_details(proven)["argument_interval"] ==
              "[-Inf, -1.0]"
        @test occursin(
            "v$(x.value)=declared_variable_bounds:MathOptInterface.VariableIndex/MathOptInterface.LessThan{Float64}#1",
            evidence_details(proven)["support_interval_origins"],
        )
        @test proven_report.metadata[:proven_domain_violation_count] == "1"

        possible_model = new_model()
        x = MOI.add_variable(possible_model)
        MOI.add_constraint(possible_model, x, MOI.Interval(-1.0, 2.0))
        log_x = MOI.ScalarNonlinearFunction(:log, Any[x])
        MOI.add_constraint(possible_model, log_x, MOI.LessThan(0.0))
        possible = only(
            findings(
                NLPDiagnostics.analyze(possible_model),
                :possible_expression_domain_violation,
            ),
        )
        @test possible.basis == NLPDiagnostics.HeuristicInterpretation
        @test possible.confidence == NLPDiagnostics.ConfidenceHigh
        @test evidence_details(possible)["required_domain"] ==
              "argument > 0"

        safe_model = new_model()
        x = MOI.add_variable(safe_model)
        MOI.add_constraint(safe_model, x, MOI.GreaterThan(1.0))
        log_x = MOI.ScalarNonlinearFunction(:log, Any[x])
        MOI.add_constraint(safe_model, log_x, MOI.LessThan(1.0))
        @test isempty(NLPDiagnostics.domain_issues(safe_model))
    end

    @testset "atan ratio formulation fingerprint" begin
        ratio_model = new_model()
        denominator, numerator = MOI.add_variables(ratio_model, 2)
        ratio = MOI.ScalarNonlinearFunction(:/, Any[numerator, denominator])
        MOI.add_constraint(
            ratio_model,
            MOI.ScalarNonlinearFunction(:atan, Any[ratio]),
            MOI.LessThan(2.0),
        )
        ratio_finding = only(findings(
            NLPDiagnostics.analyze_static(ratio_model),
            :atan_ratio_may_need_atan2,
        ))
        @test ratio_finding.domain == NLPDiagnostics.RepresentationalIssue
        @test ratio_finding.basis == NLPDiagnostics.HeuristicInterpretation
        @test ratio_finding.confidence == NLPDiagnostics.ConfidenceMedium
        @test Dict(ratio_finding.evidence[1].details)[
            "quadrant_aware_julia_convention"
        ] == "atan(y, x)"
        zero_risk = only(findings(
            NLPDiagnostics.analyze_static(ratio_model),
            :atan_ratio_denominator_may_be_zero,
        ))
        @test zero_risk.domain == NLPDiagnostics.NumericalIssue
        @test Dict(zero_risk.evidence[1].details)["zero_contained"] == "true"

        protected_ratio_model = new_model()
        protected_denominator, protected_numerator = MOI.add_variables(protected_ratio_model, 2)
        MOI.add_constraint(protected_ratio_model, protected_denominator, MOI.GreaterThan(0.1))
        protected_ratio = MOI.ScalarNonlinearFunction(
            :/, Any[protected_numerator, protected_denominator],
        )
        MOI.add_constraint(
            protected_ratio_model,
            MOI.ScalarNonlinearFunction(:atan, Any[protected_ratio]),
            MOI.LessThan(2.0),
        )
        @test isempty(findings(
            NLPDiagnostics.analyze_static(protected_ratio_model),
            :atan_ratio_denominator_may_be_zero,
        ))

        two_argument_model = new_model()
        x, y = MOI.add_variables(two_argument_model, 2)
        MOI.add_constraint(
            two_argument_model,
            MOI.ScalarNonlinearFunction(:atan, Any[y, x]),
            MOI.LessThan(2.0),
        )
        @test isempty(findings(
            NLPDiagnostics.analyze_static(two_argument_model),
            :atan_ratio_may_need_atan2,
        ))
        @test length(findings(
            NLPDiagnostics.analyze_static(two_argument_model),
            :atan2_branch_cut_may_be_crossed,
        )) == 1

        branch_cut_model = new_model()
        branch_cut_y, branch_cut_x = MOI.add_variables(branch_cut_model, 2)
        MOI.add_constraint(branch_cut_model, branch_cut_y, MOI.EqualTo(0.0))
        MOI.add_constraint(branch_cut_model, branch_cut_x, MOI.LessThan(-0.1))
        MOI.add_constraint(
            branch_cut_model,
            MOI.ScalarNonlinearFunction(:atan, Any[branch_cut_y, branch_cut_x]),
            MOI.LessThan(Float64(pi)),
        )
        branch_cut = only(findings(
            NLPDiagnostics.analyze_static(branch_cut_model),
            :atan2_on_branch_cut,
        ))
        @test branch_cut.confidence == NLPDiagnostics.ConfidenceHigh

        branch_safe_model = new_model()
        branch_safe_y, branch_safe_x = MOI.add_variables(branch_safe_model, 2)
        MOI.add_constraint(branch_safe_model, branch_safe_x, MOI.GreaterThan(0.1))
        MOI.add_constraint(
            branch_safe_model,
            MOI.ScalarNonlinearFunction(:atan, Any[branch_safe_y, branch_safe_x]),
            MOI.LessThan(Float64(pi)),
        )
        @test isempty(findings(
            NLPDiagnostics.analyze_static(branch_safe_model),
            :atan2_branch_cut_may_be_crossed,
        ))

        atan2_range_model = new_model()
        atan2_y, atan2_x = MOI.add_variables(atan2_range_model, 2)
        MOI.add_constraint(
            atan2_range_model,
            MOI.ScalarNonlinearFunction(:atan, Any[atan2_y, atan2_x]),
            MOI.EqualTo(-Float64(pi)),
        )
        atan2_range = only(findings(
            NLPDiagnostics.analyze_static(atan2_range_model),
            :infeasible_atan2_principal_range_constraint,
        ))
        @test atan2_range.basis == NLPDiagnostics.MathematicalProof

        atan2_upper_endpoint = new_model()
        atan2_upper_y, atan2_upper_x = MOI.add_variables(atan2_upper_endpoint, 2)
        MOI.add_constraint(
            atan2_upper_endpoint,
            MOI.ScalarNonlinearFunction(:atan, Any[atan2_upper_y, atan2_upper_x]),
            MOI.EqualTo(Float64(pi)),
        )
        @test isempty(findings(
            NLPDiagnostics.analyze_static(atan2_upper_endpoint),
            :infeasible_atan2_principal_range_constraint,
        ))

        atan2_axis_model = new_model()
        atan2_axis_y, atan2_axis_x = MOI.add_variables(atan2_axis_model, 2)
        MOI.add_constraint(
            atan2_axis_model,
            MOI.ScalarNonlinearFunction(:atan, Any[atan2_axis_y, atan2_axis_x]),
            MOI.EqualTo(Float64(pi / 2)),
        )
        axis_finding = only(findings(
            NLPDiagnostics.analyze_static(atan2_axis_model),
            :atan2_axis_angle_implies_fixed_variable,
        ))
        @test axis_finding.basis == NLPDiagnostics.MathematicalProof
        axis_details = Dict(axis_finding.evidence[1].details)
        @test axis_details["fixed_argument_position"] == "2"
        @test axis_details["implied_value"] == "0.0"

        atan2_axis_bound_conflict = new_model()
        atan2_conflict_y, atan2_conflict_x = MOI.add_variables(atan2_axis_bound_conflict, 2)
        MOI.add_constraint(atan2_axis_bound_conflict, atan2_conflict_x, MOI.GreaterThan(0.1))
        MOI.add_constraint(
            atan2_axis_bound_conflict,
            MOI.ScalarNonlinearFunction(:atan, Any[atan2_conflict_y, atan2_conflict_x]),
            MOI.EqualTo(Float64(pi / 2)),
        )
        @test length(findings(
            NLPDiagnostics.analyze_static(atan2_axis_bound_conflict),
            :inconsistent_atan2_axis_angle_variable_bound,
        )) == 1

        atan2_axis_sign_conflict = new_model()
        atan2_sign_y, atan2_sign_x = MOI.add_variables(atan2_axis_sign_conflict, 2)
        MOI.add_constraint(atan2_axis_sign_conflict, atan2_sign_y, MOI.LessThan(0.0))
        MOI.add_constraint(
            atan2_axis_sign_conflict,
            MOI.ScalarNonlinearFunction(:atan, Any[atan2_sign_y, atan2_sign_x]),
            MOI.EqualTo(Float64(pi / 2)),
        )
        @test length(findings(
            NLPDiagnostics.analyze_static(atan2_axis_sign_conflict),
            :inconsistent_atan2_axis_angle_sign_bound,
        )) == 1

        # Preserve Julia's `atan(y, x)` semantics when a two-coordinate
        # expression becomes fixed, and do not apply the unary range rule to
        # its rectangular input domain.
        @test NLPDiagnostics.fixed_operator_value(
            Val(:atan),
            Any[0.0, -1.0],
        ) == Float64(pi)
        atan2_interval = NLPDiagnostics.operator_interval(
            Val(:atan),
            [
                NLPDiagnostics.IntervalEnclosure(-1.0, 1.0),
                NLPDiagnostics.IntervalEnclosure(-1.0, 1.0),
            ],
            Any[],
        )
        @test atan2_interval.lower == -Float64(pi)
        @test atan2_interval.upper == Float64(pi)
        @test !atan2_interval.informative
    end

    @testset "square root and quadratic interval propagation" begin
        possible_model = new_model()
        x = MOI.add_variable(possible_model)
        MOI.add_constraint(possible_model, x, MOI.Interval(-1.0, 4.0))
        sqrt_x = MOI.ScalarNonlinearFunction(:sqrt, Any[x])
        MOI.add_constraint(possible_model, sqrt_x, MOI.LessThan(3.0))
        issue = only(NLPDiagnostics.domain_issues(possible_model))
        @test issue.assessment == NLPDiagnostics.DomainPossibleViolation
        @test issue.requirement == "argument ≥ 0"

        proven_model = new_model()
        x = MOI.add_variable(proven_model)
        MOI.add_constraint(proven_model, x, MOI.LessThan(-1.0))
        sqrt_x = MOI.ScalarNonlinearFunction(:sqrt, Any[x])
        MOI.add_constraint(proven_model, sqrt_x, MOI.LessThan(0.0))
        @test only(NLPDiagnostics.domain_issues(proven_model)).assessment ==
              NLPDiagnostics.DomainProvenViolation

        quadratic_model = new_model()
        x = MOI.add_variable(quadratic_model)
        MOI.add_constraint(quadratic_model, x, MOI.Interval(-1.0, 1.0))
        Q = MOI.ScalarQuadraticTerm{Float64}
        quadratic = MOI.ScalarQuadraticFunction(
            [Q(2.0, x, x)],
            MOI.ScalarAffineTerm{Float64}[],
            0.0,
        )
        sqrt_x_squared = MOI.ScalarNonlinearFunction(
            :sqrt,
            Any[quadratic],
        )
        MOI.add_constraint(
            quadratic_model,
            sqrt_x_squared,
            MOI.LessThan(2.0),
        )
        @test isempty(NLPDiagnostics.domain_issues(quadratic_model))
    end

    @testset "division and inverse domains" begin
        proven_model = new_model()
        x, denominator = MOI.add_variables(proven_model, 2)
        MOI.add_constraint(
            proven_model,
            denominator,
            MOI.EqualTo(0.0),
        )
        quotient = MOI.ScalarNonlinearFunction(
            :/,
            Any[x, denominator],
        )
        MOI.add_constraint(proven_model, quotient, MOI.LessThan(1.0))
        issue = only(NLPDiagnostics.domain_issues(proven_model))
        @test issue.assessment == NLPDiagnostics.DomainProvenViolation
        @test issue.argument == 2
        @test issue.requirement == "denominator ≠ 0"

        possible_model = new_model()
        denominator = MOI.add_variable(possible_model)
        MOI.add_constraint(
            possible_model,
            denominator,
            MOI.Interval(-1.0, 1.0),
        )
        inverse = MOI.ScalarNonlinearFunction(:inv, Any[denominator])
        MOI.add_constraint(possible_model, inverse, MOI.LessThan(1.0))
        issue = only(NLPDiagnostics.domain_issues(possible_model))
        @test issue.assessment == NLPDiagnostics.DomainPossibleViolation
    end

    @testset "integer and fractional power domains" begin
        fractional_model = new_model()
        x = MOI.add_variable(fractional_model)
        MOI.add_constraint(fractional_model, x, MOI.LessThan(-1.0))
        root = MOI.ScalarNonlinearFunction(:^, Any[x, 0.5])
        MOI.add_constraint(fractional_model, root, MOI.LessThan(1.0))
        fractional_issue = only(
            NLPDiagnostics.domain_issues(fractional_model),
        )
        @test fractional_issue.assessment ==
              NLPDiagnostics.DomainProvenViolation
        @test fractional_issue.requirement ==
              "base ≥ 0 for a non-integer exponent"

        negative_model = new_model()
        x = MOI.add_variable(negative_model)
        MOI.add_constraint(negative_model, x, MOI.EqualTo(0.0))
        reciprocal = MOI.ScalarNonlinearFunction(:^, Any[x, -1])
        MOI.add_constraint(negative_model, reciprocal, MOI.LessThan(1.0))
        negative_issue = only(
            NLPDiagnostics.domain_issues(negative_model),
        )
        @test negative_issue.assessment ==
              NLPDiagnostics.DomainProvenViolation
        @test occursin("negative integer", negative_issue.requirement)

        integer_model = new_model()
        x = MOI.add_variable(integer_model)
        MOI.add_constraint(integer_model, x, MOI.Interval(-2.0, 2.0))
        square = MOI.ScalarNonlinearFunction(:^, Any[x, 2])
        MOI.add_constraint(integer_model, square, MOI.LessThan(4.0))
        @test isempty(NLPDiagnostics.domain_issues(integer_model))
    end

    @testset "reciprocal-hyperbolic value and derivative domains" begin
        value_model = new_model()
        x = MOI.add_variable(value_model)
        MOI.add_constraint(value_model, x, MOI.EqualTo(0.0))
        MOI.add_constraint(
            value_model,
            MOI.ScalarNonlinearFunction(:csch, Any[x]),
            MOI.LessThan(1.0),
        )
        value_issue = only(NLPDiagnostics.domain_issues(value_model))
        @test value_issue.assessment == NLPDiagnostics.DomainProvenViolation
        @test value_issue.requirement == "argument ≠ 0"

        derivative_model = new_model()
        y = MOI.add_variable(derivative_model)
        MOI.add_constraint(derivative_model, y, MOI.Interval(0.0, 1.0))
        MOI.add_constraint(
            derivative_model,
            MOI.ScalarNonlinearFunction(:coth, Any[y]),
            MOI.LessThan(10.0),
        )
        derivative_issues = NLPDiagnostics.derivative_issues(derivative_model)
        @test count(
            issue -> issue.operator == :coth &&
                     issue.assessment == NLPDiagnostics.DomainPossibleViolation,
            derivative_issues,
        ) == 2
    end

    @testset "expression paths and vector-row provenance" begin
        nested_model = new_model()
        x, y = MOI.add_variables(nested_model, 2)
        MOI.add_constraint(nested_model, y, MOI.LessThan(-1.0))
        log_y = MOI.ScalarNonlinearFunction(:log, Any[y])
        expression = MOI.ScalarNonlinearFunction(:+, Any[x, log_y])
        MOI.add_constraint(nested_model, expression, MOI.LessThan(0.0))
        nested_issue = only(NLPDiagnostics.domain_issues(nested_model))
        @test nested_issue.path.arguments == [2]
        @test occursin("/arg[2]", sprint(show, nested_issue.path))

        vector_model = new_model()
        x, y = MOI.add_variables(vector_model, 2)
        MOI.add_constraint(vector_model, x, MOI.LessThan(-1.0))
        MOI.add_constraint(vector_model, y, MOI.Interval(-1.0, 1.0))
        rows = MOI.VectorNonlinearFunction(
            [
                MOI.ScalarNonlinearFunction(:log, Any[x]),
                MOI.ScalarNonlinearFunction(:sqrt, Any[y]),
            ],
        )
        MOI.add_constraint(vector_model, rows, MOI.Nonpositives(2))
        issues = NLPDiagnostics.domain_issues(vector_model)
        @test length(issues) == 2
        @test [issue.path.source.subindex for issue in issues] == [1, 2]
        @test [issue.assessment for issue in issues] == [
            NLPDiagnostics.DomainProvenViolation,
            NLPDiagnostics.DomainPossibleViolation,
        ]
    end

    @testset "constant objective and constraint domain handling" begin
        objective_model = new_model()
        bad_objective = MOI.ScalarNonlinearFunction(:log, Any[-1.0])
        MOI.set(objective_model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        MOI.set(
            objective_model,
            MOI.ObjectiveFunction{MOI.ScalarNonlinearFunction}(),
            bad_objective,
        )
        issue = only(NLPDiagnostics.domain_issues(objective_model))
        @test issue.path.source.kind == :objective
        @test issue.assessment == NLPDiagnostics.DomainProvenViolation

        constraint_model = new_model()
        bad_constraint = MOI.ScalarNonlinearFunction(:log, Any[-1.0])
        MOI.add_constraint(
            constraint_model,
            bad_constraint,
            MOI.LessThan(0.0),
        )
        report = NLPDiagnostics.analyze(constraint_model)
        @test length(findings(report, :constant_domain_violation)) == 1
        @test isempty(
            findings(report, :proven_expression_domain_violation),
        )
    end

    @testset "custom operator domain extension hooks" begin
        range_model = new_model()
        x = MOI.add_variable(range_model)
        positive = MOI.ScalarNonlinearFunction(
            :positive_output,
            Any[x],
        )
        log_positive = MOI.ScalarNonlinearFunction(:log, Any[positive])
        MOI.add_constraint(range_model, log_positive, MOI.LessThan(2.0))
        @test isempty(NLPDiagnostics.domain_issues(range_model))

        domain_model = new_model()
        x = MOI.add_variable(domain_model)
        MOI.add_constraint(domain_model, x, MOI.LessThan(-1.0))
        positive_only = MOI.ScalarNonlinearFunction(
            :positive_only,
            Any[x],
        )
        MOI.add_constraint(domain_model, positive_only, MOI.LessThan(2.0))
        issue = only(NLPDiagnostics.domain_issues(domain_model))
        @test issue.assessment == NLPDiagnostics.DomainProvenViolation
        @test issue.requirement == "argument > 0 for positive_only"

        opaque_model = new_model()
        x = MOI.add_variable(opaque_model)
        opaque = MOI.ScalarNonlinearFunction(:opaque_range, Any[x])
        log_opaque = MOI.ScalarNonlinearFunction(:log, Any[opaque])
        MOI.add_constraint(opaque_model, log_opaque, MOI.LessThan(2.0))
        finding = only(
            findings(
                NLPDiagnostics.analyze(opaque_model),
                :possible_expression_domain_violation,
            ),
        )
        @test finding.confidence == NLPDiagnostics.ConfidenceMedium
        @test evidence_details(finding)["interval_informative"] == "false"
    end

    @testset "domain intervals preserve non-Float64 bounds" begin
        model = MOIU.UniversalFallback(MOIU.Model{BigFloat}())
        x = MOI.add_variable(model)
        lower = big"1e-1000"
        MOI.add_constraint(model, x, MOI.GreaterThan(lower))
        log_x = MOI.ScalarNonlinearFunction(:log, Any[x])
        MOI.add_constraint(model, log_x, MOI.LessThan(big"1.0"))
        @test isempty(NLPDiagnostics.domain_issues(model))
    end

    @testset "overdetermined equality matching and DM partition" begin
        model = new_model()
        x = MOI.add_variable(model)
        MOI.set(model, MOI.VariableName(), x, "x")
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        f = F([T(1.0, x)], 0.0)
        MOI.add_constraint(model, f, MOI.EqualTo(0.0))
        MOI.add_constraint(model, f, MOI.EqualTo(1.0))

        graph = NLPDiagnostics.incidence_graph(model)
        matching = NLPDiagnostics.maximum_matching(graph)
        @test NLPDiagnostics.matching_cardinality(matching) == 1
        @test matching.variable_match == [1]
        @test matching.constraint_match == [1, 0]
        partition = NLPDiagnostics.dulmage_mendelsohn(
            graph;
            matching = matching,
        )
        @test partition.overdetermined_variables == [1]
        @test partition.overdetermined_constraints == [1, 2]
        @test isempty(partition.well_determined_constraints)
        @test isempty(partition.underdetermined_variables)

        report = NLPDiagnostics.analyze(model)
        @test length(findings(report, :unmatched_structural_equations)) == 1
        @test length(findings(report, :overdetermined_equality_partition)) == 1
    end

    @testset "fixed variables are excluded from matching" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        MOI.add_constraint(model, x, MOI.EqualTo(2.0))
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        MOI.add_constraint(
            model,
            F([T(1.0, x), T(1.0, y)], 0.0),
            MOI.EqualTo(0.0),
        )

        graph = NLPDiagnostics.incidence_graph(model)
        matching = NLPDiagnostics.maximum_matching(graph)
        @test matching.eligible_variable_positions == [2]
        @test NLPDiagnostics.matching_cardinality(matching) == 1
        @test matching.variable_match == [0, 1]
        partition = NLPDiagnostics.dulmage_mendelsohn(graph)
        @test partition.well_determined_variables == [2]
        @test partition.well_determined_constraints == [1]
        report = NLPDiagnostics.analyze(model)
        @test isempty(findings(report, :unmatched_structural_variables))
        @test isempty(findings(report, :unmatched_structural_equations))
    end

    @testset "inequalities are excluded from default matching" begin
        model = new_model()
        x = MOI.add_variable(model)
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        MOI.add_constraint(
            model,
            F([T(1.0, x)], 0.0),
            MOI.LessThan(1.0),
        )
        graph = NLPDiagnostics.incidence_graph(model)
        @test only(graph.constraint_nodes).role ==
              NLPDiagnostics.InequalityConstraint
        matching = NLPDiagnostics.maximum_matching(graph)
        @test isempty(matching.eligible_constraint_positions)
        @test matching.eligible_variable_positions == [1]
        report = NLPDiagnostics.analyze(model)
        finding = only(findings(report, :unmatched_structural_variables))
        @test evidence_details(finding)["scope"] ==
              "free variables and equality nodes only"
    end

    @testset "JuMP extension" begin
        model = JuMP.Model()
        JuMP.@variable(model, x >= 0)
        JuMP.@constraint(model, sin(x) <= 1)
        JuMP.set_start_value(x, 0.5)
        report = NLPDiagnostics.analyze(model)
        @test report isa NLPDiagnostics.DiagnosticReport
        @test isempty(findings(report, :disconnected_variable))
        @test NLPDiagnostics.incidence_graph(model) isa
              NLPDiagnostics.IncidenceGraph
        @test NLPDiagnostics.maximum_matching(model) isa
              NLPDiagnostics.StructuralMatching
        @test NLPDiagnostics.dulmage_mendelsohn(model) isa
              NLPDiagnostics.DulmageMendelsohnPartition
        @test NLPDiagnostics.well_determined_blocks(model) isa
              Vector{NLPDiagnostics.DulmageMendelsohnBlock}
        @test NLPDiagnostics.structural_graph_data(model) isa
              NLPDiagnostics.StructuralGraphData
        @test occursin(
            "Structural graph",
            NLPDiagnostics.structural_graph_text(model),
        )
        @test startswith(
            NLPDiagnostics.structural_graph_dot(model),
            "graph NLPDiagnostics {",
        )
        point = NLPDiagnostics.evaluation_point(
            model,
            [0.5];
            label = "JuMP point",
        )
        numerical = NLPDiagnostics.evaluate_numerical(model, point)
        @test numerical.point == point
        @test !isempty(numerical.constraint_values)
        @test NLPDiagnostics.initialization_point(model) !== nothing
        @test NLPDiagnostics.analyze_initialization(model) isa
              NLPDiagnostics.DiagnosticReport
    end

    @testset "evaluation points preserve variable order" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        point = NLPDiagnostics.evaluation_point(
            model,
            Dict(y => 3.0, x => 2.0);
            label = "initial",
        )
        @test point.variables == [x, y]
        @test point.values == [2.0, 3.0]
        @test point.label == "initial"
        @test_throws DimensionMismatch NLPDiagnostics.EvaluationPoint(
            [x],
            [1.0, 2.0],
        )
        @test_throws ArgumentError NLPDiagnostics.evaluation_point(
            model,
            Dict(x => 2.0),
        )
    end

    @testset "symbolic values finite differences cache and scaling" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        objective = MOI.ScalarNonlinearFunction(
            :+,
            Any[
                MOI.ScalarNonlinearFunction(:^, Any[x, 2]),
                y,
            ],
        )
        MOI.set(model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        MOI.set(
            model,
            MOI.ObjectiveFunction{MOI.ScalarNonlinearFunction}(),
            objective,
        )
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        MOI.add_constraint(
            model,
            F([T(1.0e-6, x)], 0.0),
            MOI.EqualTo(0.0),
        )
        MOI.add_constraint(
            model,
            F([T(1.0e6, y)], 0.0),
            MOI.EqualTo(0.0),
        )
        point = NLPDiagnostics.evaluation_point(
            model,
            [2.0, 3.0];
            label = "scaling probe",
        )
        cache = NLPDiagnostics.EvaluationCache()
        evaluation =
            NLPDiagnostics.evaluate_numerical(model, point; cache = cache)
        @test evaluation.objective_value ≈ 7.0
        @test evaluation.objective_gradient ≈ [4.0, 1.0] rtol = 1.0e-5
        @test evaluation.constraint_values ≈ [2.0e-6, 3.0e6]
        @test evaluation.jacobian_row_methods == fill(:exact_symbolic, 2)
        @test evaluation.objective_gradient_method == :exact_constructed_nonlinear_ad
        summary = NLPDiagnostics.jacobian_scale_summary(evaluation)
        @test summary.row_norms ≈ [1.0e-6, 1.0e6] rtol = 1.0e-5
        @test summary.column_norms ≈ [1.0e-6, 1.0e6] rtol = 1.0e-5
        @test summary.row_scale_ratio ≈ 1.0e12 rtol = 1.0e-4
        @test summary.column_scale_ratio ≈ 1.0e12 rtol = 1.0e-4
        @test cache.misses == 1
        @test cache.hits == 0
        NLPDiagnostics.evaluate_numerical(model, point; cache = cache)
        @test cache.hits == 1
        @test cache.misses == 1
        generation = cache.generation
        empty!(cache)
        @test cache.generation == generation + 1
        @test isempty(cache.entries)

        report = NLPDiagnostics.analyze_numerical(
            model,
            point;
            cache = cache,
        )
        @test length(findings(report, :large_jacobian_row_scale_spread)) ==
              1
        @test length(findings(report, :large_jacobian_column_scale_spread)) ==
              1
        @test report.metadata[:evaluation_point_label] == "scaling probe"
        @test report.metadata[:jacobian_derivative_method_count] == "1"
        @test report.metadata[:jacobian_derivative_row_method_counts] ==
              "exact_symbolic=2"
        @test report.metadata[:objective_gradient_method] ==
              "exact_constructed_nonlinear_ad"
        scale_report = NLPDiagnostics.analyze_objective_jacobian_scaling(
            evaluation;
            mismatch_factor = 1.0e3,
        )
        @test length(findings(scale_report, :objective_jacobian_scale_summary)) == 1
        @test scale_report.metadata[:objective_jacobian_scale_mismatch] == "false"
        combined = NLPDiagnostics.analyze(model; point = point, cache = cache)
        @test combined.metadata[:stages] ==
              "static,domains,derivatives,expressions,structural,numerical"
        checked = NLPDiagnostics.analyze(
            model;
            point = point,
            cache = cache,
            check_policy = NLPDiagnostics.CheckPolicy(objective_jacobian_scaling = true),
        )
        @test occursin(",objective_jacobian_scaling", checked.metadata[:stages])
        @test length(findings(checked, :objective_jacobian_scale_summary)) == 1
        convexity_checked = NLPDiagnostics.analyze(
            model;
            point = point,
            cache = cache,
            check_policy = NLPDiagnostics.CheckPolicy(convexity = true),
        )
        @test occursin(",convexity", convexity_checked.metadata[:stages])
        @test haskey(convexity_checked.metadata, :convexity_classification)
        @test convexity_checked.metadata[:convexity_hessian_source] == "objective"
        @test occursin(
            "constraint_multipliers=zeros",
            convexity_checked.metadata[:convexity_hessian_multiplier_policy],
        )
        dof_checked = NLPDiagnostics.analyze(
            model;
            point = point,
            cache = cache,
            check_policy = NLPDiagnostics.CheckPolicy(degrees_of_freedom = true),
        )
        @test occursin(",degrees_of_freedom", dof_checked.metadata[:stages])
        @test dof_checked.metadata[:degrees_of_freedom_status] ==
              "locally_constrained"
        @test dof_checked.metadata[:degrees_of_freedom_numerical_right_nullity] ==
              "0"
        @test length(findings(dof_checked, :degrees_of_freedom_summary)) == 1
        smoothness_checked = NLPDiagnostics.analyze(
            model;
            point = point,
            cache = cache,
            check_policy = NLPDiagnostics.CheckPolicy(nonsmoothness = true),
        )
        @test occursin(",nonsmoothness", smoothness_checked.metadata[:stages])
        @test haskey(smoothness_checked.metadata, :nonsmoothness_status)
        weak_checked = NLPDiagnostics.analyze(
            model;
            point = point,
            cache = cache,
            check_policy = NLPDiagnostics.CheckPolicy(weak_activity = true),
        )
        @test occursin(",weak_activity", weak_checked.metadata[:stages])
        @test weak_checked.metadata[:weak_activity_row_count] == "0"
        nonsmoothness_persistence = NLPDiagnostics.analyze_nonsmoothness_persistence(
            model,
            [point, NLPDiagnostics.evaluation_point(model, [2.1, 3.1]; label = "nearby")],
            ;
            direction_count = 2,
        )
        @test nonsmoothness_persistence.metadata[:nonsmoothness_persistence_classification] ==
              "no_nonsmoothness_inconsistency_observed_persistent"
    end

    @testset "constructed MOI nonlinear evaluator supplies exact first derivatives" begin
        model = new_model()
        x = MOI.add_variable(model)
        objective = MOI.ScalarNonlinearFunction(:sin, Any[x])
        constraint = MOI.ScalarNonlinearFunction(:exp, Any[x])
        MOI.set(model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        MOI.set(
            model,
            MOI.ObjectiveFunction{MOI.ScalarNonlinearFunction}(),
            objective,
        )
        MOI.add_constraint(model, constraint, MOI.EqualTo(0.0))
        evaluation = NLPDiagnostics.evaluate_numerical(
            model,
            [0.3];
            # Deliberately too coarse for the former finite-difference path.
            relative_step = 0.1,
        )
        @test evaluation.objective_gradient ≈ [cos(0.3)] atol = 1.0e-12
        @test evaluation.jacobian_row_methods == [:exact_constructed_nonlinear_ad]
        @test only(evaluation.jacobian_entries).value ≈ exp(0.3) atol = 1.0e-12
        @test evaluation.call_statistics[:constructed_nlp_initialize][1] == 2
        @test evaluation.call_statistics[:constructed_nlp_objective_gradient][1] == 2
    end

    @testset "zero Jacobian rows and columns are local inferences" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        square = MOI.ScalarNonlinearFunction(:^, Any[x, 2])
        MOI.add_constraint(model, square, MOI.EqualTo(0.0))
        report = NLPDiagnostics.analyze_numerical(
            model,
            [0.0, 1.0];
            label = "stationary point",
        )
        row_finding = only(findings(report, :zero_jacobian_rows))
        column_finding = only(findings(report, :zero_jacobian_columns))
        @test row_finding.basis == NLPDiagnostics.LocalInference
        @test column_finding.basis == NLPDiagnostics.LocalInference
        @test Dict(row_finding.evidence[2].details)["rows"] == "1"
        @test Dict(column_finding.evidence[2].details)["columns"] == "1,2"
    end

    @testset "stationary circular rows retain activity and non-unit radius" begin
        Q = MOI.ScalarQuadraticFunction{Float64}
        QT = MOI.ScalarQuadraticTerm{Float64}
        inactive_model = new_model()
        x, y = MOI.add_variables(inactive_model, 2)
        circle = Q([QT(2.0, x, x), QT(2.0, y, y)],
                   MOI.ScalarAffineTerm{Float64}[], 0.0)
        MOI.add_constraint(inactive_model, circle, MOI.LessThan(4.0))
        inactive_report = NLPDiagnostics.analyze_numerical(
            inactive_model, [0.0, 0.0]; label = "non-unit circle center")
        inactive = only(findings(
            inactive_report, :inactive_stationary_diagonal_quadratic_row))
        inactive_details = Dict(inactive.evidence[2].details)
        @test inactive.severity == NLPDiagnostics.SeverityInfo
        @test inactive_details["activity"] == "interior"
        @test inactive_details["upper_radius_squared"] == "4.0"
        @test inactive_details["upper_radius"] == "2.0"
        @test inactive_report.metadata[:inactive_stationary_diagonal_quadratic_row_count] == "1"
        @test inactive_report.metadata[:active_stationary_diagonal_quadratic_row_count] == "0"

        active_model = new_model()
        a, b = MOI.add_variables(active_model, 2)
        active_circle = Q([QT(6.0, a, a), QT(6.0, b, b)],
                          MOI.ScalarAffineTerm{Float64}[], 0.0)
        MOI.add_constraint(active_model, active_circle, MOI.LessThan(0.0))
        active_report = NLPDiagnostics.analyze_numerical(
            active_model, [0.0, 0.0]; label = "active quadratic minimum")
        active = only(findings(
            active_report, :active_stationary_diagonal_quadratic_row))
        @test active.severity == NLPDiagnostics.SeverityWarning
        @test Dict(active.evidence[2].details)["activity"] == "active_upper"
        @test active_report.metadata[:active_stationary_diagonal_quadratic_row_count] == "1"

        violated_model = new_model()
        u, v = MOI.add_variables(violated_model, 2)
        violated_circle = Q([QT(2.0, u, u), QT(2.0, v, v)],
                            MOI.ScalarAffineTerm{Float64}[], 0.0)
        MOI.add_constraint(violated_model, violated_circle, MOI.LessThan(-1.0))
        violated_report = NLPDiagnostics.analyze_numerical(
            violated_model, [0.0, 0.0]; label = "violated quadratic center")
        violated = only(findings(
            violated_report, :violated_stationary_diagonal_quadratic_row))
        @test violated.severity == NLPDiagnostics.SeverityError
        @test violated_report.metadata[:violated_stationary_diagonal_quadratic_row_count] == "1"
    end

    @testset "exact quadratic derivatives use MOI diagonal semantics" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        Q = MOI.ScalarQuadraticFunction{Float64}
        QT = MOI.ScalarQuadraticTerm{Float64}
        quadratic = Q(
            [
                QT(2.0, x, x),
                QT(3.0, x, y),
            ],
            MOI.ScalarAffineTerm{Float64}[],
            0.0,
        )
        MOI.add_constraint(model, quadratic, MOI.EqualTo(0.0))
        evaluation = NLPDiagnostics.evaluate_numerical(model, [2.0, 4.0])
        @test evaluation.constraint_values == [28.0]
        @test evaluation.jacobian_row_methods == [:exact_symbolic]
        @test [entry.value for entry in evaluation.jacobian_entries] ==
              [16.0, 6.0]
    end

    @testset "guarded Jacobian rank distinguishes scale from deficiency" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        MOI.add_constraint(model, F([T(1.0, x), T(1.0, y)], 0.0), MOI.EqualTo(0.0))
        MOI.add_constraint(model, F([T(2.0, x), T(2.0, y)], 0.0), MOI.EqualTo(0.0))
        evaluation = NLPDiagnostics.evaluate_numerical(model, [0.0, 0.0])
        estimate = NLPDiagnostics.jacobian_rank_estimate(evaluation)
        @test estimate.available
        @test estimate.rank == 1
        @test estimate.left_nullity == 1
        @test estimate.right_nullity == 1
        @test maximum(abs, [1.0 1.0; 2.0 2.0] * estimate.right_nullspace) < 1.0e-10
        report = NLPDiagnostics.analyze_numerical(model, [0.0, 0.0])
        @test length(findings(report, :numerical_jacobian_rank_deficiency)) == 1
        @test length(findings(report, :dense_sparse_qr_rank_agreement)) == 1
        @test report.metadata[:dense_sparse_qr_unscaled_rank_agree] == "true"
        @test report.metadata[:sparse_qr_rank_available] == "true"
        @test report.metadata[:sparse_qr_rank] == "1"
        @test report.metadata[:sparse_qr_rank_scaling] == "none"
        @test report.metadata[:sparse_qr_row_column_rank] == "1"
        @test report.metadata[:sparse_qr_condition_proxy] == "1.0"
        sparse = NLPDiagnostics.sparse_jacobian_pattern_estimate(evaluation)
        @test sparse.available
        # Pattern matching cannot see the numerical dependence of two
        # proportional rows, but it can prove a zero-column deficiency.
        @test sparse.rank_upper_bound == 2
        sparse_qr = NLPDiagnostics.sparse_qr_rank_estimate(evaluation)
        @test sparse_qr.available
        @test sparse_qr.rank == 1
        @test sparse_qr.condition_proxy == 1.0
        resource_guarded_report = NLPDiagnostics.analyze_numerical(
            model, [0.0, 0.0];
            rank_max_dense_entries = 0,
            sparse_qr_rank_max_input_nonzeros = 0,
        )
        @test length(findings(
            resource_guarded_report, :sparse_qr_rank_resource_guarded,
        )) == 1
        @test resource_guarded_report.metadata[:sparse_qr_rank_available] ==
            "false"
        @test resource_guarded_report.metadata[:sparse_qr_input_nonzeros] ==
            "4"
        @test occursin(
            "max_input_nonzeros=0",
            resource_guarded_report.metadata[:sparse_qr_rank_reason],
        )
        resource_guarded_data = NLPDiagnostics.report_data(resource_guarded_report)
        resource_guarded_reasons = resource_guarded_data["unavailable_reasons"]
        @test Set(item["code"] for item in resource_guarded_reasons) ⊇ Set([
            "jacobian_rank_unavailable",
            "sparse_qr_rank_unavailable",
            "scaled_sparse_qr_rank_unavailable",
        ])
        @test all(
            item -> item["category"] == "numerical",
            filter(
                item -> item["code"] in Set([
                    "jacobian_rank_unavailable",
                    "sparse_qr_rank_unavailable",
                    "scaled_sparse_qr_rank_unavailable",
                ]),
                resource_guarded_reasons,
            ),
        )
        incomplete_rank_evaluation = NLPDiagnostics.NumericalEvaluation{Float64}(
            evaluation.point,
            evaluation.objective_value,
            evaluation.objective_source,
            evaluation.objective_gradient,
            evaluation.constraint_values,
            evaluation.constraint_sources,
            evaluation.jacobian_entries,
            fill(:unavailable, length(evaluation.jacobian_row_methods)),
            evaluation.capabilities,
            evaluation.failures,
        )
        incomplete_rank_report = NLPDiagnostics.analyze_numerical(
            model,
            incomplete_rank_evaluation,
        )
        incomplete_rank_reasons = NLPDiagnostics.report_data(
            incomplete_rank_report,
        )["unavailable_reasons"]
        @test any(
            item -> item["code"] == "sparse_jacobian_pattern_unavailable",
            incomplete_rank_reasons,
        )
        @test all(
            item -> item["category"] == "numerical",
            filter(
                item -> item["code"] in Set([
                    "jacobian_rank_unavailable",
                    "sparse_jacobian_pattern_unavailable",
                    "sparse_qr_rank_unavailable",
                    "scaled_sparse_qr_rank_unavailable",
                ]),
                incomplete_rank_reasons,
            ),
        )
        sparse_nullspace_guard_report = NLPDiagnostics.analyze_sparse_qr_nullspace(
            evaluation;
            max_input_nonzeros = 0,
        )
        sparse_nullspace_guard_data = NLPDiagnostics.report_data(
            sparse_nullspace_guard_report,
        )
        sparse_nullspace_guard_reason = only(filter(
            item -> item["code"] == "sparse_qr_nullspace_unavailable",
            sparse_nullspace_guard_data["unavailable_reasons"],
        ))
        @test sparse_nullspace_guard_reason["category"] == "numerical"
        @test sparse_nullspace_guard_reason["stage"] == "sparse_qr_nullspace"
        sparse_dense_calibration_guard_report =
            NLPDiagnostics.analyze_sparse_qr_nullspace_dense_calibration(
                evaluation;
                dense_max_entries = 0,
            )
        sparse_dense_calibration_guard_reason = only(filter(
            item -> item["code"] ==
                "sparse_qr_nullspace_dense_calibration_unavailable",
            NLPDiagnostics.report_data(sparse_dense_calibration_guard_report)[
                "unavailable_reasons"
            ],
        ))
        @test sparse_dense_calibration_guard_reason["category"] == "numerical"
        @test sparse_dense_calibration_guard_reason["stage"] ==
              "sparse_qr_nullspace_dense_calibration"
        sparse_persistence_guard_report =
            NLPDiagnostics.analyze_sparse_qr_nullspace_persistence(
                [evaluation, evaluation];
                max_input_nonzeros = 0,
            )
        sparse_persistence_guard_reason = only(filter(
            item -> item["code"] ==
                "sparse_qr_nullspace_persistence_unavailable",
            NLPDiagnostics.report_data(sparse_persistence_guard_report)[
                "unavailable_reasons"
            ],
        ))
        @test sparse_persistence_guard_reason["category"] == "numerical"
        @test sparse_persistence_guard_reason["stage"] ==
              "sparse_qr_nullspace_persistence"
        restarted_dense_calibration_guard_report =
            NLPDiagnostics.analyze_restarted_smallest_singular_dense_calibration(
                evaluation;
                dense_max_entries = 0,
                iterations = 4,
            )
        restarted_dense_calibration_guard_reason = only(filter(
            item -> item["code"] == "restarted_dense_calibration_unavailable",
            NLPDiagnostics.report_data(restarted_dense_calibration_guard_report)[
                "unavailable_reasons"
            ],
        ))
        @test restarted_dense_calibration_guard_reason["category"] == "numerical"
        @test restarted_dense_calibration_guard_reason["stage"] ==
              "restarted_smallest_singular_dense_calibration"
        harmonic_dense_calibration_guard_report =
            NLPDiagnostics.analyze_harmonic_golub_kahan_dense_calibration(
                evaluation;
                dense_max_entries = 0,
                steps_per_seed = 1,
                cycles = 2,
            )
        harmonic_dense_calibration_guard_reason = only(filter(
            item -> item["code"] == "harmonic_dense_calibration_unavailable",
            NLPDiagnostics.report_data(harmonic_dense_calibration_guard_report)[
                "unavailable_reasons"
            ],
        ))
        @test harmonic_dense_calibration_guard_reason["category"] == "numerical"
        @test harmonic_dense_calibration_guard_reason["stage"] ==
              "harmonic_golub_kahan_dense_calibration"
        backend_crosscheck_guard_report =
            NLPDiagnostics.analyze_smallest_singular_backend_crosscheck(
                evaluation;
                dimension = 1,
                restarted_iterations = 4,
                harmonic_steps_per_seed = 1,
                harmonic_cycles = 2,
                max_basis_entries = 0,
            )
        backend_crosscheck_guard_reason = only(filter(
            item -> item["code"] ==
                "smallest_singular_backend_crosscheck_unavailable",
            NLPDiagnostics.report_data(backend_crosscheck_guard_report)[
                "unavailable_reasons"
            ],
        ))
        @test backend_crosscheck_guard_reason["category"] == "numerical"
        @test backend_crosscheck_guard_reason["stage"] ==
              "smallest_singular_backend_crosscheck"
        scaled_sparse_qr = NLPDiagnostics.sparse_qr_rank_estimate(
            evaluation;
            scaling = :row_column,
        )
        @test scaled_sparse_qr.available
        @test scaled_sparse_qr.rank == 1
        @test scaled_sparse_qr.scaling == :row_column
        iterative_null = NLPDiagnostics.iterative_right_nullspace_estimate(
            evaluation;
            iterations = 200,
        )
        @test iterative_null.available
        @test iterative_null.residual_norm < 1.0e-6
        @test maximum(abs, [1.0 1.0; 2.0 2.0] * iterative_null.direction) <
              1.0e-6
        iterative_probe_report = NLPDiagnostics.analyze_iterative_right_nullspace_probe(
            evaluation;
            iterations = 200,
            residual_relative_tolerance = 1.0e-5,
        )
        @test iterative_probe_report.metadata[:iterative_probe_available] == "true"
        @test iterative_probe_report.metadata[
            :iterative_probe_small_residual_direction_count
        ] == "1"
        @test length(findings(
            iterative_probe_report,
            :iterative_jacobian_candidate_small_residual_direction,
        )) == 1
        iterative_left_subspace =
            NLPDiagnostics.iterative_left_nullspace_subspace_estimate(
                evaluation,
                1;
                iterations = 200,
            )
        @test iterative_left_subspace.available
        @test size(iterative_left_subspace.directions) == (2, 1)
        @test only(iterative_left_subspace.residual_norms) < 1.0e-6
        @test maximum(abs, transpose([1.0 1.0; 2.0 2.0]) *
                         iterative_left_subspace.directions) < 1.0e-6
        iterative_left_probe_report = NLPDiagnostics.analyze_iterative_left_nullspace_probe(
            evaluation;
            iterations = 200,
            residual_relative_tolerance = 1.0e-5,
        )
        @test iterative_left_probe_report.metadata[:iterative_left_probe_available] == "true"
        @test iterative_left_probe_report.metadata[
            :iterative_left_probe_small_residual_direction_count
        ] == "1"
        @test length(findings(
            iterative_left_probe_report,
            :iterative_jacobian_candidate_small_residual_left_direction,
        )) == 1
        iterative_left_probe_from_model = NLPDiagnostics.analyze_iterative_left_nullspace_probe(
            model,
            [0.0, 0.0];
            label = "left probe convenience point",
            iterations = 200,
            residual_relative_tolerance = 1.0e-5,
        )
        @test iterative_left_probe_from_model.metadata[:evaluation_point_label] ==
              "left probe convenience point"
        second_evaluation = NLPDiagnostics.evaluate_numerical(
            model,
            NLPDiagnostics.evaluation_point(
                model,
                [1.0, -1.0];
                label = "second affine point",
            ),
        )
        right_probe_persistence =
            NLPDiagnostics.analyze_iterative_right_nullspace_persistence(
                [evaluation, second_evaluation];
                iterations = 200,
                residual_relative_tolerance = 1.0e-5,
            )
        @test length(findings(
            right_probe_persistence,
            :iterative_right_nullspace_persistence_persistent,
        )) == 1
        @test length(only(findings(
            right_probe_persistence,
            :iterative_right_nullspace_persistence_persistent,
        )).affected) == 2
        left_probe_persistence =
            NLPDiagnostics.analyze_iterative_left_nullspace_persistence(
                [evaluation, second_evaluation];
                iterations = 200,
                residual_relative_tolerance = 1.0e-5,
            )
        @test length(findings(
            left_probe_persistence,
            :iterative_left_nullspace_persistence_persistent,
        )) == 1
        for (report, code, stage) in (
            (
                NLPDiagnostics.analyze_iterative_right_nullspace_persistence(
                    [evaluation],
                ),
                "iterative_right_nullspace_persistence_unavailable",
                "iterative_right_nullspace_persistence",
            ),
            (
                NLPDiagnostics.analyze_iterative_left_nullspace_persistence(
                    [evaluation],
                ),
                "iterative_left_nullspace_persistence_unavailable",
                "iterative_left_nullspace_persistence",
            ),
        )
            reason = only(filter(
                item -> item["code"] == code,
                NLPDiagnostics.report_data(report)["unavailable_reasons"],
            ))
            @test reason["category"] == "numerical"
            @test reason["stage"] == stage
        end
        right_probe_persistence_from_model =
            NLPDiagnostics.analyze_iterative_right_nullspace_persistence(
                model,
                [
                    NLPDiagnostics.evaluation_point(model, [0.0, 0.0]; label = "first"),
                    NLPDiagnostics.evaluation_point(model, [1.0, -1.0]; label = "second"),
                ];
                iterations = 200,
                residual_relative_tolerance = 1.0e-5,
            )
        @test right_probe_persistence_from_model.metadata[:available_evaluation_count] ==
              "2"
        @test_throws ArgumentError NLPDiagnostics.analyze_iterative_right_nullspace_persistence(
            [evaluation, second_evaluation]; support_relative = 0,
        )
        dense_rank_persistence = NLPDiagnostics.analyze_jacobian_rank_persistence(
            [evaluation, second_evaluation],
        )
        @test dense_rank_persistence.metadata[:observed_left_nullities] == "1,1"
        @test length(findings(
            dense_rank_persistence,
            :jacobian_left_nullspace_persistent,
        )) == 1
        @test length(only(findings(
            dense_rank_persistence,
            :jacobian_left_nullspace_persistent,
        )).affected) == 2
        @test length(only(findings(
            dense_rank_persistence,
            :jacobian_right_nullspace_persistent,
        )).affected) == 2
        @test_throws ArgumentError NLPDiagnostics.analyze_jacobian_rank_persistence(
            [evaluation, second_evaluation]; left_nullspace_support_relative = 0,
        )
        @test_throws ArgumentError NLPDiagnostics.analyze_jacobian_rank_persistence(
            [evaluation, second_evaluation]; right_nullspace_support_relative = 0,
        )
        degeneracy_with_sparse_probes = NLPDiagnostics.analyze_degeneracy(
            model,
            evaluation;
            iterative_right_nullspace_probe_dimension = 1,
            iterative_right_nullspace_probe_iterations = 200,
            iterative_right_nullspace_probe_residual_relative_tolerance = 1.0e-5,
            iterative_left_nullspace_probe_dimension = 1,
            iterative_left_nullspace_probe_iterations = 200,
            iterative_left_nullspace_probe_residual_relative_tolerance = 1.0e-5,
        )
        @test degeneracy_with_sparse_probes.metadata[
            :degeneracy_iterative_left_probe_requested
        ] == "true"
        @test length(findings(
            degeneracy_with_sparse_probes,
            :iterative_jacobian_candidate_small_residual_left_direction,
        )) == 1
        combined_iterative_probe_report = NLPDiagnostics.analyze(
            model;
            evaluation = evaluation,
            iterative_right_nullspace_probe_dimension = 1,
            iterative_right_nullspace_probe_iterations = 200,
            iterative_right_nullspace_probe_residual_relative_tolerance = 1.0e-5,
            iterative_left_nullspace_probe_dimension = 1,
            iterative_left_nullspace_probe_iterations = 200,
            iterative_left_nullspace_probe_residual_relative_tolerance = 1.0e-5,
            iterative_spectrum_probe_dimension = 1,
            iterative_spectrum_probe_iterations = 200,
            iterative_spectrum_probe_spread_threshold = 1.0e6,
        )
        @test occursin(
            "iterative_right_nullspace_probe",
            combined_iterative_probe_report.metadata[:stages],
        )
        @test occursin(
            "iterative_left_nullspace_probe",
            combined_iterative_probe_report.metadata[:stages],
        )
        @test length(findings(
            combined_iterative_probe_report,
            :iterative_jacobian_candidate_small_residual_left_direction,
        )) == 1
        @test_throws ArgumentError NLPDiagnostics.analyze(
            model;
            iterative_left_nullspace_probe_dimension = 1,
        )
        iterative_probe_from_model = NLPDiagnostics.analyze_iterative_right_nullspace_probe(
            model,
            [0.0, 0.0];
            label = "probe convenience point",
            iterations = 200,
            residual_relative_tolerance = 1.0e-5,
        )
        @test iterative_probe_from_model.metadata[:evaluation_point_label] ==
              "probe convenience point"
        @test iterative_probe_from_model.metadata[
            :iterative_probe_small_residual_direction_count
        ] == "1"
        @test_throws ArgumentError NLPDiagnostics.analyze_iterative_right_nullspace_probe(
            evaluation; probe_dimension = 0,
        )
        two_dimensional_model = new_model()
        a, b, c = MOI.add_variables(two_dimensional_model, 3)
        MOI.add_constraint(
            two_dimensional_model,
            F([T(1.0, a), T(-1.0, b)], 0.0),
            MOI.EqualTo(0.0),
        )
        two_dimensional_evaluation = NLPDiagnostics.evaluate_numerical(
            two_dimensional_model,
            [0.0, 0.0, 0.0],
        )
        iterative_subspace =
            NLPDiagnostics.iterative_right_nullspace_subspace_estimate(
                two_dimensional_evaluation,
                2;
                iterations = 200,
            )
        @test iterative_subspace.available
        @test size(iterative_subspace.directions) == (3, 2)
        @test maximum(iterative_subspace.residual_norms) < 1.0e-6
        @test maximum(abs, transpose(iterative_subspace.directions) *
                         iterative_subspace.directions - [1.0 0.0; 0.0 1.0]) <
              1.0e-10
        iterative_spectrum = NLPDiagnostics.iterative_jacobian_spectrum_estimate(
            two_dimensional_evaluation;
            probe_dimension = 2,
            iterations = 200,
        )
        @test iterative_spectrum.available
        @test iterative_spectrum.largest_singular_value_proxy ≈ sqrt(2.0) atol = 1.0e-6
        @test maximum(iterative_spectrum.candidate_small_singular_values) < 1.0e-6
        @test all(value -> value > 1.0e6, iterative_spectrum.spectral_spread_proxies)
        iterative_spectrum_report = NLPDiagnostics.analyze_iterative_jacobian_spectrum_probe(
            two_dimensional_evaluation;
            probe_dimension = 2,
            iterations = 200,
            spectral_spread_threshold = 1.0e6,
        )
        @test iterative_spectrum_report.metadata[
            :iterative_spectrum_probe_large_spread_count
        ] == "2"
        @test length(findings(
            iterative_spectrum_report,
            :iterative_jacobian_large_spectral_spread_proxy,
        )) == 2
        incomplete_probe_evaluation = NLPDiagnostics.NumericalEvaluation{Float64}(
            evaluation.point,
            evaluation.objective_value,
            evaluation.objective_source,
            evaluation.objective_gradient,
            evaluation.constraint_values,
            evaluation.constraint_sources,
            evaluation.jacobian_entries,
            fill(:unavailable, length(evaluation.jacobian_row_methods)),
            evaluation.capabilities,
            evaluation.failures,
        )
        incomplete_right_probe = NLPDiagnostics.analyze_iterative_right_nullspace_probe(
            incomplete_probe_evaluation,
        )
        incomplete_left_probe = NLPDiagnostics.analyze_iterative_left_nullspace_probe(
            incomplete_probe_evaluation,
        )
        incomplete_spectrum_probe =
            NLPDiagnostics.analyze_iterative_jacobian_spectrum_probe(
                incomplete_probe_evaluation,
            )
        @test incomplete_right_probe.metadata[:iterative_probe_available] == "false"
        @test incomplete_left_probe.metadata[:iterative_left_probe_available] == "false"
        @test incomplete_spectrum_probe.metadata[
            :iterative_spectrum_probe_available
        ] == "false"
        incomplete_probe_data = vcat(
            NLPDiagnostics.report_data(incomplete_right_probe)["unavailable_reasons"],
            NLPDiagnostics.report_data(incomplete_left_probe)["unavailable_reasons"],
            NLPDiagnostics.report_data(incomplete_spectrum_probe)["unavailable_reasons"],
        )
        @test Set(item["code"] for item in incomplete_probe_data) == Set([
            "iterative_probe_unavailable",
            "iterative_left_probe_unavailable",
            "iterative_spectrum_probe_unavailable",
        ])
        @test all(item -> item["category"] == "numerical", incomplete_probe_data)
        iterative_spectrum_from_model = NLPDiagnostics.analyze_iterative_jacobian_spectrum_probe(
            two_dimensional_model,
            NLPDiagnostics.evaluation_point(
                two_dimensional_model,
                [0.0, 0.0, 0.0];
                label = "spectrum convenience point",
            );
            probe_dimension = 2,
            iterations = 200,
            spectral_spread_threshold = 1.0e6,
        )
        @test iterative_spectrum_from_model.metadata[:evaluation_point_label] ==
              "spectrum convenience point"
        @test iterative_spectrum_from_model.metadata[
            :iterative_spectrum_probe_candidate_count
        ] == "2"
        @test_throws ArgumentError NLPDiagnostics.analyze_iterative_jacobian_spectrum_probe(
            two_dimensional_evaluation; spectral_spread_threshold = 1.0,
        )

        zero_column_model = new_model()
        r, s = MOI.add_variables(zero_column_model, 2)
        zero_column_function = F([T(1.0, r)], 0.0)
        MOI.add_constraint(
            zero_column_model,
            zero_column_function,
            MOI.EqualTo(0.0),
        )
        MOI.add_constraint(
            zero_column_model,
            zero_column_function,
            MOI.EqualTo(0.0),
        )
        zero_column_evaluation = NLPDiagnostics.evaluate_numerical(
            zero_column_model,
            [0.0, 0.0],
        )
        zero_column_bound = NLPDiagnostics.sparse_jacobian_pattern_estimate(
            zero_column_evaluation,
        )
        @test zero_column_bound.rank_upper_bound == 1
        guarded_report = NLPDiagnostics.analyze_numerical(
            zero_column_model,
            [0.0, 0.0];
            rank_max_dense_entries = 1,
        )
        @test !parse(Bool, guarded_report.metadata[:jacobian_rank_available])
        @test length(
            findings(guarded_report, :sparse_jacobian_pattern_rank_deficiency),
        ) == 1
        @test length(
            findings(guarded_report, :sparse_qr_jacobian_rank_deficiency),
        ) == 1

        scaled_model = new_model()
        a, b = MOI.add_variables(scaled_model, 2)
        MOI.add_constraint(scaled_model, a, MOI.EqualTo(0.0))
        MOI.add_constraint(
            scaled_model,
            MOI.ScalarAffineFunction([T(1.0e-10, b)], 0.0),
            MOI.EqualTo(0.0),
        )
        scaled_evaluation = NLPDiagnostics.evaluate_numerical(scaled_model, [0.0, 0.0])
        unscaled = NLPDiagnostics.jacobian_rank_estimate(
            scaled_evaluation;
            relative_tolerance = 1.0e-6,
        )
        normalized = NLPDiagnostics.jacobian_rank_estimate(
            scaled_evaluation;
            scaling = :row_column,
            relative_tolerance = 1.0e-6,
        )
        @test unscaled.rank == 1
        @test normalized.rank == 2
        scaled_report = NLPDiagnostics.analyze_numerical(
            scaled_model,
            [0.0, 0.0];
            rank_relative_tolerance = 1.0e-6,
        )
        @test length(findings(scaled_report, :jacobian_rank_scaling_sensitive)) == 1
        sparse_scaled_report = NLPDiagnostics.analyze_numerical(
            scaled_model,
            [0.0, 0.0];
            rank_max_dense_entries = 1,
            jacobian_condition_threshold = 1.0e5,
        )
        @test length(
            findings(sparse_scaled_report, :sparse_qr_pivot_scale_spread),
        ) == 1

        family_model = new_model()
        family_x, family_y = MOI.add_variables(family_model, 2)
        MOI.add_constraint(family_model,
            F([T(1.0, family_x)], 0.0), MOI.EqualTo(0.0))
        MOI.add_constraint(family_model,
            F([T(2.0, family_x)], 0.0), MOI.EqualTo(0.0))
        MOI.add_constraint(family_model,
            F([T(1.0, family_y)], 0.0), MOI.EqualTo(0.0))
        MOI.add_constraint(family_model,
            F(T[], 0.0), MOI.EqualTo(0.0))
        family_evaluation = NLPDiagnostics.evaluate_numerical(
            family_model, [0.0, 0.0],
        )
        family_report = NLPDiagnostics.analyze_jacobian_row_family_perturbations(
            family_evaluation,
            Dict(1 => Dict("constraint_family" => "dependent"),
                 2 => Dict("constraint_family" => "dependent"),
                 3 => Dict("constraint_family" => "independent"),
                 4 => Dict("constraint_family" => "zero"));
            max_dense_entries = 16,
        )
        @test family_report.metadata[:baseline_rank] == "2"
        @test family_report.metadata[:rank_effect_family_count] == "2"
        @test family_report.metadata[:no_rank_effect_family_count] == "1"
        @test length(findings(
            family_report, :jacobian_row_family_perturbation_rank_effect,
        )) == 2
        @test length(findings(
            family_report, :jacobian_row_family_perturbation_no_rank_effect,
        )) == 1
        guarded_family_report =
            NLPDiagnostics.analyze_jacobian_row_family_perturbations(
                family_evaluation,
                Dict(1 => "dependent", 2 => "dependent",
                     3 => "independent", 4 => "zero");
                max_dense_entries = 0,
            )
        guarded_family_reason = only(filter(
            item -> item["code"] ==
                "jacobian_row_family_perturbation_unavailable",
            NLPDiagnostics.report_data(guarded_family_report)[
                "unavailable_reasons"
            ],
        ))
        @test guarded_family_reason["category"] == "numerical"
        @test guarded_family_reason["stage"] ==
              "jacobian_row_family_perturbations"
        @test_throws ArgumentError NLPDiagnostics.analyze_jacobian_row_family_perturbations(
            evaluation, ["only one row"],
        )
        family_scales = NLPDiagnostics.jacobian_row_family_scale_attribution(
            family_evaluation,
            Dict(1 => Dict("constraint_family" => "dependent"),
                 2 => Dict("constraint_family" => "dependent"),
                 3 => Dict("constraint_family" => "independent"),
                 4 => Dict("constraint_family" => "zero")),
        )
        @test family_scales["report_version"] ==
              "jacobian-row-family-scale-attribution-v1"
        @test family_scales["row_count"] == 4
        @test family_scales["family_count"] == 3
        @test family_scales["global_maximum_families"] == ["dependent"]
        @test family_scales["global_minimum_families"] ==
              ["dependent", "independent"]
        dependent_scales = family_scales["families"]["dependent"]
        @test dependent_scales["row_count"] == 2
        @test dependent_scales["combined_nonzero_entry_count"] == 2
        @test dependent_scales["smallest_positive_row_norm"] == 1.0
        @test dependent_scales["row_norm_q25"] == 1.25
        @test dependent_scales["row_norm_median"] == 1.5
        @test dependent_scales["row_norm_q75"] == 1.75
        @test dependent_scales["largest_finite_row_norm"] == 2.0
        @test dependent_scales["row_scale_ratio"] == 2.0
        @test family_scales["families"]["zero"]["zero_row_count"] == 1
        column_labels = Dict(
            1 => Dict("variable_family" => "state"),
            2 => Dict("variable_family" => "control"),
        )
        column_scales =
            NLPDiagnostics.jacobian_column_family_scale_attribution(
                family_evaluation, column_labels,
            )
        @test column_scales["report_version"] ==
              "jacobian-column-family-scale-attribution-v1"
        @test column_scales["column_count"] == 2
        @test column_scales["family_count"] == 2
        @test column_scales["derivative_rows_complete"]
        @test column_scales["global_maximum_families"] == ["state"]
        @test column_scales["global_minimum_families"] == ["control"]
        @test column_scales["families"]["state"][
            "combined_nonzero_entry_count"
        ] == 2
        family_geometry = NLPDiagnostics.jacobian_family_geometry_comparison(
            family_evaluation,
            family_evaluation;
            reference_row_labels=Dict(
                1 => "dependent", 2 => "dependent",
                3 => "independent", 4 => "zero",
            ),
            candidate_row_labels=Dict(
                1 => "dependent", 2 => "dependent",
                3 => "independent", 4 => "zero",
            ),
            reference_column_labels=column_labels,
            candidate_column_labels=column_labels,
        )
        @test family_geometry["available"]
        @test family_geometry["family_sets_agree"]
        @test family_geometry["comparisons"]["columns"]["families"][
            "state"
        ]["column_norm_median"]["relation"] == "approximately_equal"
        @test_throws ArgumentError NLPDiagnostics.jacobian_column_family_scale_attribution(
            family_evaluation, ["only one column"],
        )
        scaling_experiment =
            NLPDiagnostics.jacobian_row_family_scaling_experiment(
                family_evaluation,
                ["dependent", "dependent", "independent", "zero"];
                families = ["dependent", "zero"],
            )
        @test scaling_experiment["baseline_available"]
        @test scaling_experiment["families"]["dependent"]["available"]
        @test scaling_experiment["families"]["dependent"]["rank_delta"] == 0
        @test scaling_experiment["families"]["dependent"]["condition_proxy_ratio"] < 1
        @test !scaling_experiment["families"]["zero"]["available"]
        @test scaling_experiment["families"]["zero"]["zero_row_count"] == 1
        @test_throws ArgumentError NLPDiagnostics.jacobian_row_family_scaling_experiment(
            family_evaluation, ["a", "b", "c", "d"];
            families = ["missing"],
        )
        @test_throws ArgumentError NLPDiagnostics.jacobian_row_family_scale_attribution(
            family_evaluation, ["only one row"],
        )
    end

    @testset "Jacobian rank tolerance sweep is explicit" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        MOI.add_constraint(model, F([T(1.0, x)], 0.0), MOI.EqualTo(0.0))
        MOI.add_constraint(model, F([T(1.0e-8, y)], 0.0), MOI.EqualTo(0.0))
        point = NLPDiagnostics.evaluation_point(model, [0.0, 0.0]; label = "tolerance-sweep")
        sensitive = NLPDiagnostics.analyze_jacobian_rank_tolerance_sweep(
            model,
            point;
            relative_tolerances = [1.0e-10, 1.0e-6],
        )
        @test length(findings(sensitive, :jacobian_rank_tolerance_sensitive)) == 1
        @test sensitive.metadata[:ranks] == "2,1"
        guarded_sweep = NLPDiagnostics.analyze_jacobian_rank_tolerance_sweep(
            model,
            point;
            relative_tolerances = [1.0e-10, 1.0e-6],
            max_dense_entries = 0,
        )
        guarded_sweep_reason = only(filter(
            item -> item["code"] == "jacobian_rank_tolerance_sweep_unavailable",
            NLPDiagnostics.report_data(guarded_sweep)["unavailable_reasons"],
        ))
        @test guarded_sweep_reason["category"] == "numerical"
        @test guarded_sweep_reason["stage"] == "jacobian_rank_tolerance_sweep"
        combined = NLPDiagnostics.analyze(
            model;
            point = point,
            jacobian_rank_tolerance_sweep_tolerances = [1.0e-10, 1.0e-6],
        )
        @test length(findings(combined, :jacobian_rank_tolerance_sensitive)) == 1
        @test occursin("jacobian_rank_tolerance_sweep", combined.metadata[:stages])
        stable = NLPDiagnostics.analyze_jacobian_rank_tolerance_sweep(
            model,
            point;
            relative_tolerances = [1.0e-6, 1.0e-4],
        )
        @test length(findings(stable, :jacobian_rank_tolerance_stable)) == 1
        @test_throws ArgumentError NLPDiagnostics.analyze_jacobian_rank_tolerance_sweep(
            model,
            point;
            relative_tolerances = Float64[],
        )
        @test_throws ArgumentError NLPDiagnostics.analyze(
            model;
            jacobian_rank_tolerance_sweep_tolerances = [1.0e-10, 1.0e-6],
        )
    end

    @testset "Jacobian scaling persistence is separate from rank persistence" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        MOI.add_constraint(
            model,
            MOI.ScalarNonlinearFunction(:^, Any[x, 2]),
            MOI.EqualTo(0.0),
        )
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        MOI.add_constraint(model, F([T(1.0, y)], 0.0), MOI.EqualTo(0.0))
        points = [
            NLPDiagnostics.evaluation_point(model, [1.0, 1.0]; label = "near"),
            NLPDiagnostics.evaluation_point(model, [100.0, 1.0]; label = "far"),
        ]
        scaling = NLPDiagnostics.analyze_jacobian_scaling_persistence(
            model, points; change_factor_threshold = 10,
        )
        @test length(findings(scaling, :jacobian_scaling_changing)) == 1
        @test scaling.metadata[:row_change_factor] == "100.0"
        @test_throws ArgumentError NLPDiagnostics.analyze_jacobian_scaling_persistence(
            model, points; change_factor_threshold = 0.5,
        )
        rank = NLPDiagnostics.analyze_jacobian_rank_persistence(
            model, points; scaling_change_factor_threshold = 10,
        )
        @test length(findings(rank, :jacobian_rank_persistent)) == 1
        @test length(findings(rank, :jacobian_scaling_changing)) == 1
        @test rank.metadata[:scaling_row_change_factor] == "100.0"
        conditioning = NLPDiagnostics.analyze_jacobian_condition_persistence(
            model, points; change_factor_threshold = 10,
        )
        @test length(findings(conditioning, :jacobian_condition_changing)) == 1
        @test conditioning.metadata[:change_factor] == "100.0"
        short_conditioning = NLPDiagnostics.analyze_jacobian_condition_persistence(
            [NLPDiagnostics.evaluate_numerical(model, points[1])];
        )
        short_conditioning_reason = only(filter(
            item -> item["code"] == "jacobian_condition_persistence_unavailable",
            NLPDiagnostics.report_data(short_conditioning)["unavailable_reasons"],
        ))
        @test short_conditioning_reason["category"] == "numerical"
        @test short_conditioning_reason["stage"] == "jacobian_condition_persistence"
        evaluations = [NLPDiagnostics.evaluate_numerical(model, point) for point in points]
        for (report, code, stage) in (
            (
                NLPDiagnostics.analyze_jacobian_scaling_persistence(
                    [evaluations[1]],
                ),
                "jacobian_scaling_persistence_unavailable",
                "jacobian_scaling_persistence",
            ),
            (
                NLPDiagnostics.analyze_jacobian_derivative_provenance_persistence(
                    [evaluations[1]],
                ),
                "jacobian_derivative_provenance_persistence_unavailable",
                "jacobian_derivative_provenance_persistence",
            ),
            (
                NLPDiagnostics.analyze_jacobian_rank_persistence(
                    [evaluations[1]],
                ),
                "jacobian_rank_persistence_unavailable",
                "jacobian_rank_persistence",
            ),
        )
            reason = only(filter(
                item -> item["code"] == code,
                NLPDiagnostics.report_data(report)["unavailable_reasons"],
            ))
            @test reason["category"] == "numerical"
            @test reason["stage"] == stage
        end
        changed_provenance = NLPDiagnostics.NumericalEvaluation{Float64}(
            evaluations[2].point,
            evaluations[2].objective_value,
            evaluations[2].objective_source,
            evaluations[2].objective_gradient,
            evaluations[2].constraint_values,
            evaluations[2].constraint_sources,
            evaluations[2].jacobian_entries,
            [:central_finite_difference, evaluations[2].jacobian_row_methods[2]],
            evaluations[2].capabilities,
            evaluations[2].failures,
        )
        provenance = NLPDiagnostics.analyze_jacobian_derivative_provenance_persistence(
            [evaluations[1], changed_provenance],
        )
        @test length(findings(
            provenance, :jacobian_derivative_provenance_changing,
        )) == 1
        @test length(only(findings(
            provenance, :jacobian_derivative_provenance_changing,
        )).affected) == 1
        misaligned_evaluation = NLPDiagnostics.NumericalEvaluation{Float64}(
            evaluations[2].point,
            evaluations[2].objective_value,
            evaluations[2].objective_source,
            evaluations[2].objective_gradient,
            evaluations[2].constraint_values,
            collect(reverse(evaluations[2].constraint_sources)),
            evaluations[2].jacobian_entries,
            evaluations[2].jacobian_row_methods,
            evaluations[2].capabilities,
            evaluations[2].failures,
        )
        for (report, code, stage) in (
            (
                NLPDiagnostics.analyze_jacobian_scaling_persistence(
                    [evaluations[1], misaligned_evaluation],
                ),
                "jacobian_scaling_persistence_unavailable",
                "jacobian_scaling_persistence",
            ),
            (
                NLPDiagnostics.analyze_jacobian_derivative_provenance_persistence(
                    [evaluations[1], misaligned_evaluation],
                ),
                "jacobian_derivative_provenance_persistence_unavailable",
                "jacobian_derivative_provenance_persistence",
            ),
            (
                NLPDiagnostics.analyze_jacobian_condition_persistence(
                    [evaluations[1], misaligned_evaluation],
                ),
                "jacobian_condition_persistence_unavailable",
                "jacobian_condition_persistence",
            ),
            (
                NLPDiagnostics.analyze_jacobian_rank_persistence(
                    [evaluations[1], misaligned_evaluation],
                ),
                "jacobian_rank_persistence_unavailable",
                "jacobian_rank_persistence",
            ),
        )
            reason = only(filter(
                item -> item["code"] == code,
                NLPDiagnostics.report_data(report)["unavailable_reasons"],
            ))
            @test reason["category"] == "input"
            @test reason["stage"] == stage
        end
    end

    @testset "structural and numerical rank comparison stays nonphysical" begin
        underdetermined = new_model()
        x, y = MOI.add_variables(underdetermined, 2)
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        MOI.add_constraint(
            underdetermined,
            F([T(1.0, x), T(-1.0, y)], 0.0),
            MOI.EqualTo(0.0),
        )
        expected = NLPDiagnostics.structural_numerical_comparison(
            underdetermined,
            [0.0, 0.0],
        )
        @test expected.available
        @test expected.structural_matching_rank == 1
        @test expected.structural_right_nullity == 1
        @test expected.numerical_rank == 1
        report = NLPDiagnostics.analyze_degeneracy(underdetermined, [0.0, 0.0])
        @test length(findings(report, :structurally_expected_local_nullspace)) == 1
        @test length(
            findings(report, :candidate_uniform_coordinate_shift_null_mode),
        ) == 1
        guarded_degeneracy = NLPDiagnostics.analyze_degeneracy(
            underdetermined,
            [0.0, 0.0];
            max_dense_entries = 0,
        )
        @test guarded_degeneracy.metadata[
            :structural_numerical_comparison_available
        ] == "false"
        guarded_degeneracy_data = NLPDiagnostics.report_data(guarded_degeneracy)
        guarded_degeneracy_reason = only(filter(
            item -> item["code"] == "structural_numerical_comparison_unavailable",
            guarded_degeneracy_data["unavailable_reasons"],
        ))
        @test guarded_degeneracy_reason["category"] == "numerical"
        @test guarded_degeneracy_reason["stage"] ==
              "degeneracy_structural_numerical"
        common_shift = NLPDiagnostics.ExpectedNullspaceMode(
            :common_shift,
            [x, y],
            [1.0, 1.0];
            description = "common reference-coordinate shift",
        )
        expected_mode_report = NLPDiagnostics.analyze_degeneracy(
            underdetermined,
            [0.0, 0.0];
            expected_modes = [common_shift],
        )
        @test length(
            findings(expected_mode_report, :expected_nullspace_mode_observed),
        ) == 1
        fixed_difference = NLPDiagnostics.ExpectedNullspaceMode(
            :fixed_difference,
            [x, y],
            [1.0, -1.0],
        )
        mismatch_report = NLPDiagnostics.analyze_degeneracy(
            underdetermined,
            [0.0, 0.0];
            expected_modes = [fixed_difference],
        )
        @test length(
            findings(mismatch_report, :expected_nullspace_mode_not_observed),
        ) == 1

        partially_aligned = new_model()
        fixed_coordinate, free_coordinate = MOI.add_variables(partially_aligned, 2)
        MOI.add_constraint(
            partially_aligned,
            fixed_coordinate,
            MOI.EqualTo(0.0),
        )
        MOI.add_constraint(
            partially_aligned,
            MOI.ScalarNonlinearFunction(:sin, Any[free_coordinate]),
            MOI.EqualTo(0.0),
        )
        partial_mode = NLPDiagnostics.ExpectedNullspaceMode(
            :fixed_and_free_coordinates,
            [fixed_coordinate, free_coordinate],
            [1.0, 1.0],
        )
        partial_mode_report = NLPDiagnostics.analyze_degeneracy(
            partially_aligned,
            [0.0, 0.0];
            expected_modes = [partial_mode],
        )
        @test length(
            findings(partial_mode_report, :expected_nullspace_mode_partial_alignment),
        ) == 1
        @test length(
            findings(partial_mode_report, :expected_nullspace_mode_unaligned),
        ) == 1

        extra_freedom = new_model()
        a, b, c = MOI.add_variables(extra_freedom, 3)
        MOI.add_constraint(
            extra_freedom,
            F([T(1.0, a), T(-1.0, b)], 0.0),
            MOI.EqualTo(0.0),
        )
        partial_expected = NLPDiagnostics.ExpectedNullspaceMode(
            :declared_common_shift,
            [a, b],
            [1.0, 1.0],
        )
        extra_freedom_report = NLPDiagnostics.analyze_degeneracy(
            extra_freedom,
            [0.0, 0.0, 0.0];
            expected_modes = [partial_expected],
        )
        @test length(
            findings(extra_freedom_report, :undeclared_observed_nullspace_directions),
        ) == 1
        duplicate_expected_report = NLPDiagnostics.analyze_degeneracy(
            underdetermined,
            [0.0, 0.0];
            expected_modes = [common_shift, NLPDiagnostics.ExpectedNullspaceMode(
                :same_common_shift,
                [x, y],
                [-2.0, -2.0],
            )],
        )
        @test length(
            findings(
                duplicate_expected_report,
                :expected_nullspace_mode_declarations_dependent,
            ),
        ) == 1

        stationary = new_model()
        z = MOI.add_variable(stationary)
        MOI.add_constraint(
            stationary,
            MOI.ScalarNonlinearFunction(:^, Any[z, 2]),
            MOI.EqualTo(0.0),
        )
        local_loss = NLPDiagnostics.analyze_degeneracy(stationary, [0.0])
        finding = only(findings(local_loss, :unexpected_local_rank_loss))
        @test finding.domain == NLPDiagnostics.NumericalIssue
        @test finding.basis == NLPDiagnostics.LocalInference
        @test length(findings(local_loss, :candidate_single_coordinate_null_direction)) == 1
        @test isempty(findings(local_loss, :unknown_local_degeneracy_mode))
        @test local_loss.metadata[:generic_nullspace_fingerprint_count] == "1"

        compact_mode = new_model()
        p, q, r = MOI.add_variables(compact_mode, 3)
        MOI.add_constraint(
            compact_mode,
            F([T(1.0, p)], 0.0),
            MOI.EqualTo(0.0),
        )
        MOI.add_constraint(
            compact_mode,
            F([T(1.0, q), T(-1.0, r)], 0.0),
            MOI.EqualTo(0.0),
        )
        compact_report = NLPDiagnostics.analyze_degeneracy(
            compact_mode,
            [0.0, 0.0, 0.0],
        )
        @test length(
            findings(compact_report, :candidate_compact_coordinate_null_direction),
        ) == 1
        @test compact_report.metadata[:generic_nullspace_max_compact_support] == "8"
        @test_throws ArgumentError NLPDiagnostics.analyze_degeneracy(
            compact_mode,
            [0.0, 0.0, 0.0];
            nullspace_max_compact_support = 1,
        )
        persistent_jacobian_report = NLPDiagnostics.analyze_jacobian_rank_persistence([
            NLPDiagnostics.evaluate_numerical(
                underdetermined,
                NLPDiagnostics.evaluation_point(underdetermined, [0.0, 0.0]; label = "first"),
            ),
            NLPDiagnostics.evaluate_numerical(
                underdetermined,
                NLPDiagnostics.evaluation_point(underdetermined, [2.0, 2.0]; label = "second"),
            ),
        ])
        @test length(
            findings(persistent_jacobian_report, :jacobian_right_nullspace_persistent),
        ) == 1
        persistent_expected_report = NLPDiagnostics.analyze_jacobian_rank_persistence(
            [
                NLPDiagnostics.evaluate_numerical(
                    underdetermined,
                    NLPDiagnostics.evaluation_point(underdetermined, [0.0, 0.0]; label = "first"),
                ),
                NLPDiagnostics.evaluate_numerical(
                    underdetermined,
                    NLPDiagnostics.evaluation_point(underdetermined, [2.0, 2.0]; label = "second"),
                ),
            ];
            expected_modes = [common_shift],
        )
        @test length(
            findings(persistent_expected_report, :persistent_jacobian_expected_mode_observed),
        ) == 1
        @test length(findings(
            persistent_expected_report,
            :persistent_jacobian_expected_mode_span_observed,
        )) == 1
        misaligned_expected_mode = NLPDiagnostics.ExpectedNullspaceMode(
            :misaligned_persistence_mode,
            [x, MOI.VariableIndex(999)],
            [1.0, 1.0],
        )
        misaligned_expected_report = NLPDiagnostics.analyze_jacobian_rank_persistence(
            [
                NLPDiagnostics.evaluate_numerical(
                    underdetermined,
                    NLPDiagnostics.evaluation_point(underdetermined, [0.0, 0.0]; label = "first"),
                ),
                NLPDiagnostics.evaluate_numerical(
                    underdetermined,
                    NLPDiagnostics.evaluation_point(underdetermined, [2.0, 2.0]; label = "second"),
                ),
            ];
            expected_modes = [misaligned_expected_mode],
        )
        misaligned_expected_reasons = NLPDiagnostics.report_data(
            misaligned_expected_report,
        )["unavailable_reasons"]
        @test any(
            item -> item["code"] ==
                "jacobian_expected_mode_persistence_unavailable" &&
                item["category"] == "input" &&
                item["stage"] == "jacobian_expected_mode_persistence",
            misaligned_expected_reasons,
        )
        @test any(
            item -> item["code"] ==
                "jacobian_expected_mode_span_persistence_unavailable" &&
                item["category"] == "input" &&
                item["stage"] == "jacobian_expected_mode_span_persistence",
            misaligned_expected_reasons,
        )
        persistent_unexpected_report = NLPDiagnostics.analyze_jacobian_rank_persistence(
            [
                NLPDiagnostics.evaluate_numerical(
                    underdetermined,
                    NLPDiagnostics.evaluation_point(underdetermined, [0.0, 0.0]; label = "first"),
                ),
                NLPDiagnostics.evaluate_numerical(
                    underdetermined,
                    NLPDiagnostics.evaluation_point(underdetermined, [2.0, 2.0]; label = "second"),
                ),
            ];
            expected_modes = [fixed_difference],
        )
        @test length(
            findings(persistent_unexpected_report, :persistent_jacobian_expected_mode_not_observed),
        ) == 1
        persistent_overspecified_span_report =
            NLPDiagnostics.analyze_jacobian_rank_persistence(
                [
                    NLPDiagnostics.evaluate_numerical(
                        underdetermined,
                        NLPDiagnostics.evaluation_point(underdetermined, [0.0, 0.0]; label = "first"),
                    ),
                    NLPDiagnostics.evaluate_numerical(
                        underdetermined,
                        NLPDiagnostics.evaluation_point(underdetermined, [2.0, 2.0]; label = "second"),
                    ),
                ];
                expected_modes = [common_shift, fixed_difference],
            )
        @test length(findings(
            persistent_overspecified_span_report,
            :persistent_jacobian_expected_mode_span_not_observed,
        )) == 1
        @test_throws ArgumentError NLPDiagnostics.analyze_jacobian_rank_persistence(
            [
                NLPDiagnostics.evaluate_numerical(
                    underdetermined,
                    NLPDiagnostics.evaluation_point(underdetermined, [0.0, 0.0]; label = "first"),
                ),
                NLPDiagnostics.evaluate_numerical(
                    underdetermined,
                    NLPDiagnostics.evaluation_point(underdetermined, [2.0, 2.0]; label = "second"),
                ),
            ];
            expected_modes = [common_shift],
            expected_mode_span_alignment_threshold = 2.0,
        )
        persistent_point_report = NLPDiagnostics.analyze_jacobian_rank_persistence(
            underdetermined,
            [
                NLPDiagnostics.evaluation_point(underdetermined, [0.0, 0.0]; label = "first"),
                NLPDiagnostics.evaluation_point(underdetermined, [2.0, 2.0]; label = "second"),
            ];
            expected_modes = [common_shift],
        )
        @test length(
            findings(persistent_point_report, :persistent_jacobian_expected_mode_observed),
        ) == 1
        stationary_evaluations = [
            NLPDiagnostics.evaluate_numerical(
                stationary,
                NLPDiagnostics.evaluation_point(stationary, [0.0]; label = "stationary"),
            ),
            NLPDiagnostics.evaluate_numerical(
                stationary,
                NLPDiagnostics.evaluation_point(stationary, [1.0]; label = "away"),
            ),
        ]
        changing_jacobian_report = NLPDiagnostics.analyze_jacobian_rank_persistence(
            stationary_evaluations,
        )
        @test length(
            findings(changing_jacobian_report, :jacobian_rank_not_persistent),
        ) == 1
        @test changing_jacobian_report.metadata[
            :derivative_provenance_stable_row_count
        ] == "1"
        combined = NLPDiagnostics.analyze(
            stationary;
            point = NLPDiagnostics.evaluation_point(stationary, [0.0]),
            check_degeneracy = true,
        )
        @test occursin("degeneracy", combined.metadata[:stages])

        duplicate_rows = new_model()
        q = MOI.add_variable(duplicate_rows)
        q_expression = F([T(1.0, q)], 0.0)
        twice_q_expression = F([T(2.0, q)], 0.0)
        MOI.add_constraint(duplicate_rows, q_expression, MOI.EqualTo(0.0))
        MOI.add_constraint(duplicate_rows, twice_q_expression, MOI.EqualTo(0.0))
        dependency = NLPDiagnostics.analyze_degeneracy(duplicate_rows, [0.0])
        @test length(
            findings(dependency, :candidate_two_row_equation_dependence),
        ) == 1
        @test isempty(findings(dependency, :unknown_local_degeneracy_mode))
    end

    @testset "profile cases retain formulation evidence and provenance" begin
        model = new_model()
        x = MOI.add_variable(model)
        MOI.add_constraint(model, x, MOI.EqualTo(0.0))
        point = NLPDiagnostics.evaluation_point(
            model,
            [0.0];
            label = "flat start",
        )
        case = NLPDiagnostics.ProfileCase(
            "unit equality",
            point;
            task = "one-variable equality",
            formulation = "toy-affine",
            initialization = "flat start",
            scale = "unit",
            solver = "Ipopt",
            expected_evidence = [:structural_numerical_rank_agreement],
            tags = [:regression, :profile],
            metadata = Dict("network" => "none"),
        )
        cache = NLPDiagnostics.EvaluationCache()
        result = NLPDiagnostics.profile_case(model, case; cache = cache)
        @test result.case.name == "unit equality"
        @test result.case.formulation == "toy-affine"
        @test result.case.task == "one-variable equality"
        @test result.case.solver == "Ipopt"
        @test result.case.metadata["network"] == "none"
        @test result.evaluation.point == point
        @test result.callback_statistics[:symbolic_stage][1] == 1
        @test result.derivative_row_method_counts[:exact_symbolic] == 1
        @test result.capability_source_counts[:symbolic] == 1
        @test result.cache_misses == 1
        @test result.cache_hits >= 1
        @test all(value -> value >= 0.0, values(result.stage_seconds))
        @test all(value -> value >= 0, values(result.stage_allocations))
        @test haskey(result.stage_seconds, :static)
        @test haskey(result.stage_allocations, :static)
        @test !isempty(result.static_report.findings)
        @test haskey(result.stage_seconds, :expressions)
        @test haskey(result.stage_allocations, :expressions)
        @test isempty(result.expression_report.findings)
        @test haskey(result.stage_allocations, :numerical)
        @test length(
            findings(result.degeneracy_report, :structural_numerical_rank_agreement),
        ) == 1
        result_data = NLPDiagnostics.profile_result_data(result)
        @test haskey(result_data, "unavailable_reasons")
        @test isempty(result_data["unavailable_reasons"])
        guarded_profile = NLPDiagnostics.profile_case(
            model,
            case;
            rank_max_dense_entries = 0,
            sparse_qr_rank_max_input_nonzeros = 0,
            sparse_qr_rank_max_factor_nonzeros = 0,
        )
        guarded_data = NLPDiagnostics.profile_result_data(guarded_profile)
        typed_unavailable = guarded_data["unavailable_reasons"]
        @test !isempty(typed_unavailable)
        @test all(
            entry -> entry["schema_version"] ==
                "nlpdiagnostics-unavailable-reason-v1",
            typed_unavailable,
        )
        @test any(entry -> entry["capability"] == "jacobian_rank", typed_unavailable)
        @test any(entry -> entry["capability"] == "sparse_qr_rank", typed_unavailable)
        sparse_probe_result = NLPDiagnostics.profile_case(
            model,
            case;
            iterative_right_nullspace_probe_dimension = 1,
            iterative_right_nullspace_probe_iterations = 20,
            iterative_left_nullspace_probe_dimension = 1,
            iterative_left_nullspace_probe_iterations = 20,
            iterative_spectrum_probe_dimension = 1,
            iterative_spectrum_probe_iterations = 20,
        )
        @test haskey(
            sparse_probe_result.stage_seconds,
            :iterative_right_nullspace_probe,
        )
        @test haskey(
            sparse_probe_result.stage_allocations,
            :iterative_jacobian_spectrum_probe,
        )
        @test haskey(
            sparse_probe_result.stage_seconds,
            :iterative_left_nullspace_probe,
        )
        @test sparse_probe_result.numerical_report.metadata[
            :iterative_probe_requested_dimension
        ] == "1"
        @test sparse_probe_result.numerical_report.metadata[
            :iterative_spectrum_probe_candidate_count
        ] == "1"
        @test sparse_probe_result.numerical_report.metadata[
            :iterative_left_probe_requested_dimension
        ] == "1"
        @test length(findings(
            sparse_probe_result.numerical_report,
            :iterative_jacobian_no_small_residual_direction,
        )) == 1
        @test length(findings(
            sparse_probe_result.numerical_report,
            :iterative_jacobian_no_large_spectral_spread_proxy,
        )) == 1
        crosscheck_profile_result = NLPDiagnostics.profile_case(
            model,
            case;
            smallest_singular_backend_crosscheck_dimension = 1,
            smallest_singular_backend_crosscheck_restarted_iterations = 5,
            smallest_singular_backend_crosscheck_harmonic_steps_per_seed = 1,
            smallest_singular_backend_crosscheck_harmonic_cycles = 3,
            smallest_singular_backend_crosscheck_max_basis_entries = 100,
            smallest_singular_backend_crosscheck_scaling = :row_column,
            smallest_singular_backend_crosscheck_dense_calibration = true,
            smallest_singular_backend_crosscheck_dense_max_entries = 100,
            check_sparse_qr_nullspace = true,
            sparse_qr_nullspace_dense_calibration = true,
            sparse_qr_nullspace_dense_max_entries = 100,
        )
        @test haskey(crosscheck_profile_result.stage_seconds,
            :smallest_singular_backend_crosscheck)
        @test haskey(crosscheck_profile_result.stage_allocations,
            :smallest_singular_backend_crosscheck)
        @test haskey(crosscheck_profile_result.stage_seconds,
            :smallest_singular_backend_crosscheck_scaling_intervention)
        @test crosscheck_profile_result.numerical_report.metadata[
            :smallest_singular_backend_crosscheck_available
        ] == "true"
        @test haskey(crosscheck_profile_result.numerical_report.metadata,
            :smallest_singular_backend_crosscheck_relation)
        @test haskey(crosscheck_profile_result.stage_seconds,
            :restarted_smallest_singular_dense_calibration)
        @test haskey(crosscheck_profile_result.stage_seconds,
            :harmonic_golub_kahan_dense_calibration)
        @test crosscheck_profile_result.numerical_report.metadata[
            :restarted_dense_calibration_available
        ] == "true"
        @test crosscheck_profile_result.numerical_report.metadata[
            :harmonic_dense_calibration_available
        ] == "true"
        @test crosscheck_profile_result.numerical_report.metadata[
            :smallest_singular_backend_crosscheck_scaling
        ] == "row_column"
        @test crosscheck_profile_result.numerical_report.metadata[
            :smallest_singular_backend_crosscheck_coordinate_system
        ] == "diagonally_transformed_variables"
        @test crosscheck_profile_result.numerical_report.metadata[
            :smallest_singular_backend_crosscheck_model_modified
        ] == "false"
        @test crosscheck_profile_result.numerical_report.metadata[
            :smallest_singular_backend_crosscheck_original_audit_available
        ] == "true"
        @test haskey(crosscheck_profile_result.numerical_report.metadata,
            :smallest_singular_backend_crosscheck_restarted_original_relative_residuals)
        @test haskey(crosscheck_profile_result.numerical_report.metadata,
            :smallest_singular_backend_crosscheck_harmonic_original_relative_residuals)
        @test length(findings(
            crosscheck_profile_result.numerical_report,
            :smallest_singular_backend_crosscheck_scaling_intervention,
        )) == 1
        @test haskey(crosscheck_profile_result.stage_seconds,
            :sparse_qr_nullspace)
        @test haskey(crosscheck_profile_result.stage_seconds,
            :sparse_qr_nullspace_dense_calibration)
        @test crosscheck_profile_result.numerical_report.metadata[
            :sparse_qr_nullspace_available
        ] == "true"
        @test crosscheck_profile_result.numerical_report.metadata[
            :sparse_qr_nullspace_dense_calibration_available
        ] == "true"
        @test_throws ArgumentError NLPDiagnostics.profile_case(
            model, case;
            smallest_singular_backend_crosscheck_dense_calibration = true,
        )
        @test_throws ArgumentError NLPDiagnostics.profile_case(
            model, case;
            sparse_qr_nullspace_dense_calibration = true,
        )
        sweep_profile_result = NLPDiagnostics.profile_case(
            model,
            case;
            jacobian_rank_tolerance_sweep_tolerances = [1.0e-10, 1.0e-6],
        )
        @test haskey(sweep_profile_result.stage_seconds, :jacobian_rank_tolerance_sweep)
        @test sweep_profile_result.numerical_report.metadata[:rank_span] == "0"
        sparse_probe_aggregate = NLPDiagnostics.profile_case_repeated(
            model,
            case;
            repetitions = 2,
            warmup = false,
            iterative_right_nullspace_probe_dimension = 1,
            iterative_right_nullspace_probe_iterations = 20,
            iterative_left_nullspace_probe_dimension = 1,
            iterative_left_nullspace_probe_iterations = 20,
            iterative_spectrum_probe_dimension = 1,
            iterative_spectrum_probe_iterations = 20,
        )
        repeated_probe_directions = only(filter(
            item -> item.metric == :iterative_probe_small_residual_direction_count,
            sparse_probe_aggregate.numerical_summary,
        ))
        @test repeated_probe_directions.available_count == 2
        @test repeated_probe_directions.mean == 0.0
        repeated_left_probe_directions = only(filter(
            item -> item.metric == :iterative_left_probe_small_residual_direction_count,
            sparse_probe_aggregate.numerical_summary,
        ))
        @test repeated_left_probe_directions.available_count == 2
        @test repeated_left_probe_directions.maximum == 0.0
        repeated_probe_spread = only(filter(
            item -> item.metric == :iterative_spectrum_probe_large_spread_count,
            sparse_probe_aggregate.numerical_summary,
        ))
        @test repeated_probe_spread.available_count == 2
        @test repeated_probe_spread.maximum == 0.0
        aggregate = NLPDiagnostics.profile_case_repeated(
            model,
            case;
            repetitions = 2,
            warmup = true,
        )
        @test aggregate.warmup_performed
        @test length(aggregate.runs) == 2
        evaluation_timing = aggregate.stage_timing[:evaluation]
        @test evaluation_timing.sample_count == 2
        @test evaluation_timing.minimum <= evaluation_timing.mean <=
              evaluation_timing.maximum
        @test evaluation_timing.standard_deviation >= 0.0
        evaluation_allocations = aggregate.stage_allocations[:evaluation]
        @test evaluation_allocations.sample_count == 2
        @test evaluation_allocations.minimum <= evaluation_allocations.mean <=
              evaluation_allocations.maximum
        @test evaluation_allocations.standard_deviation >= 0.0
        stable_rank = only(filter(
            item -> item.stage == :degeneracy &&
                    item.code == :structural_numerical_rank_agreement,
            aggregate.finding_stability,
        ))
        @test stable_rank.occurrence_count == 2
        @test stable_rank.fraction == 1.0
        expected_rank = only(aggregate.expected_evidence)
        @test expected_rank.code == :structural_numerical_rank_agreement
        @test expected_rank.occurrence_count == 2
        @test expected_rank.fraction == 1.0
        repeated_rank = only(filter(
            item -> item.metric == :jacobian_rank,
            aggregate.numerical_summary,
        ))
        @test repeated_rank.run_count == 2
        @test repeated_rank.available_count == 2
        @test repeated_rank.minimum == 1.0
        @test repeated_rank.mean == 1.0
        @test repeated_rank.maximum == 1.0
        repeated_proxy = only(filter(
            item -> item.metric == :sparse_qr_condition_proxy,
            aggregate.numerical_summary,
        ))
        @test repeated_proxy.available_count == 2
        @test repeated_proxy.minimum == 1.0
        unmet_case = NLPDiagnostics.ProfileCase(
            "unmet profile expectation",
            point;
            task = "one-variable equality",
            expected_evidence = [:never_emitted],
        )
        unmet = NLPDiagnostics.profile_case_repeated(
            model,
            unmet_case;
            repetitions = 1,
            warmup = false,
        )
        unmet_expectation = only(unmet.expected_evidence)
        @test unmet_expectation.code == :never_emitted
        @test unmet_expectation.occurrence_count == 0
        @test unmet_expectation.fraction == 0.0
        comparison = NLPDiagnostics.compare_profiles(aggregate, unmet)
        @test comparison.baseline === aggregate
        @test comparison.candidate === unmet
        @test comparison.task_relation == :declared_same_task
        @test comparison.task == "one-variable equality"
        evaluation_comparison = only(filter(
            item -> item.stage == :evaluation,
            comparison.stage_comparisons,
        ))
        @test evaluation_comparison.baseline_seconds >= 0.0
        @test evaluation_comparison.candidate_seconds >= 0.0
        @test evaluation_comparison.baseline_allocations >= 0.0
        @test evaluation_comparison.candidate_allocations >= 0.0
        @test any(
            item -> item.code == :structural_numerical_rank_agreement &&
                    item.baseline_fraction == 1.0 && item.candidate_fraction == 1.0,
            comparison.finding_comparisons,
        )
        rank_comparison = only(filter(
            item -> item.metric == :jacobian_rank,
            comparison.numerical_comparisons,
        ))
        @test rank_comparison.baseline_available_count == 2
        @test rank_comparison.candidate_available_count == 1
        @test rank_comparison.baseline_mean == 1.0
        @test rank_comparison.candidate_mean == 1.0
        @test rank_comparison.mean_difference == 0.0
        @test rank_comparison.mean_ratio == 1.0
        different_task = NLPDiagnostics.profile_case_repeated(
            model,
            NLPDiagnostics.ProfileCase("different task", point; task = "different"),
            repetitions = 1,
            warmup = false,
        )
        @test NLPDiagnostics.compare_profiles(aggregate, different_task).task_relation ==
              :declared_different_task
        @test_throws ArgumentError NLPDiagnostics.profile_case_repeated(
            model,
            case;
            repetitions = 0,
        )
    end

    @testset "explicit activity, LICQ, and MFCQ screens" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        MOI.add_constraint(model, x, MOI.EqualTo(0.0))
        MOI.add_constraint(model, y, MOI.GreaterThan(0.0))
        evaluation = NLPDiagnostics.evaluate_numerical(
            model,
            [0.0, 1.0e-8];
            relative_step = 1.0e-6,
        )
        summary = NLPDiagnostics.constraint_feasibility_summary(
            model,
            evaluation;
            feasibility_tolerance = 1.0e-7,
            active_tolerance = 1.0e-7,
        )
        @test summary.complete
        @test [activity.classification for activity in summary.activities] ==
              [:equality, :active_lower]
        @test NLPDiagnostics.active_constraint_rows(summary) == [1, 2]
        weak_evaluation = NLPDiagnostics.evaluate_numerical(
            model,
            [0.0, 5.0e-7];
            relative_step = 1.0e-6,
        )
        weak_report = NLPDiagnostics.analyze_weak_activity(
            model,
            weak_evaluation;
            feasibility_tolerance = 1.0e-7,
            active_tolerance = 1.0e-7,
            weak_activity_tolerance = 1.0e-6,
        )
        @test weak_report.metadata[:weak_activity_row_count] == "1"
        @test length(findings(weak_report, :weak_activity_detected)) == 1
        weak_persistence = NLPDiagnostics.analyze_weak_activity_persistence(
            model,
            [
                weak_evaluation,
                NLPDiagnostics.evaluate_numerical(
                    model,
                    [0.0, 6.0e-7];
                    relative_step = 1.0e-6,
                ),
            ];
            feasibility_tolerance = 1.0e-7,
            active_tolerance = 1.0e-7,
            weak_activity_tolerance = 1.0e-6,
        )
        @test weak_persistence.metadata[:weak_activity_persistence_classification] ==
              "weak_activity_persistent"
        screen = NLPDiagnostics.mfcq_screen(
            evaluation,
            summary;
            strict_tolerance = 1.0e-10,
        )
        @test screen.available
        @test screen.direction_found
        report = NLPDiagnostics.analyze_active_set(
            model,
            evaluation;
            feasibility_tolerance = 1.0e-7,
            active_tolerance = 1.0e-7,
            mfcq_strict_tolerance = 1.0e-10,
        )
        @test isempty(findings(report, :active_constraint_licq_failure))
        @test length(findings(report, :mfcq_common_descent_direction_found)) == 1
        descent_finding = only(findings(
            report, :mfcq_common_descent_direction_found,
        ))
        @test Dict(descent_finding.evidence[end].details)[
            "material_direction_variables"
        ] == string(y.value)
        @test Dict(descent_finding.evidence[end].details)[
            "material_witness_rows"
        ] == "2"

        tangent_shift = new_model()
        t1, t2 = MOI.add_variables(tangent_shift, 2)
        MOI.add_constraint(
            tangent_shift,
            MOI.ScalarAffineFunction([
                MOI.ScalarAffineTerm(1.0, t1),
                MOI.ScalarAffineTerm(-1.0, t2),
            ], 0.0),
            MOI.EqualTo(0.0),
        )
        tangent_report = NLPDiagnostics.analyze_active_set(tangent_shift, [0.0, 0.0])
        @test length(findings(
            tangent_report,
            :active_candidate_uniform_tangent_shift,
        )) == 1
        active_common_shift = NLPDiagnostics.ExpectedNullspaceMode(
            :active_common_shift,
            [t1, t2],
            [1.0, 1.0],
            description = "active common-coordinate shift",
        )
        expected_tangent_report = NLPDiagnostics.analyze_active_set(
            tangent_shift,
            [0.0, 0.0];
            expected_modes = [active_common_shift],
        )
        @test length(findings(
            expected_tangent_report,
            :active_expected_nullspace_mode_observed,
        )) == 1
        extra_tangent = new_model()
        e1, e2, e3 = MOI.add_variables(extra_tangent, 3)
        MOI.add_constraint(
            extra_tangent,
            MOI.ScalarAffineFunction([
                MOI.ScalarAffineTerm(1.0, e1),
                MOI.ScalarAffineTerm(-1.0, e2),
            ], 0.0),
            MOI.EqualTo(0.0),
        )
        declared_tangent = NLPDiagnostics.ExpectedNullspaceMode(
            :declared_tangent,
            [e1, e2],
            [1.0, 1.0],
        )
        extra_tangent_report = NLPDiagnostics.analyze_active_set(
            extra_tangent,
            [0.0, 0.0, 0.0];
            expected_modes = [declared_tangent],
        )
        @test length(findings(
            extra_tangent_report,
            :active_candidate_compact_tangent_direction,
        )) == 1
        @test length(findings(
            extra_tangent_report,
            :active_undeclared_tangent_directions,
        )) == 1
        @test length(findings(
            extra_tangent_report,
            :active_expected_nullspace_span_does_not_cover_observed,
        )) == 1
        overdeclared_model = new_model()
        overdeclared_x, overdeclared_y = MOI.add_variables(overdeclared_model, 2)
        MOI.add_constraint(
            overdeclared_model,
            MOI.ScalarAffineFunction([
                MOI.ScalarAffineTerm(1.0e-9, overdeclared_x),
                MOI.ScalarAffineTerm(-1.0e-9, overdeclared_y),
            ], 0.0),
            MOI.EqualTo(0.0),
        )
        overdeclared_tangent = NLPDiagnostics.ExpectedNullspaceMode(
            :overdeclared_tangent,
            [overdeclared_x, overdeclared_y],
            [1.0, -1.0],
        )
        scaled_declared_tangent = NLPDiagnostics.ExpectedNullspaceMode(
            :scaled_declared_tangent,
            [overdeclared_x, overdeclared_y],
            [1.0, 1.0],
        )
        overdeclared_tangent_report = NLPDiagnostics.analyze_active_set(
            overdeclared_model,
            [0.0, 0.0];
            expected_modes = [scaled_declared_tangent, overdeclared_tangent],
        )
        @test length(findings(
            overdeclared_tangent_report,
            :active_expected_nullspace_span_exceeds_observed,
        )) == 1
        @test length(findings(
            extra_tangent_report,
            :active_structurally_expected_tangent_nullspace,
        )) == 1
        active_stationary = new_model()
        stationary_variable = MOI.add_variable(active_stationary)
        MOI.add_constraint(
            active_stationary,
            MOI.ScalarNonlinearFunction(:^, Any[stationary_variable, 2]),
            MOI.EqualTo(0.0),
        )
        stationary_active_report = NLPDiagnostics.analyze_active_set(
            active_stationary,
            [0.0],
        )
        @test length(findings(
            stationary_active_report,
            :active_unexpected_local_tangent_rank_loss,
        )) == 1
        @test length(findings(
            stationary_active_report,
            :active_candidate_single_coordinate_tangent_direction,
        )) == 1
        stationary_coordinate_fingerprint = only(findings(
            stationary_active_report,
            :active_candidate_single_coordinate_tangent_direction,
        ))
        @test parse(Float64, Dict(
            stationary_coordinate_fingerprint.evidence[end].details,
        )["variable"]) == stationary_variable.value
        combined = NLPDiagnostics.analyze(
            model;
            point = evaluation.point,
            check_active_set = true,
        )
        @test occursin("active_set", combined.metadata[:stages])

        infeasible = NLPDiagnostics.analyze_active_set(
            model,
            [0.0, -0.1];
            feasibility_tolerance = 1.0e-7,
            active_tolerance = 1.0e-7,
        )
        @test length(findings(infeasible, :constraint_feasibility_violation)) == 1

        opposing = new_model()
        z = MOI.add_variable(opposing)
        MOI.add_constraint(opposing, z, MOI.GreaterThan(0.0))
        MOI.add_constraint(opposing, z, MOI.LessThan(0.0))
        opposing_evaluation = NLPDiagnostics.evaluate_numerical(opposing, [0.0])
        opposing_summary = NLPDiagnostics.constraint_feasibility_summary(
            opposing,
            opposing_evaluation,
        )
        opposing_screen = NLPDiagnostics.mfcq_screen(
            opposing_evaluation,
            opposing_summary;
            strict_tolerance = 1.0e-10,
        )
        @test opposing_screen.available
        @test !opposing_screen.direction_found
        @test opposing_screen.failure_witness_found
        @test opposing_screen.failure_witness_residual < 1.0e-10
        @test opposing_screen.failure_witness_projected_gradient_scale ≈ 1.0
        @test opposing_screen.failure_witness_effective_tolerance ≈ sqrt(eps())
        @test opposing_screen.failure_witness_iterations > 0
        opposing_report = NLPDiagnostics.analyze_active_set(opposing, [0.0])
        @test length(findings(opposing_report, :mfcq_no_common_descent_witness)) == 1
        @test parse(Float64, Dict(only(findings(
            opposing_report, :mfcq_no_common_descent_witness,
        )).evidence[end].details)["witness_weight_sum"]) ≈ 1.0
        opposing_witness = only(findings(
            opposing_report, :mfcq_no_common_descent_witness,
        ))
        @test Dict(opposing_witness.evidence[end].details)[
            "material_support_rows"
        ] == "1,2"
        @test haskey(
            Dict(opposing_witness.evidence[end].details),
            "effective_witness_tolerance",
        )
        @test NLPDiagnostics.analyze_active_set(
            opposing, [0.0]; mfcq_support_relative = 0.5,
        ).metadata[:mfcq_support_relative] == "0.5"
        @test_throws ArgumentError NLPDiagnostics.analyze_active_set(
            opposing, [0.0]; mfcq_support_relative = 0,
        )

        unbalanced_descent = new_model()
        ux, uy = MOI.add_variables(unbalanced_descent, 2)
        MOI.add_constraint(
            unbalanced_descent,
            MOI.ScalarAffineFunction([
                MOI.ScalarAffineTerm(-1.0, ux),
                MOI.ScalarAffineTerm(1000.0, uy),
            ], 0.0),
            MOI.LessThan(0.0),
        )
        MOI.add_constraint(
            unbalanced_descent,
            MOI.ScalarAffineFunction([
                MOI.ScalarAffineTerm(-1.0, ux),
                MOI.ScalarAffineTerm(-999.0, uy),
            ], 0.0),
            MOI.LessThan(0.0),
        )
        unbalanced_evaluation = NLPDiagnostics.evaluate_numerical(
            unbalanced_descent, [0.0, 0.0],
        )
        unbalanced_summary = NLPDiagnostics.constraint_feasibility_summary(
            unbalanced_descent, unbalanced_evaluation,
        )
        unbalanced_screen = NLPDiagnostics.mfcq_screen(
            unbalanced_evaluation,
            unbalanced_summary;
            strict_tolerance = 1.0e-10,
        )
        @test unbalanced_screen.available
        @test unbalanced_screen.direction_found
        @test unbalanced_screen.largest_active_inequality_directional_derivative < 0
        limited_mfcq_report = NLPDiagnostics.analyze_active_set(
            unbalanced_descent,
            unbalanced_evaluation;
            mfcq_witness_max_iterations = 1,
            mfcq_strict_tolerance = 1.0e-10,
        )
        @test limited_mfcq_report.metadata[
            :mfcq_witness_max_iterations
        ] == "1"
        @test haskey(limited_mfcq_report.metadata, :mfcq_witness_converged)
        scaled_witness_report = NLPDiagnostics.analyze_active_set(
            unbalanced_descent,
            unbalanced_evaluation;
            mfcq_witness_relative_tolerance = 1.0e-6,
        )
        @test scaled_witness_report.metadata[
            :mfcq_witness_relative_tolerance
        ] == "1.0e-6"
        @test_throws ArgumentError NLPDiagnostics.mfcq_screen(
            unbalanced_evaluation,
            unbalanced_summary;
            witness_relative_tolerance = -1.0,
        )

        rank_deficient_mfcq = new_model()
        rank_deficient_variable = MOI.add_variable(rank_deficient_mfcq)
        MOI.add_constraint(
            rank_deficient_mfcq,
            MOI.ScalarNonlinearFunction(:^, Any[rank_deficient_variable, 2]),
            MOI.EqualTo(0.0),
        )
        MOI.add_constraint(
            rank_deficient_mfcq,
            rank_deficient_variable,
            MOI.GreaterThan(0.0),
        )
        rank_deficient_mfcq_report = NLPDiagnostics.analyze_active_set(
            rank_deficient_mfcq, [0.0],
        )
        @test isempty(findings(
            rank_deficient_mfcq_report, :mfcq_screen_inconclusive,
        ))
        @test length(findings(
            rank_deficient_mfcq_report, :mfcq_equality_jacobian_rank_deficient,
        )) == 1
        @test Dict(only(findings(
            rank_deficient_mfcq_report, :mfcq_equality_jacobian_rank_deficient,
        )).evidence[end].details)["equality_jacobian_rank"] == "0"
        @test Dict(only(findings(
            rank_deficient_mfcq_report, :mfcq_equality_jacobian_rank_deficient,
        )).evidence[end].details)["equality_derivative_methods"] ==
              "exact_constructed_nonlinear_ad"
        @test occursin(
            "rank deficient", rank_deficient_mfcq_report.metadata[:mfcq_screen_reason],
        )
        @test rank_deficient_mfcq_report.metadata[:mfcq_equality_jacobian_rank] ==
              "0"
        guarded_mfcq_report = NLPDiagnostics.analyze_active_set(
            rank_deficient_mfcq,
            [0.0];
            rank_max_dense_entries = 0,
        )
        @test guarded_mfcq_report.metadata[:mfcq_screen_available] == "false"
        guarded_mfcq_data = NLPDiagnostics.report_data(guarded_mfcq_report)
        guarded_mfcq_reason = only(filter(
            item -> item["code"] == "mfcq_screen_unavailable",
            guarded_mfcq_data["unavailable_reasons"],
        ))
        @test guarded_mfcq_reason["category"] == "numerical"
        @test guarded_mfcq_reason["stage"] == "active_set_mfcq_screen"
        guarded_rank_reason = only(filter(
            item -> item["code"] == "active_jacobian_rank_unavailable",
            guarded_mfcq_data["unavailable_reasons"],
        ))
        @test guarded_rank_reason["category"] == "numerical"
        @test guarded_rank_reason["stage"] == "active_set_rank"

        # NLP-block rows are numerically evaluable but have no ordinary MOI
        # incidence nodes. The active structural view must expose both the
        # alignment boundary and its dependent DM-partition boundary through
        # the typed unavailable-reason schema.
        callback_active_model = new_model()
        MOI.add_variables(callback_active_model, 2)
        MOI.set(callback_active_model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        MOI.set(
            callback_active_model,
            MOI.NLPBlock(),
            MOI.NLPBlockData(
                MOI.NLPBoundsPair.([0.0, 0.0], [0.0, 0.0]),
                TestNLPEvaluator(),
                true,
            ),
        )
        callback_active_evaluation = NLPDiagnostics.evaluate_numerical(
            callback_active_model, [0.0, 0.0],
        )
        callback_active_report = NLPDiagnostics.analyze_active_set(
            callback_active_model, callback_active_evaluation,
        )
        @test callback_active_report.metadata[
            :active_structural_matching_available
        ] == "false"
        @test callback_active_report.metadata[:active_dm_partition_available] == "false"
        callback_active_data = NLPDiagnostics.report_data(callback_active_report)
        callback_matching_reason = only(filter(
            item -> item["code"] == "active_structural_matching_unavailable",
            callback_active_data["unavailable_reasons"],
        ))
        @test callback_matching_reason["category"] == "capability"
        @test callback_matching_reason["stage"] == "active_set_structural_matching"
        callback_dm_reason = only(filter(
            item -> item["code"] == "active_dm_partition_unavailable",
            callback_active_data["unavailable_reasons"],
        ))
        @test callback_dm_reason["category"] == "capability"
        @test callback_dm_reason["stage"] == "active_set_dm_partition"

        dependent = new_model()
        z = MOI.add_variable(dependent)
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        z_expression = F([T(1.0, z)], 0.0)
        MOI.add_constraint(dependent, z_expression, MOI.EqualTo(0.0))
        MOI.add_constraint(dependent, z_expression, MOI.GreaterThan(0.0))
        dependent_report = NLPDiagnostics.analyze_active_set(
            dependent,
            [0.0];
            active_tolerance = 1.0e-7,
        )
        @test length(findings(dependent_report, :active_constraint_licq_failure)) == 1
        @test length(findings(
            dependent_report,
            :active_candidate_two_row_dependence,
        )) == 1

        dependent_cluster = new_model()
        p, q = MOI.add_variables(dependent_cluster, 2)
        MOI.add_constraint(dependent_cluster, p, MOI.EqualTo(0.0))
        MOI.add_constraint(dependent_cluster, q, MOI.EqualTo(0.0))
        MOI.add_constraint(
            dependent_cluster,
            MOI.ScalarAffineFunction([
                T(1.0, p),
                T(1.0, q),
            ], 0.0),
            MOI.EqualTo(0.0),
        )
        cluster_report = NLPDiagnostics.analyze_active_set(dependent_cluster, [0.0, 0.0])
        @test length(findings(
            cluster_report,
            :active_candidate_multirow_dependence,
        )) == 1

        dual_model = new_model()
        d = MOI.add_variable(dual_model)
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        expression = F([T(1.0, d)], 0.0)
        MOI.set(dual_model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        MOI.set(dual_model, MOI.ObjectiveFunction{F}(), expression)
        MOI.add_constraint(dual_model, expression, MOI.EqualTo(1.0))
        MOI.add_constraint(dual_model, expression, MOI.GreaterThan(1.0))
        dual_evaluation = NLPDiagnostics.evaluate_numerical(dual_model, [1.0])
        dual_summary = NLPDiagnostics.constraint_feasibility_summary(dual_model, dual_evaluation)
        recovery = NLPDiagnostics.recover_stationarity_multipliers(
            dual_model,
            dual_evaluation,
            dual_summary,
        )
        @test recovery.available
        @test !recovery.unique
        @test recovery.stationarity_residual_norm ≈ 0.0 atol = 1.0e-12
        active_matching = NLPDiagnostics.active_set_matching(
            dual_model,
            dual_evaluation,
            dual_summary,
        )
        @test active_matching.complete
        @test active_matching.selected_rows == [1, 2]
        @test NLPDiagnostics.matching_cardinality(active_matching.matching) == 1
        active_decomposition = NLPDiagnostics.active_set_structural_decomposition(
            dual_model, dual_evaluation, dual_summary,
        )
        @test active_decomposition.matching == active_matching
        @test active_decomposition.partition isa NLPDiagnostics.DulmageMendelsohnPartition
        dual_report = NLPDiagnostics.analyze_active_set(dual_model, dual_evaluation)
        @test length(findings(dual_report, :nonunique_active_multipliers)) == 1
        dual_multiplier_finding = only(findings(
            dual_report, :nonunique_active_multipliers,
        ))
        @test haskey(
            Dict(dual_multiplier_finding.evidence[end].details),
            "minimum_norm_multipliers",
        )
        @test Dict(dual_multiplier_finding.evidence[end].details)[
            "relative_support_threshold"
        ] == "0.001"
        @test Dict(dual_multiplier_finding.evidence[end].details)[
            "objective_gradient_method"
        ] == "exact_symbolic"
        custom_multiplier_report = NLPDiagnostics.analyze_active_set(
            dual_model, dual_evaluation; multiplier_support_relative = 0.5,
        )
        custom_multiplier_finding = only(findings(
            custom_multiplier_report, :nonunique_active_multipliers,
        ))
        @test Dict(custom_multiplier_finding.evidence[end].details)[
            "relative_support_threshold"
        ] == "0.5"
        @test custom_multiplier_report.metadata[
            :multiplier_support_relative
        ] == "0.5"
        @test_throws ArgumentError NLPDiagnostics.analyze_active_set(
            dual_model, dual_evaluation; multiplier_support_relative = 0.0,
        )
        @test length(
            findings(dual_report, :active_set_structural_overdetermination),
        ) == 1
        @test length(findings(dual_report, :active_set_dm_overdetermined_region)) == 1
        @test length(findings(
            dual_report,
            :active_set_dm_overdetermined_region_left_nullspace_support,
        )) == 1

        overdetermined_rank_loss = new_model()
        over_rank_x = MOI.add_variable(overdetermined_rank_loss)
        over_rank_expression = MOI.ScalarNonlinearFunction(:^, Any[over_rank_x, 2])
        MOI.add_constraint(
            overdetermined_rank_loss, over_rank_expression, MOI.EqualTo(0.0),
        )
        MOI.add_constraint(
            overdetermined_rank_loss, over_rank_expression, MOI.GreaterThan(0.0),
        )
        overdetermined_rank_loss_report = NLPDiagnostics.analyze_active_set(
            overdetermined_rank_loss, [0.0],
        )
        @test length(findings(
            overdetermined_rank_loss_report,
            :active_set_dm_overdetermined_region_additional_left_nullity,
        )) == 1
        @test dual_report.metadata[:active_structural_matching_cardinality] == "1"
        @test dual_report.metadata[:active_structural_aligned_row_count] == "2"
        @test dual_report.metadata[:active_dm_partition_available] == "true"
        @test dual_report.metadata[:active_dm_overdetermined_row_count] == "2"

        # A numerical rank above an asserted structural matching rank is not
        # interpreted as removed mathematical freedom: it exposes an invalid
        # structural/numerical alignment or derivative-pattern claim.
        inconsistent_structural_matching = NLPDiagnostics.StructuralMatching(
            [0], [0], [1], [1], true,
        )
        inconsistent_active_matching = NLPDiagnostics.ActiveSetStructuralMatching(
            inconsistent_structural_matching, [1], [1], [1], Int[], true, nothing,
        )
        inconsistent_tangent = NLPDiagnostics._active_structural_numerical_tangent_findings(
            dual_model, dual_evaluation, inconsistent_active_matching;
            rank_relative_tolerance = 1e-12,
            rank_max_dense_entries = 100,
        )
        @test only(inconsistent_tangent).code ==
              :active_structural_numerical_pattern_inconsistency

        unavailable_matching = NLPDiagnostics.ActiveSetStructuralMatching(
            active_matching.matching,
            active_matching.selected_rows,
            active_matching.aligned_rows,
            active_matching.selected_constraint_positions,
            [2],
            false,
            "selected rows do not align with ordinary scalar incidence nodes",
        )
        unavailable = only(NLPDiagnostics._active_matching_findings(
            dual_model,
            dual_evaluation,
            unavailable_matching,
        ))
        @test unavailable.code == :active_set_structural_matching_unavailable
        @test unavailable.basis == NLPDiagnostics.LocalInference
        @test Dict(unavailable.evidence[end].details)["unmapped_activity_rows"] == "2"

        underdetermined_active = new_model()
        underdetermined_x, underdetermined_y = MOI.add_variables(underdetermined_active, 2)
        underdetermined_expression = MOI.ScalarAffineFunction(
            [MOI.ScalarAffineTerm(1.0, underdetermined_x)], 0.0,
        )
        MOI.add_constraint(underdetermined_active, underdetermined_expression, MOI.EqualTo(0.0))
        underdetermined_evaluation = NLPDiagnostics.evaluate_numerical(
            underdetermined_active, [0.0, 0.0],
        )
        underdetermined_summary = NLPDiagnostics.constraint_feasibility_summary(
            underdetermined_active, underdetermined_evaluation,
        )
        underdetermined_matching = NLPDiagnostics.active_set_matching(
            underdetermined_active, underdetermined_evaluation, underdetermined_summary,
        )
        underdetermined = only(filter(
            finding -> finding.code == :active_set_structural_underdetermination,
            NLPDiagnostics._active_matching_findings(
                underdetermined_active, underdetermined_evaluation, underdetermined_matching,
            ),
        ))
        @test underdetermined.code == :active_set_structural_underdetermination
        @test underdetermined.confidence == NLPDiagnostics.ConfidenceHigh
        @test length(findings(
            NLPDiagnostics.analyze_active_set(
                underdetermined_active, underdetermined_evaluation,
            ),
            :active_set_dm_underdetermined_region,
        )) == 1
        @test length(findings(
            NLPDiagnostics.analyze_active_set(
                underdetermined_active, underdetermined_evaluation,
            ),
            :active_set_dm_underdetermined_region_right_nullspace_support,
        )) == 1

        underdetermined_rank_loss = new_model()
        under_rank_x, under_rank_y = MOI.add_variables(
            underdetermined_rank_loss, 2,
        )
        MOI.add_constraint(
            underdetermined_rank_loss,
            MOI.ScalarNonlinearFunction(
                :-,
                Any[
                    MOI.ScalarNonlinearFunction(:^, Any[under_rank_x, 2]),
                    MOI.ScalarNonlinearFunction(:^, Any[under_rank_y, 2]),
                ],
            ),
            MOI.EqualTo(0.0),
        )
        underdetermined_rank_loss_report = NLPDiagnostics.analyze_active_set(
            underdetermined_rank_loss, [0.0, 0.0],
        )
        @test length(findings(
            underdetermined_rank_loss_report,
            :active_set_dm_underdetermined_region_additional_rank_loss,
        )) == 1

        # A direct VariableIndex equality is an MOI variable-domain declaration.
        # It fixes x, so it is outside the free-variable incidence matching
        # scope rather than an unmapped ordinary equation row.
        domain_active = new_model()
        domain_x, domain_y = MOI.add_variables(domain_active, 2)
        MOI.add_constraint(domain_active, domain_x, MOI.EqualTo(0.0))
        domain_evaluation = NLPDiagnostics.evaluate_numerical(
            domain_active, [0.0, 0.0],
        )
        domain_summary = NLPDiagnostics.constraint_feasibility_summary(
            domain_active, domain_evaluation,
        )
        domain_matching = NLPDiagnostics.active_set_matching(
            domain_active, domain_evaluation, domain_summary,
        )
        @test domain_matching.complete
        @test domain_matching.selected_rows == [1]
        @test isempty(domain_matching.aligned_rows)
        @test isempty(domain_matching.selected_constraint_positions)
        @test isempty(domain_matching.unmapped_rows)
        domain_findings = NLPDiagnostics._active_matching_findings(
            domain_active, domain_evaluation, domain_matching,
        )
        domain_underdetermination = only(filter(
            finding -> finding.code == :active_set_structural_underdetermination,
            domain_findings,
        ))
        @test domain_underdetermination.code == :active_set_structural_underdetermination
        @test Dict(domain_underdetermination.evidence[end].details)[
            "excluded_nonfree_variable_domain_rows"
        ] == "1"

        bound_active = new_model()
        bound_x = MOI.add_variable(bound_active)
        MOI.add_constraint(bound_active, bound_x, MOI.GreaterThan(0.0))
        bound_evaluation = NLPDiagnostics.evaluate_numerical(bound_active, [0.0])
        bound_summary = NLPDiagnostics.constraint_feasibility_summary(
            bound_active, bound_evaluation,
        )
        bound_matching = NLPDiagnostics.active_set_matching(
            bound_active, bound_evaluation, bound_summary,
        )
        @test bound_matching.complete
        @test bound_matching.aligned_rows == [1]
        @test bound_matching.selected_constraint_positions == [1]
        @test NLPDiagnostics.matching_cardinality(bound_matching.matching) == 1

        block_active = new_model()
        block_x, block_y = MOI.add_variables(block_active, 2)
        block_x_row = MOI.ScalarAffineFunction(
            [MOI.ScalarAffineTerm(1.0, block_x)], 0.0,
        )
        block_y_row = MOI.ScalarAffineFunction(
            [MOI.ScalarAffineTerm(1.0, block_y)], 0.0,
        )
        MOI.add_constraint(block_active, block_x_row, MOI.EqualTo(0.0))
        MOI.add_constraint(block_active, block_y_row, MOI.EqualTo(0.0))
        block_report = NLPDiagnostics.analyze_active_set(block_active, [0.0, 0.0])
        @test length(findings(
            block_report, :active_set_dm_well_determined_blocks,
        )) == 1
        @test block_report.metadata[:active_dm_well_determined_block_count] == "2"
        block_evaluation_for_decomposition = NLPDiagnostics.evaluate_numerical(
            block_active, [0.0, 0.0],
        )
        block_summary_for_decomposition = NLPDiagnostics.constraint_feasibility_summary(
            block_active, block_evaluation_for_decomposition,
        )
        block_decomposition = NLPDiagnostics.active_set_structural_decomposition(
            block_active,
            block_evaluation_for_decomposition,
            block_summary_for_decomposition,
        )
        @test length(block_decomposition.well_determined_blocks) == 2
        active_graph_data = NLPDiagnostics.structural_graph_data(
            block_active, block_decomposition,
        )
        @test active_graph_data.complete
        @test count(node -> node.block == 1, active_graph_data.variables) == 1
        @test count(node -> node.block == 2, active_graph_data.variables) == 1
        @test occursin(
            "dm=well",
            NLPDiagnostics.structural_graph_text(block_active, block_decomposition),
        )
        @test occursin(
            "NLPDiagnostics structural graph",
            NLPDiagnostics.structural_graph_dot(block_active, block_decomposition),
        )
        @test length(
            NLPDiagnostics.active_set_structural_decomposition(
                block_active, [0.0, 0.0],
            ).well_determined_blocks,
        ) == 2
        block_evaluation = NLPDiagnostics.evaluate_numerical(
            block_active, [0.0, 0.0],
        )
        finite_difference_block_evaluation = NLPDiagnostics.NumericalEvaluation{Float64}(
            block_evaluation.point,
            block_evaluation.objective_value,
            block_evaluation.objective_source,
            block_evaluation.objective_gradient,
            block_evaluation.constraint_values,
            block_evaluation.constraint_sources,
            block_evaluation.jacobian_entries,
            [:central_finite_difference, :exact_symbolic],
            block_evaluation.capabilities,
            block_evaluation.failures,
        )
        finite_difference_block_report = NLPDiagnostics.analyze_active_set(
            block_active, finite_difference_block_evaluation,
        )
        numerical_provenance = NLPDiagnostics._jacobian_derivative_provenance_findings(
            finite_difference_block_evaluation,
        )
        @test length(filter(
            finding -> finding.code == :mixed_jacobian_derivative_provenance,
            numerical_provenance,
        )) == 1
        @test length(filter(
            finding -> finding.code == :finite_difference_jacobian_derivatives,
            numerical_provenance,
        )) == 1
        finite_difference_objective_evaluation = NLPDiagnostics.NumericalEvaluation{Float64}(
            block_evaluation.point,
            block_evaluation.objective_value,
            block_evaluation.objective_source,
            block_evaluation.objective_gradient,
            block_evaluation.constraint_values,
            block_evaluation.constraint_sources,
            block_evaluation.jacobian_entries,
            block_evaluation.jacobian_row_methods,
            block_evaluation.capabilities,
            block_evaluation.failures,
            block_evaluation.call_statistics,
            :central_finite_difference,
        )
        objective_provenance = NLPDiagnostics._jacobian_derivative_provenance_findings(
            finite_difference_objective_evaluation,
        )
        @test length(filter(
            finding -> finding.code == :finite_difference_objective_gradient,
            objective_provenance,
        )) == 1
        supplied_evaluation_report = NLPDiagnostics.analyze_numerical(
            block_active, finite_difference_objective_evaluation,
        )
        @test length(findings(
            supplied_evaluation_report, :finite_difference_objective_gradient,
        )) == 1
        @test supplied_evaluation_report.metadata[:objective_gradient_method] ==
              "central_finite_difference"
        supplied_combined_report = NLPDiagnostics.analyze(
            block_active;
            evaluation = finite_difference_objective_evaluation,
            check_active_set = true,
        )
        @test occursin("numerical,active_set", supplied_combined_report.metadata[:stages])
        @test length(findings(
            supplied_combined_report, :finite_difference_objective_gradient,
        )) == 1
        @test_throws ArgumentError NLPDiagnostics.analyze(
            block_active;
            point = block_evaluation.point,
            evaluation = finite_difference_objective_evaluation,
        )
        @test length(findings(
            finite_difference_block_report,
            :active_set_finite_difference_derivatives,
        )) == 1
        @test length(findings(
            finite_difference_block_report,
            :active_set_mixed_derivative_provenance,
        )) == 1
        @test finite_difference_block_report.metadata[
            :active_derivative_method_count
        ] == "2"
        @test finite_difference_block_report.metadata[
            :active_derivative_row_method_counts
        ] == "central_finite_difference=1,exact_symbolic=1"
        @test finite_difference_block_report.metadata[
            :active_central_finite_difference_row_count
        ] == "1"
        @test length(findings(
            finite_difference_block_report,
            :active_set_well_determined_block_finite_difference_derivatives,
        )) == 1
        # Each well-determined block contains one row. The full active set
        # mixes derivative sources, but no individual block does.
        @test isempty(findings(
            finite_difference_block_report,
            :active_set_well_determined_block_mixed_derivative_provenance,
        ))
        partial_finite_difference_block_evaluation = NLPDiagnostics.NumericalEvaluation{Float64}(
            block_evaluation.point,
            block_evaluation.objective_value,
            block_evaluation.objective_source,
            block_evaluation.objective_gradient,
            block_evaluation.constraint_values,
            block_evaluation.constraint_sources,
            block_evaluation.jacobian_entries,
            [:partial_central_finite_difference, :exact_symbolic],
            block_evaluation.capabilities,
            block_evaluation.failures,
        )
        partial_finite_difference_block_report = NLPDiagnostics.analyze_active_set(
            block_active, partial_finite_difference_block_evaluation,
        )
        @test length(findings(
            partial_finite_difference_block_report,
            :active_set_partial_finite_difference_derivatives,
        )) == 1
        @test partial_finite_difference_block_report.metadata[
            :active_partial_finite_difference_row_count
        ] == "1"

        block_rank_loss = new_model()
        block_rank_x, block_rank_y = MOI.add_variables(block_rank_loss, 2)
        MOI.add_constraint(
            block_rank_loss,
            MOI.ScalarAffineFunction(
                [MOI.ScalarAffineTerm(1.0, block_rank_x)], 0.0,
            ),
            MOI.EqualTo(0.0),
        )
        MOI.add_constraint(
            block_rank_loss,
            MOI.ScalarNonlinearFunction(:^, Any[block_rank_y, 2]),
            MOI.EqualTo(0.0),
        )
        block_rank_report = NLPDiagnostics.analyze_active_set(
            block_rank_loss, [0.0, 0.0],
        )
        @test length(findings(
            block_rank_report, :active_set_well_determined_block_rank_loss,
        )) == 1
        @test length(findings(
            block_rank_report,
            :active_set_well_determined_block_nullspace_support,
        )) == 1
        block_nullspace_support = only(findings(
            block_rank_report,
            :active_set_well_determined_block_nullspace_support,
        ))
        @test Dict(block_nullspace_support.evidence[end].details)[
            "relative_support_threshold"
        ] == "0.1"
        custom_nullspace_support_report = NLPDiagnostics.analyze_active_set(
            block_rank_loss, [0.0, 0.0]; nullspace_support_relative = 0.5,
        )
        custom_block_nullspace_support = only(findings(
            custom_nullspace_support_report,
            :active_set_well_determined_block_nullspace_support,
        ))
        @test Dict(custom_block_nullspace_support.evidence[end].details)[
            "relative_support_threshold"
        ] == "0.5"
        @test custom_nullspace_support_report.metadata[
            :nullspace_support_relative
        ] == "0.5"
        @test_throws ArgumentError NLPDiagnostics.analyze_active_set(
            block_rank_loss, [0.0, 0.0]; nullspace_support_relative = 0.0,
        )
        @test length(findings(
            block_rank_report,
            :active_set_well_determined_block_zero_sensitivities,
        )) == 1

        block_rank_scaling_sensitive = new_model()
        rank_scale_x, rank_scale_y, rank_scale_z = MOI.add_variables(
            block_rank_scaling_sensitive, 3,
        )
        MOI.add_constraint(
            block_rank_scaling_sensitive,
            MOI.ScalarAffineFunction(
                [MOI.ScalarAffineTerm(1.0, rank_scale_x)], 0.0,
            ),
            MOI.EqualTo(0.0),
        )
        MOI.add_constraint(
            block_rank_scaling_sensitive,
            MOI.ScalarAffineFunction([
                MOI.ScalarAffineTerm(1.0e8, rank_scale_y),
                MOI.ScalarAffineTerm(1.0, rank_scale_z),
            ], 0.0),
            MOI.EqualTo(0.0),
        )
        MOI.add_constraint(
            block_rank_scaling_sensitive,
            MOI.ScalarAffineFunction([
                MOI.ScalarAffineTerm(1.0, rank_scale_y),
                MOI.ScalarAffineTerm(1.0e-8 + 1.0e-16, rank_scale_z),
            ], 0.0),
            MOI.EqualTo(0.0),
        )
        block_rank_scaling_report = NLPDiagnostics.analyze_active_set(
            block_rank_scaling_sensitive, [0.0, 0.0, 0.0],
        )
        @test length(findings(
            block_rank_scaling_report,
            :active_set_well_determined_block_rank_scaling_sensitive,
        )) == 1

        block_ill_conditioned = new_model()
        block_condition_x, block_condition_y, block_condition_z = MOI.add_variables(
            block_ill_conditioned, 3,
        )
        MOI.add_constraint(
            block_ill_conditioned,
            MOI.ScalarAffineFunction(
                [MOI.ScalarAffineTerm(1.0, block_condition_x)], 0.0,
            ),
            MOI.EqualTo(0.0),
        )
        MOI.add_constraint(
            block_ill_conditioned,
            MOI.ScalarAffineFunction([
                MOI.ScalarAffineTerm(1.0, block_condition_y),
                MOI.ScalarAffineTerm(1.0, block_condition_z),
            ], 0.0),
            MOI.EqualTo(0.0),
        )
        MOI.add_constraint(
            block_ill_conditioned,
            MOI.ScalarAffineFunction([
                MOI.ScalarAffineTerm(1.0, block_condition_y),
                MOI.ScalarAffineTerm(1.0 + 1.0e-12, block_condition_z),
            ], 0.0),
            MOI.EqualTo(0.0),
        )
        block_condition_report = NLPDiagnostics.analyze_active_set(
            block_ill_conditioned, [0.0, 0.0, 0.0],
        )
        @test length(findings(
            block_condition_report,
            :active_set_well_determined_block_ill_conditioned,
        )) == 1

        block_scaling_sensitive = new_model()
        scale_x, scale_y, scale_z = MOI.add_variables(block_scaling_sensitive, 3)
        MOI.add_constraint(
            block_scaling_sensitive,
            MOI.ScalarAffineFunction(
                [MOI.ScalarAffineTerm(1.0, scale_x)], 0.0,
            ),
            MOI.EqualTo(0.0),
        )
        MOI.add_constraint(
            block_scaling_sensitive,
            MOI.ScalarAffineFunction([
                MOI.ScalarAffineTerm(1.0e8, scale_y),
                MOI.ScalarAffineTerm(1.0, scale_z),
            ], 0.0),
            MOI.EqualTo(0.0),
        )
        MOI.add_constraint(
            block_scaling_sensitive,
            MOI.ScalarAffineFunction([
                MOI.ScalarAffineTerm(1.0, scale_y),
                MOI.ScalarAffineTerm(1.0e-4, scale_z),
            ], 0.0),
            MOI.EqualTo(0.0),
        )
        block_scaling_report = NLPDiagnostics.analyze_active_set(
            block_scaling_sensitive, [0.0, 0.0, 0.0];
            block_condition_threshold = 1.0e6,
        )
        @test length(findings(
            block_scaling_report,
            :active_set_well_determined_block_conditioning_scaling_sensitive,
        )) == 1
        @test length(findings(
            block_scaling_report,
            :active_set_well_determined_block_scale_spread,
        )) == 1
        block_scale_finding = only(findings(
            block_scaling_report,
            :active_set_well_determined_block_scale_spread,
        ))
        @test haskey(
            Dict(block_scale_finding.evidence[end].details),
            "smallest_positive_row",
        )

        sign_model = new_model()
        sign_variable = MOI.add_variable(sign_model)
        sign_expression = F([T(-1.0, sign_variable)], 0.0)
        MOI.set(sign_model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        MOI.set(sign_model, MOI.ObjectiveFunction{F}(), sign_expression)
        MOI.add_constraint(sign_model, sign_variable, MOI.GreaterThan(0.0))
        sign_evaluation = NLPDiagnostics.evaluate_numerical(sign_model, [0.0])
        sign_summary = NLPDiagnostics.constraint_feasibility_summary(
            sign_model,
            sign_evaluation,
        )
        sign_recovery = NLPDiagnostics.recover_stationarity_multipliers(
            sign_model,
            sign_evaluation,
            sign_summary,
        )
        @test sign_recovery.inequality_dual_violation ≈ 1.0
        @test sign_recovery.complementarity_residual ≈ 0.0
        sign_report = NLPDiagnostics.analyze_active_set(sign_model, sign_evaluation)
        @test length(
            findings(sign_report, :recovered_active_multiplier_sign_violation),
        ) == 1
        sign_violation = only(findings(
            sign_report, :recovered_active_multiplier_sign_violation,
        ))
        @test Dict(sign_violation.evidence[end].details)["violating_rows"] == "1"

        complementarity_model = new_model()
        complementarity_variable = MOI.add_variable(complementarity_model)
        complementarity_objective = F(
            [T(1.0, complementarity_variable)], 0.0,
        )
        MOI.set(complementarity_model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        MOI.set(
            complementarity_model, MOI.ObjectiveFunction{F}(), complementarity_objective,
        )
        MOI.add_constraint(
            complementarity_model,
            complementarity_variable,
            MOI.GreaterThan(0.0),
        )
        complementarity_report = NLPDiagnostics.analyze_active_set(
            complementarity_model, [1.0e-9],
        )
        complementarity_finding = only(findings(
            complementarity_report,
            :recovered_active_multiplier_complementarity_residual,
        ))
        @test Dict(complementarity_finding.evidence[end].details)["rows"] == "1"
        @test Dict(complementarity_finding.evidence[end].details)[
            "relative_support_threshold"
        ] == "0.001"

        rectangle_model = new_model()
        r1, r2 = MOI.add_variables(rectangle_model, 2)
        MOI.add_constraint(
            rectangle_model,
            MOI.VectorOfVariables([r1, r2]),
            MOI.HyperRectangle([0.0, 1.0], [1.0, 2.0]),
        )
        rectangle_evaluation = NLPDiagnostics.evaluate_numerical(
            rectangle_model,
            [0.0, 1.5],
        )
        rectangle_summary = NLPDiagnostics.constraint_feasibility_summary(
            rectangle_model,
            rectangle_evaluation;
            active_tolerance = 1.0e-7,
        )
        @test rectangle_summary.complete
        @test [activity.classification for activity in rectangle_summary.activities] ==
              [:active_lower, :interior]
        @test NLPDiagnostics.active_constraint_rows(rectangle_summary) == [1]

        cone_model = new_model()
        cone_t, cone_x = MOI.add_variables(cone_model, 2)
        MOI.add_constraint(
            cone_model,
            MOI.VectorOfVariables([cone_t, cone_x]),
            MOI.SecondOrderCone(2),
        )
        cone_evaluation = NLPDiagnostics.evaluate_numerical(cone_model, [1.0, 1.0])
        cone_summary = NLPDiagnostics.coupled_set_feasibility_summary(
            cone_model,
            cone_evaluation,
        )
        @test cone_summary.complete
        cone_qualification = NLPDiagnostics.coupled_set_qualification_screen(
            cone_evaluation, cone_summary,
        )
        @test cone_qualification.available
        @test cone_qualification.robinson_regular
        @test length(cone_qualification.tangent_sources) == 1
        @test cone_qualification.witness_direction ≈ [-1 / sqrt(2), 1 / sqrt(2)]
        @test cone_qualification.normal_weights ≈ [1.0]
        @test cone_qualification.normal_combination ≈ [1.0, -1.0]
        @test cone_qualification.converged
        @test cone_qualification.derivative_methods == [:exact_symbolic]
        @test NLPDiagnostics.coupled_set_qualification_screen(
            cone_evaluation, cone_summary;
            strict_tolerance = 1.0e-5,
            max_iterations = 7,
        ).tolerance ≈ 1.0e-5 * sqrt(2)
        @test_throws ArgumentError NLPDiagnostics.coupled_set_qualification_screen(
            cone_evaluation, cone_summary; strict_tolerance = 0.0,
        )
        @test length(findings(NLPDiagnostics.analyze_coupled_set_qualification(
            cone_model, cone_evaluation,
        ), :coupled_set_robinson_cq_regular)) == 1
        @test length(findings(NLPDiagnostics.analyze_coupled_set_qualification(
            cone_evaluation; summary = cone_summary,
        ), :coupled_set_robinson_cq_regular)) == 1
        standalone_cone_qualification = NLPDiagnostics.analyze_coupled_set_qualification(
            cone_evaluation; summary = cone_summary,
        )
        @test length(findings(
            standalone_cone_qualification, :coupled_set_boundary_active,
        )) == 1
        @test length(findings(
            standalone_cone_qualification,
            :coupled_set_smooth_boundary_tangent_gradient_available,
        )) == 1
        cone_qualification_report = NLPDiagnostics.analyze_coupled_set_qualification(
            cone_model, cone_evaluation,
        )
        @test NLPDiagnostics.analyze_coupled_set_qualification(
            cone_model, [1.0, 1.0]; label = "initialization",
        ).metadata[:evaluation_point_label] == "initialization"
        @test NLPDiagnostics.analyze(
            cone_model;
            evaluation = cone_evaluation,
            check_active_set = true,
            coupled_qualification_strict_tolerance = 1.0e-5,
            coupled_qualification_max_iterations = 7,
        ).metadata[:coupled_qualification_max_iterations] == "7"
        standalone_coupled_report = NLPDiagnostics.analyze(
            cone_model;
            evaluation = cone_evaluation,
            check_coupled_set_qualification = true,
        )
        @test occursin(
            "coupled_set_qualification", standalone_coupled_report.metadata[:stages],
        )
        @test length(findings(
            standalone_coupled_report, :coupled_set_robinson_cq_regular,
        )) == 1
        combined_active_and_coupled_report = NLPDiagnostics.analyze(
            cone_model;
            evaluation = cone_evaluation,
            check_active_set = true,
            check_coupled_set_qualification = true,
        )
        @test length(findings(
            combined_active_and_coupled_report, :coupled_set_robinson_cq_regular,
        )) == 1
        @test !occursin(
            "coupled_set_qualification",
            combined_active_and_coupled_report.metadata[:stages],
        )
        cone_qualification_finding = only(findings(
            cone_qualification_report, :coupled_set_robinson_cq_regular,
        ))
        @test Dict(cone_qualification_finding.evidence[end].details)[
            "normal_combination_weights"
        ] == "1.0"
        @test cone_qualification_report.metadata[
            :coupled_normal_combination_converged
        ] == "true"
        @test NLPDiagnostics.coupled_set_qualification_screen(
            cone_model, cone_evaluation,
        ).tangent_sources == cone_qualification.tangent_sources
        cone_mapped_tangents = NLPDiagnostics.coupled_set_mapped_tangents(
            cone_evaluation, cone_summary,
        )
        @test length(cone_mapped_tangents) == 1
        @test only(cone_mapped_tangents).gradient ≈ [1.0, -1.0]
        partial_cone_evaluation = NLPDiagnostics.NumericalEvaluation{Float64}(
            cone_evaluation.point,
            cone_evaluation.objective_value,
            cone_evaluation.objective_source,
            cone_evaluation.objective_gradient,
            cone_evaluation.constraint_values,
            cone_evaluation.constraint_sources,
            cone_evaluation.jacobian_entries,
            [:partial_central_finite_difference, :exact_symbolic],
            cone_evaluation.capabilities,
            cone_evaluation.failures,
        )
        @test isempty(NLPDiagnostics.coupled_set_mapped_tangents(
            partial_cone_evaluation, cone_summary,
        ))
        @test_throws ArgumentError NLPDiagnostics.coupled_set_mapped_tangents(
            NLPDiagnostics.evaluate_numerical(cone_model, [1.0, 0.0]), cone_summary,
        )
        @test_throws ArgumentError NLPDiagnostics.coupled_set_qualification_screen(
            NLPDiagnostics.evaluate_numerical(cone_model, [1.0, 0.0]), cone_summary,
        )
        @test length(cone_summary.activities) == 1
        @test only(cone_summary.activities).classification == :boundary
        cone_report = NLPDiagnostics.analyze_active_set(cone_model, cone_evaluation)
        @test length(findings(
            cone_report, :coupled_set_robinson_cq_regular,
        )) == 1
        @test length(findings(
            cone_report, :scalar_active_set_excludes_coupled_sets,
        )) == 1
        @test length(findings(cone_report, :coupled_set_boundary_active)) == 1
        @test length(findings(
            cone_report,
            :coupled_set_smooth_boundary_tangent_available,
        )) == 1
        @test length(findings(
            cone_report,
            :coupled_set_smooth_boundary_tangent_gradient_available,
        )) == 1
        cone_gradient_finding = only(findings(
            cone_report, :coupled_set_smooth_boundary_tangent_gradient_available,
        ))
        @test cone_gradient_finding.basis == NLPDiagnostics.MathematicalProof
        @test Dict(cone_gradient_finding.evidence[end].details)["derivative_methods"] ==
              "exact_symbolic"
        finite_difference_cone_evaluation = NLPDiagnostics.NumericalEvaluation{Float64}(
            cone_evaluation.point,
            cone_evaluation.objective_value,
            cone_evaluation.objective_source,
            cone_evaluation.objective_gradient,
            cone_evaluation.constraint_values,
            cone_evaluation.constraint_sources,
            cone_evaluation.jacobian_entries,
            fill(:central_finite_difference, length(cone_evaluation.jacobian_row_methods)),
            cone_evaluation.capabilities,
            cone_evaluation.failures,
        )
        finite_difference_cone_report = NLPDiagnostics.analyze_active_set(
            cone_model, finite_difference_cone_evaluation,
        )
        finite_difference_cone_gradient = only(findings(
            finite_difference_cone_report,
            :coupled_set_smooth_boundary_tangent_gradient_available,
        ))
        @test finite_difference_cone_gradient.basis == NLPDiagnostics.NumericalObservation
        @test finite_difference_cone_gradient.confidence == NLPDiagnostics.ConfidenceMedium
        finite_difference_cone_qualification = only(findings(
            finite_difference_cone_report, :coupled_set_robinson_cq_regular,
        ))
        @test finite_difference_cone_qualification.basis == NLPDiagnostics.NumericalObservation
        @test finite_difference_cone_qualification.confidence == NLPDiagnostics.ConfidenceMedium
        cone_apex_report = NLPDiagnostics.analyze_active_set(cone_model, [0.0, 0.0])
        cone_apex_evaluation = NLPDiagnostics.evaluate_numerical(cone_model, [0.0, 0.0])
        cone_apex_summary = NLPDiagnostics.coupled_set_feasibility_summary(
            cone_model, cone_apex_evaluation,
        )
        cone_apex_qualification = NLPDiagnostics.coupled_set_qualification_screen(
            cone_apex_evaluation, cone_apex_summary,
        )
        @test isempty(cone_apex_qualification.tangent_sources)
        @test occursin("no smooth", cone_apex_qualification.reason)
        two_cones = new_model()
        t1, x1, t2, x2 = MOI.add_variables(two_cones, 4)
        MOI.add_constraint(two_cones, MOI.VectorOfVariables([t1, x1]), MOI.SecondOrderCone(2))
        MOI.add_constraint(two_cones, MOI.VectorOfVariables([t2, x2]), MOI.SecondOrderCone(2))
        two_cone_evaluation = NLPDiagnostics.evaluate_numerical(
            two_cones, [1.0, 1.0, 1.0, 1.0],
        )
        two_cone_qualification = NLPDiagnostics.coupled_set_qualification_screen(
            two_cones, two_cone_evaluation,
        )
        @test two_cone_qualification.available
        @test two_cone_qualification.robinson_regular
        @test length(two_cone_qualification.tangent_sources) == 2
        @test two_cone_qualification.witness_direction ≈ [-0.5, 0.5, -0.5, 0.5]
        opposed_cones = new_model()
        opposed_t, opposed_x = MOI.add_variables(opposed_cones, 2)
        MOI.add_constraint(
            opposed_cones,
            MOI.VectorOfVariables([opposed_t, opposed_x]),
            MOI.SecondOrderCone(2),
        )
        MOI.add_constraint(
            opposed_cones,
            MOI.VectorAffineFunction(
                [
                    MOI.VectorAffineTerm(1, MOI.ScalarAffineTerm(-1.0, opposed_t)),
                    MOI.VectorAffineTerm(2, MOI.ScalarAffineTerm(1.0, opposed_x)),
                ],
                [2.0, -2.0],
            ),
            MOI.SecondOrderCone(2),
        )
        opposed_qualification = NLPDiagnostics.coupled_set_qualification_screen(
            opposed_cones,
            NLPDiagnostics.evaluate_numerical(opposed_cones, [1.0, 1.0]),
        )
        @test opposed_qualification.available
        @test !opposed_qualification.robinson_regular
        @test occursin("zero convex-hull", opposed_qualification.reason)
        opposed_report = NLPDiagnostics.analyze_coupled_set_qualification(
            opposed_cones, [1.0, 1.0],
        )
        opposed_dependence = only(findings(
            opposed_report, :coupled_set_dependent_boundary_normals,
        ))
        @test length(opposed_dependence.affected) == 2
        @test Dict(opposed_dependence.evidence[end].details)["support_positions"] == "1,2"
        stationary_cone = new_model()
        stationary_variable = MOI.add_variable(stationary_cone)
        MOI.add_constraint(
            stationary_cone,
            MOI.VectorAffineFunction(
                MOI.VectorAffineTerm{Float64}[], [1.0, 1.0],
            ),
            MOI.SecondOrderCone(2),
        )
        stationary_evaluation = NLPDiagnostics.evaluate_numerical(
            stationary_cone, [0.0],
        )
        stationary_qualification = NLPDiagnostics.coupled_set_qualification_screen(
            stationary_cone, stationary_evaluation,
        )
        @test stationary_qualification.available
        @test !stationary_qualification.robinson_regular
        @test occursin("zero", stationary_qualification.reason)
        @test length(findings(
            cone_apex_report,
            :coupled_set_nonsmooth_boundary_active,
        )) == 1
        @test isempty(findings(
            cone_apex_report,
            :coupled_set_smooth_boundary_tangent_available,
        ))
        outside_cone = NLPDiagnostics.analyze_active_set(cone_model, [0.0, 1.0])
        @test length(findings(outside_cone, :coupled_set_feasibility_violation)) == 1

        rotated_cone_model = new_model()
        rotated_u, rotated_v, rotated_w = MOI.add_variables(rotated_cone_model, 3)
        MOI.add_constraint(
            rotated_cone_model,
            MOI.VectorOfVariables([rotated_u, rotated_v, rotated_w]),
            MOI.RotatedSecondOrderCone(3),
        )
        rotated_smooth_report = NLPDiagnostics.analyze_active_set(
            rotated_cone_model, [1.0, 1.0, sqrt(2.0)],
        )
        @test length(findings(
            rotated_smooth_report,
            :coupled_set_boundary_active,
        )) == 1
        @test length(findings(
            rotated_smooth_report,
            :coupled_set_smooth_boundary_tangent_available,
        )) == 1
        @test length(findings(
            rotated_smooth_report,
            :coupled_set_smooth_boundary_tangent_gradient_available,
        )) == 1
        rotated_axis_report = NLPDiagnostics.analyze_active_set(
            rotated_cone_model, [0.0, 1.0, 0.0],
        )
        @test length(findings(
            rotated_axis_report,
            :coupled_set_nonsmooth_boundary_active,
        )) == 1

        norm_one_model = new_model()
        norm_one_t, norm_one_x, norm_one_y = MOI.add_variables(norm_one_model, 3)
        MOI.add_constraint(
            norm_one_model,
            MOI.VectorOfVariables([norm_one_t, norm_one_x, norm_one_y]),
            MOI.NormOneCone(3),
        )
        norm_one_report = NLPDiagnostics.analyze_active_set(
            norm_one_model, [2.0, 1.0, -1.0],
        )
        @test length(findings(norm_one_report, :coupled_set_robinson_cq_regular)) == 1
        @test only(NLPDiagnostics.coupled_set_feasibility_summary(
            norm_one_model,
            NLPDiagnostics.evaluate_numerical(norm_one_model, [2.0, 1.0, -1.0]),
        ).tangents).set_kind == :norm_one_cone
        norm_one_nonsmooth = NLPDiagnostics.analyze_active_set(
            norm_one_model, [1.0, 1.0, 0.0],
        )
        @test length(findings(
            norm_one_nonsmooth, :coupled_set_nonsmooth_boundary_active,
        )) == 1

        norm_infinity_model = new_model()
        norm_inf_t, norm_inf_x, norm_inf_y = MOI.add_variables(norm_infinity_model, 3)
        MOI.add_constraint(
            norm_infinity_model,
            MOI.VectorOfVariables([norm_inf_t, norm_inf_x, norm_inf_y]),
            MOI.NormInfinityCone(3),
        )
        norm_infinity_report = NLPDiagnostics.analyze_active_set(
            norm_infinity_model, [2.0, -2.0, 0.25],
        )
        @test length(findings(
            norm_infinity_report, :coupled_set_robinson_cq_regular,
        )) == 1
        norm_infinity_tie = NLPDiagnostics.analyze_active_set(
            norm_infinity_model, [2.0, 2.0, -2.0],
        )
        @test length(findings(
            norm_infinity_tie, :coupled_set_nonsmooth_boundary_active,
        )) == 1

        generic_norm_model = new_model()
        generic_norm_t, generic_norm_x, generic_norm_y = MOI.add_variables(
            generic_norm_model, 3,
        )
        MOI.add_constraint(
            generic_norm_model,
            MOI.VectorOfVariables([generic_norm_t, generic_norm_x, generic_norm_y]),
            MOI.NormCone(3.0, 3),
        )
        generic_norm_report = NLPDiagnostics.analyze_active_set(
            generic_norm_model, [1.0, 1.0, 0.0],
        )
        @test length(findings(
            generic_norm_report, :coupled_set_robinson_cq_regular,
        )) == 1
        generic_norm_tangent = only(NLPDiagnostics.coupled_set_feasibility_summary(
            generic_norm_model,
            NLPDiagnostics.evaluate_numerical(generic_norm_model, [1.0, 1.0, 0.0]),
        ).tangents)
        @test generic_norm_tangent.set_kind == :norm_cone
        @test generic_norm_tangent.normal ≈ [1.0, -1.0, 0.0]
        generic_norm_apex = NLPDiagnostics.analyze_active_set(
            generic_norm_model, [0.0, 0.0, 0.0],
        )
        @test length(findings(
            generic_norm_apex, :coupled_set_nonsmooth_boundary_active,
        )) == 1

        spectral_cone_model = new_model()
        spectral_variables = MOI.add_variables(spectral_cone_model, 5)
        spectral_t = spectral_variables[1]
        spectral_entries = spectral_variables[2:end]
        MOI.add_constraint(
            spectral_cone_model,
            MOI.VectorOfVariables([spectral_t; spectral_entries]),
            MOI.NormSpectralCone(2, 2),
        )
        spectral_report = NLPDiagnostics.analyze_active_set(
            spectral_cone_model, [2.0, 2.0, 0.0, 0.0, 1.0],
        )
        @test length(findings(
            spectral_report, :coupled_set_robinson_cq_regular,
        )) == 1
        spectral_tangent = only(NLPDiagnostics.coupled_set_feasibility_summary(
            spectral_cone_model,
            NLPDiagnostics.evaluate_numerical(
                spectral_cone_model, [2.0, 2.0, 0.0, 0.0, 1.0],
            ),
        ).tangents)
        @test spectral_tangent.set_kind == :norm_spectral_cone
        @test spectral_tangent.normal ≈ [1.0, -1.0, 0.0, 0.0, 0.0]
        spectral_tied_report = NLPDiagnostics.analyze_active_set(
            spectral_cone_model, [1.0, 1.0, 0.0, 0.0, 1.0],
        )
        @test length(findings(
            spectral_tied_report, :coupled_set_nonsmooth_boundary_active,
        )) == 1
        @test isempty(findings(
            spectral_tied_report, :coupled_set_smooth_boundary_tangent_available,
        ))

        nuclear_cone_model = new_model()
        nuclear_variables = MOI.add_variables(nuclear_cone_model, 5)
        nuclear_t = nuclear_variables[1]
        nuclear_entries = nuclear_variables[2:end]
        MOI.add_constraint(
            nuclear_cone_model,
            MOI.VectorOfVariables([nuclear_t; nuclear_entries]),
            MOI.NormNuclearCone(2, 2),
        )
        nuclear_report = NLPDiagnostics.analyze_active_set(
            nuclear_cone_model, [3.0, 2.0, 0.0, 0.0, 1.0],
        )
        @test length(findings(
            nuclear_report, :coupled_set_robinson_cq_regular,
        )) == 1
        nuclear_tangent = only(NLPDiagnostics.coupled_set_feasibility_summary(
            nuclear_cone_model,
            NLPDiagnostics.evaluate_numerical(
                nuclear_cone_model, [3.0, 2.0, 0.0, 0.0, 1.0],
            ),
        ).tangents)
        @test nuclear_tangent.set_kind == :norm_nuclear_cone
        @test nuclear_tangent.normal ≈ [1.0, -1.0, 0.0, 0.0, -1.0]
        nuclear_rank_deficient_report = NLPDiagnostics.analyze_active_set(
            nuclear_cone_model, [2.0, 2.0, 0.0, 0.0, 0.0],
        )
        @test length(findings(
            nuclear_rank_deficient_report, :coupled_set_nonsmooth_boundary_active,
        )) == 1
        @test isempty(findings(
            nuclear_rank_deficient_report,
            :coupled_set_smooth_boundary_tangent_available,
        ))

        psd_triangle_model = new_model()
        psd_entries = MOI.add_variables(psd_triangle_model, 3)
        MOI.add_constraint(
            psd_triangle_model,
            MOI.VectorOfVariables(psd_entries),
            MOI.PositiveSemidefiniteConeTriangle(2),
        )
        psd_report = NLPDiagnostics.analyze_active_set(
            psd_triangle_model, [0.0, 0.0, 1.0],
        )
        @test length(findings(
            psd_report, :coupled_set_robinson_cq_regular,
        )) == 1
        psd_tangent = only(NLPDiagnostics.coupled_set_feasibility_summary(
            psd_triangle_model,
            NLPDiagnostics.evaluate_numerical(psd_triangle_model, [0.0, 0.0, 1.0]),
        ).tangents)
        @test psd_tangent.set_kind == :positive_semidefinite_cone_triangle
        @test psd_tangent.normal ≈ [1.0, 0.0, 0.0]
        psd_repeated_zero_report = NLPDiagnostics.analyze_active_set(
            psd_triangle_model, [0.0, 0.0, 0.0],
        )
        @test length(findings(
            psd_repeated_zero_report, :coupled_set_nonsmooth_boundary_active,
        )) == 1
        @test isempty(findings(
            psd_repeated_zero_report,
            :coupled_set_smooth_boundary_tangent_available,
        ))

        scaled_psd_model = new_model()
        scaled_psd_entries = MOI.add_variables(scaled_psd_model, 3)
        MOI.add_constraint(
            scaled_psd_model,
            MOI.VectorOfVariables(scaled_psd_entries),
            MOI.Scaled(MOI.PositiveSemidefiniteConeTriangle(2)),
        )
        scaled_psd_tangent = only(NLPDiagnostics.coupled_set_feasibility_summary(
            scaled_psd_model,
            NLPDiagnostics.evaluate_numerical(scaled_psd_model, [0.0, 0.0, 1.0]),
        ).tangents)
        @test scaled_psd_tangent.set_kind == :scaled_positive_semidefinite_cone_triangle
        @test scaled_psd_tangent.normal ≈ [1.0, 0.0, 0.0]
        scaled_psd_offdiagonal_tangent = only(
            NLPDiagnostics.coupled_set_feasibility_summary(
                scaled_psd_model,
                NLPDiagnostics.evaluate_numerical(
                    scaled_psd_model, [1.0, sqrt(2.0), 1.0],
                ),
            ).tangents,
        )
        @test scaled_psd_offdiagonal_tangent.normal ≈ [0.5, -inv(sqrt(2.0)), 0.5]

        psd_square_model = new_model()
        psd_square_entries = MOI.add_variables(psd_square_model, 4)
        MOI.add_constraint(
            psd_square_model,
            MOI.VectorOfVariables(psd_square_entries),
            MOI.PositiveSemidefiniteConeSquare(2),
        )
        psd_square_report = NLPDiagnostics.analyze_active_set(
            psd_square_model, [0.0, 0.0, 0.0, 1.0],
        )
        @test length(findings(
            psd_square_report, :coupled_set_boundary_active,
        )) == 1
        @test length(findings(
            psd_square_report, :coupled_set_boundary_tangent_semantics_unavailable,
        )) == 1
        @test isempty(NLPDiagnostics.coupled_set_feasibility_summary(
            psd_square_model,
            NLPDiagnostics.evaluate_numerical(psd_square_model, [0.0, 0.0, 0.0, 1.0]),
        ).tangents)
        psd_square_asymmetric_report = NLPDiagnostics.analyze_active_set(
            psd_square_model, [1.0, 0.0, 0.5, 1.0],
        )
        @test length(findings(
            psd_square_asymmetric_report, :coupled_set_feasibility_violation,
        )) == 1

        hermitian_psd_model = new_model()
        hermitian_entries = MOI.add_variables(hermitian_psd_model, 4)
        MOI.add_constraint(
            hermitian_psd_model,
            MOI.VectorOfVariables(hermitian_entries),
            MOI.HermitianPositiveSemidefiniteConeTriangle(2),
        )
        hermitian_psd_report = NLPDiagnostics.analyze_active_set(
            hermitian_psd_model, [0.0, 0.0, 1.0, 0.0],
        )
        @test length(findings(
            hermitian_psd_report, :coupled_set_robinson_cq_regular,
        )) == 1
        hermitian_psd_tangent = only(NLPDiagnostics.coupled_set_feasibility_summary(
            hermitian_psd_model,
            NLPDiagnostics.evaluate_numerical(
                hermitian_psd_model, [0.0, 0.0, 1.0, 0.0],
            ),
        ).tangents)
        @test hermitian_psd_tangent.set_kind ==
              :hermitian_positive_semidefinite_cone_triangle
        @test hermitian_psd_tangent.normal ≈ [1.0, 0.0, 0.0, 0.0]
        hermitian_imaginary_tangent = only(
            NLPDiagnostics.coupled_set_feasibility_summary(
                hermitian_psd_model,
                NLPDiagnostics.evaluate_numerical(
                    hermitian_psd_model, [1.0, 0.0, 1.0, 1.0],
                ),
            ).tangents,
        )
        @test hermitian_imaginary_tangent.normal ≈ [0.5, 0.0, 0.5, -1.0]
        scaled_hermitian_model = new_model()
        scaled_hermitian_entries = MOI.add_variables(scaled_hermitian_model, 4)
        MOI.add_constraint(
            scaled_hermitian_model,
            MOI.VectorOfVariables(scaled_hermitian_entries),
            MOI.Scaled(MOI.HermitianPositiveSemidefiniteConeTriangle(2)),
        )
        scaled_hermitian_tangent = only(
            NLPDiagnostics.coupled_set_feasibility_summary(
                scaled_hermitian_model,
                NLPDiagnostics.evaluate_numerical(
                    scaled_hermitian_model, [1.0, 0.0, 1.0, sqrt(2.0)],
                ),
            ).tangents,
        )
        @test scaled_hermitian_tangent.set_kind ==
              :scaled_hermitian_positive_semidefinite_cone_triangle
        @test scaled_hermitian_tangent.normal ≈
              [0.5, 0.0, 0.5, -inv(sqrt(2.0))]
        hermitian_repeated_zero_report = NLPDiagnostics.analyze_active_set(
            hermitian_psd_model, [0.0, 0.0, 0.0, 0.0],
        )
        @test length(findings(
            hermitian_repeated_zero_report,
            :coupled_set_nonsmooth_boundary_active,
        )) == 1

        logdet_model = new_model()
        logdet_entries = MOI.add_variables(logdet_model, 5)
        MOI.add_constraint(
            logdet_model,
            MOI.VectorOfVariables(logdet_entries),
            MOI.LogDetConeTriangle(2),
        )
        logdet_report = NLPDiagnostics.analyze_active_set(
            logdet_model, [0.0, 1.0, 1.0, 0.0, 1.0],
        )
        @test length(findings(
            logdet_report, :coupled_set_robinson_cq_regular,
        )) == 1
        logdet_tangent = only(NLPDiagnostics.coupled_set_feasibility_summary(
            logdet_model,
            NLPDiagnostics.evaluate_numerical(
                logdet_model, [0.0, 1.0, 1.0, 0.0, 1.0],
            ),
        ).tangents)
        @test logdet_tangent.set_kind == :logdet_cone_triangle
        @test logdet_tangent.normal ≈ [-1.0, -2.0, 1.0, 0.0, 1.0]
        logdet_domain_report = NLPDiagnostics.analyze_active_set(
            logdet_model, [0.0, 1.0, 0.0, 0.0, 1.0],
        )
        @test length(findings(
            logdet_domain_report, :coupled_set_activity_unavailable,
        )) == 1
        logdet_near_singular_report = NLPDiagnostics.analyze_active_set(
            logdet_model, [log(1.0e-10), 1.0, 1.0e-10, 0.0, 1.0],
        )
        @test length(findings(
            logdet_near_singular_report,
            :coupled_set_boundary_tangent_semantics_unavailable,
        )) == 1
        @test isempty(NLPDiagnostics.coupled_set_feasibility_summary(
            logdet_model,
            NLPDiagnostics.evaluate_numerical(
                logdet_model, [log(1.0e-10), 1.0, 1.0e-10, 0.0, 1.0],
            ),
        ).tangents)
        for (variable, value) in zip(
            logdet_entries, [log(1.0e-10), 1.0, 1.0e-10, 0.0, 1.0],
        )
            MOI.set(logdet_model, MOI.VariablePrimalStart(), variable, value)
        end
        logdet_initialization_report = NLPDiagnostics.analyze_initialization(logdet_model)
        @test length(findings(
            logdet_initialization_report,
            :coupled_set_boundary_tangent_semantics_unavailable,
        )) == 1

        scaled_logdet_model = new_model()
        scaled_logdet_entries = MOI.add_variables(scaled_logdet_model, 5)
        MOI.add_constraint(
            scaled_logdet_model,
            MOI.VectorOfVariables(scaled_logdet_entries),
            MOI.Scaled(MOI.LogDetConeTriangle(2)),
        )
        scaled_logdet_tangent = only(NLPDiagnostics.coupled_set_feasibility_summary(
            scaled_logdet_model,
            NLPDiagnostics.evaluate_numerical(
                scaled_logdet_model, [0.0, 1.0, 1.0, 0.0, 1.0],
            ),
        ).tangents)
        @test scaled_logdet_tangent.set_kind == :scaled_logdet_cone_triangle
        @test scaled_logdet_tangent.normal ≈ [-1.0, -2.0, 1.0, 0.0, 1.0]
        scaled_logdet_offdiagonal_tangent = only(
            NLPDiagnostics.coupled_set_feasibility_summary(
                scaled_logdet_model,
                NLPDiagnostics.evaluate_numerical(
                    scaled_logdet_model, [0.0, 1.0, 1.0, sqrt(2.0), 2.0],
                ),
            ).tangents,
        )
        @test scaled_logdet_offdiagonal_tangent.normal ≈
              [-1.0, -2.0, 2.0, -sqrt(2.0), 1.0]

        rootdet_model = new_model()
        rootdet_entries = MOI.add_variables(rootdet_model, 4)
        MOI.add_constraint(
            rootdet_model,
            MOI.VectorOfVariables(rootdet_entries),
            MOI.RootDetConeTriangle(2),
        )
        rootdet_report = NLPDiagnostics.analyze_active_set(
            rootdet_model, [1.0, 1.0, 0.0, 1.0],
        )
        @test length(findings(
            rootdet_report, :coupled_set_robinson_cq_regular,
        )) == 1
        rootdet_tangent = only(NLPDiagnostics.coupled_set_feasibility_summary(
            rootdet_model,
            NLPDiagnostics.evaluate_numerical(
                rootdet_model, [1.0, 1.0, 0.0, 1.0],
            ),
        ).tangents)
        @test rootdet_tangent.set_kind == :rootdet_cone_triangle
        @test rootdet_tangent.normal ≈ [-1.0, 0.5, 0.0, 0.5]
        rootdet_rank_deficient_report = NLPDiagnostics.analyze_active_set(
            rootdet_model, [0.0, 0.0, 0.0, 1.0],
        )
        @test length(findings(
            rootdet_rank_deficient_report,
            :coupled_set_nonsmooth_boundary_active,
        )) == 1

        scaled_rootdet_model = new_model()
        scaled_rootdet_entries = MOI.add_variables(scaled_rootdet_model, 4)
        MOI.add_constraint(
            scaled_rootdet_model,
            MOI.VectorOfVariables(scaled_rootdet_entries),
            MOI.Scaled(MOI.RootDetConeTriangle(2)),
        )
        scaled_rootdet_tangent = only(NLPDiagnostics.coupled_set_feasibility_summary(
            scaled_rootdet_model,
            NLPDiagnostics.evaluate_numerical(
                scaled_rootdet_model, [1.0, 1.0, 0.0, 1.0],
            ),
        ).tangents)
        @test scaled_rootdet_tangent.set_kind == :scaled_rootdet_cone_triangle
        @test scaled_rootdet_tangent.normal ≈ [-1.0, 0.5, 0.0, 0.5]

        logdet_square_model = new_model()
        logdet_square_entries = MOI.add_variables(logdet_square_model, 6)
        MOI.add_constraint(
            logdet_square_model,
            MOI.VectorOfVariables(logdet_square_entries),
            MOI.LogDetConeSquare(2),
        )
        logdet_square_report = NLPDiagnostics.analyze_active_set(
            logdet_square_model, [0.0, 1.0, 1.0, 0.0, 0.0, 1.0],
        )
        @test length(findings(
            logdet_square_report,
            :coupled_set_boundary_tangent_semantics_unavailable,
        )) == 1
        @test isempty(NLPDiagnostics.coupled_set_feasibility_summary(
            logdet_square_model,
            NLPDiagnostics.evaluate_numerical(
                logdet_square_model, [0.0, 1.0, 1.0, 0.0, 0.0, 1.0],
            ),
        ).tangents)
        logdet_square_asymmetric_report = NLPDiagnostics.analyze_active_set(
            logdet_square_model, [0.0, 1.0, 1.0, 0.0, 0.5, 1.0],
        )
        @test length(findings(
            logdet_square_asymmetric_report,
            :coupled_set_feasibility_violation,
        )) == 1

        rootdet_square_model = new_model()
        rootdet_square_entries = MOI.add_variables(rootdet_square_model, 5)
        MOI.add_constraint(
            rootdet_square_model,
            MOI.VectorOfVariables(rootdet_square_entries),
            MOI.RootDetConeSquare(2),
        )
        rootdet_square_report = NLPDiagnostics.analyze_active_set(
            rootdet_square_model, [1.0, 1.0, 0.0, 0.0, 1.0],
        )
        @test length(findings(
            rootdet_square_report,
            :coupled_set_boundary_tangent_semantics_unavailable,
        )) == 1
        @test isempty(NLPDiagnostics.coupled_set_feasibility_summary(
            rootdet_square_model,
            NLPDiagnostics.evaluate_numerical(
                rootdet_square_model, [1.0, 1.0, 0.0, 0.0, 1.0],
            ),
        ).tangents)
        rootdet_square_asymmetric_report = NLPDiagnostics.analyze_active_set(
            rootdet_square_model, [1.0, 1.0, 0.0, 0.5, 1.0],
        )
        @test length(findings(
            rootdet_square_asymmetric_report,
            :coupled_set_feasibility_violation,
        )) == 1
        @test occursin(
            "symmetric matrix",
            string(Dict(only(findings(
                rootdet_square_asymmetric_report,
                :coupled_set_feasibility_violation,
            )).evidence[end].details)["reason"]),
        )

        power_cone_model = new_model()
        power_x, power_y, power_z = MOI.add_variables(power_cone_model, 3)
        MOI.add_constraint(
            power_cone_model,
            MOI.VectorOfVariables([power_x, power_y, power_z]),
            MOI.PowerCone(0.5),
        )
        power_cone_report = NLPDiagnostics.analyze_active_set(
            power_cone_model, [1.0, 4.0, 2.0],
        )
        @test length(findings(
            power_cone_report, :coupled_set_robinson_cq_regular,
        )) == 1
        power_tangent = only(NLPDiagnostics.coupled_set_feasibility_summary(
            power_cone_model,
            NLPDiagnostics.evaluate_numerical(power_cone_model, [1.0, 4.0, 2.0]),
        ).tangents)
        @test power_tangent.set_kind == :power_cone
        @test power_tangent.normal ≈ [1.0, 0.25, -1.0]
        power_axis = NLPDiagnostics.analyze_active_set(
            power_cone_model, [0.0, 4.0, 0.0],
        )
        @test length(findings(
            power_axis, :coupled_set_nonsmooth_boundary_active,
        )) == 1

        dual_power_model = new_model()
        dual_power_u, dual_power_v, dual_power_w = MOI.add_variables(dual_power_model, 3)
        MOI.add_constraint(
            dual_power_model,
            MOI.VectorOfVariables([dual_power_u, dual_power_v, dual_power_w]),
            MOI.DualPowerCone(0.5),
        )
        dual_power_report = NLPDiagnostics.analyze_active_set(
            dual_power_model, [0.5, 2.0, 2.0],
        )
        @test length(findings(
            dual_power_report, :coupled_set_robinson_cq_regular,
        )) == 1
        dual_power_tangent = only(NLPDiagnostics.coupled_set_feasibility_summary(
            dual_power_model,
            NLPDiagnostics.evaluate_numerical(dual_power_model, [0.5, 2.0, 2.0]),
        ).tangents)
        @test dual_power_tangent.set_kind == :dual_power_cone
        @test dual_power_tangent.normal ≈ [2.0, 0.5, -1.0]
        dual_power_axis = NLPDiagnostics.analyze_active_set(
            dual_power_model, [0.0, 2.0, 0.0],
        )
        @test length(findings(
            dual_power_axis, :coupled_set_nonsmooth_boundary_active,
        )) == 1

        exponential_cone_model = new_model()
        exponential_x, exponential_y, exponential_z = MOI.add_variables(
            exponential_cone_model, 3,
        )
        MOI.add_constraint(
            exponential_cone_model,
            MOI.VectorOfVariables([exponential_x, exponential_y, exponential_z]),
            MOI.ExponentialCone(),
        )
        exponential_report = NLPDiagnostics.analyze_active_set(
            exponential_cone_model, [0.0, 1.0, 1.0],
        )
        @test length(findings(
            exponential_report, :coupled_set_robinson_cq_regular,
        )) == 1
        exponential_tangent = only(NLPDiagnostics.coupled_set_feasibility_summary(
            exponential_cone_model,
            NLPDiagnostics.evaluate_numerical(exponential_cone_model, [0.0, 1.0, 1.0]),
        ).tangents)
        @test exponential_tangent.set_kind == :exponential_cone
        @test exponential_tangent.normal ≈ [-1.0, -1.0, 1.0]
        exponential_overflow_report = NLPDiagnostics.analyze_active_set(
            exponential_cone_model, [800.0, 1.0, 0.0],
        )
        exponential_unavailable = only(findings(
            exponential_overflow_report, :coupled_set_activity_unavailable,
        ))
        @test occursin(
            "non-finite",
            Dict(exponential_unavailable.evidence[end].details)["reason"],
        )
        exponential_qualification_unavailable = only(findings(
            exponential_overflow_report, :coupled_set_robinson_cq_unavailable,
        ))
        @test occursin(
            "non-finite",
            Dict(exponential_qualification_unavailable.evidence[end].details)["reason"],
        )

        dual_exponential_model = new_model()
        dual_exponential_u, dual_exponential_v, dual_exponential_w = MOI.add_variables(
            dual_exponential_model, 3,
        )
        MOI.add_constraint(
            dual_exponential_model,
            MOI.VectorOfVariables([
                dual_exponential_u, dual_exponential_v, dual_exponential_w,
            ]),
            MOI.DualExponentialCone(),
        )
        dual_exponential_report = NLPDiagnostics.analyze_active_set(
            dual_exponential_model, [-1.0, 0.0, exp(-1.0)],
        )
        @test length(findings(
            dual_exponential_report, :coupled_set_robinson_cq_regular,
        )) == 1
        dual_exponential_tangent = only(NLPDiagnostics.coupled_set_feasibility_summary(
            dual_exponential_model,
            NLPDiagnostics.evaluate_numerical(
                dual_exponential_model, [-1.0, 0.0, exp(-1.0)],
            ),
        ).tangents)
        @test dual_exponential_tangent.set_kind == :dual_exponential_cone
        @test dual_exponential_tangent.normal ≈ [1.0, 1.0, exp(1.0)]

        geometric_mean_model = new_model()
        geometric_t, geometric_x, geometric_y = MOI.add_variables(geometric_mean_model, 3)
        MOI.add_constraint(
            geometric_mean_model,
            MOI.VectorOfVariables([geometric_t, geometric_x, geometric_y]),
            MOI.GeometricMeanCone(3),
        )
        geometric_report = NLPDiagnostics.analyze_active_set(
            geometric_mean_model, [2.0, 1.0, 4.0],
        )
        @test length(findings(
            geometric_report, :coupled_set_robinson_cq_regular,
        )) == 1
        geometric_tangent = only(NLPDiagnostics.coupled_set_feasibility_summary(
            geometric_mean_model,
            NLPDiagnostics.evaluate_numerical(geometric_mean_model, [2.0, 1.0, 4.0]),
        ).tangents)
        @test geometric_tangent.set_kind == :geometric_mean_cone
        @test geometric_tangent.normal ≈ [-1.0, 1.0, 0.25]
        geometric_axis = NLPDiagnostics.analyze_active_set(
            geometric_mean_model, [0.0, 0.0, 4.0],
        )
        @test length(findings(
            geometric_axis, :coupled_set_nonsmooth_boundary_active,
        )) == 1

        relative_entropy_model = new_model()
        entropy_u, entropy_v, entropy_w = MOI.add_variables(relative_entropy_model, 3)
        MOI.add_constraint(
            relative_entropy_model,
            MOI.VectorOfVariables([entropy_u, entropy_v, entropy_w]),
            MOI.RelativeEntropyCone(3),
        )
        relative_entropy_report = NLPDiagnostics.analyze_active_set(
            relative_entropy_model, [0.0, 1.0, 1.0],
        )
        @test length(findings(
            relative_entropy_report, :coupled_set_robinson_cq_regular,
        )) == 1
        relative_entropy_tangent = only(NLPDiagnostics.coupled_set_feasibility_summary(
            relative_entropy_model,
            NLPDiagnostics.evaluate_numerical(relative_entropy_model, [0.0, 1.0, 1.0]),
        ).tangents)
        @test relative_entropy_tangent.set_kind == :relative_entropy_cone
        @test relative_entropy_tangent.normal ≈ [1.0, 1.0, -1.0]

        plugin_cone_model = new_model()
        e1, e2, e3 = MOI.add_variables(plugin_cone_model, 3)
        MOI.add_constraint(
            plugin_cone_model,
            MOI.VectorOfVariables([e1, e2, e3]),
            PluginCoupledSet(),
        )
        plugin_cone_evaluation = NLPDiagnostics.evaluate_numerical(
            plugin_cone_model,
            [0.0, 1.0, 1.0],
        )
        plugin_cone_summary = NLPDiagnostics.coupled_set_feasibility_summary(
            plugin_cone_model,
            plugin_cone_evaluation,
        )
        @test only(plugin_cone_summary.activities).set_kind == :test_plugin_coupled_set

        unsupported_cone_model = new_model()
        unknown_1, unknown_2 = MOI.add_variables(unsupported_cone_model, 2)
        MOI.add_constraint(
            unsupported_cone_model,
            MOI.VectorOfVariables([unknown_1, unknown_2]),
            UnknownCoupledSet(),
        )
        unsupported_cone_report = NLPDiagnostics.analyze_active_set(
            unsupported_cone_model, [0.0, 0.0],
        )
        @test length(findings(
            unsupported_cone_report, :coupled_set_semantics_unavailable,
        )) == 1
        unsupported_cone_summary = NLPDiagnostics.coupled_set_feasibility_summary(
            unsupported_cone_model,
            NLPDiagnostics.evaluate_numerical(unsupported_cone_model, [0.0, 0.0]),
        )
        @test !unsupported_cone_summary.complete
        @test occursin("no generic", unsupported_cone_summary.reason)
        unsupported_cone_data = NLPDiagnostics.report_data(unsupported_cone_report)
        unsupported_coupled_reason = only(filter(
            item -> item["code"] == "coupled_qualification_unavailable",
            unsupported_cone_data["unavailable_reasons"],
        ))
        @test unsupported_coupled_reason["category"] == "capability"
        @test unsupported_coupled_reason["stage"] ==
              "coupled_set_qualification"
    end

    @testset "finite-difference and reduced Hessian evidence" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        Q = MOI.ScalarQuadraticFunction{Float64}
        QT = MOI.ScalarQuadraticTerm{Float64}
        objective = Q(
            [QT(2.0, x, x), QT(6.0, y, y)],
            MOI.ScalarAffineTerm{Float64}[],
            0.0,
        )
        MOI.set(model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        MOI.set(model, MOI.ObjectiveFunction{Q}(), objective)
        hessian = NLPDiagnostics.evaluate_lagrangian_hessian(model, [1.0, 2.0])
        @test hessian.complete
        @test hessian.methods == [:finite_difference_function_values]
        combined = NLPDiagnostics._combined_hessian_matrix(hessian)
        @test combined[1, 1] ≈ 2.0 rtol = 1.0e-6
        @test combined[2, 2] ≈ 6.0 rtol = 1.0e-6

        constrained = new_model()
        u, v, w = MOI.add_variables(constrained, 3)
        MOI.add_constraint(constrained, u, MOI.EqualTo(0.0))
        evaluation = NLPDiagnostics.evaluate_numerical(constrained, [0.0, 0.0, 0.0])
        exact_hessian = NLPDiagnostics.HessianEvaluation(
            evaluation.point,
            1.0,
            [0.0],
            NLPDiagnostics.HessianEntry{Float64}[
                NLPDiagnostics.HessianEntry(1, 1, 1.0),
                NLPDiagnostics.HessianEntry(2, 2, 1.0),
                NLPDiagnostics.HessianEntry(3, 3, 1.0e-12),
            ],
            [:test_exact],
            true,
            NLPDiagnostics.EvaluationFailure[],
        )
        reduced = NLPDiagnostics.reduced_hessian_analysis(
            evaluation,
            exact_hessian;
            active_rows = [1],
        )
        @test reduced.available
        @test reduced.tangent_dimension == 2
        @test reduced.positive_eigenvalues == 2
        @test reduced.condition_estimate ≈ 1.0e12
        report = NLPDiagnostics.analyze_reduced_hessian(
            evaluation,
            exact_hessian;
            active_rows = [1],
        )
        @test length(findings(report, :ill_conditioned_reduced_hessian)) == 1

        guarded_reduced_report = NLPDiagnostics.analyze_reduced_hessian(
            evaluation,
            exact_hessian;
            active_rows = [1],
            max_dense_entries = 0,
        )
        @test guarded_reduced_report.metadata[:reduced_hessian_available] == "false"
        guarded_reduced_data = NLPDiagnostics.report_data(guarded_reduced_report)
        guarded_reduced_reason = only(filter(
            item -> item["code"] == "reduced_hessian_unavailable",
            guarded_reduced_data["unavailable_reasons"],
        ))
        @test guarded_reduced_reason["category"] == "numerical"
        @test guarded_reduced_reason["stage"] == "reduced_hessian"

        guarded_report = NLPDiagnostics.analyze_active_set_second_order(
            constrained,
            evaluation;
            rank_max_dense_entries = 0,
        )
        @test length(findings(
            guarded_report, :active_set_second_order_analysis_unavailable,
        )) == 1
        guarded_data = NLPDiagnostics.report_data(guarded_report)
        @test length(guarded_data["unavailable_reasons"]) == 1
        @test guarded_data["unavailable_reasons"][1]["code"] ==
              "second_order_multiplier_recovery_unavailable"
        @test guarded_data["unavailable_reasons"][1]["category"] == "numerical"
        @test guarded_data["unavailable_reasons"][1]["stage"] ==
              "active_set_second_order"

        flat_model = new_model()
        flat_variable = MOI.add_variable(flat_model)
        flat_objective = MOI.ScalarAffineFunction(
            [MOI.ScalarAffineTerm(1.0, flat_variable)],
            0.0,
        )
        MOI.set(flat_model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        MOI.set(
            flat_model,
            MOI.ObjectiveFunction{typeof(flat_objective)}(),
            flat_objective,
        )
        flat_evaluation = NLPDiagnostics.evaluate_numerical(flat_model, [0.0])
        flat_report = NLPDiagnostics.analyze_active_set_second_order(
            flat_model,
            flat_evaluation,
        )
        @test flat_report.metadata[:second_order_reduced_hessian_available] == "true"
        @test length(findings(flat_report, :reduced_hessian_flat_directions)) == 1
        @test length(findings(
            flat_report, :active_set_second_order_finite_difference_hessian,
        )) == 1

        guarded_flat_report = NLPDiagnostics.analyze_active_set_second_order(
            flat_model,
            flat_evaluation;
            max_dense_entries = 0,
        )
        @test guarded_flat_report.metadata[
            :second_order_reduced_hessian_available
        ] == "false"
        guarded_flat_data = NLPDiagnostics.report_data(guarded_flat_report)
        guarded_flat_reason = only(filter(
            item -> item["code"] == "second_order_reduced_hessian_unavailable",
            guarded_flat_data["unavailable_reasons"],
        ))
        @test guarded_flat_reason["category"] == "numerical"
        @test guarded_flat_reason["stage"] == "active_set_second_order"

        flat_shift_model = new_model()
        s1, s2 = MOI.add_variables(flat_shift_model, 2)
        flat_shift_evaluation = NLPDiagnostics.evaluate_numerical(
            flat_shift_model, [0.0, 0.0],
        )
        flat_shift_hessian = NLPDiagnostics.HessianEvaluation(
            flat_shift_evaluation.point,
            1.0,
            [0.0, 0.0],
            NLPDiagnostics.HessianEntry{Float64}[
                NLPDiagnostics.HessianEntry(1, 1, 1.0),
                NLPDiagnostics.HessianEntry(1, 2, -1.0),
                NLPDiagnostics.HessianEntry(2, 2, 1.0),
            ],
            [:test_exact],
            true,
            NLPDiagnostics.EvaluationFailure[],
        )
        flat_shift_report = NLPDiagnostics.analyze_reduced_hessian(
            flat_shift_evaluation,
            flat_shift_hessian;
            active_rows = Int[],
            expected_modes = [
                NLPDiagnostics.ExpectedNullspaceMode(
                    :common_shift,
                    [s1, s2],
                    [1.0, 1.0],
                ),
                NLPDiagnostics.ExpectedNullspaceMode(
                    :differential_shift,
                    [s1, s2],
                    [1.0, -1.0],
                ),
            ],
        )
        @test length(findings(
            flat_shift_report,
            :reduced_hessian_candidate_uniform_flat_direction,
        )) == 1
        @test length(findings(
            flat_shift_report,
            :reduced_hessian_expected_flat_mode_observed,
        )) == 1
        @test length(findings(
            flat_shift_report,
            :reduced_hessian_expected_flat_mode_not_observed,
        )) == 1

        compact_model = new_model()
        c1, c2, c3 = MOI.add_variables(compact_model, 3)
        compact_evaluation = NLPDiagnostics.evaluate_numerical(
            compact_model, [0.0, 0.0, 0.0],
        )
        compact_hessian = NLPDiagnostics.HessianEvaluation(
            compact_evaluation.point,
            1.0,
            zeros(3),
            NLPDiagnostics.HessianEntry{Float64}[
                NLPDiagnostics.HessianEntry(1, 1, 1.0),
                NLPDiagnostics.HessianEntry(1, 2, -1.0),
                NLPDiagnostics.HessianEntry(2, 2, 1.0),
                NLPDiagnostics.HessianEntry(3, 3, 2.0),
            ],
            [:test_exact],
            true,
            NLPDiagnostics.EvaluationFailure[],
        )
        compact_report = NLPDiagnostics.analyze_reduced_hessian(
            compact_evaluation,
            compact_hessian;
            active_rows = Int[],
        )
        compact_findings = findings(
            compact_report,
            :reduced_hessian_candidate_compact_flat_direction,
        )
        @test length(compact_findings) == 1
        @test length(only(compact_findings).affected) == 2

        persistent_evaluation = NLPDiagnostics.evaluate_numerical(
            compact_model, [0.01, 0.01, 0.2]; label = "nearby",
        )
        persistent_hessian = NLPDiagnostics.HessianEvaluation(
            persistent_evaluation.point,
            1.0,
            zeros(3),
            NLPDiagnostics.HessianEntry{Float64}[
                NLPDiagnostics.HessianEntry(1, 1, 1.0),
                NLPDiagnostics.HessianEntry(1, 2, -1.0),
                NLPDiagnostics.HessianEntry(2, 2, 1.0),
                NLPDiagnostics.HessianEntry(3, 3, 2.0),
            ],
            [:test_exact],
            true,
            NLPDiagnostics.EvaluationFailure[],
        )
        persistent_analysis = NLPDiagnostics.reduced_hessian_analysis(
            persistent_evaluation,
            persistent_hessian;
            active_rows = Int[],
        )
        compact_analysis = NLPDiagnostics.reduced_hessian_analysis(
            compact_evaluation,
            compact_hessian;
            active_rows = Int[],
        )
        persistence_report = NLPDiagnostics.analyze_reduced_hessian_persistence([
            NLPDiagnostics.ReducedHessianSnapshot(compact_evaluation, compact_analysis),
            NLPDiagnostics.ReducedHessianSnapshot(persistent_evaluation, persistent_analysis),
        ])
        @test length(findings(
            persistence_report,
            :reduced_hessian_flat_subspace_persistent,
        )) == 1
        reduced_hessian_short_report =
            NLPDiagnostics.analyze_reduced_hessian_persistence([
                NLPDiagnostics.ReducedHessianSnapshot(
                    compact_evaluation, compact_analysis,
                ),
            ])
        reduced_hessian_short_reason = only(filter(
            item -> item["code"] == "reduced_hessian_persistence_unavailable",
            NLPDiagnostics.report_data(reduced_hessian_short_report)[
                "unavailable_reasons"
            ],
        ))
        @test reduced_hessian_short_reason["category"] == "numerical"
        @test reduced_hessian_short_reason["stage"] ==
              "reduced_hessian_persistence"
        expected_subspace_report = NLPDiagnostics.analyze_reduced_hessian_persistence(
            [
                NLPDiagnostics.ReducedHessianSnapshot(compact_evaluation, compact_analysis),
                NLPDiagnostics.ReducedHessianSnapshot(persistent_evaluation, persistent_analysis),
            ];
            expected_modes = [
                NLPDiagnostics.ExpectedNullspaceMode(
                    :common_shift,
                    [c1, c2],
                    [1.0, 1.0],
                ),
            ],
        )
        @test length(findings(
            expected_subspace_report,
            :reduced_hessian_persistent_expected_mode_subspace_observed,
        )) == 1
        unexpected_subspace_report = NLPDiagnostics.analyze_reduced_hessian_persistence(
            [
                NLPDiagnostics.ReducedHessianSnapshot(compact_evaluation, compact_analysis),
                NLPDiagnostics.ReducedHessianSnapshot(persistent_evaluation, persistent_analysis),
            ];
            expected_modes = [
                NLPDiagnostics.ExpectedNullspaceMode(
                    :differential_shift,
                    [c1, c2],
                    [1.0, -1.0],
                ),
            ],
        )
        @test length(findings(
            unexpected_subspace_report,
            :reduced_hessian_persistent_expected_mode_subspace_not_observed,
        )) == 1
        misaligned_flat_expected_mode = NLPDiagnostics.ExpectedNullspaceMode(
            :misaligned_flat_mode,
            [c1, MOI.VariableIndex(999)],
            [1.0, 1.0],
        )
        misaligned_flat_expected_report =
            NLPDiagnostics.analyze_reduced_hessian_persistence(
                compact_model,
                [
                    NLPDiagnostics.ReducedHessianSnapshot(compact_evaluation, compact_analysis),
                    NLPDiagnostics.ReducedHessianSnapshot(persistent_evaluation, persistent_analysis),
                ];
                expected_modes = [misaligned_flat_expected_mode],
                include_port_topology_modes = false,
            )
        misaligned_flat_expected_reason = only(filter(
            item -> item["code"] ==
                "reduced_hessian_expected_mode_persistence_unavailable",
            NLPDiagnostics.report_data(misaligned_flat_expected_report)[
                "unavailable_reasons"
            ],
        ))
        @test misaligned_flat_expected_reason["category"] == "input"
        @test misaligned_flat_expected_reason["stage"] ==
              "reduced_hessian_expected_mode_persistence"
        @test length(findings(
            persistence_report,
            :reduced_hessian_flat_support_persistent,
        )) == 1
        @test length(findings(
            persistence_report,
            :reduced_hessian_active_rows_persistent,
        )) == 1
        @test length(findings(
            persistence_report,
            :reduced_hessian_active_jacobian_rank_persistent,
        )) == 1
        spanning_report = NLPDiagnostics.analyze_reduced_hessian_persistence(
            compact_model,
            [
                NLPDiagnostics.ReducedHessianSnapshot(compact_evaluation, compact_analysis),
                NLPDiagnostics.ReducedHessianSnapshot(persistent_evaluation, persistent_analysis),
            ],
        )
        @test length(findings(
            spanning_report,
            :reduced_hessian_persistent_flat_spans_components,
        )) == 1
        opaque_scope_model = new_model()
        MOI.add_variables(opaque_scope_model, 3)
        MOI.set(opaque_scope_model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        MOI.set(
            opaque_scope_model,
            MOI.NLPBlock(),
            MOI.NLPBlockData(
                MOI.NLPBoundsPair.([0.0, 0.0, 0.0], [0.0, 0.0, 0.0]),
                TestNLPEvaluator(),
                true,
            ),
        )
        opaque_scope_report = NLPDiagnostics.analyze_reduced_hessian_persistence(
            opaque_scope_model,
            [
                NLPDiagnostics.ReducedHessianSnapshot(compact_evaluation, compact_analysis),
                NLPDiagnostics.ReducedHessianSnapshot(persistent_evaluation, persistent_analysis),
            ];
            components = NLPDiagnostics.ComponentMetadata[],
            include_port_topology_modes = false,
        )
        opaque_scope_reason = only(filter(
            item -> item["code"] ==
                "reduced_hessian_persistent_flat_structural_scope_unavailable",
            NLPDiagnostics.report_data(opaque_scope_report)["unavailable_reasons"],
        ))
        @test opaque_scope_reason["category"] == "domain"
        @test opaque_scope_reason["stage"] ==
              "reduced_hessian_persistent_flat_structural_scope"
        unaligned_scope_model = new_model()
        MOI.add_variable(unaligned_scope_model)
        unaligned_scope_report = NLPDiagnostics.analyze_reduced_hessian_persistence(
            unaligned_scope_model,
            [
                NLPDiagnostics.ReducedHessianSnapshot(compact_evaluation, compact_analysis),
                NLPDiagnostics.ReducedHessianSnapshot(persistent_evaluation, persistent_analysis),
            ];
            components = NLPDiagnostics.ComponentMetadata[],
            include_port_topology_modes = false,
        )
        unaligned_scope_reason = only(filter(
            item -> item["code"] ==
                "reduced_hessian_persistent_flat_structural_scope_unavailable" &&
                item["category"] == "input",
            NLPDiagnostics.report_data(unaligned_scope_report)["unavailable_reasons"],
        ))
        @test unaligned_scope_reason["category"] == "input"
        @test unaligned_scope_reason["stage"] ==
              "reduced_hessian_persistent_flat_structural_scope"
        linking_constraint = MOI.ScalarAffineFunction(
            [MOI.ScalarAffineTerm(1.0, c1), MOI.ScalarAffineTerm(-1.0, c2)],
            0.0,
        )
        MOI.add_constraint(compact_model, linking_constraint, MOI.EqualTo(0.0))
        localized_report = NLPDiagnostics.analyze_reduced_hessian_persistence(
            compact_model,
            [
                NLPDiagnostics.ReducedHessianSnapshot(compact_evaluation, compact_analysis),
                NLPDiagnostics.ReducedHessianSnapshot(persistent_evaluation, persistent_analysis),
            ],
        )
        @test length(findings(
            localized_report,
            :reduced_hessian_persistent_flat_structurally_localized,
        )) == 1
        component_overlap_report = NLPDiagnostics.analyze_reduced_hessian_persistence(
            compact_model,
            [
                NLPDiagnostics.ReducedHessianSnapshot(compact_evaluation, compact_analysis),
                NLPDiagnostics.ReducedHessianSnapshot(persistent_evaluation, persistent_analysis),
            ];
            components = [
                NLPDiagnostics.ComponentMetadata(
                    :test_device,
                    "local";
                    variables = [c1, c2],
                    units = Dict(:voltage => "pu"),
                ),
                NLPDiagnostics.ComponentMetadata(
                    :test_device,
                    "outside";
                    variables = [c3],
                ),
            ],
        )
        overlaps = findings(
            component_overlap_report,
            :reduced_hessian_persistent_flat_declared_component_overlap,
        )
        @test length(overlaps) == 1
        @test length(only(overlaps).affected) == 2

        changing_hessian = NLPDiagnostics.HessianEvaluation(
            persistent_evaluation.point,
            1.0,
            zeros(3),
            NLPDiagnostics.HessianEntry{Float64}[
                NLPDiagnostics.HessianEntry(1, 1, 1.0),
                NLPDiagnostics.HessianEntry(1, 2, 1.0),
                NLPDiagnostics.HessianEntry(2, 2, 1.0),
                NLPDiagnostics.HessianEntry(3, 3, 2.0),
            ],
            [:test_exact],
            true,
            NLPDiagnostics.EvaluationFailure[],
        )
        changing_analysis = NLPDiagnostics.reduced_hessian_analysis(
            persistent_evaluation,
            changing_hessian;
            active_rows = Int[],
        )
        changing_report = NLPDiagnostics.analyze_reduced_hessian_persistence([
            NLPDiagnostics.ReducedHessianSnapshot(compact_evaluation, compact_analysis),
            NLPDiagnostics.ReducedHessianSnapshot(persistent_evaluation, changing_analysis),
        ])
        @test length(findings(
            changing_report,
            :reduced_hessian_flat_subspace_not_persistent,
        )) == 1
        @test length(findings(
            changing_report,
            :reduced_hessian_flat_support_persistent,
        )) == 1

        support_changing_hessian = NLPDiagnostics.HessianEvaluation(
            persistent_evaluation.point,
            1.0,
            zeros(3),
            NLPDiagnostics.HessianEntry{Float64}[
                NLPDiagnostics.HessianEntry(1, 1, 2.0),
                NLPDiagnostics.HessianEntry(2, 2, 1.0),
                NLPDiagnostics.HessianEntry(2, 3, -1.0),
                NLPDiagnostics.HessianEntry(3, 3, 1.0),
            ],
            [:test_exact],
            true,
            NLPDiagnostics.EvaluationFailure[],
        )
        support_changing_analysis = NLPDiagnostics.reduced_hessian_analysis(
            persistent_evaluation,
            support_changing_hessian;
            active_rows = Int[],
        )
        support_changing_report = NLPDiagnostics.analyze_reduced_hessian_persistence([
            NLPDiagnostics.ReducedHessianSnapshot(compact_evaluation, compact_analysis),
            NLPDiagnostics.ReducedHessianSnapshot(
                persistent_evaluation, support_changing_analysis,
            ),
        ])
        @test length(findings(
            support_changing_report,
            :reduced_hessian_flat_support_changing,
        )) == 1

        active_model = new_model()
        a1, a2 = MOI.add_variables(active_model, 2)
        active_constraint = MOI.ScalarAffineFunction(
            [MOI.ScalarAffineTerm(1.0, a1), MOI.ScalarAffineTerm(-1.0, a2)],
            0.0,
        )
        MOI.add_constraint(active_model, active_constraint, MOI.EqualTo(0.0))
        active_evaluation_1 = NLPDiagnostics.evaluate_numerical(
            active_model, [0.0, 0.0]; label = "active",
        )
        active_evaluation_2 = NLPDiagnostics.evaluate_numerical(
            active_model, [0.01, 0.01]; label = "inactive",
        )
        active_hessian_1 = NLPDiagnostics.HessianEvaluation(
            active_evaluation_1.point,
            1.0,
            zeros(2),
            NLPDiagnostics.HessianEntry{Float64}[],
            [:test_exact],
            true,
            NLPDiagnostics.EvaluationFailure[],
        )
        active_hessian_2 = NLPDiagnostics.HessianEvaluation(
            active_evaluation_2.point,
            1.0,
            zeros(2),
            NLPDiagnostics.HessianEntry{Float64}[],
            [:test_exact],
            true,
            NLPDiagnostics.EvaluationFailure[],
        )
        active_analysis_1 = NLPDiagnostics.reduced_hessian_analysis(
            active_evaluation_1, active_hessian_1; active_rows = [1],
        )
        active_analysis_2 = NLPDiagnostics.reduced_hessian_analysis(
            active_evaluation_2, active_hessian_2; active_rows = Int[],
        )
        active_changing_report = NLPDiagnostics.analyze_reduced_hessian_persistence([
            NLPDiagnostics.ReducedHessianSnapshot(
                active_evaluation_1, active_analysis_1,
            ),
            NLPDiagnostics.ReducedHessianSnapshot(
                active_evaluation_2, active_analysis_2,
            ),
        ])
        @test length(findings(
            active_changing_report,
            :reduced_hessian_active_rows_changing,
        )) == 1
        @test length(findings(
            active_changing_report,
            :reduced_hessian_active_jacobian_rank_changing,
        )) == 1

        multiplier_hessian_1 = NLPDiagnostics.HessianEvaluation(
            active_evaluation_1.point,
            1.0,
            [1.0],
            NLPDiagnostics.HessianEntry{Float64}[],
            [:test_exact],
            true,
            NLPDiagnostics.EvaluationFailure[],
        )
        multiplier_hessian_2 = NLPDiagnostics.HessianEvaluation(
            active_evaluation_2.point,
            1.0,
            [1.0],
            NLPDiagnostics.HessianEntry{Float64}[],
            [:test_exact],
            true,
            NLPDiagnostics.EvaluationFailure[],
        )
        multiplier_analysis_1 = NLPDiagnostics.reduced_hessian_analysis(
            active_evaluation_1, multiplier_hessian_1; active_rows = [1],
        )
        multiplier_analysis_2 = NLPDiagnostics.reduced_hessian_analysis(
            active_evaluation_2, multiplier_hessian_2; active_rows = [1],
        )
        multiplier_persistent_report =
            NLPDiagnostics.analyze_reduced_hessian_persistence([
                NLPDiagnostics.ReducedHessianSnapshot(
                    active_evaluation_1,
                    multiplier_analysis_1,
                    multiplier_hessian_1,
                ),
                NLPDiagnostics.ReducedHessianSnapshot(
                    active_evaluation_2,
                    multiplier_analysis_2,
                    multiplier_hessian_2,
                ),
            ])
        @test length(findings(
            multiplier_persistent_report,
            :reduced_hessian_multiplier_representative_persistent,
        )) == 1
        malformed_multiplier_hessian = NLPDiagnostics.HessianEvaluation(
            active_evaluation_2.point,
            1.0,
            Float64[],
            NLPDiagnostics.HessianEntry{Float64}[],
            [:test_exact],
            true,
            NLPDiagnostics.EvaluationFailure[],
        )
        malformed_multiplier_report =
            NLPDiagnostics.analyze_reduced_hessian_persistence([
                NLPDiagnostics.ReducedHessianSnapshot(
                    active_evaluation_1,
                    multiplier_analysis_1,
                    multiplier_hessian_1,
                ),
                NLPDiagnostics.ReducedHessianSnapshot(
                    active_evaluation_2,
                    multiplier_analysis_2,
                    malformed_multiplier_hessian,
                ),
            ])
        malformed_multiplier_reason = only(filter(
            item -> item["code"] ==
                "reduced_hessian_multiplier_persistence_unavailable",
            NLPDiagnostics.report_data(malformed_multiplier_report)[
                "unavailable_reasons"
            ],
        ))
        @test malformed_multiplier_reason["category"] == "numerical"
        @test malformed_multiplier_reason["stage"] ==
              "reduced_hessian_multiplier_persistence"
        multiplier_changing_hessian = NLPDiagnostics.HessianEvaluation(
            active_evaluation_2.point,
            1.0,
            [2.0],
            NLPDiagnostics.HessianEntry{Float64}[],
            [:test_exact],
            true,
            NLPDiagnostics.EvaluationFailure[],
        )
        multiplier_changing_report =
            NLPDiagnostics.analyze_reduced_hessian_persistence([
                NLPDiagnostics.ReducedHessianSnapshot(
                    active_evaluation_1,
                    multiplier_analysis_1,
                    multiplier_hessian_1,
                ),
                NLPDiagnostics.ReducedHessianSnapshot(
                    active_evaluation_2,
                    multiplier_analysis_2,
                    multiplier_changing_hessian,
                ),
            ])
        @test length(findings(
            multiplier_changing_report,
            :reduced_hessian_multiplier_representative_changing,
        )) == 1

        scaling_model = new_model()
        scale_x, scale_y = MOI.add_variables(scaling_model, 2)
        scaling_quadratic = MOI.ScalarQuadraticFunction(
            [MOI.ScalarQuadraticTerm(1.0, scale_x, scale_x)],
            MOI.ScalarAffineTerm{Float64}[],
            0.0,
        )
        scaling_affine = MOI.ScalarAffineFunction(
            [MOI.ScalarAffineTerm(1.0, scale_y)],
            0.0,
        )
        MOI.add_constraint(scaling_model, scaling_quadratic, MOI.EqualTo(0.0))
        MOI.add_constraint(scaling_model, scaling_affine, MOI.EqualTo(0.0))
        scaling_evaluation_1 = NLPDiagnostics.evaluate_numerical(
            scaling_model, [1.0, 0.0]; label = "small_scale",
        )
        scaling_evaluation_2 = NLPDiagnostics.evaluate_numerical(
            scaling_model, [100.0, 0.0]; label = "large_scale",
        )
        scaling_hessian_1 = NLPDiagnostics.HessianEvaluation(
            scaling_evaluation_1.point,
            1.0,
            [0.0, 0.0],
            NLPDiagnostics.HessianEntry{Float64}[],
            [:test_exact],
            true,
            NLPDiagnostics.EvaluationFailure[],
        )
        scaling_hessian_2 = NLPDiagnostics.HessianEvaluation(
            scaling_evaluation_2.point,
            1.0,
            [0.0, 0.0],
            NLPDiagnostics.HessianEntry{Float64}[],
            [:test_exact],
            true,
            NLPDiagnostics.EvaluationFailure[],
        )
        scaling_analysis_1 = NLPDiagnostics.reduced_hessian_analysis(
            scaling_evaluation_1, scaling_hessian_1; active_rows = Int[],
        )
        scaling_analysis_2 = NLPDiagnostics.reduced_hessian_analysis(
            scaling_evaluation_2, scaling_hessian_2; active_rows = Int[],
        )
        misaligned_scaling_evaluation = NLPDiagnostics.NumericalEvaluation{Float64}(
            scaling_evaluation_2.point,
            scaling_evaluation_2.objective_value,
            scaling_evaluation_2.objective_source,
            scaling_evaluation_2.objective_gradient,
            scaling_evaluation_2.constraint_values,
            collect(reverse(scaling_evaluation_2.constraint_sources)),
            scaling_evaluation_2.jacobian_entries,
            scaling_evaluation_2.jacobian_row_methods,
            scaling_evaluation_2.capabilities,
            scaling_evaluation_2.failures,
        )
        multiplier_alignment_hessian_1 = NLPDiagnostics.HessianEvaluation(
            scaling_evaluation_1.point,
            1.0,
            [1.0, 1.0],
            NLPDiagnostics.HessianEntry{Float64}[],
            [:test_exact],
            true,
            NLPDiagnostics.EvaluationFailure[],
        )
        multiplier_alignment_hessian_2 = NLPDiagnostics.HessianEvaluation(
            misaligned_scaling_evaluation.point,
            1.0,
            [1.0, 1.0],
            NLPDiagnostics.HessianEntry{Float64}[],
            [:test_exact],
            true,
            NLPDiagnostics.EvaluationFailure[],
        )
        multiplier_alignment_report =
            NLPDiagnostics.analyze_reduced_hessian_persistence([
                NLPDiagnostics.ReducedHessianSnapshot(
                    scaling_evaluation_1,
                    scaling_analysis_1,
                    multiplier_alignment_hessian_1,
                ),
                NLPDiagnostics.ReducedHessianSnapshot(
                    misaligned_scaling_evaluation,
                    scaling_analysis_2,
                    multiplier_alignment_hessian_2,
                ),
            ])
        multiplier_alignment_reason = only(filter(
            item -> item["code"] ==
                "reduced_hessian_multiplier_persistence_unavailable",
            NLPDiagnostics.report_data(multiplier_alignment_report)[
                "unavailable_reasons"
            ],
        ))
        @test multiplier_alignment_reason["category"] == "input"
        @test multiplier_alignment_reason["stage"] ==
              "reduced_hessian_multiplier_persistence"
        scaling_changing_report =
            NLPDiagnostics.analyze_reduced_hessian_persistence([
                NLPDiagnostics.ReducedHessianSnapshot(
                    scaling_evaluation_1, scaling_analysis_1,
                ),
                NLPDiagnostics.ReducedHessianSnapshot(
                    scaling_evaluation_2, scaling_analysis_2,
                ),
            ])
        @test length(findings(
            scaling_changing_report,
            :reduced_hessian_jacobian_scaling_changing,
        )) == 1
        swapped_point = NLPDiagnostics.EvaluationPoint(
            [scale_y, scale_x], [0.0, 100.0]; label = "swapped_coordinates",
        )
        misaligned_coordinate_evaluation = NLPDiagnostics.NumericalEvaluation{Float64}(
            swapped_point,
            scaling_evaluation_2.objective_value,
            scaling_evaluation_2.objective_source,
            scaling_evaluation_2.objective_gradient,
            scaling_evaluation_2.constraint_values,
            scaling_evaluation_2.constraint_sources,
            scaling_evaluation_2.jacobian_entries,
            scaling_evaluation_2.jacobian_row_methods,
            scaling_evaluation_2.capabilities,
            scaling_evaluation_2.failures,
        )
        reduced_hessian_alignment_report =
            NLPDiagnostics.analyze_reduced_hessian_persistence([
                NLPDiagnostics.ReducedHessianSnapshot(
                    scaling_evaluation_1, scaling_analysis_1,
                ),
                NLPDiagnostics.ReducedHessianSnapshot(
                    misaligned_coordinate_evaluation, scaling_analysis_2,
                ),
            ])
        reduced_hessian_alignment_reason = only(filter(
            item -> item["code"] ==
                "reduced_hessian_persistence_unavailable" &&
                item["category"] == "input",
            NLPDiagnostics.report_data(reduced_hessian_alignment_report)[
                "unavailable_reasons"
            ],
        ))
        @test reduced_hessian_alignment_reason["stage"] ==
              "reduced_hessian_persistence"
        misaligned_scaling_report =
            NLPDiagnostics.analyze_reduced_hessian_persistence([
                NLPDiagnostics.ReducedHessianSnapshot(
                    scaling_evaluation_1, scaling_analysis_1,
                ),
                NLPDiagnostics.ReducedHessianSnapshot(
                    misaligned_scaling_evaluation, scaling_analysis_2,
                ),
            ])
        misaligned_scaling_reasons = NLPDiagnostics.report_data(
            misaligned_scaling_report,
        )["unavailable_reasons"]
        @test any(
            item -> item["code"] ==
                "reduced_hessian_active_row_persistence_unavailable" &&
                item["category"] == "input" &&
                item["stage"] == "reduced_hessian_active_row_persistence",
            misaligned_scaling_reasons,
        )
        @test any(
            item -> item["code"] ==
                "reduced_hessian_active_jacobian_rank_persistence_unavailable" &&
                item["category"] == "input" &&
                item["stage"] ==
                "reduced_hessian_active_jacobian_rank_persistence",
            misaligned_scaling_reasons,
        )
        @test any(
            item -> item["code"] ==
                "reduced_hessian_jacobian_scaling_persistence_unavailable" &&
                item["category"] == "input" &&
                item["stage"] ==
                "reduced_hessian_jacobian_scaling_persistence",
            misaligned_scaling_reasons,
        )
        malformed_scaling_evaluation = NLPDiagnostics.NumericalEvaluation{Float64}(
            scaling_evaluation_2.point,
            scaling_evaluation_2.objective_value,
            scaling_evaluation_2.objective_source,
            scaling_evaluation_2.objective_gradient,
            scaling_evaluation_2.constraint_values,
            scaling_evaluation_2.constraint_sources,
            NLPDiagnostics.JacobianEntry{Float64}[NLPDiagnostics.JacobianEntry(1, 1, NaN)],
            scaling_evaluation_2.jacobian_row_methods,
            scaling_evaluation_2.capabilities,
            scaling_evaluation_2.failures,
        )
        malformed_scaling_report =
            NLPDiagnostics.analyze_reduced_hessian_persistence([
                NLPDiagnostics.ReducedHessianSnapshot(
                    scaling_evaluation_1, scaling_analysis_1,
                ),
                NLPDiagnostics.ReducedHessianSnapshot(
                    malformed_scaling_evaluation, scaling_analysis_2,
                ),
            ])
        malformed_scaling_reason = only(filter(
            item -> item["code"] ==
                "reduced_hessian_jacobian_scaling_persistence_unavailable",
            NLPDiagnostics.report_data(malformed_scaling_report)[
                "unavailable_reasons"
            ],
        ))
        @test malformed_scaling_reason["category"] == "numerical"
        @test malformed_scaling_reason["stage"] ==
              "reduced_hessian_jacobian_scaling_persistence"

        spectral_hessian = NLPDiagnostics.HessianEvaluation(
            persistent_evaluation.point,
            1.0,
            zeros(3),
            NLPDiagnostics.HessianEntry{Float64}[
                NLPDiagnostics.HessianEntry(1, 1, 100.0),
                NLPDiagnostics.HessianEntry(1, 2, -100.0),
                NLPDiagnostics.HessianEntry(2, 2, 100.0),
                NLPDiagnostics.HessianEntry(3, 3, 200.0),
            ],
            [:test_exact],
            true,
            NLPDiagnostics.EvaluationFailure[],
        )
        spectral_analysis = NLPDiagnostics.reduced_hessian_analysis(
            persistent_evaluation, spectral_hessian; active_rows = Int[],
        )
        spectral_changing_report = NLPDiagnostics.analyze_reduced_hessian_persistence([
            NLPDiagnostics.ReducedHessianSnapshot(compact_evaluation, compact_analysis),
            NLPDiagnostics.ReducedHessianSnapshot(
                persistent_evaluation, spectral_analysis,
            ),
        ])
        @test length(findings(
            spectral_changing_report,
            :reduced_hessian_spectral_scale_changing,
        )) == 1
        malformed_spectral_analysis = NLPDiagnostics.ReducedHessianAnalysis{Float64}(
            spectral_analysis.available,
            spectral_analysis.reason,
            spectral_analysis.point,
            spectral_analysis.active_rows,
            spectral_analysis.jacobian_rank,
            spectral_analysis.tangent_dimension,
            spectral_analysis.jacobian_threshold,
            spectral_analysis.eigenvalue_threshold,
            [NaN],
            spectral_analysis.positive_eigenvalues,
            spectral_analysis.negative_eigenvalues,
            spectral_analysis.zero_eigenvalues,
            spectral_analysis.condition_estimate,
            spectral_analysis.tangent_basis,
            spectral_analysis.reduced_eigenvectors,
        )
        malformed_spectral_report =
            NLPDiagnostics.analyze_reduced_hessian_persistence([
                NLPDiagnostics.ReducedHessianSnapshot(
                    compact_evaluation, compact_analysis,
                ),
                NLPDiagnostics.ReducedHessianSnapshot(
                    persistent_evaluation, malformed_spectral_analysis,
                ),
            ])
        malformed_spectral_reason = only(filter(
            item -> item["code"] ==
                "reduced_hessian_spectral_scale_persistence_unavailable",
            NLPDiagnostics.report_data(malformed_spectral_report)[
                "unavailable_reasons"
            ],
        ))
        @test malformed_spectral_reason["category"] == "numerical"
        @test malformed_spectral_reason["stage"] ==
              "reduced_hessian_spectral_scale_persistence"
    end

    @testset "non-unit circular equalities are explicit scaling hints" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        Q = MOI.ScalarQuadraticFunction{Float64}
        QT = MOI.ScalarQuadraticTerm{Float64}
        circle = Q(
            [QT(2.0, x, x), QT(2.0, y, y)],
            MOI.ScalarAffineTerm{Float64}[],
            0.0,
        )
        MOI.add_constraint(model, circle, MOI.EqualTo(4.0))
        finding = only(findings(NLPDiagnostics.analyze_static(model), :nonunit_circular_constraint_radius))
        @test finding.domain == NLPDiagnostics.RepresentationalIssue
        @test finding.basis == NLPDiagnostics.HeuristicInterpretation
        @test Dict(finding.evidence[1].details)["radius"] == "2.0"

        near_unit = new_model()
        u, v = MOI.add_variables(near_unit, 2)
        near_unit_circle = Q(
            [QT(2.0, u, u), QT(2.0, v, v)],
            MOI.ScalarAffineTerm{Float64}[],
            0.0,
        )
        MOI.add_constraint(near_unit, near_unit_circle, MOI.EqualTo(1.0001))
        @test isempty(findings(
            NLPDiagnostics.analyze_static(
                near_unit;
                unit_circle_radius_tolerance = 1.0e-3,
            ),
            :nonunit_circular_constraint_radius,
        ))
        @test length(findings(
            NLPDiagnostics.analyze_static(
                near_unit;
                unit_circle_radius_tolerance = 1.0e-6,
            ),
            :nonunit_circular_constraint_radius,
        )) == 1

        nonlinear = new_model()
        u, v = MOI.add_variables(nonlinear, 2)
        sum_of_squares = MOI.ScalarNonlinearFunction(
            :+,
            Any[
                MOI.ScalarNonlinearFunction(:^, Any[u, 2]),
                MOI.ScalarNonlinearFunction(:*, Any[v, v]),
            ],
        )
        MOI.add_constraint(nonlinear, sum_of_squares, MOI.EqualTo(4.0))
        nonlinear_finding = only(findings(
            NLPDiagnostics.analyze_static(nonlinear),
            :nonunit_circular_constraint_radius,
        ))
        @test evidence_details(nonlinear_finding)["representation"] ==
              "ScalarNonlinearFunction"

        weighted_nonlinear = new_model()
        p, q = MOI.add_variables(weighted_nonlinear, 2)
        weighted_sum_of_squares = MOI.ScalarNonlinearFunction(
            :+,
            Any[
                MOI.ScalarNonlinearFunction(
                    :*,
                    Any[2.0, MOI.ScalarNonlinearFunction(:^, Any[p, 2])],
                ),
                MOI.ScalarNonlinearFunction(
                    :*,
                    Any[MOI.ScalarNonlinearFunction(:*, Any[q, q]), 2.0],
                ),
            ],
        )
        MOI.add_constraint(weighted_nonlinear, weighted_sum_of_squares, MOI.EqualTo(4.0))
        weighted_finding = only(findings(
            NLPDiagnostics.analyze_static(weighted_nonlinear),
            :nonunit_circular_constraint_radius,
        ))
        @test evidence_details(weighted_finding)["radius_squared"] == "2.0"

        nary_weighted_nonlinear = new_model()
        r, s = MOI.add_variables(nary_weighted_nonlinear, 2)
        nary_weighted_sum = MOI.ScalarNonlinearFunction(
            :+,
            Any[
                MOI.ScalarNonlinearFunction(:*, Any[2.0, r, r]),
                MOI.ScalarNonlinearFunction(:*, Any[s, 2.0, s]),
            ],
        )
        MOI.add_constraint(nary_weighted_nonlinear, nary_weighted_sum, MOI.EqualTo(4.0))
        nary_finding = only(findings(
            NLPDiagnostics.analyze_static(nary_weighted_nonlinear),
            :nonunit_circular_constraint_radius,
        ))
        @test evidence_details(nary_finding)["radius_squared"] == "2.0"

        coupled = new_model()
        m, n = MOI.add_variables(coupled, 2)
        coupled_quadratic = MOI.ScalarNonlinearFunction(
            :+,
            Any[
                MOI.ScalarNonlinearFunction(:^, Any[m, 2]),
                MOI.ScalarNonlinearFunction(:^, Any[n, 2]),
                MOI.ScalarNonlinearFunction(:*, Any[m, n]),
            ],
        )
        MOI.add_constraint(coupled, coupled_quadratic, MOI.EqualTo(4.0))
        coupled_report = NLPDiagnostics.analyze_static(coupled)
        @test isempty(findings(coupled_report, :nonunit_circular_constraint_radius))
        @test isempty(findings(coupled_report, :nonunit_ellipsoidal_constraint_axes))

        nonfinite = new_model()
        α, β = MOI.add_variables(nonfinite, 2)
        nonfinite_circle = Q(
            [QT(Inf, α, α), QT(2.0, β, β)],
            MOI.ScalarAffineTerm{Float64}[],
            0.0,
        )
        MOI.add_constraint(nonfinite, nonfinite_circle, MOI.EqualTo(4.0))
        nonfinite_report = NLPDiagnostics.analyze_static(nonfinite)
        @test isempty(findings(nonfinite_report, :nonunit_circular_constraint_radius))
        @test isempty(findings(nonfinite_report, :nonunit_ellipsoidal_constraint_axes))

        shifted_level_nonlinear = new_model()
        a, b = MOI.add_variables(shifted_level_nonlinear, 2)
        level_in_expression = MOI.ScalarNonlinearFunction(
            :-,
            Any[
                MOI.ScalarNonlinearFunction(
                    :+,
                    Any[
                        MOI.ScalarNonlinearFunction(:^, Any[a, 2]),
                        MOI.ScalarNonlinearFunction(:^, Any[b, 2]),
                    ],
                ),
                4.0,
            ],
        )
        MOI.add_constraint(shifted_level_nonlinear, level_in_expression, MOI.EqualTo(0.0))
        level_finding = only(findings(
            NLPDiagnostics.analyze_static(shifted_level_nonlinear),
            :nonunit_circular_constraint_radius,
        ))
        @test evidence_details(level_finding)["radius_squared"] == "4.0"

        bounded_circle = new_model()
        r, s = MOI.add_variables(bounded_circle, 2)
        bounded_circle_function = Q(
            [QT(2.0, r, r), QT(2.0, s, s)],
            MOI.ScalarAffineTerm{Float64}[],
            0.0,
        )
        MOI.add_constraint(bounded_circle, bounded_circle_function, MOI.EqualTo(4.0))
        MOI.add_constraint(bounded_circle, r, MOI.GreaterThan(3.0))
        circle_contradiction = only(findings(
            NLPDiagnostics.analyze_static(bounded_circle),
            :inconsistent_circular_implied_variable_bound,
        ))
        @test circle_contradiction.basis == NLPDiagnostics.MathematicalProof
        @test evidence_details(circle_contradiction)["derived_upper"] == "2.0"

        shifted_center_nonlinear = new_model()
        c, d = MOI.add_variables(shifted_center_nonlinear, 2)
        shifted_circle_expression = MOI.ScalarNonlinearFunction(
            :+,
            Any[
                MOI.ScalarNonlinearFunction(:^, Any[c, 2]),
                MOI.ScalarNonlinearFunction(:^, Any[d, 2]),
                MOI.ScalarNonlinearFunction(:*, Any[-4.0, c]),
                MOI.ScalarNonlinearFunction(:*, Any[6.0, d]),
            ],
        )
        # (c - 2)^2 + (d + 3)^2 = 4.
        MOI.add_constraint(shifted_center_nonlinear, shifted_circle_expression, MOI.EqualTo(-9.0))
        shifted_finding = only(findings(
            NLPDiagnostics.analyze_static(shifted_center_nonlinear),
            :nonunit_circular_constraint_radius,
        ))
        @test evidence_details(shifted_finding)["center"] == "[2.0, -3.0]"
        @test evidence_details(shifted_finding)["radius_squared"] == "4.0"
    end

    @testset "nonpositive circular equality levels have proven consequences" begin
        Q = MOI.ScalarQuadraticFunction{Float64}
        QT = MOI.ScalarQuadraticTerm{Float64}

        infeasible = new_model()
        x, y = MOI.add_variables(infeasible, 2)
        circle = Q(
            [QT(2.0, x, x), QT(2.0, y, y)],
            MOI.ScalarAffineTerm{Float64}[],
            0.0,
        )
        MOI.add_constraint(infeasible, circle, MOI.EqualTo(-1.0))
        negative = only(findings(
            NLPDiagnostics.analyze_static(infeasible),
            :infeasible_negative_radius_squared_circular_constraint,
        ))
        @test negative.severity == NLPDiagnostics.SeverityError
        @test negative.basis == NLPDiagnostics.MathematicalProof

        zero_radius = new_model()
        p, q = MOI.add_variables(zero_radius, 2)
        zero_circle = Q(
            [QT(2.0, p, p), QT(2.0, q, q)],
            MOI.ScalarAffineTerm{Float64}[],
            0.0,
        )
        MOI.add_constraint(zero_radius, zero_circle, MOI.EqualTo(0.0))
        zero = only(findings(
            NLPDiagnostics.analyze_static(zero_radius),
            :zero_radius_circular_constraint,
        ))
        @test zero.basis == NLPDiagnostics.MathematicalProof
        @test evidence_details(zero)["center"] == "[0.0, 0.0]"
        nonregular = only(findings(
            NLPDiagnostics.analyze_static(zero_radius),
            :nonregular_zero_radius_quadratic_fixing,
        ))
        @test nonregular.domain == NLPDiagnostics.NumericalIssue
        @test nonregular.basis == NLPDiagnostics.MathematicalProof

        zero_conflict = new_model()
        u, v = MOI.add_variables(zero_conflict, 2)
        conflicting_circle = Q(
            [QT(2.0, u, u), QT(2.0, v, v)],
            MOI.ScalarAffineTerm{Float64}[],
            0.0,
        )
        MOI.add_constraint(zero_conflict, conflicting_circle, MOI.EqualTo(0.0))
        MOI.add_constraint(zero_conflict, u, MOI.GreaterThan(1.0))
        contradiction = only(findings(
            NLPDiagnostics.analyze_static(zero_conflict),
            :inconsistent_zero_radius_circular_variable_bound,
        ))
        @test contradiction.basis == NLPDiagnostics.MathematicalProof
        @test evidence_details(contradiction)["implied_value"] == "0.0"
    end

    @testset "shifted isotropic quadratic equalities are completed statically" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        Q = MOI.ScalarQuadraticFunction{Float64}
        QT = MOI.ScalarQuadraticTerm{Float64}
        AT = MOI.ScalarAffineTerm{Float64}
        shifted_circle = Q(
            [QT(2.0, x, x), QT(2.0, y, y)],
            [AT(-4.0, x), AT(6.0, y)],
            0.0,
        )
        # (x - 2)^2 + (y + 3)^2 = 4.
        MOI.add_constraint(model, shifted_circle, MOI.EqualTo(-9.0))
        scaling = only(findings(
            NLPDiagnostics.analyze_static(model),
            :nonunit_circular_constraint_radius,
        ))
        @test evidence_details(scaling)["is_shifted"] == "true"
        @test evidence_details(scaling)["center"] == "[2.0, -3.0]"
        @test evidence_details(scaling)["radius_squared"] == "4.0"

        impossible = new_model()
        u, v = MOI.add_variables(impossible, 2)
        impossible_circle = Q(
            [QT(2.0, u, u), QT(2.0, v, v)],
            [AT(-4.0, u), AT(6.0, v)],
            0.0,
        )
        MOI.add_constraint(impossible, impossible_circle, MOI.EqualTo(-14.0))
        @test length(findings(
            NLPDiagnostics.analyze_static(impossible),
            :infeasible_negative_radius_squared_circular_constraint,
        )) == 1
    end

    @testset "diagonal ellipsoidal equalities expose axis scaling" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        Q = MOI.ScalarQuadraticFunction{Float64}
        QT = MOI.ScalarQuadraticTerm{Float64}
        AT = MOI.ScalarAffineTerm{Float64}
        ellipsoid = Q(
            [QT(2.0, x, x), QT(8.0, y, y)],
            [AT(-4.0, x), AT(8.0, y)],
            0.0,
        )
        # (x - 2)^2 + 4 * (y + 1)^2 = 4.
        MOI.add_constraint(model, ellipsoid, MOI.EqualTo(-4.0))
        scaling = only(findings(
            NLPDiagnostics.analyze_static(model),
            :nonunit_ellipsoidal_constraint_axes,
        ))
        @test evidence_details(scaling)["center"] == "[2.0, -1.0]"
        @test evidence_details(scaling)["semiaxes"] == "[2.0, 1.0]"

        impossible = new_model()
        u, v = MOI.add_variables(impossible, 2)
        impossible_ellipsoid = Q(
            [QT(2.0, u, u), QT(8.0, v, v)],
            [AT(-4.0, u), AT(8.0, v)],
            0.0,
        )
        MOI.add_constraint(impossible, impossible_ellipsoid, MOI.EqualTo(-9.0))
        @test length(findings(
            NLPDiagnostics.analyze_static(impossible),
            :infeasible_negative_level_diagonal_quadratic_constraint,
        )) == 1

        zero_level = new_model()
        p, q = MOI.add_variables(zero_level, 2)
        zero_ellipsoid = Q(
            [QT(2.0, p, p), QT(8.0, q, q)],
            [AT(-4.0, p), AT(8.0, q)],
            0.0,
        )
        MOI.add_constraint(zero_level, zero_ellipsoid, MOI.EqualTo(-8.0))
        fixed = only(findings(
            NLPDiagnostics.analyze_static(zero_level),
            :zero_level_diagonal_quadratic_constraint,
        ))
        @test fixed.basis == NLPDiagnostics.MathematicalProof
        @test evidence_details(fixed)["center"] == "[2.0, -1.0]"
        @test length(findings(
            NLPDiagnostics.analyze_static(zero_level),
            :nonregular_zero_level_diagonal_quadratic_fixing,
        )) == 1

        minimum_conflict = new_model()
        c, d = MOI.add_variables(minimum_conflict, 2)
        conflicting_minimum_bowl = Q(
            [QT(2.0, c, c), QT(8.0, d, d)],
            [AT(-4.0, c), AT(8.0, d)],
            3.0,
        )
        MOI.add_constraint(minimum_conflict, conflicting_minimum_bowl, MOI.LessThan(-5.0))
        MOI.add_constraint(minimum_conflict, c, MOI.GreaterThan(3.0))
        minimum_contradiction = only(findings(
            NLPDiagnostics.analyze_static(minimum_conflict),
            :inconsistent_diagonal_quadratic_minimum_variable_bound,
        ))
        @test minimum_contradiction.basis == NLPDiagnostics.MathematicalProof
        @test evidence_details(minimum_contradiction)["implied_value"] == "2.0"

        nonlinear = new_model()
        a, b = MOI.add_variables(nonlinear, 2)
        nonlinear_ellipsoid = MOI.ScalarNonlinearFunction(
            :+,
            Any[
                MOI.ScalarNonlinearFunction(:^, Any[a, 2]),
                MOI.ScalarNonlinearFunction(
                    :*,
                    Any[4.0, MOI.ScalarNonlinearFunction(:^, Any[b, 2])],
                ),
                MOI.ScalarNonlinearFunction(:*, Any[-4.0, a]),
                MOI.ScalarNonlinearFunction(:*, Any[8.0, b]),
            ],
        )
        # (a - 2)^2 + 4 * (b + 1)^2 = 4.
        MOI.add_constraint(nonlinear, nonlinear_ellipsoid, MOI.EqualTo(-4.0))
        nonlinear_scaling = only(findings(
            NLPDiagnostics.analyze_static(nonlinear),
            :nonunit_ellipsoidal_constraint_axes,
        ))
        @test evidence_details(nonlinear_scaling)["semiaxes"] == "[2.0, 1.0]"
        @test evidence_details(nonlinear_scaling)["representation"] ==
              "ScalarNonlinearFunction"

        bounded_ellipsoid = new_model()
        g, h = MOI.add_variables(bounded_ellipsoid, 2)
        bounded_ellipsoid_function = Q(
            [QT(2.0, g, g), QT(8.0, h, h)],
            [AT(-4.0, g), AT(8.0, h)],
            0.0,
        )
        MOI.add_constraint(bounded_ellipsoid, bounded_ellipsoid_function, MOI.EqualTo(-4.0))
        MOI.add_constraint(bounded_ellipsoid, g, MOI.GreaterThan(5.0))
        ellipsoid_contradiction = only(findings(
            NLPDiagnostics.analyze_static(bounded_ellipsoid),
            :inconsistent_ellipsoidal_implied_variable_bound,
        ))
        @test ellipsoid_contradiction.basis == NLPDiagnostics.MathematicalProof
        @test evidence_details(ellipsoid_contradiction)["derived_upper"] == "4.0"

        domain_model = new_model()
        domain_x, domain_y = MOI.add_variables(domain_model, 2)
        domain_ellipsoid = Q(
            [QT(2.0, domain_x, domain_x), QT(8.0, domain_y, domain_y)],
            [AT(-4.0, domain_x), AT(8.0, domain_y)],
            0.0,
        )
        # (x - 2)^2 + 4 * (y + 1)^2 = 1, so x ∈ [1, 3].
        MOI.add_constraint(domain_model, domain_ellipsoid, MOI.EqualTo(-7.0))
        propagated_domains = NLPDiagnostics._domain_variable_intervals(
            NLPDiagnostics.snapshot(domain_model),
        )
        @test propagated_domains[domain_x].lower == 1.0
        @test propagated_domains[domain_x].upper == 3.0

        # Geometry-derived coordinate intervals feed the generic expression
        # domain pass, but remain analysis-only: the model has no scalar bound
        # constraint on `domain_x` other than its ellipsoidal equality.
        MOI.add_constraint(
            domain_model,
            MOI.ScalarNonlinearFunction(:log, Any[domain_x]),
            MOI.LessThan(10.0),
        )
        @test isempty(NLPDiagnostics.domain_issues(domain_model))

        nonlinear_domain_model = new_model()
        nonlinear_x, nonlinear_y = MOI.add_variables(nonlinear_domain_model, 2)
        # (x - 2)^2 + 4 * (y + 1)^2 = 1, represented as a nonlinear tree.
        nonlinear_domain_ellipsoid = MOI.ScalarNonlinearFunction(
            :+,
            Any[
                MOI.ScalarNonlinearFunction(:^, Any[nonlinear_x, 2]),
                MOI.ScalarNonlinearFunction(
                    :*,
                    Any[4.0, MOI.ScalarNonlinearFunction(:^, Any[nonlinear_y, 2])],
                ),
                MOI.ScalarNonlinearFunction(:*, Any[-4.0, nonlinear_x]),
                MOI.ScalarNonlinearFunction(:*, Any[8.0, nonlinear_y]),
            ],
        )
        MOI.add_constraint(
            nonlinear_domain_model,
            nonlinear_domain_ellipsoid,
            MOI.EqualTo(-7.0),
        )
        MOI.add_constraint(
            nonlinear_domain_model,
            MOI.ScalarNonlinearFunction(:log, Any[nonlinear_x]),
            MOI.LessThan(10.0),
        )
        @test isempty(NLPDiagnostics.domain_issues(nonlinear_domain_model))

        affine_domain_model = new_model()
        affine_a, affine_b, affine_c = MOI.add_variables(affine_domain_model, 3)
        MOI.add_constraint(affine_domain_model, affine_a, MOI.Interval(0.0, 1.0))
        # The second equality becomes informative only after the first has
        # propagated b's interval; c is then strictly positive.
        MOI.add_constraint(
            affine_domain_model,
            MOI.ScalarAffineFunction(
                [MOI.ScalarAffineTerm(1.0, affine_a),
                 MOI.ScalarAffineTerm(1.0, affine_b)],
                0.0,
            ),
            MOI.EqualTo(3.0),
        )
        MOI.add_constraint(
            affine_domain_model,
            MOI.ScalarAffineFunction(
                [MOI.ScalarAffineTerm(1.0, affine_b),
                 MOI.ScalarAffineTerm(1.0, affine_c)],
                0.0,
            ),
            MOI.EqualTo(4.0),
        )
        MOI.add_constraint(
            affine_domain_model,
            MOI.ScalarNonlinearFunction(:log, Any[affine_c]),
            MOI.LessThan(10.0),
        )
        affine_domains = NLPDiagnostics._domain_variable_intervals(
            NLPDiagnostics.snapshot(affine_domain_model),
        )
        @test affine_domains[affine_b].lower == 2.0
        @test affine_domains[affine_b].upper == 3.0
        @test affine_domains[affine_c].lower == 1.0
        @test affine_domains[affine_c].upper == 2.0
        @test isempty(NLPDiagnostics.domain_issues(affine_domain_model))

        monotone_domain_model = new_model()
        monotone_x, monotone_y, monotone_z = MOI.add_variables(
            monotone_domain_model,
            3,
        )
        MOI.add_constraint(
            monotone_domain_model,
            MOI.ScalarNonlinearFunction(:log, Any[monotone_x]),
            MOI.GreaterThan(0.0),
        )
        MOI.add_constraint(
            monotone_domain_model,
            MOI.ScalarNonlinearFunction(:exp, Any[monotone_y]),
            MOI.LessThan(exp(2.0)),
        )
        MOI.add_constraint(
            monotone_domain_model,
            MOI.ScalarNonlinearFunction(:sqrt, Any[monotone_z]),
            MOI.GreaterThan(2.0),
        )
        # These downstream expressions need the input ranges inferred from
        # the monotone rows above; no direct scalar bounds are declared.
        MOI.add_constraint(
            monotone_domain_model,
            MOI.ScalarNonlinearFunction(
                :sqrt,
                Any[MOI.ScalarAffineFunction(
                    [MOI.ScalarAffineTerm(1.0, monotone_x)],
                    -0.5,
                )],
            ),
            MOI.LessThan(10.0),
        )
        MOI.add_constraint(
            monotone_domain_model,
            MOI.ScalarNonlinearFunction(
                :log,
                Any[MOI.ScalarAffineFunction(
                    [MOI.ScalarAffineTerm(-1.0, monotone_y)],
                    3.0,
                )],
            ),
            MOI.LessThan(10.0),
        )
        MOI.add_constraint(
            monotone_domain_model,
            MOI.ScalarNonlinearFunction(:log, Any[monotone_z]),
            MOI.LessThan(10.0),
        )
        monotone_domains = NLPDiagnostics._domain_variable_intervals(
            NLPDiagnostics.snapshot(monotone_domain_model),
        )
        @test monotone_domains[monotone_x].lower == 1.0
        @test monotone_domains[monotone_y].upper ≈ 2.0 atol = 1.0e-12
        @test monotone_domains[monotone_z].lower == 4.0
        @test isempty(NLPDiagnostics.domain_issues(monotone_domain_model))

        log1mexp_domain_model = new_model()
        log1mexp_x = MOI.add_variable(log1mexp_domain_model)
        MOI.add_constraint(
            log1mexp_domain_model,
            MOI.ScalarNonlinearFunction(:log1mexp, Any[log1mexp_x]),
            MOI.GreaterThan(-1.0),
        )
        # log1mexp(x) ≥ -1 implies x ≤ log(1 - exp(-1)), so -x is
        # strictly positive for the downstream square root.
        MOI.add_constraint(
            log1mexp_domain_model,
            MOI.ScalarNonlinearFunction(
                :sqrt,
                Any[MOI.ScalarNonlinearFunction(:-, Any[log1mexp_x])],
            ),
            MOI.LessThan(10.0),
        )
        log1mexp_domains = NLPDiagnostics._domain_variable_intervals(
            NLPDiagnostics.snapshot(log1mexp_domain_model),
        )
        @test log1mexp_domains[log1mexp_x].upper ≈
              log1p(-exp(-1.0)) atol = 1.0e-12
        @test isempty(NLPDiagnostics.domain_issues(log1mexp_domain_model))

        softplus_domain_model = new_model()
        softplus_x = MOI.add_variable(softplus_domain_model)
        MOI.add_constraint(
            softplus_domain_model,
            MOI.ScalarNonlinearFunction(:softplus, Any[softplus_x]),
            MOI.GreaterThan(2.0),
        )
        MOI.add_constraint(
            softplus_domain_model,
            MOI.ScalarNonlinearFunction(:log, Any[softplus_x]),
            MOI.LessThan(10.0),
        )
        softplus_domains = NLPDiagnostics._domain_variable_intervals(
            NLPDiagnostics.snapshot(softplus_domain_model),
        )
        @test softplus_domains[softplus_x].lower ≈
              2.0 + log1p(-exp(-2.0)) atol = 1.0e-12
        @test isempty(NLPDiagnostics.domain_issues(softplus_domain_model))

        logistic_domain_model = new_model()
        logistic_x = MOI.add_variable(logistic_domain_model)
        MOI.add_constraint(
            logistic_domain_model,
            MOI.ScalarNonlinearFunction(:logistic, Any[logistic_x]),
            MOI.GreaterThan(0.9),
        )
        MOI.add_constraint(
            logistic_domain_model,
            MOI.ScalarNonlinearFunction(:log, Any[logistic_x]),
            MOI.LessThan(10.0),
        )
        logistic_domains = NLPDiagnostics._domain_variable_intervals(
            NLPDiagnostics.snapshot(logistic_domain_model),
        )
        @test logistic_domains[logistic_x].lower ≈
              log(0.9) - log1p(-0.9) atol = 1.0e-12
        @test isempty(NLPDiagnostics.domain_issues(logistic_domain_model))

        tanh_domain_model = new_model()
        tanh_x = MOI.add_variable(tanh_domain_model)
        MOI.add_constraint(
            tanh_domain_model,
            MOI.ScalarNonlinearFunction(:tanh, Any[tanh_x]),
            MOI.GreaterThan(0.9),
        )
        MOI.add_constraint(
            tanh_domain_model,
            MOI.ScalarNonlinearFunction(:log, Any[tanh_x]),
            MOI.LessThan(10.0),
        )
        tanh_domains = NLPDiagnostics._domain_variable_intervals(
            NLPDiagnostics.snapshot(tanh_domain_model),
        )
        @test tanh_domains[tanh_x].lower ≈
              (log1p(0.9) - log1p(-0.9)) / 2 atol = 1.0e-12
        @test isempty(NLPDiagnostics.domain_issues(tanh_domain_model))

        atanh_domain_model = new_model()
        atanh_x = MOI.add_variable(atanh_domain_model)
        MOI.add_constraint(
            atanh_domain_model,
            MOI.ScalarNonlinearFunction(:atanh, Any[atanh_x]),
            MOI.GreaterThan(0.9),
        )
        MOI.add_constraint(
            atanh_domain_model,
            MOI.ScalarNonlinearFunction(:log, Any[atanh_x]),
            MOI.LessThan(10.0),
        )
        atanh_domains = NLPDiagnostics._domain_variable_intervals(
            NLPDiagnostics.snapshot(atanh_domain_model),
        )
        @test atanh_domains[atanh_x].lower ≈ tanh(0.9) atol = 1.0e-12
        @test isempty(filter(
            issue -> issue.operator == :log,
            NLPDiagnostics.domain_issues(atanh_domain_model),
        ))

        asinh_domain_model = new_model()
        asinh_x = MOI.add_variable(asinh_domain_model)
        MOI.add_constraint(
            asinh_domain_model,
            MOI.ScalarNonlinearFunction(:asinh, Any[asinh_x]),
            MOI.GreaterThan(1.0),
        )
        MOI.add_constraint(
            asinh_domain_model,
            MOI.ScalarNonlinearFunction(:log, Any[asinh_x]),
            MOI.LessThan(10.0),
        )
        asinh_domains = NLPDiagnostics._domain_variable_intervals(
            NLPDiagnostics.snapshot(asinh_domain_model),
        )
        @test asinh_domains[asinh_x].lower ≈ sinh(1.0) atol = 1.0e-12
        @test isempty(NLPDiagnostics.domain_issues(asinh_domain_model))

        acosh_domain_model = new_model()
        acosh_x = MOI.add_variable(acosh_domain_model)
        MOI.add_constraint(
            acosh_domain_model,
            MOI.ScalarNonlinearFunction(:acosh, Any[acosh_x]),
            MOI.GreaterThan(1.0),
        )
        MOI.add_constraint(
            acosh_domain_model,
            MOI.ScalarNonlinearFunction(:log, Any[acosh_x]),
            MOI.LessThan(10.0),
        )
        acosh_domains = NLPDiagnostics._domain_variable_intervals(
            NLPDiagnostics.snapshot(acosh_domain_model),
        )
        @test acosh_domains[acosh_x].lower ≈ cosh(1.0) atol = 1.0e-12
        @test isempty(NLPDiagnostics.domain_issues(acosh_domain_model))

        atan_domain_model = new_model()
        atan_x = MOI.add_variable(atan_domain_model)
        MOI.add_constraint(
            atan_domain_model,
            MOI.ScalarNonlinearFunction(:atan, Any[atan_x]),
            MOI.GreaterThan(1.0),
        )
        MOI.add_constraint(
            atan_domain_model,
            MOI.ScalarNonlinearFunction(:log, Any[atan_x]),
            MOI.LessThan(10.0),
        )
        atan_domains = NLPDiagnostics._domain_variable_intervals(
            NLPDiagnostics.snapshot(atan_domain_model),
        )
        @test atan_domains[atan_x].lower ≈ tan(1.0) atol = 1.0e-12
        @test isempty(NLPDiagnostics.domain_issues(atan_domain_model))

        inverse_trig_domain_model = new_model()
        asin_x, acos_x, asind_x, acosd_x, atand_x = MOI.add_variables(
            inverse_trig_domain_model, 5,
        )
        MOI.add_constraint(
            inverse_trig_domain_model,
            MOI.ScalarNonlinearFunction(:asin, Any[asin_x]),
            MOI.GreaterThan(0.5),
        )
        MOI.add_constraint(
            inverse_trig_domain_model,
            MOI.ScalarNonlinearFunction(:acos, Any[acos_x]),
            MOI.LessThan(1.0),
        )
        MOI.add_constraint(
            inverse_trig_domain_model,
            MOI.ScalarNonlinearFunction(:asind, Any[asind_x]),
            MOI.GreaterThan(30.0),
        )
        MOI.add_constraint(
            inverse_trig_domain_model,
            MOI.ScalarNonlinearFunction(:acosd, Any[acosd_x]),
            MOI.LessThan(60.0),
        )
        MOI.add_constraint(
            inverse_trig_domain_model,
            MOI.ScalarNonlinearFunction(:atand, Any[atand_x]),
            MOI.GreaterThan(45.0),
        )
        inverse_trig_domains = NLPDiagnostics._domain_variable_intervals(
            NLPDiagnostics.snapshot(inverse_trig_domain_model),
        )
        @test inverse_trig_domains[asin_x].lower ≈ sin(0.5) atol = 1.0e-12
        @test inverse_trig_domains[acos_x].lower ≈ cos(1.0) atol = 1.0e-12
        @test inverse_trig_domains[asind_x].lower ≈ 0.5 atol = 1.0e-12
        @test inverse_trig_domains[acosd_x].lower ≈ 0.5 atol = 1.0e-12
        @test inverse_trig_domains[atand_x].lower ≈ 1.0 atol = 1.0e-12

        monotone_extension_model = new_model()
        sinh_x, cbrt_x = MOI.add_variables(monotone_extension_model, 2)
        MOI.add_constraint(
            monotone_extension_model,
            MOI.ScalarNonlinearFunction(:sinh, Any[sinh_x]),
            MOI.GreaterThan(1.0),
        )
        MOI.add_constraint(
            monotone_extension_model,
            MOI.ScalarNonlinearFunction(:cbrt, Any[cbrt_x]),
            MOI.GreaterThan(2.0),
        )
        monotone_extension_domains = NLPDiagnostics._domain_variable_intervals(
            NLPDiagnostics.snapshot(monotone_extension_model),
        )
        @test monotone_extension_domains[sinh_x].lower ≈ asinh(1.0) atol = 1.0e-12
        @test monotone_extension_domains[cbrt_x].lower == 8.0

        bounded_logistic_model = new_model()
        bounded_logistic_x = MOI.add_variable(bounded_logistic_model)
        MOI.add_constraint(
            bounded_logistic_model,
            bounded_logistic_x,
            MOI.Interval(-2.0, 2.0),
        )
        MOI.add_constraint(
            bounded_logistic_model,
            MOI.ScalarNonlinearFunction(
                :log,
                Any[MOI.ScalarNonlinearFunction(:logistic, Any[bounded_logistic_x])],
            ),
            MOI.LessThan(10.0),
        )
        @test isempty(filter(
            issue -> issue.operator == :log,
            NLPDiagnostics.domain_issues(bounded_logistic_model),
        ))

        bounded_sine_model = new_model()
        bounded_sine_x = MOI.add_variable(bounded_sine_model)
        MOI.add_constraint(
            bounded_sine_model,
            bounded_sine_x,
            MOI.Interval(0.1, 0.2),
        )
        MOI.add_constraint(
            bounded_sine_model,
            MOI.ScalarNonlinearFunction(
                :log,
                Any[MOI.ScalarNonlinearFunction(:sin, Any[bounded_sine_x])],
            ),
            MOI.LessThan(10.0),
        )
        @test isempty(filter(
            issue -> issue.operator == :log,
            NLPDiagnostics.domain_issues(bounded_sine_model),
        ))

        bounded_tangent_model = new_model()
        bounded_tangent_x = MOI.add_variable(bounded_tangent_model)
        MOI.add_constraint(
            bounded_tangent_model,
            bounded_tangent_x,
            MOI.Interval(0.1, 0.2),
        )
        MOI.add_constraint(
            bounded_tangent_model,
            MOI.ScalarNonlinearFunction(
                :log,
                Any[MOI.ScalarNonlinearFunction(:tan, Any[bounded_tangent_x])],
            ),
            MOI.LessThan(10.0),
        )
        @test isempty(filter(
            issue -> issue.operator == :log,
            NLPDiagnostics.domain_issues(bounded_tangent_model),
        ))

        absolute_domain_model = new_model()
        absolute_x = MOI.add_variable(absolute_domain_model)
        MOI.add_constraint(
            absolute_domain_model,
            MOI.ScalarNonlinearFunction(:abs, Any[absolute_x]),
            MOI.EqualTo(0.0),
        )
        MOI.add_constraint(
            absolute_domain_model,
            MOI.ScalarNonlinearFunction(:log, Any[absolute_x]),
            MOI.LessThan(10.0),
        )
        absolute_domains = NLPDiagnostics._domain_variable_intervals(
            NLPDiagnostics.snapshot(absolute_domain_model),
        )
        @test absolute_domains[absolute_x].lower == 0.0
        @test absolute_domains[absolute_x].upper == 0.0
        absolute_domain_finding = only(findings(
            NLPDiagnostics.analyze_domains(absolute_domain_model),
            :proven_expression_domain_violation,
        ))
        @test occursin(
            "absolute_value_range:MathOptInterface.ScalarNonlinearFunction/MathOptInterface.EqualTo{Float64}#1",
            Dict(absolute_domain_finding.evidence[1].details)[
                "support_interval_origins"
            ],
        )

        cosh_domain_model = new_model()
        cosh_x = MOI.add_variable(cosh_domain_model)
        MOI.add_constraint(
            cosh_domain_model,
            MOI.ScalarNonlinearFunction(:cosh, Any[cosh_x]),
            MOI.EqualTo(1.0),
        )
        MOI.add_constraint(
            cosh_domain_model,
            MOI.ScalarNonlinearFunction(:log, Any[cosh_x]),
            MOI.LessThan(10.0),
        )
        cosh_domains = NLPDiagnostics._domain_variable_intervals(
            NLPDiagnostics.snapshot(cosh_domain_model),
        )
        @test cosh_domains[cosh_x].lower == 0.0
        @test cosh_domains[cosh_x].upper == 0.0
        cosh_domain_finding = only(findings(
            NLPDiagnostics.analyze_domains(cosh_domain_model),
            :proven_expression_domain_violation,
        ))
        @test occursin(
            "cosh_range:MathOptInterface.ScalarNonlinearFunction/MathOptInterface.EqualTo{Float64}#1",
            Dict(cosh_domain_finding.evidence[1].details)[
                "support_interval_origins"
            ],
        )

        logcosh_domain_model = new_model()
        logcosh_x = MOI.add_variable(logcosh_domain_model)
        MOI.add_constraint(
            logcosh_domain_model,
            MOI.ScalarNonlinearFunction(:logcosh, Any[logcosh_x]),
            MOI.EqualTo(0.0),
        )
        MOI.add_constraint(
            logcosh_domain_model,
            MOI.ScalarNonlinearFunction(:log, Any[logcosh_x]),
            MOI.LessThan(10.0),
        )
        logcosh_domains = NLPDiagnostics._domain_variable_intervals(
            NLPDiagnostics.snapshot(logcosh_domain_model),
        )
        @test logcosh_domains[logcosh_x].lower == 0.0
        @test logcosh_domains[logcosh_x].upper == 0.0
        logcosh_domain_finding = only(findings(
            NLPDiagnostics.analyze_domains(logcosh_domain_model),
            :proven_expression_domain_violation,
        ))
        @test occursin(
            "logcosh_range:MathOptInterface.ScalarNonlinearFunction/MathOptInterface.EqualTo{Float64}#1",
            Dict(logcosh_domain_finding.evidence[1].details)[
                "support_interval_origins"
            ],
        )

        minmax_domain_model = new_model()
        minmax_x, minmax_y = MOI.add_variables(minmax_domain_model, 2)
        MOI.add_constraint(
            minmax_domain_model,
            MOI.ScalarNonlinearFunction(:min, Any[minmax_x, 2.0]),
            MOI.GreaterThan(1.0),
        )
        MOI.add_constraint(
            minmax_domain_model,
            MOI.ScalarNonlinearFunction(:log, Any[minmax_x]),
            MOI.LessThan(10.0),
        )
        MOI.add_constraint(
            minmax_domain_model,
            MOI.ScalarNonlinearFunction(:max, Any[minmax_y, 0.0]),
            MOI.EqualTo(0.0),
        )
        MOI.add_constraint(
            minmax_domain_model,
            MOI.ScalarNonlinearFunction(:log, Any[minmax_y]),
            MOI.LessThan(10.0),
        )
        minmax_domains = NLPDiagnostics._domain_variable_intervals(
            NLPDiagnostics.snapshot(minmax_domain_model),
        )
        @test minmax_domains[minmax_x].lower == 1.0
        @test minmax_domains[minmax_y].upper == 0.0
        minmax_interval_data = NLPDiagnostics.domain_interval_data(
            minmax_domain_model,
        )
        minmax_x_data = only(filter(
            item -> item["variable_index"] == minmax_x.value,
            minmax_interval_data,
        ))
        @test minmax_x_data["lower"] == 1.0
        @test occursin("minmax_branch_interval", minmax_x_data["origins"])
        minmax_report = NLPDiagnostics.analyze_domains(minmax_domain_model)
        @test isempty(findings(minmax_report, :possible_expression_domain_violation))
        minmax_finding = only(findings(
            minmax_report,
            :proven_expression_domain_violation,
        ))
        @test occursin(
            "minmax_branch_interval:MathOptInterface.ScalarNonlinearFunction/MathOptInterface.EqualTo{Float64}#1",
            Dict(minmax_finding.evidence[1].details)[
                "support_interval_origins"
            ],
        )

        zero_domain_model = new_model()
        zero_x, zero_y = MOI.add_variables(zero_domain_model, 2)
        zero_domain_circle = Q(
            [QT(2.0, zero_x, zero_x), QT(2.0, zero_y, zero_y)],
            MOI.ScalarAffineTerm{Float64}[],
            0.0,
        )
        MOI.add_constraint(zero_domain_model, zero_domain_circle, MOI.EqualTo(0.0))
        zero_propagated_domains = NLPDiagnostics._domain_variable_intervals(
            NLPDiagnostics.snapshot(zero_domain_model),
        )
        @test zero_propagated_domains[zero_x].lower == 0.0
        @test zero_propagated_domains[zero_x].upper == 0.0
        MOI.add_constraint(
            zero_domain_model,
            MOI.ScalarNonlinearFunction(:log, Any[zero_x]),
            MOI.LessThan(10.0),
        )
        @test length(findings(
            NLPDiagnostics.analyze_domains(zero_domain_model),
            :proven_expression_domain_violation,
        )) == 1

        near_unit = new_model()
        near_x, near_y = MOI.add_variables(near_unit, 2)
        near_unit_ellipsoid = Q(
            [QT(2.0, near_x, near_x), QT(2.000001, near_y, near_y)],
            MOI.ScalarAffineTerm{Float64}[],
            0.0,
        )
        MOI.add_constraint(near_unit, near_unit_ellipsoid, MOI.EqualTo(1.0))
        near_report = NLPDiagnostics.analyze_static(near_unit)
        @test isempty(findings(near_report, :nonunit_ellipsoidal_constraint_axes))
        @test length(findings(near_report, :ellipsoidal_implied_variable_bound)) == 2

        zero_conflict = new_model()
        e, f = MOI.add_variables(zero_conflict, 2)
        zero_ellipsoid_conflict = Q(
            [QT(2.0, e, e), QT(8.0, f, f)],
            [AT(-4.0, e), AT(8.0, f)],
            0.0,
        )
        MOI.add_constraint(zero_conflict, zero_ellipsoid_conflict, MOI.EqualTo(-8.0))
        MOI.add_constraint(zero_conflict, e, MOI.GreaterThan(3.0))
        zero_contradiction = only(findings(
            NLPDiagnostics.analyze_static(zero_conflict),
            :inconsistent_zero_level_diagonal_quadratic_variable_bound,
        ))
        @test zero_contradiction.basis == NLPDiagnostics.MathematicalProof
        @test evidence_details(zero_contradiction)["implied_value"] == "2.0"
    end

    @testset "diagonal quadratic upper bounds expose exact minima" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        Q = MOI.ScalarQuadraticFunction{Float64}
        QT = MOI.ScalarQuadraticTerm{Float64}
        AT = MOI.ScalarAffineTerm{Float64}
        bowl = Q(
            [QT(2.0, x, x), QT(8.0, y, y)],
            [AT(-4.0, x), AT(8.0, y)],
            3.0,
        )
        # (x - 2)^2 + 4 * (y + 1)^2 - 5 has minimum -5.
        MOI.add_constraint(model, bowl, MOI.LessThan(-6.0))
        infeasible = only(findings(
            NLPDiagnostics.analyze_static(model),
            :infeasible_below_minimum_diagonal_quadratic_constraint,
        ))
        @test infeasible.basis == NLPDiagnostics.MathematicalProof
        @test evidence_details(infeasible)["minimum_value"] == "-5.0"

        minimum_level = new_model()
        u, v = MOI.add_variables(minimum_level, 2)
        minimum_bowl = Q(
            [QT(2.0, u, u), QT(8.0, v, v)],
            [AT(-4.0, u), AT(8.0, v)],
            3.0,
        )
        MOI.add_constraint(minimum_level, minimum_bowl, MOI.Interval(-10.0, -5.0))
        fixed = only(findings(
            NLPDiagnostics.analyze_static(minimum_level),
            :minimum_level_diagonal_quadratic_constraint,
        ))
        @test evidence_details(fixed)["center"] == "[2.0, -1.0]"
        nonregular_minimum = only(findings(
            NLPDiagnostics.analyze_static(minimum_level),
            :nonregular_minimum_level_diagonal_quadratic_inequality,
        ))
        @test nonregular_minimum.domain == NLPDiagnostics.NumericalIssue
        @test nonregular_minimum.basis == NLPDiagnostics.MathematicalProof

        bounded = new_model()
        p, q = MOI.add_variables(bounded, 2)
        bounded_bowl = Q(
            [QT(2.0, p, p), QT(8.0, q, q)],
            [AT(-4.0, p), AT(8.0, q)],
            3.0,
        )
        # The level -1 is four above the minimum, giving p ∈ [0, 4], q ∈ [-2, 0].
        MOI.add_constraint(bounded, bounded_bowl, MOI.LessThan(-1.0))
        implied = findings(
            NLPDiagnostics.analyze_static(bounded),
            :diagonal_quadratic_implied_variable_bound,
        )
        @test length(implied) == 2
        implied_by_variable = Dict(
            only(ref.index for ref in finding.affected if ref.kind == :variable) =>
                evidence_details(finding) for finding in implied
        )
        @test implied_by_variable[p.value]["derived_lower"] == "0.0"
        @test implied_by_variable[p.value]["derived_upper"] == "4.0"
        @test implied_by_variable[q.value]["derived_lower"] == "-2.0"
        @test implied_by_variable[q.value]["derived_upper"] == "0.0"

        nonlinear_bounded = new_model()
        nonlinear_p, nonlinear_q = MOI.add_variables(nonlinear_bounded, 2)
        nonlinear_bowl = MOI.ScalarNonlinearFunction(
            :+,
            Any[
                MOI.ScalarNonlinearFunction(:^, Any[nonlinear_p, 2]),
                MOI.ScalarNonlinearFunction(
                    :*,
                    Any[4.0, MOI.ScalarNonlinearFunction(:^, Any[nonlinear_q, 2])],
                ),
                MOI.ScalarNonlinearFunction(:*, Any[-4.0, nonlinear_p]),
                MOI.ScalarNonlinearFunction(:*, Any[8.0, nonlinear_q]),
                3.0,
            ],
        )
        MOI.add_constraint(nonlinear_bounded, nonlinear_bowl, MOI.LessThan(-1.0))
        nonlinear_implied = findings(
            NLPDiagnostics.analyze_static(nonlinear_bounded),
            :diagonal_quadratic_implied_variable_bound,
        )
        @test length(nonlinear_implied) == 2
        @test Set(evidence_details(finding)["derived_upper"] for finding in nonlinear_implied) ==
              Set(["4.0", "0.0"])

        conflicting_bound = new_model()
        a, b = MOI.add_variables(conflicting_bound, 2)
        conflicting_bowl = Q(
            [QT(2.0, a, a), QT(8.0, b, b)],
            [AT(-4.0, a), AT(8.0, b)],
            3.0,
        )
        MOI.add_constraint(conflicting_bound, conflicting_bowl, MOI.LessThan(-1.0))
        MOI.add_constraint(conflicting_bound, a, MOI.GreaterThan(5.0))
        contradiction = only(findings(
            NLPDiagnostics.analyze_static(conflicting_bound),
            :inconsistent_diagonal_quadratic_implied_variable_bound,
        ))
        @test contradiction.basis == NLPDiagnostics.MathematicalProof
        @test evidence_details(contradiction)["derived_upper"] == "4.0"
        @test evidence_details(contradiction)["declared_lower"] == "5.0"
    end

    @testset "initialization identifies diagonal quadratic coordinate violations" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        Q = MOI.ScalarQuadraticFunction{Float64}
        QT = MOI.ScalarQuadraticTerm{Float64}
        AT = MOI.ScalarAffineTerm{Float64}
        bowl = Q(
            [QT(2.0, x, x), QT(8.0, y, y)],
            [AT(-4.0, x), AT(8.0, y)],
            3.0,
        )
        MOI.add_constraint(model, bowl, MOI.LessThan(-1.0))
        MOI.set(model, MOI.VariablePrimalStart(), x, 5.0)
        MOI.set(model, MOI.VariablePrimalStart(), y, -1.0)
        report = NLPDiagnostics.analyze_initialization(model)
        violation = only(findings(
            report,
            :initialization_violates_diagonal_quadratic_implied_bound,
        ))
        @test violation.basis == NLPDiagnostics.MathematicalProof
        @test occursin(
            "value=5.0",
            Dict(violation.evidence[2].details)["v$(x.value)"],
        )

        nonlinear = new_model()
        p, q = MOI.add_variables(nonlinear, 2)
        nonlinear_bowl = MOI.ScalarNonlinearFunction(
            :+,
            Any[
                MOI.ScalarNonlinearFunction(:^, Any[p, 2]),
                MOI.ScalarNonlinearFunction(
                    :*,
                    Any[4.0, MOI.ScalarNonlinearFunction(:^, Any[q, 2])],
                ),
                MOI.ScalarNonlinearFunction(:*, Any[-4.0, p]),
                MOI.ScalarNonlinearFunction(:*, Any[8.0, q]),
                3.0,
            ],
        )
        MOI.add_constraint(nonlinear, nonlinear_bowl, MOI.LessThan(-1.0))
        MOI.set(nonlinear, MOI.VariablePrimalStart(), p, 5.0)
        MOI.set(nonlinear, MOI.VariablePrimalStart(), q, -1.0)
        nonlinear_report = NLPDiagnostics.analyze_initialization(nonlinear)
        @test length(findings(
            nonlinear_report,
            :initialization_violates_diagonal_quadratic_implied_bound,
        )) == 1

        equality = new_model()
        a, b = MOI.add_variables(equality, 2)
        circle = Q(
            [QT(2.0, a, a), QT(2.0, b, b)],
            MOI.ScalarAffineTerm{Float64}[],
            0.0,
        )
        MOI.add_constraint(equality, circle, MOI.EqualTo(4.0))
        MOI.set(equality, MOI.VariablePrimalStart(), a, 3.0)
        MOI.set(equality, MOI.VariablePrimalStart(), b, 0.0)
        equality_report = NLPDiagnostics.analyze_initialization(equality)
        @test length(findings(
            equality_report,
            :initialization_violates_diagonal_quadratic_equality_implied_bound,
        )) == 1

        nonlinear_equality = new_model()
        c, d = MOI.add_variables(nonlinear_equality, 2)
        nonlinear_circle = MOI.ScalarNonlinearFunction(
            :+,
            Any[
                MOI.ScalarNonlinearFunction(:^, Any[c, 2]),
                MOI.ScalarNonlinearFunction(:^, Any[d, 2]),
            ],
        )
        MOI.add_constraint(nonlinear_equality, nonlinear_circle, MOI.EqualTo(4.0))
        MOI.set(nonlinear_equality, MOI.VariablePrimalStart(), c, 3.0)
        MOI.set(nonlinear_equality, MOI.VariablePrimalStart(), d, 0.0)
        nonlinear_equality_report = NLPDiagnostics.analyze_initialization(nonlinear_equality)
        nonlinear_equality_violation = only(findings(
            nonlinear_equality_report,
            :initialization_violates_diagonal_quadratic_equality_implied_bound,
        ))
        @test Dict(nonlinear_equality_violation.evidence[2].details)["representation"] ==
              "ScalarNonlinearFunction"
    end

    @testset "operating-point domain failures are captured" begin
        model = new_model()
        x = MOI.add_variable(model)
        MOI.add_constraint(
            model,
            MOI.ScalarNonlinearFunction(:log, Any[x]),
            MOI.EqualTo(0.0),
        )
        evaluation = NLPDiagnostics.evaluate_numerical(
            model,
            [-1.0];
            label = "invalid start",
        )
        @test isnan(only(evaluation.constraint_values))
        report = NLPDiagnostics.analyze_numerical(
            model,
            [-1.0];
            label = "invalid start",
        )
        finding =
            first(findings(report, :operating_point_domain_violation))
        @test finding.domain == NLPDiagnostics.MathematicalIssue
        @test finding.basis == NLPDiagnostics.MathematicalProof
        @test finding.confidence == NLPDiagnostics.ConfidenceCertain
    end

    @testset "non-finite values and derivatives remain evidence" begin
        model = new_model()
        x = MOI.add_variable(model)
        explosive = MOI.ScalarNonlinearFunction(:exp, Any[x])
        MOI.set(model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        MOI.set(
            model,
            MOI.ObjectiveFunction{MOI.ScalarNonlinearFunction}(),
            explosive,
        )
        report = NLPDiagnostics.analyze_numerical(
            model,
            [1000.0];
            label = "overflow probe",
        )
        @test length(findings(report, :nonfinite_objective_value)) == 1
        @test length(findings(report, :nonfinite_objective_gradient)) == 1
    end

    @testset "NLPBlock exact evaluator capabilities and duplicates" begin
        model = new_model()
        MOI.add_variables(model, 2)
        MOI.set(model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        evaluator = TestNLPEvaluator()
        block = MOI.NLPBlockData(
            MOI.NLPBoundsPair.([0.0, 0.0], [0.0, 0.0]),
            evaluator,
            true,
        )
        MOI.set(model, MOI.NLPBlock(), block)
        capabilities = NLPDiagnostics.evaluator_capabilities(model)
        nlp_capability =
            only(filter(capability -> capability.source == :nlp_block, capabilities))
        @test nlp_capability.available_features == [:Grad, :Jac, :Hess]
        @test nlp_capability.requested_features == [:Grad, :Jac]

        cache = NLPDiagnostics.EvaluationCache()
        point = NLPDiagnostics.evaluation_point(
            model,
            [2.0, 3.0];
            label = "callback point",
        )
        evaluation =
            NLPDiagnostics.evaluate_numerical(model, point; cache = cache)
        @test evaluation.objective_value == 7.0
        @test evaluation.objective_gradient == [4.0, 1.0]
        @test evaluation.constraint_values == [5.0, 9.0]
        @test length(evaluation.jacobian_entries) == 4
        @test evaluation.jacobian_row_methods ==
              fill(:exact_nlp_evaluator, 2)
        summary = NLPDiagnostics.jacobian_scale_summary(evaluation)
        @test summary.row_norms == [1.0, 6.0]
        @test summary.column_norms == [1.0, 6.0]
        @test evaluator.initialize_count == 1
        callback_statistics = NLPDiagnostics.evaluation_call_statistics(evaluation)
        @test callback_statistics[:nlp_initialize][1] == 1
        @test callback_statistics[:nlp_objective_value][1] == 1
        @test callback_statistics[:nlp_objective_gradient][1] == 1
        @test callback_statistics[:nlp_constraint_value][1] == 1
        @test callback_statistics[:nlp_constraint_jacobian][1] == 1
        NLPDiagnostics.evaluate_numerical(model, point; cache = cache)
        @test evaluator.initialize_count == 1
        static_report = NLPDiagnostics.analyze(model)
        @test isempty(findings(static_report, :disconnected_variable))
        @test length(
            findings(
                static_report,
                :variable_incidence_analysis_unavailable,
            ),
        ) == 1
        nan_report = NLPDiagnostics.analyze_numerical(
            model,
            [NaN, 3.0];
            label = "non-finite callback probe",
        )
        @test length(
            findings(nan_report, :nonfinite_objective_gradient),
        ) == 1
        hessian = NLPDiagnostics.evaluate_lagrangian_hessian(
            model,
            point;
            constraint_multipliers = [0.0, 3.0],
        )
        @test hessian.complete
        @test hessian.methods == [:exact_nlp_evaluator]
        @test evaluator.initialize_count == 4
        combined = NLPDiagnostics._combined_hessian_matrix(hessian)
        @test combined == [2.0 0.0; 0.0 6.0]
    end

    @testset "VectorNonlinearOracle value and exact Jacobian adapter" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        oracle = MOI.VectorNonlinearOracle(;
            dimension = 2,
            l = [0.0],
            u = [0.0],
            eval_f = (output, input) -> begin
                output[1] = input[1] * input[2]
                return
            end,
            jacobian_structure = [(1, 1), (1, 2)],
            eval_jacobian = (output, input) -> begin
                output[1] = input[2]
                output[2] = input[1]
                return
            end,
        )
        MOI.add_constraint(model, MOI.VectorOfVariables([x, y]), oracle)
        capabilities = NLPDiagnostics.evaluator_capabilities(model)
        @test any(
            capability -> capability.source == :nonlinear_oracle,
            capabilities,
        )
        evaluation = NLPDiagnostics.evaluate_numerical(
            model,
            [2.0, 3.0];
            label = "oracle point",
        )
        @test evaluation.constraint_values == [6.0]
        @test evaluation.jacobian_row_methods == [:exact_nonlinear_oracle]
        @test [entry.value for entry in evaluation.jacobian_entries] ==
              [3.0, 2.0]
        @test NLPDiagnostics.jacobian_scale_summary(evaluation).row_norms ==
              [3.0]
        callback_statistics = NLPDiagnostics.evaluation_call_statistics(evaluation)
        @test callback_statistics[:oracle_constraint_value][1] == 1
        @test callback_statistics[:oracle_constraint_jacobian][1] == 1
    end

    @testset "function-value and derivative domains remain distinct" begin
        model = new_model()
        x = MOI.add_variable(model)
        MOI.add_constraint(model, x, MOI.Interval(0.0, 1.0))
        root = MOI.ScalarNonlinearFunction(:sqrt, Any[x])
        MOI.add_constraint(model, root, MOI.LessThan(2.0))
        @test isempty(
            findings(
                NLPDiagnostics.analyze_domains(model),
                :possible_expression_domain_violation,
            ),
        )
        derivative_report = NLPDiagnostics.analyze_derivatives(model)
        possible =
            findings(derivative_report, :possible_derivative_domain_violation)
        @test length(possible) == 2
        @test sort(
            parse.(
                Int,
                [
                    Dict(finding.evidence[1].details)["derivative_order"] for
                    finding in possible
                ],
            ),
        ) == [1, 2]
        @test all(
            finding ->
                Dict(finding.evidence[1].details)["support_interval_origins"] ==
                "v$(x.value)=declared_variable_bounds:MathOptInterface.VariableIndex/MathOptInterface.Interval{Float64}#1",
            possible,
        )

        point = NLPDiagnostics.evaluation_point(
            model,
            [0.0];
            label = "sqrt boundary",
        )
        point_report =
            NLPDiagnostics.analyze_derivatives(model; point = point)
        @test length(
            findings(point_report, :operating_point_derivative_violation),
        ) == 2
        @test all(
            finding ->
                finding.basis == NLPDiagnostics.MathematicalProof &&
                    finding.confidence == NLPDiagnostics.ConfidenceCertain,
            findings(
                point_report,
                :operating_point_derivative_violation,
            ),
        )
    end

    @testset "nonsmooth and fractional-power derivative fingerprints" begin
        absolute_model = new_model()
        x = MOI.add_variable(absolute_model)
        MOI.add_constraint(absolute_model, x, MOI.EqualTo(0.0))
        MOI.add_constraint(
            absolute_model,
            MOI.ScalarNonlinearFunction(:abs, Any[x]),
            MOI.LessThan(1.0),
        )
        absolute_finding = only(
            findings(
                NLPDiagnostics.analyze_derivatives(absolute_model),
                :proven_derivative_domain_violation,
            ),
        )
        @test Dict(absolute_finding.evidence[1].details)["derivative_order"] ==
              "1"

        power_model = new_model()
        y = MOI.add_variable(power_model)
        MOI.add_constraint(power_model, y, MOI.Interval(0.0, 1.0))
        MOI.add_constraint(
            power_model,
            MOI.ScalarNonlinearFunction(:^, Any[y, 1.5]),
            MOI.LessThan(1.0),
        )
        power_issues = NLPDiagnostics.derivative_issues(power_model)
        @test length(power_issues) == 1
        @test only(power_issues).order == 2
        @test only(power_issues).assessment ==
              NLPDiagnostics.DomainPossibleViolation
    end

    @testset "inverse trigonometric value and derivative boundaries" begin
        invalid_model = new_model()
        x = MOI.add_variable(invalid_model)
        MOI.add_constraint(invalid_model, x, MOI.EqualTo(2.0))
        MOI.add_constraint(
            invalid_model,
            MOI.ScalarNonlinearFunction(:asin, Any[x]),
            MOI.LessThan(2.0),
        )
        @test length(
            findings(
                NLPDiagnostics.analyze_domains(invalid_model),
                :proven_expression_domain_violation,
            ),
        ) == 1

        boundary_model = new_model()
        y = MOI.add_variable(boundary_model)
        MOI.add_constraint(boundary_model, y, MOI.EqualTo(1.0))
        MOI.add_constraint(
            boundary_model,
            MOI.ScalarNonlinearFunction(:asin, Any[y]),
            MOI.LessThan(2.0),
        )
        @test isempty(NLPDiagnostics.domain_issues(boundary_model))
        derivative_issues =
            NLPDiagnostics.derivative_issues(boundary_model)
        @test length(derivative_issues) == 2
        @test all(
            issue ->
                issue.assessment ==
                NLPDiagnostics.DomainProvenViolation,
            derivative_issues,
        )
    end

    @testset "custom derivative-domain extension hook" begin
        model = new_model()
        x = MOI.add_variable(model)
        MOI.add_constraint(model, x, MOI.EqualTo(-1.0))
        custom = MOI.ScalarNonlinearFunction(
            :positive_derivative_only,
            Any[x],
        )
        MOI.add_constraint(model, custom, MOI.LessThan(0.0))
        issue = only(NLPDiagnostics.derivative_issues(model))
        @test issue.operator == :positive_derivative_only
        @test issue.assessment == NLPDiagnostics.DomainProvenViolation
    end

    @testset "stable-expression fingerprints" begin
        model = new_model()
        x = MOI.add_variable(model)
        exp_x = MOI.ScalarNonlinearFunction(:exp, Any[x])
        softplus = MOI.ScalarNonlinearFunction(
            :log,
            Any[MOI.ScalarNonlinearFunction(:+, Any[1.0, exp_x])],
        )
        log_one_plus = MOI.ScalarNonlinearFunction(
            :log,
            Any[MOI.ScalarNonlinearFunction(:+, Any[1.0, x])],
        )
        log_one_minus = MOI.ScalarNonlinearFunction(
            :log,
            Any[MOI.ScalarNonlinearFunction(:-, Any[1.0, x])],
        )
        exp_minus_one =
            MOI.ScalarNonlinearFunction(:-, Any[exp_x, 1.0])
        log_one_minus_exp = MOI.ScalarNonlinearFunction(
            :log,
            Any[MOI.ScalarNonlinearFunction(:-, Any[1.0, exp_x])],
        )
        log1p_negative_exp = MOI.ScalarNonlinearFunction(
            :log1p,
            Any[MOI.ScalarNonlinearFunction(:-, Any[exp_x])],
        )
        log_cosh = MOI.ScalarNonlinearFunction(
            :log,
            Any[MOI.ScalarNonlinearFunction(:cosh, Any[x])],
        )
        log_sum_exp = MOI.ScalarNonlinearFunction(
            :log,
            Any[MOI.ScalarNonlinearFunction(:+, Any[
                exp_x,
                MOI.ScalarNonlinearFunction(:exp, Any[
                    MOI.ScalarNonlinearFunction(:-, Any[x]),
                ]),
            ])],
        )
        log_sum_exp_three_terms = MOI.ScalarNonlinearFunction(
            :log,
            Any[MOI.ScalarNonlinearFunction(:+, Any[
                exp_x,
                MOI.ScalarNonlinearFunction(:exp, Any[
                    MOI.ScalarNonlinearFunction(:-, Any[x]),
                ]),
                MOI.ScalarNonlinearFunction(:exp, Any[
                    MOI.ScalarNonlinearFunction(:*, Any[2.0, x]),
                ]),
            ])],
        )
        log_diff_exp = MOI.ScalarNonlinearFunction(
            :log,
            Any[MOI.ScalarNonlinearFunction(:-, Any[
                MOI.ScalarNonlinearFunction(:exp, Any[1.0]),
                exp_x,
            ])],
        )
        logistic = MOI.ScalarNonlinearFunction(
            :/,
            Any[
                1.0,
                MOI.ScalarNonlinearFunction(
                    :+,
                    Any[
                        1.0,
                        MOI.ScalarNonlinearFunction(
                            :exp,
                            Any[
                                MOI.ScalarNonlinearFunction(
                                    :-,
                                    Any[x],
                                ),
                            ],
                        ),
                    ],
                ),
            ],
        )
        logistic_exp_over_sum = MOI.ScalarNonlinearFunction(
            :/,
            Any[
                exp_x,
                MOI.ScalarNonlinearFunction(:+, Any[1.0, exp_x]),
            ],
        )
        complementary_logistic = MOI.ScalarNonlinearFunction(
            :/,
            Any[
                1.0,
                MOI.ScalarNonlinearFunction(:+, Any[1.0, exp_x]),
            ],
        )
        for expression in
            (softplus, log_one_plus, log_one_minus, exp_minus_one, log_one_minus_exp,
             log1p_negative_exp, log_cosh, log_sum_exp, log_sum_exp_three_terms,
             log_diff_exp, logistic, logistic_exp_over_sum, complementary_logistic)
            MOI.add_constraint(model, expression, MOI.LessThan(1.0e6))
        end
        report = NLPDiagnostics.analyze_expressions(model)
        @test length(findings(report, :unstable_softplus_expression)) == 1
        @test length(findings(report, :log_one_plus_cancellation_risk)) ==
              1
        @test length(findings(report, :log_one_minus_cancellation_risk)) ==
              1
        @test length(findings(report, :exp_minus_one_cancellation_risk)) ==
              1
        @test length(findings(report, :log_one_minus_exp_cancellation_risk)) ==
              2
        @test length(findings(report, :unstable_logcosh_expression)) == 1
        @test length(findings(report, :unstable_logsumexp_expression)) == 2
        @test length(findings(report, :unstable_logdiffexp_expression)) == 1
        @test length(findings(report, :unstable_logistic_expression)) == 2
        @test length(findings(report, :unstable_complementary_logistic_expression)) == 1
        @test !isempty(findings(report, :exponential_overflow_risk))
        @test !isempty(findings(report, :exponential_underflow_risk))
        reformulation_plan = NLPDiagnostics.stable_reformulation_plan(model)
        @test length(reformulation_plan.candidates) == 13
        @test Set(candidate.replacement for candidate in reformulation_plan.candidates) ==
              Set([:log1pexp, :log1p, :expm1, :log1mexp, :logcosh, :logsumexp,
                   :logdiffexp, :logistic])
        @test count(
            candidate -> candidate.requires_registered_operator,
            reformulation_plan.candidates,
        ) == 10
        reformulation_report = NLPDiagnostics.analyze_stable_reformulation_plan(reformulation_plan)
        @test length(findings(reformulation_report, :stable_reformulation_candidate)) == 13

        stable_model = new_model()
        z = MOI.add_variable(stable_model)
        stable = MOI.ScalarNonlinearFunction(:log1pexp, Any[z])
        MOI.add_constraint(stable_model, stable, MOI.LessThan(1.0e6))
        @test isempty(
            findings(
                NLPDiagnostics.analyze_expressions(stable_model),
                :unstable_softplus_expression,
            ),
        )

        saturated_logistic_model = new_model()
        saturated_logistic_x = MOI.add_variable(saturated_logistic_model)
        MOI.add_constraint(saturated_logistic_model, saturated_logistic_x, MOI.EqualTo(1_000.0))
        MOI.add_constraint(
            saturated_logistic_model,
            MOI.ScalarNonlinearFunction(:logistic, Any[saturated_logistic_x]),
            MOI.LessThan(1.0),
        )
        saturated_logistic = only(findings(
            NLPDiagnostics.analyze_expressions(saturated_logistic_model),
            :logistic_derivative_underflow_risk,
        ))
        @test saturated_logistic.basis == NLPDiagnostics.LocalInference
        @test saturated_logistic.domain == NLPDiagnostics.NumericalIssue
        @test length(findings(
            NLPDiagnostics.analyze_expressions(
                saturated_logistic_model;
                point = NLPDiagnostics.EvaluationPoint([saturated_logistic_x], [1_000.0]),
            ),
            :operating_point_logistic_derivative_underflow_risk,
        )) == 1

        endpoint_logistic_model = new_model()
        endpoint_logistic_x = MOI.add_variable(endpoint_logistic_model)
        MOI.add_constraint(endpoint_logistic_model, endpoint_logistic_x, MOI.EqualTo(100.0))
        MOI.add_constraint(
            endpoint_logistic_model,
            MOI.ScalarNonlinearFunction(:logistic, Any[endpoint_logistic_x]),
            MOI.LessThan(1.0),
        )
        @test length(findings(
            NLPDiagnostics.analyze_expressions(endpoint_logistic_model),
            :logistic_value_saturation_risk,
        )) == 1
        @test isempty(findings(
            NLPDiagnostics.analyze_expressions(endpoint_logistic_model),
            :logistic_derivative_underflow_risk,
        ))
        @test length(findings(
            NLPDiagnostics.analyze_expressions(
                endpoint_logistic_model;
                point = NLPDiagnostics.EvaluationPoint([endpoint_logistic_x], [100.0]),
            ),
            :operating_point_logistic_value_saturation_risk,
        )) == 1

        saturated_tanh_model = new_model()
        saturated_tanh_x = MOI.add_variable(saturated_tanh_model)
        MOI.add_constraint(saturated_tanh_model, saturated_tanh_x, MOI.EqualTo(-1_000.0))
        MOI.add_constraint(
            saturated_tanh_model,
            MOI.ScalarNonlinearFunction(:tanh, Any[saturated_tanh_x]),
            MOI.GreaterThan(-1.0),
        )
        @test length(findings(
            NLPDiagnostics.analyze_expressions(saturated_tanh_model),
            :tanh_derivative_underflow_risk,
        )) == 1
        @test length(findings(
            NLPDiagnostics.analyze_expressions(
                saturated_tanh_model;
                point = NLPDiagnostics.EvaluationPoint([saturated_tanh_x], [-1_000.0]),
            ),
            :operating_point_tanh_derivative_underflow_risk,
        )) == 1

        endpoint_tanh_model = new_model()
        endpoint_tanh_x = MOI.add_variable(endpoint_tanh_model)
        MOI.add_constraint(endpoint_tanh_model, endpoint_tanh_x, MOI.EqualTo(100.0))
        MOI.add_constraint(
            endpoint_tanh_model,
            MOI.ScalarNonlinearFunction(:tanh, Any[endpoint_tanh_x]),
            MOI.LessThan(1.0),
        )
        @test length(findings(
            NLPDiagnostics.analyze_expressions(endpoint_tanh_model),
            :tanh_value_saturation_risk,
        )) == 1
        @test isempty(findings(
            NLPDiagnostics.analyze_expressions(endpoint_tanh_model),
            :tanh_derivative_underflow_risk,
        ))
        @test length(findings(
            NLPDiagnostics.analyze_expressions(
                endpoint_tanh_model;
                point = NLPDiagnostics.EvaluationPoint([endpoint_tanh_x], [100.0]),
            ),
            :operating_point_tanh_value_saturation_risk,
        )) == 1

        saturated_logcosh_model = new_model()
        saturated_logcosh_x = MOI.add_variable(saturated_logcosh_model)
        MOI.add_constraint(saturated_logcosh_model, saturated_logcosh_x, MOI.EqualTo(1_000.0))
        MOI.add_constraint(
            saturated_logcosh_model,
            MOI.ScalarNonlinearFunction(:logcosh, Any[saturated_logcosh_x]),
            MOI.GreaterThan(0.0),
        )
        @test length(findings(
            NLPDiagnostics.analyze_expressions(saturated_logcosh_model),
            :logcosh_curvature_underflow_risk,
        )) == 1
        @test length(findings(
            NLPDiagnostics.analyze_expressions(
                saturated_logcosh_model;
                point = NLPDiagnostics.EvaluationPoint([saturated_logcosh_x], [1_000.0]),
            ),
            :operating_point_logcosh_curvature_underflow_risk,
        )) == 1

        underflow_sech_model = new_model()
        underflow_sech_x = MOI.add_variable(underflow_sech_model)
        MOI.add_constraint(underflow_sech_model, underflow_sech_x, MOI.EqualTo(1_000.0))
        MOI.add_constraint(
            underflow_sech_model,
            MOI.ScalarNonlinearFunction(:sech, Any[underflow_sech_x]),
            MOI.LessThan(1.0),
        )
        @test length(findings(
            NLPDiagnostics.analyze_expressions(underflow_sech_model),
            :sech_value_underflow_risk,
        )) == 1
        @test length(findings(
            NLPDiagnostics.analyze_expressions(
                underflow_sech_model;
                point = NLPDiagnostics.EvaluationPoint([underflow_sech_x], [1_000.0]),
            ),
            :operating_point_sech_value_underflow_risk,
        )) == 1

        saturated_softplus_model = new_model()
        saturated_softplus_x = MOI.add_variable(saturated_softplus_model)
        MOI.add_constraint(saturated_softplus_model, saturated_softplus_x, MOI.EqualTo(-1_000.0))
        MOI.add_constraint(
            saturated_softplus_model,
            MOI.ScalarNonlinearFunction(:log1pexp, Any[saturated_softplus_x]),
            MOI.GreaterThan(0.0),
        )
        @test length(findings(
            NLPDiagnostics.analyze_expressions(saturated_softplus_model),
            :softplus_derivative_underflow_risk,
        )) == 1
        @test length(findings(
            NLPDiagnostics.analyze_expressions(
                saturated_softplus_model;
                point = NLPDiagnostics.EvaluationPoint([saturated_softplus_x], [-1_000.0]),
            ),
            :operating_point_softplus_derivative_underflow_risk,
        )) == 1
        @test length(findings(
            NLPDiagnostics.analyze_expressions(saturated_softplus_model),
            :softplus_value_underflow_risk,
        )) == 1
        @test length(findings(
            NLPDiagnostics.analyze_expressions(
                saturated_softplus_model;
                point = NLPDiagnostics.EvaluationPoint([saturated_softplus_x], [-1_000.0]),
            ),
            :operating_point_softplus_value_underflow_risk,
        )) == 1

        saturated_log1mexp_model = new_model()
        saturated_log1mexp_x = MOI.add_variable(saturated_log1mexp_model)
        MOI.add_constraint(saturated_log1mexp_model, saturated_log1mexp_x, MOI.EqualTo(-1_000.0))
        MOI.add_constraint(
            saturated_log1mexp_model,
            MOI.ScalarNonlinearFunction(:log1mexp, Any[saturated_log1mexp_x]),
            MOI.LessThan(0.0),
        )
        @test length(findings(
            NLPDiagnostics.analyze_expressions(saturated_log1mexp_model),
            :log1mexp_value_saturation_risk,
        )) == 1
        @test length(findings(
            NLPDiagnostics.analyze_expressions(
                saturated_log1mexp_model;
                point = NLPDiagnostics.EvaluationPoint([saturated_log1mexp_x], [-1_000.0]),
            ),
            :operating_point_log1mexp_value_saturation_risk,
        )) == 1

        saturated_logdiffexp_model = new_model()
        saturated_logdiffexp_a, saturated_logdiffexp_b =
            MOI.add_variables(saturated_logdiffexp_model, 2)
        MOI.add_constraint(saturated_logdiffexp_model, saturated_logdiffexp_a, MOI.EqualTo(1_000.0))
        MOI.add_constraint(saturated_logdiffexp_model, saturated_logdiffexp_b, MOI.EqualTo(0.0))
        MOI.add_constraint(
            saturated_logdiffexp_model,
            MOI.ScalarNonlinearFunction(
                :logdiffexp, Any[saturated_logdiffexp_a, saturated_logdiffexp_b],
            ),
            MOI.GreaterThan(0.0),
        )
        @test length(findings(
            NLPDiagnostics.analyze_expressions(saturated_logdiffexp_model),
            :logdiffexp_subtrahend_derivative_underflow_risk,
        )) == 1
        @test length(findings(
            NLPDiagnostics.analyze_expressions(
                saturated_logdiffexp_model;
                point = NLPDiagnostics.EvaluationPoint(
                    [saturated_logdiffexp_a, saturated_logdiffexp_b], [1_000.0, 0.0],
                ),
            ),
            :operating_point_logdiffexp_subtrahend_derivative_underflow_risk,
        )) == 1

        saturated_logsumexp_model = new_model()
        saturated_logsumexp_a, saturated_logsumexp_b =
            MOI.add_variables(saturated_logsumexp_model, 2)
        MOI.add_constraint(saturated_logsumexp_model, saturated_logsumexp_a, MOI.EqualTo(1_000.0))
        MOI.add_constraint(saturated_logsumexp_model, saturated_logsumexp_b, MOI.EqualTo(0.0))
        MOI.add_constraint(
            saturated_logsumexp_model,
            MOI.ScalarNonlinearFunction(
                :logsumexp, Any[saturated_logsumexp_a, saturated_logsumexp_b],
            ),
            MOI.GreaterThan(0.0),
        )
        logsumexp_risk = only(findings(
            NLPDiagnostics.analyze_expressions(saturated_logsumexp_model),
            :logsumexp_term_derivative_underflow_risk,
        ))
        @test Dict(logsumexp_risk.evidence[end].details)["subordinate_argument_index"] == "2"
        @test length(findings(
            NLPDiagnostics.analyze_expressions(
                saturated_logsumexp_model;
                point = NLPDiagnostics.EvaluationPoint(
                    [saturated_logsumexp_a, saturated_logsumexp_b], [1_000.0, 0.0],
                ),
            ),
            :operating_point_logsumexp_term_derivative_underflow_risk,
        )) == 1

        large_phase_model = new_model()
        large_phase_x = MOI.add_variable(large_phase_model)
        MOI.add_constraint(large_phase_model, large_phase_x, MOI.EqualTo(1.0e13))
        MOI.add_constraint(
            large_phase_model,
            MOI.ScalarNonlinearFunction(:sin, Any[large_phase_x]),
            MOI.LessThan(1.0),
        )
        @test length(findings(
            NLPDiagnostics.analyze_expressions(large_phase_model),
            :periodic_argument_reduction_risk,
        )) == 1
        @test length(findings(
            NLPDiagnostics.analyze_expressions(
                large_phase_model;
                point = NLPDiagnostics.EvaluationPoint([large_phase_x], [1.0e13]),
            ),
            :operating_point_periodic_argument_reduction_risk,
        )) == 1

        near_atan2_model = new_model()
        near_atan2_y, near_atan2_x = MOI.add_variables(near_atan2_model, 2)
        MOI.add_constraint(near_atan2_model, near_atan2_y, MOI.EqualTo(1.0e-10))
        MOI.add_constraint(near_atan2_model, near_atan2_x, MOI.EqualTo(-1.0e-10))
        MOI.add_constraint(
            near_atan2_model,
            MOI.ScalarNonlinearFunction(:atan, Any[near_atan2_y, near_atan2_x]),
            MOI.LessThan(Float64(pi)),
        )
        near_atan2 = only(findings(
            NLPDiagnostics.analyze_expressions(near_atan2_model),
            :atan2_derivative_amplification,
        ))
        @test near_atan2.basis == NLPDiagnostics.HeuristicInterpretation
        @test parse(Float64, Dict(near_atan2.evidence[end].details)[
            "estimated_first_derivative_magnitude"
        ]) > 1.0e9
        @test length(findings(
            NLPDiagnostics.analyze_expressions(
                near_atan2_model;
                point = NLPDiagnostics.EvaluationPoint(
                    [near_atan2_y, near_atan2_x], [1.0e-10, -1.0e-10],
                ),
            ),
            :operating_point_atan2_derivative_amplification,
        )) == 1

        saturated_atan_model = new_model()
        saturated_atan_x = MOI.add_variable(saturated_atan_model)
        MOI.add_constraint(saturated_atan_model, saturated_atan_x, MOI.EqualTo(1.0e20))
        MOI.add_constraint(
            saturated_atan_model,
            MOI.ScalarNonlinearFunction(:atan, Any[saturated_atan_x]),
            MOI.LessThan(Float64(pi / 2)),
        )
        @test length(findings(
            NLPDiagnostics.analyze_expressions(saturated_atan_model),
            :arctangent_endpoint_saturation_risk,
        )) == 1
        @test length(findings(
            NLPDiagnostics.analyze_expressions(
                saturated_atan_model;
                point = NLPDiagnostics.EvaluationPoint([saturated_atan_x], [1.0e20]),
            ),
            :operating_point_arctangent_endpoint_saturation_risk,
        )) == 1

        stable_domain_model = new_model()
        stable_domain_argument = MOI.add_variable(stable_domain_model)
        MOI.add_constraint(stable_domain_model, stable_domain_argument, MOI.GreaterThan(0.0))
        MOI.add_constraint(
            stable_domain_model,
            MOI.ScalarNonlinearFunction(:log1mexp, Any[stable_domain_argument]),
            MOI.LessThan(0.0),
        )
        @test count(
            issue -> issue.operator == :log1mexp &&
                     issue.assessment == NLPDiagnostics.DomainProvenViolation,
            NLPDiagnostics.domain_issues(stable_domain_model),
        ) == 1

        logdiff_domain_model = new_model()
        logdiff_a, logdiff_b = MOI.add_variables(logdiff_domain_model, 2)
        MOI.add_constraint(logdiff_domain_model, logdiff_a, MOI.LessThan(0.0))
        MOI.add_constraint(logdiff_domain_model, logdiff_b, MOI.GreaterThan(1.0))
        MOI.add_constraint(
            logdiff_domain_model,
            MOI.ScalarNonlinearFunction(:logdiffexp, Any[logdiff_a, logdiff_b]),
            MOI.LessThan(0.0),
        )
        @test count(
            issue -> issue.operator == :logdiffexp &&
                     issue.assessment == NLPDiagnostics.DomainProvenViolation,
            NLPDiagnostics.domain_issues(logdiff_domain_model),
        ) == 2

        # Stable interval rules must remain meaningful at IEEE endpoint values:
        # these are common during loose-bound static analysis, even when a
        # representative initialization is finite.
        all_negative_infinite = NLPDiagnostics.operator_interval(
            Val(:logsumexp),
            [NLPDiagnostics.IntervalEnclosure(-Inf, -Inf)],
            Any[],
        )
        mixed_infinite = NLPDiagnostics.operator_interval(
            Val(:logsumexp),
            [
                NLPDiagnostics.IntervalEnclosure(-Inf, Inf),
                NLPDiagnostics.IntervalEnclosure(-1.0, 1.0),
            ],
            Any[],
        )
        @test all_negative_infinite.lower == -Inf
        @test all_negative_infinite.upper == -Inf
        @test !isnan(mixed_infinite.lower)
        @test !isnan(mixed_infinite.upper)

        near_log1mexp_model = new_model()
        near_log1mexp = MOI.add_variable(near_log1mexp_model)
        MOI.add_constraint(
            near_log1mexp_model,
            MOI.ScalarNonlinearFunction(:log1mexp, Any[near_log1mexp]),
            MOI.LessThan(0.0),
        )
        near_log1mexp_point = NLPDiagnostics.EvaluationPoint(
            [near_log1mexp], [-1e-12]; label = "near log1mexp boundary",
        )
        near_log1mexp_report = NLPDiagnostics.analyze_expressions(
            near_log1mexp_model; point = near_log1mexp_point,
        )
        @test length(findings(
            near_log1mexp_report,
            :operating_point_strict_domain_derivative_amplification,
        )) == 1
        near_log1mexp_evidence = Dict(
            only(near_log1mexp_report.findings).evidence[end].details,
        )
        @test parse(Float64, near_log1mexp_evidence["estimated_first_derivative_magnitude"]) > 1e11
        @test parse(Float64, near_log1mexp_evidence["estimated_second_derivative_magnitude"]) > 1e23
        MOI.set(
            near_log1mexp_model,
            MOI.VariablePrimalStart(),
            near_log1mexp,
            -1e-12,
        )
        @test length(findings(
            NLPDiagnostics.analyze_initialization(near_log1mexp_model),
            :operating_point_strict_domain_derivative_amplification,
        )) == 1

        near_composite_log_model = new_model()
        near_composite_log = MOI.add_variable(near_composite_log_model)
        MOI.add_constraint(
            near_composite_log_model,
            MOI.ScalarNonlinearFunction(:log, Any[
                MOI.ScalarNonlinearFunction(:-, Any[
                    1.0,
                    MOI.ScalarNonlinearFunction(:exp, Any[near_composite_log]),
                ]),
            ]),
            MOI.LessThan(0.0),
        )
        @test length(findings(
            NLPDiagnostics.analyze_expressions(
                near_composite_log_model;
                point = NLPDiagnostics.EvaluationPoint([near_composite_log], [-1e-12]),
            ),
            :operating_point_strict_domain_derivative_amplification,
        )) == 1

        near_logdiffexp_model = new_model()
        near_a, near_b = MOI.add_variables(near_logdiffexp_model, 2)
        MOI.add_constraint(
            near_logdiffexp_model,
            MOI.ScalarNonlinearFunction(:logdiffexp, Any[near_a, near_b]),
            MOI.LessThan(0.0),
        )
        near_logdiffexp_point = NLPDiagnostics.EvaluationPoint(
            [near_a, near_b], [1.0, 1.0 - 1e-12];
            label = "near logdiffexp boundary",
        )
        near_logdiffexp_report = NLPDiagnostics.analyze_expressions(
            near_logdiffexp_model; point = near_logdiffexp_point,
        )
        @test length(findings(
            near_logdiffexp_report,
            :operating_point_strict_domain_derivative_amplification,
        )) == 1
        near_logdiffexp_evidence = Dict(
            only(near_logdiffexp_report.findings).evidence[end].details,
        )
        @test parse(Float64, near_logdiffexp_evidence["estimated_maximum_first_derivative_magnitude"]) > 1e11
        @test parse(Float64, near_logdiffexp_evidence["estimated_second_derivative_magnitude"]) > 1e23

        near_sqrt_model = new_model()
        near_sqrt = MOI.add_variable(near_sqrt_model)
        MOI.add_constraint(
            near_sqrt_model,
            MOI.ScalarNonlinearFunction(:sqrt, Any[near_sqrt]),
            MOI.LessThan(1.0),
        )
        near_sqrt_report = NLPDiagnostics.analyze_expressions(
            near_sqrt_model;
            point = NLPDiagnostics.EvaluationPoint([near_sqrt], [1e-12]),
        )
        near_sqrt_evidence = Dict(only(near_sqrt_report.findings).evidence[end].details)
        @test parse(Float64, near_sqrt_evidence["estimated_first_derivative_magnitude"]) > 1e5
        @test parse(Float64, near_sqrt_evidence["estimated_second_derivative_magnitude"]) > 1e17

        threshold_model = new_model()
        threshold_variable = MOI.add_variable(threshold_model)
        MOI.add_constraint(
            threshold_model,
            MOI.ScalarNonlinearFunction(:sqrt, Any[threshold_variable]),
            MOI.LessThan(1.0),
        )
        threshold_point = NLPDiagnostics.EvaluationPoint([threshold_variable], [1e-4])
        @test isempty(findings(
            NLPDiagnostics.analyze_expressions(threshold_model; point = threshold_point),
            :operating_point_strict_domain_derivative_amplification,
        ))
        threshold_report = NLPDiagnostics.analyze_expressions(
            threshold_model;
            point = threshold_point,
            strict_domain_proximity_threshold = 1e-3,
        )
        @test length(findings(
            threshold_report,
            :operating_point_strict_domain_derivative_amplification,
        )) == 1
        @test threshold_report.metadata[:strict_domain_proximity_threshold] == "0.001"
        @test_throws ArgumentError NLPDiagnostics.analyze_expressions(
            threshold_model;
            point = threshold_point,
            strict_domain_proximity_threshold = 0.0,
        )

        float32_derivative_model = new_model()
        float32_derivative = MOI.add_variable(float32_derivative_model)
        MOI.add_constraint(
            float32_derivative_model,
            MOI.ScalarNonlinearFunction(:sqrt, Any[float32_derivative]),
            MOI.LessThan(1.0),
        )
        float32_derivative_report = NLPDiagnostics.analyze_expressions(
            float32_derivative_model;
            point = NLPDiagnostics.EvaluationPoint([float32_derivative], [1e-30]),
            numeric_type = Float32,
        )
        float32_derivative_finding = only(findings(
            float32_derivative_report,
            :operating_point_strict_domain_derivative_amplification,
        ))
        @test float32_derivative_finding.severity == NLPDiagnostics.SeverityError
        @test float32_derivative_finding.basis == NLPDiagnostics.NumericalObservation

        near_reciprocal_model = new_model()
        near_denominator = MOI.add_variable(near_reciprocal_model)
        MOI.add_constraint(
            near_reciprocal_model,
            MOI.ScalarNonlinearFunction(:inv, Any[near_denominator]),
            MOI.LessThan(1e20),
        )
        near_reciprocal_report = NLPDiagnostics.analyze_expressions(
            near_reciprocal_model;
            point = NLPDiagnostics.EvaluationPoint([near_denominator], [1e-12]),
        )
        near_reciprocal_evidence = Dict(
            only(near_reciprocal_report.findings).evidence[end].details,
        )
        @test parse(Float64, near_reciprocal_evidence["estimated_reciprocal_first_derivative_magnitude"]) > 1e23
        @test parse(Float64, near_reciprocal_evidence["estimated_reciprocal_second_derivative_magnitude"]) > 1e35

        near_csch_model = new_model()
        near_csch = MOI.add_variable(near_csch_model)
        MOI.add_constraint(
            near_csch_model,
            MOI.ScalarNonlinearFunction(:csch, Any[near_csch]),
            MOI.LessThan(1e20),
        )
        near_csch_report = NLPDiagnostics.analyze_expressions(
            near_csch_model;
            point = NLPDiagnostics.EvaluationPoint([near_csch], [1e-12]),
        )
        near_csch_evidence = Dict(
            only(near_csch_report.findings).evidence[end].details,
        )
        @test near_csch_evidence["operator"] == "csch"
        @test parse(Float64, near_csch_evidence["estimated_first_derivative_magnitude"]) > 1e23
        @test parse(Float64, near_csch_evidence["estimated_second_derivative_magnitude"]) > 1e35

        near_acsch_model = new_model()
        near_acsch = MOI.add_variable(near_acsch_model)
        MOI.add_constraint(
            near_acsch_model,
            MOI.ScalarNonlinearFunction(:acsch, Any[near_acsch]),
            MOI.LessThan(1e20),
        )
        near_acsch_report = NLPDiagnostics.analyze_expressions(
            near_acsch_model;
            point = NLPDiagnostics.EvaluationPoint([near_acsch], [1e-12]),
        )
        near_acsch_evidence = Dict(
            only(near_acsch_report.findings).evidence[end].details,
        )
        @test near_acsch_evidence["operator"] == "acsch"
        @test parse(Float64, near_acsch_evidence["estimated_first_derivative_magnitude"]) > 1e11
        @test parse(Float64, near_acsch_evidence["estimated_second_derivative_magnitude"]) > 1e23

        near_power_model = new_model()
        near_power = MOI.add_variable(near_power_model)
        MOI.add_constraint(
            near_power_model,
            MOI.ScalarNonlinearFunction(:^, Any[near_power, 1.5]),
            MOI.LessThan(1.0),
        )
        near_power_report = NLPDiagnostics.analyze_expressions(
            near_power_model;
            point = NLPDiagnostics.EvaluationPoint([near_power], [1e-12]),
        )
        near_power_evidence = Dict(only(near_power_report.findings).evidence[end].details)
        @test near_power_evidence["exponent"] == "1.5"
        @test parse(Float64, near_power_evidence["estimated_second_derivative_magnitude"]) > 1e5

        near_negative_power_model = new_model()
        near_negative_power = MOI.add_variable(near_negative_power_model)
        MOI.add_constraint(
            near_negative_power_model,
            MOI.ScalarNonlinearFunction(:^, Any[near_negative_power, -1]),
            MOI.LessThan(1e20),
        )
        near_negative_power_report = NLPDiagnostics.analyze_expressions(
            near_negative_power_model;
            point = NLPDiagnostics.EvaluationPoint([near_negative_power], [-1e-12]),
        )
        near_negative_power_evidence = Dict(
            only(near_negative_power_report.findings).evidence[end].details,
        )
        @test near_negative_power_evidence["base_requirement"] == "nonzero base"
        @test parse(Float64, near_negative_power_evidence["estimated_first_derivative_magnitude"]) > 1e23

        near_tan_model = new_model()
        near_tan = MOI.add_variable(near_tan_model)
        MOI.add_constraint(
            near_tan_model,
            MOI.ScalarNonlinearFunction(:tan, Any[near_tan]),
            MOI.LessThan(1e20),
        )
        near_tan_report = NLPDiagnostics.analyze_expressions(
            near_tan_model;
            point = NLPDiagnostics.EvaluationPoint([near_tan], [Float64(pi / 2)]),
        )
        near_tan_evidence = Dict(only(near_tan_report.findings).evidence[end].details)
        @test near_tan_evidence["denominator"] == "cos(argument)"
        @test parse(Float64, near_tan_evidence["estimated_first_derivative_magnitude"]) > 1e30

        near_tand_model = new_model()
        near_tand = MOI.add_variable(near_tand_model)
        MOI.add_constraint(
            near_tand_model,
            MOI.ScalarNonlinearFunction(:tand, Any[near_tand]),
            MOI.LessThan(1e20),
        )
        near_tand_report = NLPDiagnostics.analyze_expressions(
            near_tand_model;
            point = NLPDiagnostics.EvaluationPoint([near_tand], [90.0]),
        )
        near_tand_evidence = Dict(only(near_tand_report.findings).evidence[end].details)
        @test near_tand_evidence["denominator"] == "cosd(argument)"
        @test only(near_tand_report.findings).severity == NLPDiagnostics.SeverityError

        near_asin_model = new_model()
        near_asin = MOI.add_variable(near_asin_model)
        MOI.add_constraint(
            near_asin_model,
            MOI.ScalarNonlinearFunction(:asin, Any[near_asin]),
            MOI.LessThan(2.0),
        )
        near_asin_report = NLPDiagnostics.analyze_expressions(
            near_asin_model;
            point = NLPDiagnostics.EvaluationPoint([near_asin], [1.0 - 1e-12]),
        )
        near_asin_evidence = Dict(only(near_asin_report.findings).evidence[end].details)
        @test near_asin_evidence["boundary"] == "±1"
        @test parse(Float64, near_asin_evidence["estimated_first_derivative_magnitude"]) > 1e5

        near_asind_model = new_model()
        near_asind = MOI.add_variable(near_asind_model)
        MOI.add_constraint(
            near_asind_model,
            MOI.ScalarNonlinearFunction(:asind, Any[near_asind]),
            MOI.LessThan(100.0),
        )
        near_asind_report = NLPDiagnostics.analyze_expressions(
            near_asind_model;
            point = NLPDiagnostics.EvaluationPoint([near_asind], [1.0 - 1e-12]),
        )
        near_asind_evidence = Dict(only(near_asind_report.findings).evidence[end].details)
        @test parse(Float64, near_asind_evidence["estimated_first_derivative_magnitude"]) > 1e7

        near_asec_model = new_model()
        near_asec = MOI.add_variable(near_asec_model)
        MOI.add_constraint(
            near_asec_model,
            MOI.ScalarNonlinearFunction(:asec, Any[near_asec]),
            MOI.LessThan(2.0),
        )
        near_asec_report = NLPDiagnostics.analyze_expressions(
            near_asec_model;
            point = NLPDiagnostics.EvaluationPoint([near_asec], [1.0 + 1e-12]),
        )
        near_asec_evidence = Dict(only(near_asec_report.findings).evidence[end].details)
        @test near_asec_evidence["boundary"] == "±1"
        @test parse(Float64, near_asec_evidence["estimated_second_derivative_magnitude"]) > 1e17

        near_atanh_model = new_model()
        near_atanh = MOI.add_variable(near_atanh_model)
        MOI.add_constraint(
            near_atanh_model,
            MOI.ScalarNonlinearFunction(:atanh, Any[near_atanh]),
            MOI.LessThan(20.0),
        )
        near_atanh_report = NLPDiagnostics.analyze_expressions(
            near_atanh_model;
            point = NLPDiagnostics.EvaluationPoint([near_atanh], [1.0 - 1e-12]),
        )
        near_atanh_evidence = Dict(only(near_atanh_report.findings).evidence[end].details)
        @test parse(Float64, near_atanh_evidence["estimated_second_derivative_magnitude"]) > 1e23

        near_acoth_model = new_model()
        near_acoth = MOI.add_variable(near_acoth_model)
        MOI.add_constraint(
            near_acoth_model,
            MOI.ScalarNonlinearFunction(:acoth, Any[near_acoth]),
            MOI.LessThan(20.0),
        )
        near_acoth_report = NLPDiagnostics.analyze_expressions(
            near_acoth_model;
            point = NLPDiagnostics.EvaluationPoint([near_acoth], [1.0 + 1e-12]),
        )
        near_acoth_evidence = Dict(only(near_acoth_report.findings).evidence[end].details)
        @test near_acoth_evidence["operator"] == "acoth"
        @test parse(Float64, near_acoth_evidence["estimated_second_derivative_magnitude"]) > 1e23
    end

    @testset "numeric type controls overflow fingerprints" begin
        model = new_model()
        x = MOI.add_variable(model)
        MOI.add_constraint(model, x, MOI.EqualTo(100.0))
        MOI.add_constraint(
            model,
            MOI.ScalarNonlinearFunction(:exp, Any[x]),
            MOI.LessThan(Inf),
        )
        float64_report =
            NLPDiagnostics.analyze_expressions(model; numeric_type = Float64)
        float32_report =
            NLPDiagnostics.analyze_expressions(model; numeric_type = Float32)
        @test isempty(
            findings(float64_report, :exponential_overflow_risk),
        )
        finding =
            only(findings(float32_report, :exponential_overflow_risk))
        @test finding.severity == NLPDiagnostics.SeverityError
        @test Dict(finding.evidence[1].details)["numeric_type"] ==
              "Float32"
        @test Dict(finding.evidence[1].details)["support_interval_origins"] ==
              "v$(x.value)=declared_variable_bounds:MathOptInterface.VariableIndex/MathOptInterface.EqualTo{Float64}#1"
    end

    @testset "initialization analysis is explicit and complete" begin
        incomplete = new_model()
        x, y = MOI.add_variables(incomplete, 2)
        MOI.set(incomplete, MOI.VariablePrimalStart(), x, 1.0)
        @test NLPDiagnostics.initialization_point(incomplete) === nothing
        incomplete_report =
            NLPDiagnostics.analyze_initialization(incomplete)
        @test length(
            findings(
                incomplete_report,
                :incomplete_variable_initialization,
            ),
        ) == 1
        @test incomplete_report.metadata[:missing_initial_value_count] ==
              "1"

        boundary = new_model()
        z = MOI.add_variable(boundary)
        MOI.add_constraint(boundary, z, MOI.GreaterThan(0.0))
        MOI.add_constraint(
            boundary,
            MOI.ScalarNonlinearFunction(:sqrt, Any[z]),
            MOI.LessThan(2.0),
        )
        MOI.set(boundary, MOI.VariablePrimalStart(), z, 0.0)
        point = NLPDiagnostics.initialization_point(boundary)
        @test point !== nothing
        @test point.label == "initialization"
        boundary_report =
            NLPDiagnostics.analyze_initialization(boundary)
        @test length(
            findings(boundary_report, :initialization_on_variable_bound),
        ) == 1
        @test length(
            findings(
                boundary_report,
                :operating_point_derivative_violation,
            ),
        ) == 2
        @test length(
            findings(
                boundary_report,
                :initialization_near_constraint_boundary,
            ),
        ) == 1
        @test boundary_report.metadata[:initialization_active_row_count] == "1"
        @test boundary_report.metadata[:initialization_degeneracy_checked] == "true"

        stationary_start = new_model()
        stationary_z = MOI.add_variable(stationary_start)
        stationary_constraint = MOI.add_constraint(
            stationary_start,
            MOI.ScalarNonlinearFunction(:^, Any[stationary_z, 2]),
            MOI.EqualTo(0.0),
        )
        MOI.set(stationary_start, MOI.VariablePrimalStart(), stationary_z, 0.0)
        stationary_start_report = NLPDiagnostics.analyze_initialization(
            stationary_start,
        )
        @test length(findings(
            stationary_start_report, :unexpected_local_rank_loss,
        )) == 1
        @test length(findings(
            stationary_start_report, :candidate_single_coordinate_null_direction,
        )) == 1
        stationary_start_sweep_report = NLPDiagnostics.analyze_initialization(
            stationary_start;
            jacobian_rank_tolerance_sweep_tolerances = [1.0e-10, 1.0e-6],
        )
        @test stationary_start_sweep_report.metadata[
            :initialization_jacobian_rank_tolerance_sweep_requested
        ] == "true"
        @test length(findings(
            stationary_start_sweep_report, :jacobian_rank_tolerance_stable,
        )) == 1
        stationary_start_probe_report = NLPDiagnostics.analyze_initialization(
            stationary_start;
            iterative_right_nullspace_probe_dimension = 1,
            iterative_right_nullspace_probe_iterations = 20,
            iterative_left_nullspace_probe_dimension = 1,
            iterative_left_nullspace_probe_iterations = 20,
            iterative_spectrum_probe_dimension = 1,
            iterative_spectrum_probe_iterations = 20,
        )
        @test stationary_start_probe_report.metadata[
            :initialization_iterative_left_probe_requested
        ] == "true"
        @test length(findings(
            stationary_start_probe_report,
            :iterative_jacobian_candidate_small_residual_left_direction,
        )) == 1
        combined_initialization_probe_report = NLPDiagnostics.analyze(
            stationary_start;
            check_initialization = true,
            iterative_left_nullspace_probe_dimension = 1,
            iterative_left_nullspace_probe_iterations = 20,
        )
        @test length(findings(
            combined_initialization_probe_report,
            :iterative_jacobian_candidate_small_residual_left_direction,
        )) == 1
        combined_initialization_sweep_report = NLPDiagnostics.analyze(
            stationary_start;
            check_initialization = true,
            jacobian_rank_tolerance_sweep_tolerances = [1.0e-10, 1.0e-6],
        )
        @test length(findings(
            combined_initialization_sweep_report, :jacobian_rank_tolerance_stable,
        )) == 1
        stationary_component = NLPDiagnostics.ComponentMetadata(
            :test_component,
            "stationary";
            variables = [stationary_z],
            constraints = [NLPDiagnostics.EntityRef(
                :constraint,
                stationary_constraint.value,
            )],
            expected_rank = 1,
        )
        component_rank_start_report = NLPDiagnostics.analyze_initialization(
            stationary_start;
            components = [stationary_component],
        )
        @test length(findings(
            component_rank_start_report, :component_expected_rank_mismatch,
        )) == 1
        @test component_rank_start_report.metadata[
            :initialization_component_ranks_checked
        ] == "true"
        no_degeneracy_start_report = NLPDiagnostics.analyze_initialization(
            stationary_start;
            check_degeneracy = false,
            check_component_ranks = false,
        )
        @test no_degeneracy_start_report.metadata[:initialization_degeneracy_checked] == "false"
        @test no_degeneracy_start_report.metadata[
            :initialization_component_ranks_checked
        ] == "false"
        @test isempty(findings(
            no_degeneracy_start_report, :unexpected_local_rank_loss,
        ))

        initialized_cone = new_model()
        initialized_t, initialized_x = MOI.add_variables(initialized_cone, 2)
        MOI.add_constraint(
            initialized_cone,
            MOI.VectorOfVariables([initialized_t, initialized_x]),
            MOI.SecondOrderCone(2),
        )
        MOI.set(initialized_cone, MOI.VariablePrimalStart(), initialized_t, 1.0)
        MOI.set(initialized_cone, MOI.VariablePrimalStart(), initialized_x, 1.0)
        initialized_cone_report = NLPDiagnostics.analyze_initialization(
            initialized_cone;
            coupled_qualification_strict_tolerance = 1.0e-5,
            coupled_qualification_max_iterations = 7,
        )
        @test initialized_cone_report.metadata[
            :coupled_qualification_max_iterations
        ] == "7"
        @test length(findings(
            initialized_cone_report, :coupled_set_robinson_cq_regular,
        )) == 1

        invalid = new_model()
        w = MOI.add_variable(invalid)
        MOI.add_constraint(invalid, w, MOI.GreaterThan(0.0))
        MOI.set(invalid, MOI.VariablePrimalStart(), w, -1.0)
        invalid_report = NLPDiagnostics.analyze_initialization(invalid)
        @test length(
            findings(
                invalid_report,
                :initialization_violates_variable_bounds,
            ),
        ) == 1
        @test length(
            findings(invalid_report, :constraint_feasibility_violation),
        ) == 1

        implied = new_model()
        implied_x = MOI.add_variable(implied)
        # log(x) ≥ 0 proves x ≥ 1 without a direct scalar variable bound.
        MOI.add_constraint(
            implied,
            MOI.ScalarNonlinearFunction(:log, Any[implied_x]),
            MOI.GreaterThan(0.0),
        )
        MOI.set(implied, MOI.VariablePrimalStart(), implied_x, 0.5)
        implied_report = NLPDiagnostics.analyze_initialization(implied)
        implied_violation = only(findings(
            implied_report,
            :initialization_violates_variable_bounds,
        ))
        @test implied_violation.basis == NLPDiagnostics.MathematicalProof
        @test occursin(
            "statically implied variable intervals",
            implied_violation.observation,
        )
        @test occursin(
            "bounds=[1.0, Inf]",
            Dict(implied_violation.evidence[2].details)["v$(implied_x.value)"],
        )
        @test occursin(
            "monotone_unary_inversion:MathOptInterface.ScalarNonlinearFunction/MathOptInterface.GreaterThan{Float64}#1",
            Dict(implied_violation.evidence[2].details)["v$(implied_x.value)"],
        )
        combined =
            NLPDiagnostics.analyze(
                boundary;
                check_initialization = true,
                coupled_qualification_max_iterations = 7,
            )
        @test endswith(combined.metadata[:stages], ",initialization")
    end

    @testset "text report" begin
        report = NLPDiagnostics.DiagnosticReport()
        text = sprint(show, MIME"text/plain"(), report)
        @test occursin("0 findings", text)
    end

    @testset "solver-independent postmortem evidence" begin
        postmortem = NLPDiagnostics.SolverPostmortem(
            "TestSolver",
            :locally_infeasible;
            raw_status = "restoration failed",
            iterations = 20,
            primal_residual = 1e-2,
            dual_residual = 2e-2,
            complementarity = 3e-2,
            restoration_attempted = true,
            restoration_succeeded = false,
        )
        report = NLPDiagnostics.analyze_postmortem(
            postmortem;
            residual_tolerance = 1e-4,
        )
        @test length(
            findings(report, :solver_reported_infeasibility),
        ) == 1
        @test length(
            findings(report, :solver_restoration_unsuccessful),
        ) == 1
        @test length(findings(report, :large_solver_residual)) == 3
        @test report.metadata[:solver] == "TestSolver"
        @test report.metadata[:termination] == "locally_infeasible"

        combined_model = new_model()
        combined_variable = MOI.add_variable(combined_model)
        combined_report = NLPDiagnostics.analyze(
            combined_model;
            postmortem = postmortem,
        )
        @test occursin("postmortem", combined_report.metadata[:stages])
        @test combined_report.metadata[:stage] == "combined"
        @test combined_report.metadata[:postmortem_solver] == "TestSolver"
        @test combined_report.metadata[:postmortem_termination] ==
              "locally_infeasible"
        @test length(findings(
            combined_report, :solver_reported_infeasibility,
        )) == 1
        @test isnothing(NLPDiagnostics.solver_result_point(combined_model))
        @test_throws ArgumentError NLPDiagnostics.solver_result_point(
            combined_model; result_index = 0,
        )
        explicit_result_analysis = NLPDiagnostics.analyze_solver_result(
            combined_model;
            postmortem = postmortem,
            read_postmortem = false,
        )
        @test explicit_result_analysis isa NLPDiagnostics.SolverResultAnalysis
        @test isnothing(explicit_result_analysis.point)
        @test explicit_result_analysis.postmortem === postmortem
        @test explicit_result_analysis.result_index == 1
        @test explicit_result_analysis.report.metadata[
            :solver_result_point_available
        ] == "false"
        @test explicit_result_analysis.report.metadata[
            :solver_result_postmortem_available
        ] == "true"
        @test length(findings(
            explicit_result_analysis.report, :solver_result_point_unavailable,
        )) == 1
        explicit_result_data = NLPDiagnostics.report_data(
            explicit_result_analysis.report,
        )
        @test length(explicit_result_data["unavailable_reasons"]) == 1
        @test explicit_result_data["unavailable_reasons"][1]["code"] ==
              "solver_result_point_unavailable"
        @test explicit_result_data["unavailable_reasons"][1]["category"] ==
              "capability"
        @test explicit_result_data["unavailable_reasons"][1]["stage"] ==
              "solver_result_point"
        unavailable_profile = NLPDiagnostics.profile_solver_result(
            combined_model; read_postmortem = false,
        )
        @test unavailable_profile isa NLPDiagnostics.SolverProfileResult
        @test unavailable_profile.profile === nothing
        @test unavailable_profile.case === nothing
        @test unavailable_profile.result_report.metadata[
            :solver_result_point_available
        ] == "false"
        unavailable_profile_data = NLPDiagnostics.profile_result_data(
            unavailable_profile,
        )
        @test unavailable_profile_data["profile"] === nothing
        @test length(
            unavailable_profile_data["result_report"]["unavailable_reasons"],
        ) == 1
        @test unavailable_profile_data["result_report"]["unavailable_reasons"][1]["code"] ==
              "solver_result_point_unavailable"
        automatic_result_analysis = NLPDiagnostics.analyze_solver_result(
            combined_model,
        )
        @test isnothing(automatic_result_analysis.postmortem)
        @test !isnothing(automatic_result_analysis.postmortem_read_error)
        @test length(findings(
            automatic_result_analysis.report, :solver_postmortem_unavailable,
        )) == 1
        automatic_result_data = NLPDiagnostics.report_data(
            automatic_result_analysis.report,
        )
        @test length(automatic_result_data["unavailable_reasons"]) == 2
        @test Set(
            item["code"] for item in automatic_result_data["unavailable_reasons"]
        ) == Set([
            "solver_result_point_unavailable",
            "solver_result_postmortem_unavailable",
        ])
        postmortem_reason = only(filter(
            item -> item["code"] == "solver_result_postmortem_unavailable",
            automatic_result_data["unavailable_reasons"],
        ))
        @test postmortem_reason["category"] == "dependency"
        @test postmortem_reason["stage"] == "solver_result_postmortem"
        combined_log = """
        iter    objective    inf_pr   inf_du lg(mu)  ||d||  lg(rg) alpha_du alpha_pr  ls
           0  1.0e+00 1.0e+00 2.0e+00  -1.0 0.0e+00    -  0.0e+00 0.0e+00   0
        Restoration Failed
        """
        trace_profile = NLPDiagnostics.profile_solver_result(
            combined_model;
            postmortem = postmortem,
            read_postmortem = false,
            solver_log = combined_log,
        )
        @test trace_profile.result_report.metadata[
            :solver_result_solver_log_available
        ] == "true"
        @test trace_profile.result_report.metadata[
            :solver_iterations_parsed_iteration_count
        ] == "1"
        @test length(findings(
            trace_profile.result_report, :solver_log_restoration_failure,
        )) == 1
        @test trace_profile.result_report.metadata[
            :postmortem_log_consistency_postmortem_log_conflicting_marker_count
        ] == "1"
        combined_log_report = NLPDiagnostics.analyze(
            combined_model;
            postmortem = postmortem,
            solver_log = combined_log,
            solver_log_residual_tolerance = 1.0e-3,
        )
        @test occursin("solver_log,solver_iterations", combined_log_report.metadata[:stages])
        @test combined_log_report.metadata[:solver_log_solver] == "TestSolver"
        @test combined_log_report.metadata[:solver_iterations_parsed_iteration_count] == "1"
        @test length(findings(
            combined_log_report, :solver_log_restoration_failure,
        )) == 1
        @test_throws ArgumentError NLPDiagnostics.analyze(
            combined_model; solver_log = combined_log,
        )
        @test_throws ArgumentError NLPDiagnostics.analyze(
            combined_model;
            solver_log = combined_log,
            solver_name = "TestSolver",
            solver_log_objective_agreement_factor = 1,
        )
        @test_throws ArgumentError NLPDiagnostics.analyze(
            combined_model;
            postmortem = postmortem,
            solver_log = combined_log,
            solver_name = "OtherSolver",
        )
        optimistic_postmortem = NLPDiagnostics.SolverPostmortem(
            "TestSolver", :optimal,
        )
        consistency_report = NLPDiagnostics.analyze_postmortem_log_consistency(
            optimistic_postmortem, combined_log,
        )
        @test length(findings(
            consistency_report, :solver_postmortem_log_failure_marker_mismatch,
        )) == 1
        count_postmortem = NLPDiagnostics.SolverPostmortem(
            "TestSolver", :optimal; iterations = 5,
        )
        count_consistency_report = NLPDiagnostics.analyze_postmortem_log_consistency(
            count_postmortem,
            """
            iter    objective    inf_pr   inf_du lg(mu)  ||d||  lg(rg) alpha_du alpha_pr  ls
               0  1.0e+00 1.0e+00 2.0e+00  -1.0 0.0e+00    -  0.0e+00 0.0e+00   0
            """,
        )
        @test length(findings(
            count_consistency_report, :solver_postmortem_log_iteration_count_mismatch,
        )) == 1
        @test count_consistency_report.metadata[
            :postmortem_log_iteration_count_compatible
        ] == "false"
        objective_postmortem = NLPDiagnostics.SolverPostmortem(
            "TestSolver", :optimal; objective_value = 1.0e4,
        )
        objective_consistency_report = NLPDiagnostics.analyze_postmortem_log_consistency(
            objective_postmortem,
            """
            iter    objective    inf_pr   inf_du lg(mu)  ||d||  lg(rg) alpha_du alpha_pr  ls
               0  1.0e+00 1.0e+00 2.0e+00  -1.0 0.0e+00    -  0.0e+00 0.0e+00   0
            """,
        )
        @test length(findings(
            objective_consistency_report, :solver_postmortem_log_objective_mismatch,
        )) == 1
        @test objective_consistency_report.metadata[
            :postmortem_log_objective_compatible
        ] == "false"
        @test_throws ArgumentError NLPDiagnostics.analyze_postmortem_log_consistency(
            objective_postmortem, combined_log; objective_agreement_factor = 1,
        )
        combined_consistency_report = NLPDiagnostics.analyze(
            combined_model;
            postmortem = optimistic_postmortem,
            solver_log = combined_log,
        )
        @test occursin(
            "postmortem_log_consistency", combined_consistency_report.metadata[:stages],
        )
        @test combined_consistency_report.metadata[
            :postmortem_log_consistency_postmortem_log_conflicting_marker_count
        ] == "1"
        combined_binding = NLPDiagnostics.IterationPointBinding(
            NLPDiagnostics.SolverIterationRecord(
                :ipopt, 1, 1, :regular, 0.0, 0.0, 0.0, nothing, 0.0, "captured",
            ),
            NLPDiagnostics.EvaluationPoint([combined_variable], [0.0]; label = "captured"),
        )
        combined_binding_report = NLPDiagnostics.analyze(
            combined_model;
            iteration_bindings = [combined_binding],
            iteration_point_relative_step = 1.0e-5,
        )
        @test occursin("iteration_points", combined_binding_report.metadata[:stages])
        @test combined_binding_report.metadata[
            :iteration_points_bound_iteration_count
        ] == "1"
        @test combined_binding_report.metadata[
            :iteration_points_bound_iteration_relative_step
        ] == "1.0e-5"
        combined_profile_binding = NLPDiagnostics.profile_solver_result(
            combined_model;
            postmortem = optimistic_postmortem,
            read_postmortem = false,
            iteration_bindings = [combined_binding],
            iteration_kwargs = (
                check_degeneracy = false,
                check_component_ranks = false,
                check_rank_persistence = false,
            ),
        )
        @test combined_profile_binding.result_report.metadata[
            :solver_result_iteration_binding_count
        ] == "1"
        @test combined_profile_binding.result_report.metadata[
            :solver_iteration_points_bound_iteration_count
        ] == "1"
        trace_capture = NLPDiagnostics.IterationTraceCapture()
        NLPDiagnostics.capture_iteration!(
            trace_capture, combined_binding.record; point = combined_binding.point,
        )
        trace = NLPDiagnostics.iteration_trace(trace_capture)
        @test length(trace.records) == 1
        @test length(trace.segments) == 1
        @test length(trace.bindings) == 1
        trace_data = NLPDiagnostics.iteration_trace_data(trace)
        @test trace_data["schema_version"] == "nlpdiagnostics-iteration-trace-v4"
        @test trace_data["record_count"] == 1
        @test trace_data["binding_count"] == 1
        trace_summary = NLPDiagnostics.iteration_trace_summary(trace)
        @test trace_data["summary"] == trace_summary
        @test trace_summary["schema_version"] ==
              "nlpdiagnostics-iteration-trace-summary-v1"
        @test trace_summary["point_binding_coverage"]["complete_point_count"] == 1
        @test trace_summary["point_binding_coverage"]["selector_counts"]["captured"] == 1
        @test trace_summary["segments"][1]["bound_point_count"] == 1
        @test trace_summary["telemetry_coverage"]["barrier_parameter"][
            "available_count"
        ] == 0
        @test trace_data["bindings"][1]["point_fingerprint"] ==
              NLPDiagnostics.evaluation_point_fingerprint(combined_binding.point)
        @test trace_data["telemetry_coverage"]["barrier_parameter"] == 0
        @test trace_data["records"][1]["metric_semantics"]["objective"] ==
              "MetricCoordinatesUnknown"
        event_capture = NLPDiagnostics.IterationTraceCapture()
        for iteration in 0:5
            event_record = NLPDiagnostics.SolverIterationRecord(
                :synthetic_callback,
                iteration + 1,
                iteration,
                :regular,
                0.0,
                6.0 - iteration,
                Float64(iteration),
                nothing,
                nothing,
                "synthetic event-preserving selection";
                regularization_size=iteration == 2 ? 1.0e4 : 0.0,
            )
            NLPDiagnostics.capture_iteration!(
                event_capture,
                event_record;
                point=combined_binding.point,
            )
        end
        event_trace = NLPDiagnostics.iteration_trace(event_capture)
        event_summary = NLPDiagnostics.iteration_trace_summary(event_trace)
        @test event_summary["record_count"] == 6
        @test event_summary["phase_counts"]["regular"] == 6
        @test event_summary["format_counts"]["synthetic_callback"] == 6
        @test event_summary["minimum_primal_infeasibility"] == 1.0
        @test event_summary["minimum_dual_infeasibility"] == 0.0
        @test event_summary["telemetry_coverage"]["regularization_size"][
            "available_count"
        ] == 6
        campaign_summary = NLPDiagnostics.iteration_trace_campaign_summary([
            Dict(
                "provenance" => Dict("case" => "single"),
                "summary" => trace_summary,
            ),
            Dict(
                "provenance" => Dict("case" => "event"),
                "summary" => event_summary,
            ),
        ])
        @test campaign_summary["schema_version"] ==
              "nlpdiagnostics-iteration-trace-campaign-summary-v1"
        @test campaign_summary["trace_count"] == 2
        @test campaign_summary["available_trace_count"] == 2
        @test campaign_summary["provenance_available_trace_count"] == 2
        @test campaign_summary["record_coverage"]["total"] == 7
        @test campaign_summary["segment_coverage"]["restart_trace_count"] == 0
        @test campaign_summary["phase_counts"]["regular"] == 7
        @test campaign_summary["traces"][1]["provenance"]["case"] == "single"
        unavailable_campaign = NLPDiagnostics.iteration_trace_campaign_summary([
            Dict(
                "provenance" => Dict("case" => "empty"),
                "summary" => NLPDiagnostics.iteration_trace_summary(
                    NLPDiagnostics.iteration_trace(
                        NLPDiagnostics.SolverIterationRecord[],
                    ),
                ),
            ),
            Dict("provenance" => Dict("case" => "event"), "summary" => event_summary),
        ])
        @test unavailable_campaign["trace_count"] == 2
        @test unavailable_campaign["available_trace_count"] == 1
        @test !unavailable_campaign["available"]
        candidate_trace_summary = deepcopy(trace_summary)
        candidate_trace_summary["record_count"] = 2
        candidate_campaign = NLPDiagnostics.iteration_trace_campaign_summary([
            Dict(
                "provenance" => Dict("case" => "single"),
                "summary" => candidate_trace_summary,
            ),
            Dict(
                "provenance" => Dict("case" => "event"),
                "summary" => event_summary,
            ),
        ])
        policy_comparison = NLPDiagnostics.iteration_trace_policy_comparison(
            Dict("baseline" => campaign_summary, "candidate" => candidate_campaign);
            reference_policy = "baseline",
        )
        @test policy_comparison["schema_version"] ==
              "nlpdiagnostics-iteration-trace-policy-comparison-v1"
        @test policy_comparison["policy_count"] == 2
        @test policy_comparison["candidate_policy_count"] == 1
        candidate_comparison = policy_comparison["comparisons"]["candidate"]
        @test candidate_comparison["pairing"]["paired_trace_count"] == 2
        @test candidate_comparison["pairing"]["coverage_complete"]
        @test candidate_comparison["paired_traces"][1]["pair_key"] ==
              "case=\"event\""
        @test candidate_comparison["paired_traces"][2]["metric_comparison"][
            "record_count"]["delta"] == 1
        partial_candidate = NLPDiagnostics.iteration_trace_campaign_summary([
            Dict("provenance" => Dict("case" => "event"), "summary" => event_summary),
        ])
        partial_comparison = NLPDiagnostics.iteration_trace_policy_comparison(
            Dict("baseline" => campaign_summary, "partial" => partial_candidate);
            reference_policy = "baseline",
        )["comparisons"]["partial"]
        @test partial_comparison["pairing"]["paired_trace_count"] == 1
        @test partial_comparison["pairing"]["unmatched_reference_count"] == 1
        @test !partial_comparison["pairing"]["coverage_complete"]
        index_campaign = NLPDiagnostics.iteration_trace_campaign_summary([
            Dict("summary" => trace_summary),
        ])
        index_comparison = NLPDiagnostics.iteration_trace_policy_comparison(
            Dict("baseline" => index_campaign, "candidate" => index_campaign);
            reference_policy = "baseline",
        )["comparisons"]["candidate"]
        @test index_comparison["pairing"]["index_key_count"] == 2
        @test index_comparison["paired_traces"][1]["reference"][
            "pair_key_source"] == "index"
        duplicate_campaign = NLPDiagnostics.iteration_trace_campaign_summary([
            Dict(
                "provenance" => Dict("case" => "event"),
                "summary" => event_summary,
            ),
            Dict(
                "provenance" => Dict("case" => "event"),
                "summary" => event_summary,
            ),
        ])
        duplicate_comparison = NLPDiagnostics.iteration_trace_policy_comparison(
            Dict("baseline" => campaign_summary, "duplicate" => duplicate_campaign);
            reference_policy = "baseline",
        )["comparisons"]["duplicate"]
        @test duplicate_comparison["pairing"]["duplicate_candidate_key_count"] == 1
        @test !duplicate_comparison["pairing"]["coverage_complete"]
        empty_campaign = NLPDiagnostics.iteration_trace_campaign_summary(Dict[])
        empty_comparison = NLPDiagnostics.iteration_trace_policy_comparison(
            Dict("baseline" => empty_campaign, "candidate" => empty_campaign);
            reference_policy = "baseline",
        )
        @test !empty_comparison["available"]
        @test !empty_comparison["comparisons"]["candidate"]["pairing"][
            "coverage_complete"]
        @test_throws ArgumentError NLPDiagnostics.iteration_trace_policy_comparison(
            Dict("candidate" => candidate_campaign);
            reference_policy = "baseline",
        )
        event_evaluation = NLPDiagnostics.evaluate_numerical(
            combined_model, combined_binding.point,
        )
        event_geometry =
            NLPDiagnostics.iteration_trace_jacobian_family_geometry_data(
                combined_model,
                event_trace;
                row_labels=fill(
                    "row", length(event_evaluation.constraint_sources),
                ),
                column_labels=fill(
                    "column", length(event_evaluation.point.variables),
                ),
                max_points=3,
            )
        @test event_geometry["selected_binding_count"] == 3
        @test 2 in event_geometry["selected_iterations"]
        trace_report = NLPDiagnostics.analyze_iteration_trace(
            combined_model, trace;
            check_degeneracy = false,
            check_component_ranks = false,
            check_rank_persistence = false,
        )
        @test trace_report.metadata[:iteration_trace_record_count] == "1"
        @test trace_report.metadata[:iteration_trace_captured_binding_count] == "1"
        combined_profile_trace = NLPDiagnostics.profile_solver_result(
            combined_model;
            postmortem = optimistic_postmortem,
            read_postmortem = false,
            iteration_trace = trace,
            iteration_kwargs = (
                check_degeneracy = false,
                check_component_ranks = false,
                check_rank_persistence = false,
            ),
        )
        @test combined_profile_trace.result_report.metadata[
            :solver_result_iteration_trace_record_count
        ] == "1"

        limit_report = NLPDiagnostics.analyze_postmortem(
            NLPDiagnostics.SolverPostmortem("TestSolver", :iteration_limit),
        )
        @test length(findings(limit_report, :solver_termination_limit)) == 1

        diverging_report = NLPDiagnostics.analyze_postmortem(
            NLPDiagnostics.SolverPostmortem("TestSolver", :diverging_iterates),
        )
        @test length(findings(diverging_report, :solver_diverging_iterates)) == 1
        slow_progress_report = NLPDiagnostics.analyze_postmortem(
            NLPDiagnostics.SolverPostmortem("TestSolver", :slow_progress),
        )
        @test length(findings(slow_progress_report, :solver_slow_progress)) == 1
        rejected_report = NLPDiagnostics.analyze_postmortem(
            NLPDiagnostics.SolverPostmortem("TestSolver", :invalid_model),
        )
        @test length(findings(rejected_report, :solver_model_or_option_rejected)) == 1
        memory_report = NLPDiagnostics.analyze_postmortem(
            NLPDiagnostics.SolverPostmortem("TestSolver", :memory_limit),
        )
        @test length(findings(memory_report, :solver_memory_limit)) == 1
        acceptable_report = NLPDiagnostics.analyze_postmortem(
            NLPDiagnostics.SolverPostmortem("TestSolver", :acceptable_solution),
        )
        @test length(findings(acceptable_report, :solver_nonfinal_feasible_termination)) == 1
        interrupted_report = NLPDiagnostics.analyze_postmortem(
            NLPDiagnostics.SolverPostmortem("TestSolver", :interrupted),
        )
        @test length(findings(interrupted_report, :solver_interrupted)) == 1
        unclassified_report = NLPDiagnostics.analyze_postmortem(
            NLPDiagnostics.SolverPostmortem("TestSolver", :unknown),
        )
        @test length(findings(
            unclassified_report, :solver_unclassified_termination,
        )) == 1

        unconfigured_jump_model = JuMP.Model()
        @test_throws ArgumentError NLPDiagnostics.solver_postmortem(
            unconfigured_jump_model,
        )
    end

    @testset "raw solver log evidence" begin
        log = """
        iter 0
        Restoration Phase is called at point 0
        Restoration Failed
        Invalid number in NLP Jacobian detected.
        Floating point overflow occurred.
        Floating point underflow occurred.
        Singular matrix encountered.
        Converged to a point of local infeasibility.
        Problem appears unbounded.
        Iterates are diverging.
        Maximum Number of Iterations Exceeded.
        """
        observations = NLPDiagnostics.solver_log_observations(log)
        @test [observation.category for observation in observations] == [
            :restoration_attempted,
            :restoration_failed,
            :invalid_number,
            :overflow_marker,
            :underflow_marker,
            :linear_system_singularity,
            :reported_infeasibility,
            :reported_unboundedness,
            :diverging_iterates,
            :termination_limit,
        ]
        report = NLPDiagnostics.analyze_solver_log(
            "TestSolver",
            log;
            max_evidence_lines = 1,
        )
        @test length(findings(report, :solver_log_restoration_failure)) == 1
        @test length(findings(report, :solver_log_restoration_attempted)) == 1
        @test length(findings(report, :solver_log_invalid_number)) == 1
        @test length(findings(report, :solver_log_overflow_marker)) == 1
        @test length(findings(report, :solver_log_underflow_marker)) == 1
        singularity = only(findings(report, :solver_log_linear_system_singularity))
        @test singularity.basis == NLPDiagnostics.NumericalObservation
        @test length(findings(report, :solver_log_reported_infeasibility)) == 1
        @test length(findings(report, :solver_log_reported_unboundedness)) == 1
        @test length(findings(report, :solver_log_diverging_iterates)) == 1
        @test length(findings(report, :solver_log_termination_limit)) == 1
        @test report.metadata[:recognized_log_observation_count] == "10"
        @test evidence_details(
            only(findings(report, :solver_log_restoration_failure)),
        )["line"] == "3"
        @test_throws ArgumentError NLPDiagnostics.analyze_solver_log(
            "TestSolver",
            log;
            max_evidence_lines = 0,
        )
        successful_ipopt_footer = """
        Dual infeasibility......:   4.2e-14    4.2e-13
        Constraint violation....:   3.3e-16    3.3e-16
        EXIT: Optimal Solution Found.
        """
        @test isempty(findings(NLPDiagnostics.analyze_solver_log(
            "Ipopt", successful_ipopt_footer,
        ), :solver_log_reported_infeasibility))
    end

    @testset "structured solver iteration evidence" begin
        ipopt_log = """
        iter    objective    inf_pr   inf_du lg(mu)  ||d||  lg(rg) alpha_du alpha_pr  ls
           0  1.0e+00 1.0e+00 2.0e+00  -1.0 0.0e+00    -  0.0e+00 0.0e+00   0
           1r 2.0e+00 1.0e-02 3.0e-02  -2.0 1.0e+00    -  1.0e+00 1.0e+00   1
        """
        records = NLPDiagnostics.solver_iteration_records(ipopt_log)
        @test length(records) == 2
        @test records[2].format == :ipopt
        @test records[2].phase == :annotated
        @test records[2].primal_step == 1.0
        suffix_log = """
        iter    objective    inf_pr   inf_du lg(mu)  ||d||  lg(rg) alpha_du alpha_pr  ls
           1  2.0e+00 1.0e-02 3.0e-02  -2.0 1.0e+00    -  1.0e+00 8.0e-01H  1
        """
        suffix_records = NLPDiagnostics.solver_iteration_records(suffix_log)
        @test length(suffix_records) == 1
        @test suffix_records[1].primal_step == 0.8
        summary = NLPDiagnostics.solver_iteration_summary(records)
        @test summary.record_count == 2
        @test summary.formats == [:ipopt]
        @test summary.first_primal_infeasibility == 1.0
        @test summary.final_primal_infeasibility == 1.0e-2
        @test summary.minimum_dual_infeasibility == 3.0e-2
        @test summary.annotated_row_count == 1
        @test summary.segment_count == 1
        @test isnothing(NLPDiagnostics.solver_iteration_summary(
            NLPDiagnostics.SolverIterationRecord[],
        ))
        appended_records = [
            records[1], records[2],
            NLPDiagnostics.SolverIterationRecord(
                :ipopt, 10, 0, :regular, 3.0, 4.0, 5.0, nothing, 0.0, "appended",
            ),
        ]
        segments = NLPDiagnostics.solver_iteration_segments(appended_records)
        @test length(segments) == 2
        @test segments[2].start_line == 10
        @test segments[2].first_iteration == 0

        madnlp_log = """
        iter    objective    inf_pr   inf_du inf_compl lg(mu) lg(rg) alpha_pr ir ls
           0  1.0e+00 1.0e+00 2.0e+00 3.0e+00 -1.0 0.0 0.0 0 0
           1  2.0e+00 2.0e+01 3.0e+01 4.0e+00 -2.0 0.0 1.0 0 1
        """
        @test only(NLPDiagnostics.solver_iteration_records(madnlp_log)[2:2]).complementarity == 4.0
        report = NLPDiagnostics.analyze_solver_iterations("Ipopt", ipopt_log; residual_tolerance = 1e-3)
        @test length(findings(report, :solver_iteration_large_final_residual)) == 1
        @test report.metadata[:minimum_logged_primal_infeasibility] == "0.01"
        @test report.metadata[:annotated_iteration_row_count] == "1"
        @test report.metadata[:iteration_segment_count] == "1"
        @test report.metadata[:final_segment_start_line] == "2"
        @test report.metadata[:final_segment_end_line] == "3"
        @test report.metadata[:final_segment_record_count] == "2"
        @test report.metadata[:final_segment_annotated_iteration_row_count] == "1"
        annotation = first(findings(report, :solver_iteration_annotated_rows))
        @test annotation.basis == NLPDiagnostics.NumericalObservation
        @test annotation.domain == NLPDiagnostics.RepresentationalIssue
        appended_log = ipopt_log * "\n" *
            "   0  3.0e+00 4.0e+00 5.0e+00  -1.0 0.0e+00    -  0.0e+00 0.0e+00   0\n"
        appended_report = NLPDiagnostics.analyze_solver_iterations(
            "Ipopt",
            appended_log;
            residual_tolerance = 1e-3,
        )
        @test appended_report.metadata[:iteration_segment_count] == "2"
        @test appended_report.metadata[:final_segment_first_iteration] == "0"
        @test appended_report.metadata[:final_segment_record_count] == "1"
        @test isempty(findings(appended_report, :solver_iteration_residual_regression))

        stagnant_log = """
        iter    objective    inf_pr   inf_du lg(mu)  ||d||  lg(rg) alpha_du alpha_pr  ls
           0  1.0e+00 1.0e+00 1.0e+00  -1.0 0.0e+00    -  0.0e+00 0.0e+00   0
           1  1.0e+00 9.0e-01 9.0e-01  -1.0 0.0e+00    -  0.0e+00 0.0e+00   0
           2  1.0e+00 8.0e-01 8.0e-01  -1.0 0.0e+00    -  0.0e+00 0.0e+00   0
        """
        stagnant_report = NLPDiagnostics.analyze_solver_iterations(
            "Ipopt",
            stagnant_log;
            residual_tolerance = 1e-3,
            stagnation_window = 3,
            stagnation_improvement_factor = 2,
        )
        stagnation = first(findings(
            stagnant_report,
            :solver_iteration_residual_stagnation,
        ))
        @test stagnation.basis == NLPDiagnostics.HeuristicInterpretation
        @test stagnation.confidence == NLPDiagnostics.ConfidenceMedium
        @test stagnant_report.metadata[:stagnation_window] == "3"
        @test stagnant_report.metadata[:small_primal_step_threshold] == "1.0e-8"
        @test_throws ArgumentError NLPDiagnostics.analyze_solver_iterations(
            "Ipopt", stagnant_log; stagnation_window = 2,
        )

        stalled_step_log = """
        iter    objective    inf_pr   inf_du lg(mu)  ||d||  lg(rg) alpha_du alpha_pr  ls
           0  1.0e+00 1.0e+00 1.0e+00  -1.0 0.0e+00    -  0.0e+00 1.0e-10   0
           1  1.0e+00 9.0e-01 9.0e-01  -1.0 0.0e+00    -  0.0e+00 1.0e-10   0
           2  1.0e+00 8.0e-01 8.0e-01  -1.0 0.0e+00    -  0.0e+00 1.0e-10   0
        """
        stalled_step_report = NLPDiagnostics.analyze_solver_iterations(
            "Ipopt", stalled_step_log;
            residual_tolerance = 1e-3,
            stagnation_window = 3,
            small_primal_step_threshold = 1e-8,
        )
        small_steps = first(findings(
            stalled_step_report,
            :solver_iteration_small_primal_steps,
        ))
        @test small_steps.basis == NLPDiagnostics.HeuristicInterpretation
        @test small_steps.confidence == NLPDiagnostics.ConfidenceMedium
        @test_throws ArgumentError NLPDiagnostics.analyze_solver_iterations(
            "Ipopt", stalled_step_log; small_primal_step_threshold = -1,
        )

        imbalanced_log = """
        iter    objective    inf_pr   inf_du lg(mu)  ||d||  lg(rg) alpha_du alpha_pr  ls
           0  1.0e+00 1.0e+00 1.0e-04  -1.0 0.0e+00    -  0.0e+00 1.0e+00   0
           1  1.0e+00 9.0e-01 1.0e-04  -1.0 0.0e+00    -  0.0e+00 1.0e+00   0
           2  1.0e+00 8.0e-01 1.0e-04  -1.0 0.0e+00    -  0.0e+00 1.0e+00   0
        """
        imbalance_report = NLPDiagnostics.analyze_solver_iterations(
            "Ipopt", imbalanced_log;
            residual_tolerance = 1e-3,
            stagnation_window = 3,
            residual_imbalance_factor = 100,
        )
        imbalance = first(findings(
            imbalance_report,
            :solver_iteration_residual_imbalance,
        ))
        @test imbalance.basis == NLPDiagnostics.NumericalObservation
        @test Dict(imbalance.evidence[end].details)["dominant_residual"] == "primal"
        @test imbalance_report.metadata[:residual_imbalance_factor] == "100"
        @test_throws ArgumentError NLPDiagnostics.analyze_solver_iterations(
            "Ipopt", imbalanced_log; residual_imbalance_factor = 1,
        )

        model = new_model()
        x = MOI.add_variable(model)
        MOI.set(model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        MOI.set(model, MOI.ObjectiveFunction{MOI.VariableIndex}(), x)
        records = NLPDiagnostics.solver_iteration_records(ipopt_log)
        bindings = NLPDiagnostics.bind_iteration_points(
            records,
            Dict(1 => NLPDiagnostics.EvaluationPoint([x], [1.0]; label = "ipopt-1")),
        )
        @test length(bindings) == 1
        point_report = NLPDiagnostics.analyze_iteration_points(
            model,
            bindings;
            objective_agreement_factor = 1.5,
        )
        @test point_report.metadata[:iteration_1_log_line] == "3"
        @test point_report.metadata[:iteration_1_point_label] == "ipopt-1"
        @test point_report.metadata[:iteration_1_point_fingerprint] ==
              NLPDiagnostics.evaluation_point_fingerprint(bindings[1].point)
        @test point_report.metadata[:iteration_1_point_provenance_kind] == "UserPoint"
        @test point_report.metadata[:bound_iteration_complete_point_count] == "1"
        @test length(
            findings(point_report, :solver_iteration_primal_residual_mismatch),
        ) == 1
        @test point_report.metadata[:iteration_1_logged_objective] == "2.0"
        @test point_report.metadata[:iteration_1_recomputed_objective] == "1.0"
        @test length(
            findings(point_report, :solver_iteration_objective_mismatch),
        ) == 1
        @test point_report.metadata[:bound_iteration_degeneracy_checked] == "true"
        stationary_iteration_model = new_model()
        stationary_iteration_variable = MOI.add_variable(stationary_iteration_model)
        stationary_iteration_constraint = MOI.add_constraint(
            stationary_iteration_model,
            MOI.ScalarNonlinearFunction(:^, Any[stationary_iteration_variable, 2]),
            MOI.EqualTo(0.0),
        )
        stationary_iteration_binding = NLPDiagnostics.IterationPointBinding(
            records[1],
            NLPDiagnostics.EvaluationPoint(
                [stationary_iteration_variable], [0.0]; label = "stationary-iterate",
            ),
            1,
            :iteration,
        )
        stationary_iteration_component = NLPDiagnostics.ComponentMetadata(
            :test_component,
            "stationary_iterate";
            variables = [stationary_iteration_variable],
            constraints = [NLPDiagnostics.EntityRef(
                :constraint,
                stationary_iteration_constraint.value,
            )],
            expected_rank = 1,
        )
        stationary_iteration_report = NLPDiagnostics.analyze_iteration_points(
            stationary_iteration_model,
            [stationary_iteration_binding],
            components = [stationary_iteration_component],
        )
        @test length(findings(
            stationary_iteration_report, :unexpected_local_rank_loss,
        )) == 1
        @test length(findings(
            stationary_iteration_report, :component_expected_rank_mismatch,
        )) == 1
        @test stationary_iteration_report.metadata[
            :bound_iteration_component_ranks_checked
        ] == "true"
        stationary_iteration_probe_report = NLPDiagnostics.analyze_iteration_points(
            stationary_iteration_model,
            [stationary_iteration_binding];
            iterative_right_nullspace_probe_dimension = 1,
            iterative_right_nullspace_probe_iterations = 20,
            iterative_left_nullspace_probe_dimension = 1,
            iterative_left_nullspace_probe_iterations = 20,
            iterative_spectrum_probe_dimension = 1,
            iterative_spectrum_probe_iterations = 20,
        )
        @test stationary_iteration_probe_report.metadata[
            :bound_iteration_iterative_left_probe_requested
        ] == "true"
        @test stationary_iteration_probe_report.metadata[
            :bound_iteration_iterative_left_probe_finding_count
        ] == "1"
        @test length(findings(
            stationary_iteration_probe_report,
            :iterative_jacobian_candidate_small_residual_left_direction,
        )) == 1
        stationary_iteration_second_binding = NLPDiagnostics.IterationPointBinding(
            records[1],
            NLPDiagnostics.EvaluationPoint(
                [stationary_iteration_variable], [0.0]; label = "stationary-iterate-repeat",
            ),
            1,
            :direct,
        )
        stationary_iteration_persistence_report =
            NLPDiagnostics.analyze_iteration_points(
                stationary_iteration_model,
                [stationary_iteration_binding, stationary_iteration_second_binding];
                iterative_right_nullspace_probe_dimension = 1,
                iterative_right_nullspace_probe_iterations = 20,
                iterative_left_nullspace_probe_dimension = 1,
                iterative_left_nullspace_probe_iterations = 20,
                check_iterative_right_nullspace_persistence = true,
                check_iterative_left_nullspace_persistence = true,
                check_jacobian_condition_persistence = true,
            )
        @test stationary_iteration_persistence_report.metadata[
            :bound_iteration_iterative_right_probe_persistence_segment_count
        ] == "1"
        @test stationary_iteration_persistence_report.metadata[
            :bound_iteration_rank_persistence_left_nullspace_support_relative
        ] == "0.1"
        @test length(findings(
            stationary_iteration_persistence_report,
            :jacobian_left_nullspace_persistent,
        )) == 1
        @test length(findings(
            stationary_iteration_persistence_report,
            :iterative_left_nullspace_persistence_persistent,
        )) == 1
        @test stationary_iteration_persistence_report.metadata[
            :bound_iteration_jacobian_condition_persistence_segment_count
        ] == "1"
        @test length(findings(
            stationary_iteration_persistence_report,
            :jacobian_condition_persistence_unavailable,
        )) == 1
        stationary_screen_persistence_report = NLPDiagnostics.analyze_iteration_points(
            stationary_iteration_model,
            [stationary_iteration_binding, stationary_iteration_second_binding];
            check_nonsmoothness_persistence = true,
            check_weak_activity_persistence = true,
        )
        @test stationary_screen_persistence_report.metadata[
            :bound_iteration_nonsmoothness_persistence_segment_count
        ] == "1"
        @test stationary_screen_persistence_report.metadata[
            :bound_iteration_weak_activity_persistence_segment_count
        ] == "1"
        combined_screen_persistence_report = NLPDiagnostics.analyze(
            stationary_iteration_model;
            iteration_bindings = [
                stationary_iteration_binding,
                stationary_iteration_second_binding,
            ],
            check_iteration_nonsmoothness_persistence = true,
            check_iteration_weak_activity_persistence = true,
        )
        @test combined_screen_persistence_report.metadata[
            :iteration_points_bound_iteration_nonsmoothness_persistence_segment_count
        ] == "1"
        combined_iteration_probe_report = NLPDiagnostics.analyze(
            stationary_iteration_model;
            iteration_bindings = [stationary_iteration_binding],
            iterative_left_nullspace_probe_dimension = 1,
            iterative_left_nullspace_probe_iterations = 20,
        )
        @test combined_iteration_probe_report.metadata[
            :iteration_points_bound_iteration_iterative_left_probe_finding_count
        ] == "1"
        combined_iteration_rank_support_report = NLPDiagnostics.analyze(
            stationary_iteration_model;
            iteration_bindings = [
                stationary_iteration_binding,
                stationary_iteration_second_binding,
            ],
            iteration_rank_persistence_left_nullspace_support_relative = 0.5,
            iteration_rank_persistence_right_nullspace_support_relative = 0.4,
            iteration_rank_persistence_scaling_change_factor_threshold = 7.0,
            iteration_rank_persistence_expected_mode_span_alignment_threshold = 0.9,
            check_iteration_jacobian_condition_persistence = true,
        )
        @test combined_iteration_rank_support_report.metadata[
            :iteration_points_bound_iteration_rank_persistence_left_nullspace_support_relative
        ] == "0.5"
        @test combined_iteration_rank_support_report.metadata[
            :iteration_points_bound_iteration_rank_persistence_right_nullspace_support_relative
        ] == "0.4"
        @test combined_iteration_rank_support_report.metadata[
            :iteration_points_bound_iteration_rank_persistence_scaling_change_factor_threshold
        ] == "7.0"
        @test combined_iteration_rank_support_report.metadata[
            :iteration_points_bound_iteration_rank_persistence_expected_mode_span_alignment_threshold
        ] == "0.9"
        @test combined_iteration_rank_support_report.metadata[
            :iteration_points_bound_iteration_jacobian_condition_persistence_checked
        ] == "true"
        no_degeneracy_iteration_report = NLPDiagnostics.analyze_iteration_points(
            stationary_iteration_model,
            [stationary_iteration_binding];
            check_degeneracy = false,
            check_component_ranks = false,
        )
        @test no_degeneracy_iteration_report.metadata[
            :bound_iteration_degeneracy_checked
        ] == "false"
        @test no_degeneracy_iteration_report.metadata[
            :bound_iteration_component_ranks_checked
        ] == "false"
        @test isempty(findings(
            no_degeneracy_iteration_report, :unexpected_local_rank_loss,
        ))
        stepped_point_report = NLPDiagnostics.analyze_iteration_points(
            model, bindings; relative_step = 1.0e-5,
        )
        @test stepped_point_report.metadata[:bound_iteration_relative_step] ==
              "1.0e-5"
        @test_throws ArgumentError NLPDiagnostics.analyze_iteration_points(
            model, bindings; relative_step = 0,
        )

        restarted_bindings = NLPDiagnostics.bind_iteration_points(
            appended_records,
            Dict((2, 0) => NLPDiagnostics.EvaluationPoint(
                [x], [3.0]; label = "restarted-0",
            )),
        )
        @test length(restarted_bindings) == 1
        @test only(restarted_bindings).segment == 2
        restarted_report = NLPDiagnostics.analyze_iteration_points(
            model, restarted_bindings,
        )
        @test restarted_report.metadata[:segment_2_iteration_0_point_label] ==
              "restarted-0"
        @test restarted_report.metadata[:segment_2_iteration_0_segment] == "2"
        legacy_restart_bindings = NLPDiagnostics.bind_iteration_points(
            appended_records,
            Dict(0 => NLPDiagnostics.EvaluationPoint(
                [x], [3.0]; label = "ambiguous-restart-0",
            )),
        )
        @test length(legacy_restart_bindings) == 2
        @test all(binding -> binding.selector == :iteration, legacy_restart_bindings)
        legacy_restart_report = NLPDiagnostics.analyze_iteration_points(
            model, legacy_restart_bindings,
        )
        @test length(findings(
            legacy_restart_report, :solver_iteration_restart_binding_ambiguous,
        )) == 1
        @test legacy_restart_report.metadata[
            :bound_iteration_legacy_selector_count
        ] == "2"
        @test_throws ArgumentError NLPDiagnostics.bind_iteration_points(
            records, Dict("one" => NLPDiagnostics.EvaluationPoint([x], [1.0])),
        )
        @test_throws ArgumentError NLPDiagnostics.bind_iteration_points(
            records, Dict(1 => [1.0]),
        )

        cone_model = new_model()
        t, z = MOI.add_variables(cone_model, 2)
        MOI.add_constraint(cone_model, MOI.VectorOfVariables([t, z]), MOI.SecondOrderCone(2))
        cone_binding = NLPDiagnostics.bind_iteration_points(
            records,
            Dict(1 => NLPDiagnostics.EvaluationPoint([t, z], [0.0, 1.0]; label = "cone-1")),
        )
        cone_report = NLPDiagnostics.analyze_iteration_points(cone_model, cone_binding)
        @test cone_report.metadata[:iteration_1_recomputed_scalar_violation] == "0.0"
        @test cone_report.metadata[:iteration_1_recomputed_coupled_violation] == "1.0"
        @test cone_report.metadata[:iteration_1_recomputed_total_violation] == "1.0"

        trend_model = new_model()
        q = MOI.add_variable(trend_model)
        MOI.add_constraint(trend_model, q, MOI.EqualTo(0.0))
        MOI.set(trend_model, MOI.ObjectiveSense(), MOI.MAX_SENSE)
        MOI.set(
            trend_model,
            MOI.ObjectiveFunction{MOI.ScalarAffineFunction{Float64}}(),
            MOI.ScalarAffineFunction([MOI.ScalarAffineTerm(-1.0, q)], 0.0),
        )
        trend_bindings = NLPDiagnostics.bind_iteration_points(
            records,
            Dict(
                0 => NLPDiagnostics.EvaluationPoint([q], [0.0]; label = "trend-0"),
                1 => NLPDiagnostics.EvaluationPoint([q], [10.0]; label = "trend-1"),
            ),
        )
        trend_report = NLPDiagnostics.analyze_iteration_points(trend_model, trend_bindings)
        @test length(
            findings(trend_report, :solver_iteration_trace_feasibility_disagreement),
        ) == 1
        @test length(
            findings(trend_report, :solver_iteration_trace_objective_disagreement),
        ) == 1

        restarted_trend_bindings = NLPDiagnostics.bind_iteration_points(
            appended_records,
            Dict(
                (1, 0) => NLPDiagnostics.EvaluationPoint(
                    [q], [0.0]; label = "first-run-0",
                ),
                (1, 1) => NLPDiagnostics.EvaluationPoint(
                    [q], [0.0]; label = "first-run-1",
                ),
                (2, 0) => NLPDiagnostics.EvaluationPoint(
                    [q], [10.0]; label = "second-run-0",
                ),
            ),
        )
        restarted_trend_report = NLPDiagnostics.analyze_iteration_points(
            trend_model, restarted_trend_bindings,
        )
        @test restarted_trend_report.metadata[:bound_iteration_segment_count] == "2"
        @test restarted_trend_report.metadata[
            :bound_iteration_multi_point_segment_count
        ] == "1"
        @test isempty(findings(
            restarted_trend_report, :solver_iteration_trace_objective_disagreement,
        ))
    end

    @testset "profile includes structural-stage timings" begin
        model = new_model()
        x = MOI.add_variable(model)
        case = NLPDiagnostics.ProfileCase(
            "structural-timing",
            NLPDiagnostics.EvaluationPoint([x], [0.0]),
        )
        result = NLPDiagnostics.profile_case(model, case)
        @test all(
            stage -> haskey(result.stage_seconds, stage),
            (:structural_graph, :structural_matching, :structural_dm),
        )
    end

    @testset "variable-domain intersections preserve type and infeasibility" begin
        typed = MOIU.Model{BigFloat}()
        x = MOI.add_variable(typed)
        MOI.add_constraint(typed, x, MOI.Interval(big"1.0", big"2.0"))
        domain = only(NLPDiagnostics.variable_domains(typed))
        @test domain.lower isa BigFloat
        @test domain.upper isa BigFloat
        unbounded = new_model()
        MOI.add_variable(unbounded)
        @test isnothing(only(NLPDiagnostics.variable_domains(unbounded)).lower)

        invalid_variable = MOI.VariableIndex(1)
        invalid_snapshot = NLPDiagnostics.ModelSnapshot(
            [NLPDiagnostics.VariableRecord(invalid_variable, nothing)],
            [NLPDiagnostics.ConstraintRecord(
                MOI.ConstraintIndex{MOI.VariableIndex,MOI.GreaterThan{Float64}}(1),
                invalid_variable,
                MOI.GreaterThan(NaN),
                nothing,
            )],
            nothing,
            nothing,
            String[],
        )
        @test only(NLPDiagnostics.variable_roles(invalid_snapshot)) ==
              NLPDiagnostics.InvalidVariableDomain
        invalid_report = NLPDiagnostics.analyze_static(invalid_snapshot)
        @test length(findings(invalid_report, :nan_variable_bound)) == 1

        semi_snapshot = NLPDiagnostics.ModelSnapshot(
            [NLPDiagnostics.VariableRecord(invalid_variable, nothing)],
            [NLPDiagnostics.ConstraintRecord(
                MOI.ConstraintIndex{MOI.VariableIndex,MOI.Semicontinuous{Float64}}(2),
                invalid_variable,
                MOI.Semicontinuous(1.0, 2.0),
                nothing,
            )],
            nothing,
            nothing,
            String[],
        )
        semi_report = NLPDiagnostics.analyze_static(semi_snapshot)
        @test length(findings(semi_report, :disjunctive_variable_domain)) == 1

        binary_snapshot = NLPDiagnostics.ModelSnapshot(
            [NLPDiagnostics.VariableRecord(invalid_variable, nothing)],
            [NLPDiagnostics.ConstraintRecord(
                MOI.ConstraintIndex{MOI.VariableIndex,MOI.ZeroOne}(3),
                invalid_variable,
                MOI.ZeroOne(),
                nothing,
            )],
            nothing,
            nothing,
            String[],
        )
        @test only(NLPDiagnostics.variable_roles(binary_snapshot)) ==
              NLPDiagnostics.DiscreteVariable
        binary_report = NLPDiagnostics.analyze_static(binary_snapshot)
        @test length(findings(binary_report, :discrete_variable_domain)) == 1

        binary_infeasible_snapshot = NLPDiagnostics.ModelSnapshot(
            [NLPDiagnostics.VariableRecord(invalid_variable, nothing)],
            [
                NLPDiagnostics.ConstraintRecord(
                    MOI.ConstraintIndex{MOI.VariableIndex,MOI.ZeroOne}(4),
                    invalid_variable,
                    MOI.ZeroOne(),
                    nothing,
                ),
                NLPDiagnostics.ConstraintRecord(
                    MOI.ConstraintIndex{MOI.VariableIndex,MOI.EqualTo{Float64}}(5),
                    invalid_variable,
                    MOI.EqualTo(2.0),
                    nothing,
                ),
            ],
            nothing,
            nothing,
            String[],
        )
        @test only(NLPDiagnostics.variable_roles(binary_infeasible_snapshot)) ==
              NLPDiagnostics.InfeasibleVariableDomain
        @test length(
            findings(
                NLPDiagnostics.analyze_static(binary_infeasible_snapshot),
                :inconsistent_variable_bounds,
            ),
        ) == 1

        binary_fractional_snapshot = NLPDiagnostics.ModelSnapshot(
            [NLPDiagnostics.VariableRecord(invalid_variable, nothing)],
            [
                NLPDiagnostics.ConstraintRecord(
                    MOI.ConstraintIndex{MOI.VariableIndex,MOI.ZeroOne}(6),
                    invalid_variable,
                    MOI.ZeroOne(),
                    nothing,
                ),
                NLPDiagnostics.ConstraintRecord(
                    MOI.ConstraintIndex{MOI.VariableIndex,MOI.EqualTo{Float64}}(7),
                    invalid_variable,
                    MOI.EqualTo(0.5),
                    nothing,
                ),
            ],
            nothing,
            nothing,
            String[],
        )
        @test length(
            findings(
                NLPDiagnostics.analyze_static(binary_fractional_snapshot),
                :nonintegral_discrete_fixed_value,
            ),
        ) == 1

        binary_empty_snapshot = NLPDiagnostics.ModelSnapshot(
            [NLPDiagnostics.VariableRecord(invalid_variable, nothing)],
            [
                NLPDiagnostics.ConstraintRecord(
                    MOI.ConstraintIndex{MOI.VariableIndex,MOI.ZeroOne}(8),
                    invalid_variable,
                    MOI.ZeroOne(),
                    nothing,
                ),
                NLPDiagnostics.ConstraintRecord(
                    MOI.ConstraintIndex{MOI.VariableIndex,MOI.Interval{Float64}}(9),
                    invalid_variable,
                    MOI.Interval(0.1, 0.9),
                    nothing,
                ),
            ],
            nothing,
            nothing,
            String[],
        )
        @test length(
            findings(
                NLPDiagnostics.analyze_static(binary_empty_snapshot),
                :empty_discrete_variable_domain,
            ),
        ) == 1
    end
end
