#!/usr/bin/env julia

"""Run a predeclared perturbed-start matrix on the qualified MV+LV snapshot.

This is a numerical-start sensitivity check, not a policy score. Each declared
start variant perturbs the authoritative BMOPFTools anchor point by a global
affine amount, transports that point into every scaling policy, and then runs
the same matched-start endpoint and covariance gates used by the snapshot
campaign. Raw solver artifacts are intentionally summarized in the output so
the matrix remains reviewable without duplicating the large per-constraint
trace payload.

Environment controls:

  * `NLPDIAGNOSTICS_COMBINED_MV_LV_PERTURBED_START_FEEDER` (default `LV1_14bus`)
  * `NLPDIAGNOSTICS_COMBINED_MV_LV_PERTURBED_START_REPEATS` (default `2`, minimum `2`)
  * `NLPDIAGNOSTICS_COMBINED_MV_LV_PERTURBED_START_MAX_ITER` (default `10`)
  * `NLPDIAGNOSTICS_COMBINED_MV_LV_PERTURBED_START_TOL` (default `1e-10`)
  * `NLPDIAGNOSTICS_COMBINED_MV_LV_PERTURBED_START_MODE` (default `global_affine`; `voltage_only` supported)
  * `NLPDIAGNOSTICS_COMBINED_MV_LV_PERTURBED_START_MAX_VARIABLES` (default `5000`)
  * `NLPDIAGNOSTICS_COMBINED_MV_LV_PERTURBED_START_SOLVER` (default `ipopt`)
  * `NLPDIAGNOSTICS_COMBINED_MV_LV_PERTURBED_START_OUTPUT` (default under `work/`)
"""

using NLPDiagnostics
using BMOPFTools
using JuMP
using SHA
import MathOptInterface as MOI

include(joinpath(@__DIR__, "bmopf_combined_mv_lv_snapshot_campaign.jl"))

const _PERTURBED_START_RUNNER_VERSION =
    "bmopf-combined-mv-lv-perturbed-start-campaign-v1"

function _perturbed_variants()
    return [("plus_1pct", 0.01), ("minus_1pct", -0.01)]
end

function _bounded_start_value(backend, variable, value)
    lower = try
        Float64(MOI.get(backend, MOI.VariableLowerBound(), variable))
    catch
        -Inf
    end
    upper = try
        Float64(MOI.get(backend, MOI.VariableUpperBound(), variable))
    catch
        Inf
    end
    return clamp(value, lower, upper)
end

function _perturb_anchor_evaluation(anchor_context, base_evaluation, label, delta, mode)
    backend = JuMP.backend(BMOPFTools.opf_model(anchor_context))
    values = Float64[]
    changed = 0
    clipped = 0
    for (variable, value) in zip(
        base_evaluation.point.variables, base_evaluation.point.values,
    )
        variable_name = try
            lowercase(String(MOI.get(backend, MOI.VariableName(), variable)))
        catch
            ""
        end
        voltage_variable = startswith(variable_name, "vr_") || startswith(variable_name, "vi_")
        perturb = mode == "global_affine" || voltage_variable
        candidate = !perturb ? Float64(value) :
            (abs(Float64(value)) > 1.0e-12 ?
                Float64(value) * (1.0 + delta) : delta * 1.0e-3)
        bounded = _bounded_start_value(backend, variable, candidate)
        changed += bounded != Float64(value)
        clipped += bounded != candidate
        push!(values, bounded)
    end
    point = NLPDiagnostics.EvaluationPoint(
        base_evaluation.point.variables,
        values;
        label,
        provenance=base_evaluation.point.provenance,
    )
    evaluation = NLPDiagnostics.evaluate_numerical(backend, point)
    return evaluation, Dict{String,Any}(
        "label" => label,
        "delta" => delta,
        "variable_count" => length(values),
        "changed_variable_count" => changed,
        "clipped_variable_count" => clipped,
        "point_fingerprint" => NLPDiagnostics.evaluation_point_fingerprint(point),
    )
end

