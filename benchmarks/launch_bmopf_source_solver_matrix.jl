#!/usr/bin/env julia

"""Run a bounded, source-preserving DSS solver-trace matrix.

Each case/budget pair gets an isolated output directory containing the trace,
summary, validation report, and process log. The final matrix manifest keeps
classification stability visible across solver budgets without reducing it to
a scalar score.
"""

using JSON

const _RUNNER_VERSION = "bmopf-source-solver-matrix-v4"
const _DEFAULT_CASES = [
    "pf_1ph_perfectneutral.dss",
    "pf_1ph_freeneutral.dss",
    "pf_delta_load.dss",
    "pf_zip_3ph.dss",
    "pf_3ph_line.dss",
    "pf_yd_xfmr.dss",
]

_dict(value) = value isa AbstractDict ? Dict{String,Any}(string(k) => v for (k, v) in value) : Dict{String,Any}()

function _list(name, defaults)
    selected = filter(!isempty, strip.(split(get(ENV, name, ""), ',')))
    return isempty(selected) ? String[defaults...] : String[selected...]
end

function _env_flag(name; default = false)
    raw = lowercase(strip(get(ENV, name, default ? "true" : "false")))
    raw in ("1", "true", "yes", "on") && return true
    raw in ("0", "false", "no", "off") && return false
    error("$name must be a boolean")
end

function _budgets()
    raw = _list("NLPDIAGNOSTICS_BMOPF_SOURCE_SOLVER_BUDGETS", ["5", "25"])
    budgets = Int[]
    for value in raw
        budget = try parse(Int, value) catch
            error("source solver budgets must be positive integers, got '$value'")
        end
        budget > 0 || error("source solver budgets must be positive")
        push!(budgets, budget)
    end
    return unique(budgets)
end

function _case_name(relative)
    return replace(replace(relative, '/' => "__"), ".dss" => "")
end

function _project()
    configured = strip(get(ENV, "NLPDIAGNOSTICS_BENCHMARK_PROJECT", ""))
    isempty(configured) ? Base.active_project() : abspath(configured)
end

function _run_command(command, environment, log_path)
    mkpath(dirname(log_path))
    open(log_path, "w+") do io
        run(pipeline(setenv(command, environment), stdout = io, stderr = io))
    end
end

