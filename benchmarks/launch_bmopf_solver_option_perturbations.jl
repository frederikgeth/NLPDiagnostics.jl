#!/usr/bin/env julia

"""Run bounded source-preserving solver-option perturbation matrices."""

using JSON

function _canonical_options(raw::AbstractString)
    options = Pair{String,String}[]
    for item in split(raw, ',')
        isempty(strip(item)) && continue
        pair = split(item, '='; limit = 2)
        length(pair) == 2 || error("solver options must be comma-separated key=value pairs")
        key, value = strip.(pair)
        isempty(key) && error("solver option keys must not be empty")
        isempty(value) && error("solver option values must not be empty")
        push!(options, lowercase(key) => value)
    end
    isempty(options) && error("every option perturbation must use an explicit option set")
    length(unique(first.(options))) == length(options) ||
        error("an option perturbation must not assign the same option more than once")
    sort!(options; by = first)
    return join(("$(pair.first)=$(pair.second)" for pair in options), ',')
end

function _specs()
    raw = get(ENV, "NLPDIAGNOSTICS_BMOPF_OPTION_PERTURBATIONS",
        "baseline:mu_strategy=monotone;" *
        "adaptive_filter:mu_strategy=adaptive,adaptive_mu_globalization=obj-constr-filter;" *
        "adaptive_free:mu_strategy=adaptive,adaptive_mu_globalization=never-monotone-mode")
    specs = NamedTuple{(:label, :options),Tuple{String,String}}[]
    for item in split(raw, ';')
        isempty(strip(item)) && continue
        pair = split(item, ':'; limit = 2)
        length(pair) == 2 || error("option perturbations must be label:options")
        label, options = strip.(pair)
        occursin(r"^[A-Za-z0-9_-]+$", label) || error("invalid perturbation label '$label'")
        push!(specs, (label = label, options = options))
    end
    isempty(specs) && error("no option perturbations selected")
    length(unique(spec.label for spec in specs)) == length(specs) ||
        error("option perturbation labels must be unique")
    canonical_options = _canonical_options.(spec.options for spec in specs)
    length(unique(canonical_options)) == length(specs) ||
        error("option perturbation option sets must be distinct")
    count(spec -> spec.label == "baseline", specs) == 1 ||
        error("exactly one option perturbation must be labelled 'baseline'")
    return specs
end

function _policies()
    raw = get(ENV, "NLPDIAGNOSTICS_BMOPF_OPTION_PERTURBATION_POLICIES", "none,zero")
    policies = filter(!isempty, strip.(split(raw, ',')))
    isempty(policies) && error("no initialization policies selected")
    return unique(policies)
end

function _campaign_scope()
    scope = lowercase(strip(get(ENV,
        "NLPDIAGNOSTICS_BMOPF_OPTION_CAMPAIGN_SCOPE", "generic")))
    scope in ("generic", "multiconductor") || error(
        "NLPDIAGNOSTICS_BMOPF_OPTION_CAMPAIGN_SCOPE must be generic or multiconductor",
    )
    return scope
end

function _flag(name; default = false)
    raw = lowercase(strip(get(ENV, name, default ? "true" : "false")))
    raw in ("1", "true", "yes", "on") && return true
    raw in ("0", "false", "no", "off") && return false
    error("$name must be a boolean")
end

function _validate_campaign_scope(scope)
    scope == "multiconductor" || return
    profile_stage = lowercase(strip(get(ENV,
        "NLPDIAGNOSTICS_BMOPF_SOURCE_SOLVER_PROFILE_STAGE", "")))
    profile_stage == "context" || error(
        "multiconductor option campaigns require " *
        "NLPDIAGNOSTICS_BMOPF_SOURCE_SOLVER_PROFILE_STAGE=context",
    )
    _flag("NLPDIAGNOSTICS_BMOPF_SOURCE_SOLVER_CAPTURE_POINTS") || error(
        "multiconductor option campaigns require captured solver-iterate points",
    )
    _flag("NLPDIAGNOSTICS_BMOPF_SOURCE_SOLVER_CAPTURE_ROW_RESIDUALS") || error(
        "multiconductor option campaigns require row-family residual capture",
    )
    return nothing