function _compact_run(record, variant)
    artifact = get(record, "artifact", Dict{String,Any}())
    endpoint = get(artifact, "physical_endpoint", Dict{String,Any}())
    transport = get(record, "common_start_transport", Dict{String,Any}())
    return Dict{String,Any}(
        "variant" => variant,
        "policy" => get(record, "policy", "unknown"),
        "replicate" => get(record, "replicate", nothing),
        "provenance_fingerprint" => get(record, "provenance_fingerprint", nothing),
        "common_start_covariance_passed" =>
            get(record, "common_start_covariance_passed", false),
        "physical_endpoint_accepted" => get(endpoint, "acceptance_passed", false),
        "point_fingerprint" => get(transport, "point_fingerprint", nothing),
        "solve_seconds" => get(record, "solve_seconds", nothing),
        "termination_status" => get(record, "termination_status", "unknown"),
        "primal_status" => get(record, "primal_status", "unknown"),
    )
end

function _compact_campaign(campaign)
    return Dict{String,Any}(
        "campaign_qualified" => get(campaign, "campaign_qualified", false),
        "gates" => get(campaign, "gates", Dict{String,Any}()),
        "policies" => get(campaign, "policies", Dict{String,Any}()),
        "comparisons" => get(campaign, "comparisons", Dict{String,Any}()),
        "metadata" => get(campaign, "metadata", Dict{String,Any}()),
    )
end