function _run_pair(script, summary_script, validator_script, project, root,
                   output_root, relative, budget)
    case_dir = joinpath(output_root, "max_iter_$(budget)", _case_name(relative))
    mkpath(case_dir)
    environment = copy(ENV)
    repository_root = normpath(joinpath(@__DIR__, ".."))
    environment["JULIA_LOAD_PATH"] = string(
        repository_root, ':', get(environment, "JULIA_LOAD_PATH", "@"),
    )
    environment["NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT"] = root
    environment["NLPDIAGNOSTICS_BMOPF_INPUT_FORMAT"] = "dss"
    environment["NLPDIAGNOSTICS_BMOPF_CASES"] = relative
    environment["NLPDIAGNOSTICS_BMOPF_SOLVER"] = "ipopt"
    environment["NLPDIAGNOSTICS_BMOPF_OUTPUT_DIR"] = case_dir
    family_enabled = lowercase(strip(get(ENV,
        "NLPDIAGNOSTICS_BMOPF_RUN_FAMILY_PERTURBATIONS", "false"))) in
        ("1", "true", "yes", "on")
    extra_solver_options = strip(get(ENV,
        "NLPDIAGNOSTICS_BMOPF_SOURCE_SOLVER_OPTIONS", ""))
    occursin(r"(^|,)\s*max_iter\s*=", extra_solver_options) && error(
        "NLPDIAGNOSTICS_BMOPF_SOURCE_SOLVER_OPTIONS must not override the matrix budget",
    )
    environment["NLPDIAGNOSTICS_BMOPF_SOLVER_OPTIONS"] = isempty(extra_solver_options) ?
        "max_iter=$(budget)" : "max_iter=$(budget),$(extra_solver_options)"
    environment["NLPDIAGNOSTICS_BMOPF_CAPTURE_POINTS"] = get(ENV,
        "NLPDIAGNOSTICS_BMOPF_SOURCE_SOLVER_CAPTURE_POINTS", "false")
    environment["NLPDIAGNOSTICS_BMOPF_CAPTURE_ROW_RESIDUALS"] = get(ENV,
        "NLPDIAGNOSTICS_BMOPF_SOURCE_SOLVER_CAPTURE_ROW_RESIDUALS", "false")
    environment["NLPDIAGNOSTICS_BMOPF_CAPTURE_LOGS"] = "false"
    configured_profile_stage = lowercase(strip(get(ENV,
        "NLPDIAGNOSTICS_BMOPF_SOURCE_SOLVER_PROFILE_STAGE", "")))
    profile_stage = isempty(configured_profile_stage) ?
        (family_enabled ? get(ENV, "NLPDIAGNOSTICS_BMOPF_FAMILY_PROFILE_STAGE", "full") : "trace") :
        configured_profile_stage
    profile_stage in ("full", "context", "numerical", "trace") || error(
        "NLPDIAGNOSTICS_BMOPF_SOURCE_SOLVER_PROFILE_STAGE must be full, context, numerical, or trace",
    )
    environment["NLPDIAGNOSTICS_BMOPF_PROFILE_STAGE"] = profile_stage
    haskey(ENV, "NLPDIAGNOSTICS_BMOPF_SOURCE_SOLVER_PROFILE_MAX_VARIABLES") &&
        (environment["NLPDIAGNOSTICS_BMOPF_PROFILE_MAX_VARIABLES"] =
            ENV["NLPDIAGNOSTICS_BMOPF_SOURCE_SOLVER_PROFILE_MAX_VARIABLES"])
    haskey(ENV, "NLPDIAGNOSTICS_BMOPF_SOURCE_SOLVER_RANK_MAX_DENSE_ENTRIES") &&
        (environment["NLPDIAGNOSTICS_BMOPF_RANK_MAX_DENSE_ENTRIES"] =
            ENV["NLPDIAGNOSTICS_BMOPF_SOURCE_SOLVER_RANK_MAX_DENSE_ENTRIES"])
    julia = Base.julia_cmd()
    compiled_modules_flag = get(environment, "JULIA_PKG_PRECOMPILE_AUTO", "") == "0" ?
        `--compiled-modules=no` : ``
    command = isnothing(project) ?
        `$julia --startup-file=no $compiled_modules_flag $script` :
        `$julia --startup-file=no --project=$project $compiled_modules_flag $script`
    process_log = joinpath(case_dir, "matrix.process.log")
    status = "ok"
    error_message = nothing
    reuse_existing = lowercase(strip(get(ENV,
        "NLPDIAGNOSTICS_BMOPF_SOURCE_SOLVER_MATRIX_REUSE", "false"))) in
        ("1", "true", "yes", "on")
    if !(reuse_existing && isfile(joinpath(case_dir, "index.json")))
        try
            _run_command(command, environment, process_log)
        catch error
            status = "process_error"
            error_message = sprint(showerror, error)
        end
    end
    index_path = joinpath(case_dir, "index.json")
    summary_path = joinpath(case_dir, "summary.json")
    validation_path = joinpath(case_dir, "validation.json")
    if isfile(index_path)
        summary_command = isnothing(project) ?
            `$julia --startup-file=no $compiled_modules_flag $summary_script $case_dir $summary_path` :
            `$julia --startup-file=no --project=$project $compiled_modules_flag $summary_script $case_dir $summary_path`
        try
            _run_command(summary_command, environment, joinpath(case_dir, "summary.log"))
        catch error
            status = "summary_error"
            error_message = sprint(showerror, error)
        end
    end
    if isfile(summary_path)
        validation_command = isnothing(project) ?
            `$julia --startup-file=no $compiled_modules_flag $validator_script $validation_path $summary_path` :
            `$julia --startup-file=no --project=$project $compiled_modules_flag $validator_script $validation_path $summary_path`
        try
            _run_command(validation_command, environment, joinpath(case_dir, "validation.log"))
        catch error
            status = "validation_error"
            error_message = sprint(showerror, error)
        end
    end
    summary = isfile(summary_path) ? JSON.parsefile(summary_path) : Dict{String,Any}()
    validation = isfile(validation_path) ? JSON.parsefile(validation_path) : Dict{String,Any}()
    family_status_counts = summary isa AbstractDict ?
        get(summary, "family_perturbation_status_counts", Dict{String,Any}()) : Dict{String,Any}()
    family_termination_counts = summary isa AbstractDict ?
        get(summary, "family_perturbation_termination_counts", Dict{String,Any}()) : Dict{String,Any}()
    family_by_family = summary isa AbstractDict ?
        get(summary, "family_perturbation_by_family", Dict{String,Any}()) : Dict{String,Any}()
    family_flag = summary isa AbstractDict ?
        get(summary, "family_perturbations_enabled", false) : false
    family_enabled = family_flag === true || lowercase(string(family_flag)) in
        ("1", "true", "yes", "on")
    family_variant_count = family_status_counts isa AbstractDict ?
        sum(Int(value) for value in values(family_status_counts) if value isa Number;
            init = 0) : 0
    summary_contract = summary isa AbstractDict ?
        get(summary, "source_behavior_contract", Dict{String,Any}()) : Dict{String,Any}()
    summary_contract isa AbstractDict || (summary_contract = Dict{String,Any}())
    summary_auxiliary = summary isa AbstractDict ?
        get(summary, "source_behavior_auxiliary", Dict{String,Any}()) : Dict{String,Any}()
    summary_auxiliary isa AbstractDict || (summary_auxiliary = Dict{String,Any}())
    comparison = summary isa AbstractDict ?
        get(summary, "source_behavior_comparison", Dict{String,Any}()) : Dict{String,Any}()
    comparison isa AbstractDict || (comparison = Dict{String,Any}())
    case_records = summary isa AbstractDict ? get(summary, "cases", Any[]) : Any[]
    case_record = case_records isa AbstractVector && !isempty(case_records) ?
        first(case_records) : Dict{String,Any}()
    case_record isa AbstractDict || (case_record = Dict{String,Any}())
    initialization = get(case_record, "initialization", Dict{String,Any}())
    initialization isa AbstractDict || (initialization = Dict{String,Any}())
    endpoint_derivative = get(case_record, "endpoint_derivative", Dict{String,Any}())
    endpoint_derivative isa AbstractDict || (endpoint_derivative = Dict{String,Any}())
    numerical_row_family_scale = get(case_record,
        "bmopf_jacobian_row_family_scale_attribution", nothing)
    endpoint_status = String(get(endpoint_derivative, "status", "unavailable"))
    if endpoint_status in ("unavailable", "not_requested") &&
        numerical_row_family_scale isa AbstractDict
        endpoint_derivative = Dict{String,Any}(
            "status" => "available_numerical_profile",
            "row_family_scale_attribution" => numerical_row_family_scale,
        )
    end
    row_family_residual_trace = get(case_record,
        "row_family_residual_trace", Dict{String,Any}())
    row_family_residual_trace isa AbstractDict ||
        (row_family_residual_trace = Dict{String,Any}())
    comparison_record = get(case_record, "source_behavior_solver_comparison", Dict())
    comparison_record isa AbstractDict || (comparison_record = Dict{String,Any}())
    row_status_counts = Dict{String,Int}()
    observed_ratios = Float64[]
    coordinate_alignment_available = true
    for raw_row in get(comparison_record, "rows", Any[])
        raw_row isa AbstractDict || continue
        row_status = String(get(raw_row, "status", "unknown"))
        row_status_counts[row_status] = get(row_status_counts, row_status, 0) + 1
        ratio = get(raw_row, "observed_ratio", nothing)
        ratio isa Real && isfinite(Float64(ratio)) && push!(observed_ratios, Float64(ratio))
        units = String(get(raw_row, "model_coordinate_units", "unknown"))
        coordinate_alignment_available &= units in ("per-unit", "SI/model-native")
        nominal = get(raw_row, "nominal_voltage_V", nothing)
        coordinate_alignment_available &= nominal isa Real &&
            isfinite(Float64(nominal)) && Float64(nominal) > 0.0
    end
    classifications = get(comparison, "classification_counts", Dict{String,Int}())
    classifications isa AbstractDict || (classifications = Dict{String,Any}())
    case_status = String(get(case_record, "status", "unknown"))
    checkpoint_phase = String(get(case_record, "checkpoint_phase", "unknown"))
    classification = isempty(classifications) ?
        (case_status == "skipped_solver_size_guard" || checkpoint_phase == "size_guard_skipped" ?
            "solver_size_guard_skipped" : "unavailable") :
        first(sort!(collect(keys(classifications)); by = string))
    return Dict{String,Any}(
        "case" => relative,
        "budget" => budget,
        "output_directory" => case_dir,
        "status" => status,
        "error" => error_message,
        "summary_path" => isfile(summary_path) ? summary_path : nothing,
        "validation_path" => isfile(validation_path) ? validation_path : nothing,
        "validation_finding_codes" => validation isa AbstractDict ?
            [get(finding, "code", "unknown") for finding in
             get(validation, "findings", Any[]) if finding isa AbstractDict] : Any[],
        "comparison_status" => get(comparison, "available_case_count", 0) > 0 ?
            "available" : "unavailable",
        "classification" => classification,
        "case_status" => case_status,
        "checkpoint_phase" => checkpoint_phase,
        "model_variable_count" => get(case_record, "model_variable_count", nothing),
        "max_solver_variables" => get(_dict(get(case_record, "checkpoint", nothing)),
            "max_solver_variables", nothing),
        "solver_log_available" => get(case_record, "solver_log_available", false),
        "solver_log_path" => get(case_record, "solver_log_path", nothing),
        "solver_trace_status" => get(case_record, "status", "unavailable"),
        "solver_trace_iteration_count" => get(_dict(get(case_record,
            "iteration_trace", nothing)), "iteration_count", nothing),
        "row_status_counts" => row_status_counts,
        "row_count" => length(get(comparison_record, "rows", Any[])),
        "observed_ratio_min" => isempty(observed_ratios) ? nothing : minimum(observed_ratios),
        "observed_ratio_max" => isempty(observed_ratios) ? nothing : maximum(observed_ratios),
        "coordinate_alignment_available" => coordinate_alignment_available &&
            !isempty(observed_ratios),
        "family_perturbations_enabled" => family_enabled,
        "family_perturbation_variant_count" => family_variant_count,
        "family_perturbation_status_counts" => family_status_counts,
        "family_perturbation_termination_counts" => family_termination_counts,
        "family_perturbation_by_family" => family_by_family,
        "threshold_violation_case_count" => get(comparison,
            "threshold_violation_case_count", 0),
        "aligned_failure_case_count" => get(comparison,
            "aligned_failure_case_count", 0),
        "source_domain_contract_case_count" => get(summary_contract,
            "available_case_count", 0),
        "source_behavior_auxiliary_mutation_case_count" => get(summary_auxiliary,
            "mutation_case_count", 0),
        "initialization_policy" => get(initialization, "policy",
            get(summary, "initialization_policy", "none")),
        "initialization_status" => get(initialization, "status", "unavailable"),
        "initialization_finite_start_count" => get(initialization,
            "finite_start_count", nothing),
        "initialization_missing_start_count" => get(initialization,
            "missing_start_count", nothing),
        "endpoint_derivative_status" => get(endpoint_derivative, "status",
            "unavailable"),
        "endpoint_derivative_fingerprint" => get(endpoint_derivative,
            "fingerprint", nothing),
        "endpoint_derivative_entry_count" => get(endpoint_derivative,
            "jacobian_entry_count", nothing),
        "endpoint_derivative_row_family_scale_attribution" => get(
            endpoint_derivative, "row_family_scale_attribution", nothing),
        "endpoint_active_set_summary" => get(endpoint_derivative,
            "active_set_summary", nothing),
        "row_family_residual_trace" => row_family_residual_trace,
    )
