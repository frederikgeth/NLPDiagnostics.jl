#!/usr/bin/env julia

"""Run bounded source-preserving solver-option perturbation matrices."""

using JSON

function _specs()
    raw = get(ENV, "NLPDIAGNOSTICS_BMOPF_OPTION_PERTURBATIONS",
        "baseline:;adaptive:mu_strategy=adaptive;monotone:mu_strategy=monotone")
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
    return specs
end

function _policies()
    raw = get(ENV, "NLPDIAGNOSTICS_BMOPF_OPTION_PERTURBATION_POLICIES", "none,zero")
    policies = filter(!isempty, strip.(split(raw, ',')))
    isempty(policies) && error("no initialization policies selected")
    return unique(policies)
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
    entries = Dict{String,Any}[]
    for spec in _specs(), policy in _policies()
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
    end
    manifest_path = joinpath(output_root, "option_perturbation_manifest.json")
    write(manifest_path, JSON.json(Dict(
        "report_version" => "bmopf-option-perturbation-manifest-v1",
        "benchmark_root" => root,
        "entries" => entries,
        "options" => [Dict("label" => spec.label, "options" => spec.options) for spec in _specs()],
        "policies" => _policies(),
        "budgets" => get(ENV, "NLPDIAGNOSTICS_BMOPF_SOURCE_SOLVER_BUDGETS", "5,25"),
        "cases" => get(ENV, "NLPDIAGNOSTICS_BMOPF_SOURCE_SOLVER_CASES", ""),
    )))
    println("wrote option perturbation manifest to $manifest_path")
end

main()
