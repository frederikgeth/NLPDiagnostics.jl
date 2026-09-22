module FindingReference

const ROOT = normpath(joinpath(@__DIR__, ".."))
const SOURCE_ROOT = get(ENV, "NLPDIAGNOSTICS_FINDING_SOURCE_ROOT", joinpath(ROOT, "src"))
const OUTPUT = joinpath(@__DIR__, "src", "reference", "finding-codes.md")

const CURATED = [
    ("inconsistent_affine_implied_variable_bounds", "model-wide", "Supported affine rows imply an empty interval for one variable.", "Check the affected rows against source data and units."),
    ("possible_expression_domain_violation", "model-wide enclosure", "Declared bounds do not keep an expression entirely inside its operator domain.", "Inspect bounds and then evaluate an independently meaningful point."),
    ("operating_point_domain_violation", "one point", "An operator argument violates its domain at the named evaluation point.", "Check point provenance before changing the model."),
    ("nonfinite_constraint_value", "one point", "A constraint produced a non-finite value at the named point.", "Inspect domain findings and the expression path."),
    ("initialization_violates_variable_bounds", "initialization", "A supplied start lies outside a declared variable bound.", "Check start construction and source-unit conversion."),
    ("underdetermined_equality_partition", "structural pattern", "The equality incidence graph contains an underdetermined region.", "Compare numerical rank and domain-declared expected freedoms."),
    ("overdetermined_equality_partition", "structural pattern", "The equality incidence graph contains an overdetermined region.", "Inspect unmatched and duplicate/proportional rows."),
    ("proportional_affine_equality_constraints", "model-wide", "Supported affine equalities encode the same equation up to scaling.", "Decide from formulation intent whether the redundancy is expected."),
    ("unmatched_structural_variables", "structural pattern", "Some eligible free variables are unmatched in a maximum equality matching.", "Inspect the corresponding Dulmage–Mendelsohn region."),
    ("dense_sparse_qr_rank_agreement", "one point and policy", "Guarded dense and sparse rank backends agree under the recorded policy.", "Retain the tolerance and scaling; agreement does not make rank global."),
    ("solver_result_point_unavailable", "solver result", "The requested result does not expose a complete real primal vector.", "Inspect result count and primal status; do not fill coordinates silently."),
]

const AREA_ORDER = [
    "Static and structural model",
    "Expression domains and derivatives",
    "Numerical geometry",
    "Initialization",
    "Solver results and traces",
    "Reports and representation",
    "Other declarations",
]

function area(path::String)
    endswith(path, "analysis/static.jl") && return "Static and structural model"
    any(endswith(path, suffix) for suffix in (
        "analysis/structure.jl", "analysis/matching.jl", "ir/structural_roles.jl",
    )) && return "Static and structural model"
    any(endswith(path, suffix) for suffix in (
        "analysis/domains.jl", "analysis/derivatives.jl", "analysis/expressions.jl",
    )) && return "Expression domains and derivatives"
    any(endswith(path, suffix) for suffix in (
        "analysis/numerical.jl", "analysis/activity.jl", "analysis/degeneracy.jl",
        "analysis/crosscheck.jl", "analysis/scaling.jl", "numerics/degeneracy.jl",
        "numerics/activity.jl", "numerics/hessian.jl", "numerics/duals.jl",
    )) && return "Numerical geometry"
    endswith(path, "analysis/initialization.jl") && return "Initialization"
    endswith(path, "analysis/postmortem.jl") && return "Solver results and traces"
    startswith(path, "src/reports/") && return "Reports and representation"
    return "Other declarations"
end

function inventory()
    records = Dict{String,Set{String}}()
    for (directory, _, files) in walkdir(SOURCE_ROOT)
        for file in sort(files)
            endswith(file, ".jl") || continue
            path = joinpath(directory, file)
            relative = replace(joinpath("src", relpath(path, SOURCE_ROOT)), '\\' => '/')
            source = read(path, String)
            for matched in eachmatch(r"Finding\(\s*:([A-Za-z0-9_]+)", source)
                push!(get!(records, matched.captures[1], Set{String}()), relative)
            end
        end
    end
    isempty(records) && error("no literal Finding(:code) declarations found")
    return records
end

function source_mentions(code::String)
    pattern = Regex(":" * code * "\\b")
    for (directory, _, files) in walkdir(SOURCE_ROOT)
        for file in files
            endswith(file, ".jl") || continue
            occursin(pattern, read(joinpath(directory, file), String)) && return true
        end
    end
    return false
end

function render()
    records = inventory()
    missing = [row[1] for row in CURATED if !source_mentions(row[1])]
    isempty(missing) || error("curated finding codes are absent from source: $(join(missing, ", "))")
    io = IOBuffer()
    println(io, "# Finding codes")
    println(io)
    println(io, "A finding code is a stable identifier for filtering and comparing reports within")
    println(io, "an experiment. The code alone is not the conclusion: always retain its basis,")
    println(io, "confidence, affected entities, evidence, point provenance, and report metadata.")
    println(io)
    println(io, "## Common codes")
    println(io)
    println(io, "| Code | Scope | How to read it | Useful next check |")
    println(io, "|:--|:--|:--|:--|")
    for (code, scope, meaning, next) in CURATED
        println(io, "| `", code, "` | ", scope, " | ", meaning, " | ", next, " |")
    end
    println(io)
    println(io, "## Statically declared inventory")
    println(io)
    println(io, "The list below is generated from literal `Finding(:code, ...)` constructors in")
    println(io, "`src/`. It is a source-coverage index, not a promise that every code is Stable,")
    println(io, "reachable for every model, or fully calibrated. Dynamically selected codes are")
    println(io, "outside this lexical inventory. The documentation build fails when this file is stale.")
    println(io)
    grouped = Dict(name => String[] for name in AREA_ORDER)
    for code in sort!(collect(keys(records)))
        paths = sort!(collect(records[code]))
        group = area(first(paths))
        links = join(["`$(path)`" for path in paths], ", ")
        push!(grouped[group], "- `$(code)` — $(links)")
    end
    for group in AREA_ORDER
        isempty(grouped[group]) && continue
        println(io, "### ", group)
        println(io)
        for line in grouped[group]
            println(io, line)
        end
        println(io)
    end
    println(io, "Inventory count: **", length(records), "** literal finding codes.")
    return String(take!(io))
end

function check()
    isfile(OUTPUT) || error("missing generated finding reference; run `julia docs/generate_finding_reference.jl --write`")
    expected = render()
    actual = read(OUTPUT, String)
    actual == expected || error("stale finding reference; run `julia docs/generate_finding_reference.jl --write`")
    return nothing
end

function main(args)
    args == ["--write"] || error("usage: julia docs/generate_finding_reference.jl --write")
    write(OUTPUT, render())
    println("wrote ", relpath(OUTPUT, ROOT))
end

abspath(PROGRAM_FILE) == abspath(@__FILE__) && main(ARGS)

end