end

function _readiness(entries)
    family_enabled = any(get(entry, "family_perturbations_enabled", false) === true
                         for entry in entries)
    return Dict{String,Any}(
        "all_pairs_completed" => !isempty(entries) &&
            all(entry -> entry["status"] == "ok", entries),
        "all_source_contracts_available" => !isempty(entries) &&
            all(entry -> entry["source_domain_contract_case_count"] > 0, entries),
        "all_auxiliary_models_non_mutating" => all(entry ->
            entry["source_behavior_auxiliary_mutation_case_count"] == 0, entries),
        "all_comparisons_available" => !isempty(entries) &&
            all(entry -> entry["comparison_status"] == "available", entries),
        "all_coordinate_alignments_available" => !isempty(entries) &&
            all(entry -> get(entry, "coordinate_alignment_available", false), entries),
        "all_initialization_metadata_available" => !isempty(entries) &&
            all(entry -> haskey(entry, "initialization_policy") &&
                haskey(entry, "initialization_status"), entries),
        "all_endpoint_derivative_metadata_available" =>
            !_env_flag("NLPDIAGNOSTICS_BMOPF_CAPTURE_ENDPOINT_DERIVATIVES") ||
            all(entry -> get(entry, "endpoint_derivative_status", "unavailable") in
                ("available", "partial"), entries),
        "all_row_family_scale_attribution_available" =>
            !_env_flag("NLPDIAGNOSTICS_BMOPF_CAPTURE_ENDPOINT_DERIVATIVES") ||
            all(entry -> begin
                attribution = get(entry,
                    "endpoint_derivative_row_family_scale_attribution", nothing)
                attribution isa AbstractDict &&
                    !isempty(get(attribution, "families", Dict{String,Any}()))
            end, entries),
        "all_row_family_residual_traces_available" =>
            !(_env_flag("NLPDIAGNOSTICS_BMOPF_SOURCE_SOLVER_CAPTURE_ROW_RESIDUALS")) ||
            all(entry -> get(get(entry, "row_family_residual_trace", Dict()),
                "status", "unavailable") in ("available", "partial"), entries),
        "family_perturbations_enabled" => family_enabled,
        "all_family_variants_completed" => !family_enabled ||
            all(entry -> get(entry, "family_perturbation_variant_count", 0) > 0,
                entries),
    )