end

function _write_manifest(path, root, entries, specs, policies; status)
    campaign_scope = _campaign_scope()
    payload = Dict{String,Any}(
        "report_version" => "bmopf-option-perturbation-manifest-v3",
        "campaign_status" => status,
        "benchmark_root" => root,
        "entries" => entries,
        "expected_entry_count" => length(specs) * length(policies),
        "completed_entry_count" => length(entries),
        "options" => [Dict(
            "label" => spec.label,
            "options" => spec.options,
        ) for spec in specs],
        "canonical_options" => [Dict(
            "label" => spec.label,
            "options" => _canonical_options(spec.options),
        ) for spec in specs],
        "policies" => policies,
        "budgets" => get(ENV, "NLPDIAGNOSTICS_BMOPF_SOURCE_SOLVER_BUDGETS", "5,25"),
        "cases" => get(ENV, "NLPDIAGNOSTICS_BMOPF_SOURCE_SOLVER_CASES", ""),
        "campaign_scope" => campaign_scope,
        "experimental_design" => Dict{String,Any}(
            "baseline_is_explicit" => true,
            "distinct_option_sets_required" => true,
            "comparison_unit" => "same case, iteration budget, and initialization policy",
            "model_semantic_invariance_required" => campaign_scope == "multiconductor",
            "interpretation" => "Profiles are controlled algorithmic interventions. They test whether a recorded signature persists; they do not establish a model-side cause.",
        ),
    )
    temporary = "$path.tmp"
    write(temporary, JSON.json(payload))
    mv(temporary, path; force = true)
    return path
end

function main()
    root = abspath(get(ENV, "NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT", ""))
    isempty(root) && error("Set NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT first")
    isdir(root) || error("benchmark root does not exist: $root")
    output_root = abspath(get(ENV, "NLPDIAGNOSTICS_BMOPF_OPTION_PERTURBATION_OUTPUT_DIR",
        joinpath(pwd(), "bmopf-option-perturbations")))
    mkpath(output_root)
    project = get(ENV, "NLPDIAGNOSTICS_BENCHMARK_PROJECT", something(Base.active_project(), pwd()))
    launcher = abspath(joinpath(@__DIR__, "launch_bmopf_source_solver_matrix.jl"))
    julia = Base.julia_cmd()
    specs = _specs()
    policies = _policies()
    _validate_campaign_scope(_campaign_scope())
    entries = Dict{String,Any}[]
    manifest_path = joinpath(output_root, "option_perturbation_manifest.json")
    _write_manifest(manifest_path, root, entries, specs, policies; status = "running")
    for spec in specs, policy in policies
        label = "$(spec.label)__$(policy)"
        case_output = joinpath(output_root, label)
        environment = copy(ENV)
        environment["NLPDIAGNOSTICS_BMOPF_SOURCE_SOLVER_MATRIX_OUTPUT_DIR"] = case_output
        environment["NLPDIAGNOSTICS_BMOPF_SOURCE_SOLVER_OPTIONS"] = spec.options
        environment["NLPDIAGNOSTICS_BMOPF_INITIALIZATION_POLICY"] = policy
        status = "ok"
        error_text = nothing
        try
            run(setenv(`$julia --startup-file=no --project=$project --compiled-modules=no $launcher`,
                environment))
        catch error
            status = "runner_error"
            error_text = sprint(showerror, error)
        end
        matrix_path = joinpath(case_output, "matrix.json")
        entry = Dict{String,Any}(
            "label" => label,
            "profile" => spec.label,
            "options" => spec.options,
            "initialization_policy" => policy,
            "status" => status,
            "matrix_path" => isfile(matrix_path) ? matrix_path : nothing,
            "output_directory" => case_output,
        )
        isnothing(error_text) || (entry["error"] = error_text)
        push!(entries, entry)
        _write_manifest(manifest_path, root, entries, specs, policies; status = "running")
    end
    _write_manifest(manifest_path, root, entries, specs, policies; status = "complete")
    println("wrote option perturbation manifest to $manifest_path")
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    main()
end