function main()
    data_root = _data_root()
    feeder = strip(get(
        ENV,
        "NLPDIAGNOSTICS_COMBINED_MV_LV_PERTURBED_START_FEEDER",
        "LV1_14bus",
    ))
    occursin(r"^LV[0-9]+_[0-9]+bus$", feeder) || error("invalid feeder: $feeder")
    isdir(joinpath(data_root, "LV", feeder)) || error("unknown LV feeder: $feeder")
    repeats = _snapshot_env_int(
        "NLPDIAGNOSTICS_COMBINED_MV_LV_PERTURBED_START_REPEATS", 2; minimum=2,
    )
    max_iter = _snapshot_env_int(
        "NLPDIAGNOSTICS_COMBINED_MV_LV_PERTURBED_START_MAX_ITER", 10; minimum=1,
    )
    solver_tolerance = _snapshot_env_float(
        "NLPDIAGNOSTICS_COMBINED_MV_LV_PERTURBED_START_TOL", 1.0e-10,
    )
    mode = lowercase(strip(get(
        ENV,
        "NLPDIAGNOSTICS_COMBINED_MV_LV_PERTURBED_START_MODE",
        "global_affine",
    )))
    mode in ("global_affine", "voltage_only") ||
        error("perturbed-start mode must be global_affine or voltage_only")
    max_variables = _snapshot_env_int(
        "NLPDIAGNOSTICS_COMBINED_MV_LV_PERTURBED_START_MAX_VARIABLES", 5000; minimum=1,
    )
    solver_name = lowercase(strip(get(
        ENV,
        "NLPDIAGNOSTICS_COMBINED_MV_LV_PERTURBED_START_SOLVER",
        "ipopt",
    )))
    optimizer, solver = _solver_config()
    output = abspath(get(
        ENV,
        "NLPDIAGNOSTICS_COMBINED_MV_LV_PERTURBED_START_OUTPUT",
        joinpath(@__DIR__, "..", "work", "bmopf-combined-mv-lv-perturbed-start-$feeder.json"),
    ))
    snapshot_path = replace(output, ".json" => ".dss")
    source_files = _flatten_snapshot(data_root, feeder, snapshot_path)
    network = BMOPFTools.from_dss(snapshot_path)
    policies, anchor_context = _policy_factories(network)
    backend = JuMP.backend(BMOPFTools.opf_model(anchor_context))
    variable_count = length(MOI.get(backend, MOI.ListOfVariableIndices()))
    source_warnings = get(get(network, "_meta", Dict{String,Any}()), "powerio_warnings", Any[])
    variants = _perturbed_variants()
    variant_payloads = Dict{String,Any}[]
    if variable_count <= max_variables
        environment = _benchmark_environment()
        fingerprint = _benchmark_environment_fingerprint(environment)
        base_evaluation = _schema_evaluation(anchor_context, "combined-mv-lv-$feeder-anchor")
        for (variant, delta) in variants
            anchor_evaluation, perturbation = _perturb_anchor_evaluation(
                anchor_context, base_evaluation,
                "combined-mv-lv-$feeder-$variant-anchor", delta,
                mode,
            )
            records = Dict{String,Any}[]
            comparisons = Dict{String,Any}[]
            private_runs = Dict{Tuple{String,Int},Any}()
            for (policy_name, factory) in policies
                for replicate in 1:repeats
                    public_record, private_record = _run_policy(
                        network, policy_name, factory(), replicate,
                        anchor_context, anchor_evaluation, fingerprint;
                        max_iter,
                        solver_tolerance,
                        add_objective=true,
                        optimizer,
                        solver,
                        max_dense_entries=0,
                    )
                    push!(records, public_record)
                    private_runs[(policy_name, replicate)] = private_record
                end
            end
            reference = first(policies)[1]
            push!(comparisons, _matched_comparison(
                reference, 1, private_runs[(reference, 1)],
                reference, 2, private_runs[(reference, 2)];
                baseline_repeat=true,
                max_dense_entries=0,
            ))
            for (policy_name, _) in policies[2:end]
                for replicate in 1:repeats
                    push!(comparisons, _matched_comparison(
                        reference, replicate, private_runs[(reference, replicate)],
                        policy_name, replicate, private_runs[(policy_name, replicate)];
                        max_dense_entries=0,
                    ))
                end
            end
            campaign = NLPDiagnostics.scaling_solver_experiment_campaign_data(
                records, comparisons;
                reference_policy=reference,
                minimum_repeats=repeats,
                metadata=Dict(
                    "runner_version" => _PERTURBED_START_RUNNER_VERSION,
                    "case" => "combined-mv-lv-$feeder",
                    "solver" => uppercasefirst(solver_name),
                    "start_variant" => variant,
                    "start_mode" => mode,
                    "start_delta" => delta,
                    "max_iter" => max_iter,
                    "solver_tolerance" => solver_tolerance,
                ),
            )
            push!(variant_payloads, Dict{String,Any}(
                "variant" => variant,
                "perturbation" => perturbation,
                "campaign" => _compact_campaign(campaign),
                "endpoint_diagnostics" => [
                    _snapshot_endpoint_diagnostic(comparison) for comparison in comparisons
                ],
                "records" => [_compact_run(record, variant) for record in records],
            ))
        end
    end
    qualified_variants = [
        get(get(payload, "campaign", Dict{String,Any}()), "campaign_qualified", false)
        for payload in variant_payloads
    ]
    payload = Dict{String,Any}(
        "schema_version" => "nlpdiagnostics-bmopf-combined-mv-lv-perturbed-start-campaign-v1",
        "runner_version" => _PERTURBED_START_RUNNER_VERSION,
        "status" => variable_count <= max_variables ?
            "perturbed_start_matrix_complete" : "snapshot_size_guarded",
        "snapshot" => Dict(
            "feeder" => feeder,
            "generated_dss" => snapshot_path,
            "source_files" => [Dict("path" => path, "sha256" => bytes2hex(sha256(read(path)))) for path in source_files],
            "network_shape" => Dict(
                "bus_count" => length(get(network, "bus", Dict())),
                "line_count" => length(get(network, "line", Dict())),
                "load_count" => length(get(network, "load", Dict())),
                "transformer_count" => sum(length(value) for value in values(get(network, "transformer", Dict())) if value isa AbstractDict),
                "switch_count" => length(get(network, "switch", Dict())),
                "model_variable_count" => variable_count,
            ),
            "source_warning_count" => length(source_warnings),
            "source_warning_codes" => _warning_codes(source_warnings),
        ),
        "budgets" => Dict(
            "variants" => [Dict("name" => name, "delta" => delta) for (name, delta) in variants],
            "repeats" => repeats,
            "max_iter" => max_iter,
            "solver_tolerance" => solver_tolerance,
            "mode" => mode,
            "max_variables" => max_variables,
        ),
        "variants" => variant_payloads,
        "matrix_gates" => Dict(
            "variant_count" => length(variant_payloads),
            "all_variants_qualified" => !isempty(qualified_variants) && all(qualified_variants),
            "all_physical_endpoints_accepted" => all(
                get(get(payload, "campaign", Dict{String,Any}()), "gates", Dict{String,Any}())["all_physical_endpoints_accepted"]
                for payload in variant_payloads
            ) && !isempty(variant_payloads),
            "all_comparisons_qualified" => all(
                get(get(payload, "campaign", Dict{String,Any}()), "gates", Dict{String,Any}())["all_comparisons_qualified"]
                for payload in variant_payloads
            ) && !isempty(variant_payloads),
        ),
        "qualification" => Dict(
            "interpretation" => "perturbed-start Ipopt evidence is a numerical-start sensitivity check; no policy score or universal rule",
            "source_provenance_preserved" => true,
        ),
    )
    mkpath(dirname(output))
    write_json(output, _snapshot_json_safe(payload))
    println("wrote combined MV/LV perturbed-start campaign to $output")
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    main()
end