end

function _stability(entries)
    by_case = Dict{String,Vector{Dict{String,Any}}}()
    for entry in entries
        push!(get!(by_case, String(entry["case"]), Dict{String,Any}[]), entry)
    end
    rows = Dict{String,Any}[]
    for (case, case_entries) in sort(collect(by_case); by = first)
        ordered = sort(case_entries; by = entry -> entry["budget"])
        classifications = String[String(entry["classification"]) for entry in ordered]
        push!(rows, Dict{String,Any}(
            "case" => case,
            "budgets" => [entry["budget"] for entry in ordered],
            "classifications" => classifications,
            "classification_stable" => length(unique(classifications)) == 1,
            "row_statuses_stable" => length(unique(
                [JSON.json(get(entry, "row_status_counts", Dict())) for entry in ordered],
            )) == 1,
            "family_perturbations_stable" => length(unique(
                [JSON.json(get(entry, "family_perturbation_by_family", Dict())) for entry in ordered],
            )) == 1,
            "nontrivial_source_alignment_stable" =>
                length(unique(filter(!=("source_domain_evidence_unavailable"), classifications))) == 1 &&
                any(classification -> classification != "source_domain_evidence_unavailable",
                    classifications),
        ))
    end
    return rows
end

function main()
    root = abspath(get(ENV, "NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT", ""))
    isempty(root) && error("Set NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT first")
    isdir(root) || error("benchmark root does not exist: $root")
    cases = _list("NLPDIAGNOSTICS_BMOPF_SOURCE_SOLVER_CASES", _DEFAULT_CASES)
    for relative in cases
        endswith(lowercase(relative), ".dss") || error("case must be a DSS deck: $relative")
        isfile(joinpath(root, relative)) || error("selected DSS deck is missing: $(joinpath(root, relative))")
    end
    budgets = _budgets()
    output_root = abspath(get(ENV, "NLPDIAGNOSTICS_BMOPF_SOURCE_SOLVER_MATRIX_OUTPUT_DIR",
        joinpath(pwd(), "bmopf-source-solver-matrix-results")))
    mkpath(output_root)
    project = _project()
    script = abspath(joinpath(@__DIR__, "bmopf_solver_trace.jl"))
    summary_script = abspath(joinpath(@__DIR__, "summarize_bmopf_solver_trace.jl"))
    validator_script = abspath(joinpath(@__DIR__, "validate_bmopf_campaign.jl"))
    entries = Dict{String,Any}[]
    manifest_path = joinpath(output_root, "matrix.json")
    for budget in budgets, relative in cases
        entry = _run_pair(script, summary_script, validator_script, project,
            root, output_root, relative, budget)
        push!(entries, entry)
    payload = Dict{String,Any}(
            "runner_version" => _RUNNER_VERSION,
            "benchmark_root" => root,
            "input_format" => "dss",
            "project" => project,
            "budgets" => budgets,
        "cases" => cases,
        "entries" => entries,
        "stability" => _stability(entries),
        "readiness" => _readiness(entries),
        "profile_stage" => get(ENV, "NLPDIAGNOSTICS_BMOPF_SOURCE_SOLVER_PROFILE_STAGE",
            get(ENV, "NLPDIAGNOSTICS_BMOPF_RUN_FAMILY_PERTURBATIONS", "false") in
            ("1", "true", "yes", "on") ?
            get(ENV, "NLPDIAGNOSTICS_BMOPF_FAMILY_PROFILE_STAGE", "full") : "trace"),
        "profile_max_variables" => get(ENV,
            "NLPDIAGNOSTICS_BMOPF_SOURCE_SOLVER_PROFILE_MAX_VARIABLES", nothing),
        "rank_max_dense_entries" => get(ENV,
            "NLPDIAGNOSTICS_BMOPF_SOURCE_SOLVER_RANK_MAX_DENSE_ENTRIES", nothing),
        "extra_solver_options" => get(ENV,
            "NLPDIAGNOSTICS_BMOPF_SOURCE_SOLVER_OPTIONS", ""),
        "initialization_policy" => get(ENV,
            "NLPDIAGNOSTICS_BMOPF_INITIALIZATION_POLICY", "none"),
    )
        write(manifest_path, JSON.json(payload))
        println("max_iter=$(budget) $(relative): $(entry["status"]) " *
                "classification=$(entry["classification"])")
    end
    println("wrote source-preserving solver matrix to $manifest_path")
end

main()
