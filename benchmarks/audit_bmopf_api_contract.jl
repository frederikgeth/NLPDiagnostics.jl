#!/usr/bin/env julia

"""
Audit the public BMOPFTools surface consumed by NLPDiagnostics' JuMP extension.

This is a dependency-contract check, not a solver or scientific calibration.
It records the exact package source revision and reports missing symbols before
an integration PR is evaluated against a clean BMOPFTools checkout.

Usage:

    julia --project=work/benchmark-environment \
        benchmarks/audit_bmopf_api_contract.jl \
        docs/bmopf_api_contract_summary.json
"""

using JSON

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "bmopf_api_contract_summary.json") : ARGS[1])
const EXTENSION_SOURCE = joinpath(ROOT, "ext", "BMOPFToolsJuMPExt.jl")
const REQUIRED_TYPES = ["OpfDiagnosticSchema", "OpfModelKey", "OpfScaling"]

function extension_symbols()
    text = read_text(EXTENSION_SOURCE)
    symbols = String[]
    for match_result in eachmatch(
        r"BMOPFTools\.([A-Za-z_][A-Za-z0-9_!]*)",
        text,
    )
        push!(symbols, match_result.captures[1])
    end
    return sort!(unique(symbols))
end

function package_git_root(source_path::AbstractString)
    current = abspath(dirname(source_path))
    while true
        isdir(joinpath(current, ".git")) && return current
        parent = dirname(current)
        parent == current && return nothing
        current = parent
    end
end

function audit_contract()
    package_path = Base.find_package("BMOPFTools")
    package_path === nothing && return Dict{String,Any}(
        "schema_version" => "nlpdiagnostics-bmopf-api-contract-v1",
        "status" => "unavailable",
        "reason" => "BMOPFTools is not discoverable in the active environment",
        "required_symbols" => extension_symbols(),
    )

    BMOPF = Base.require(Main, :BMOPFTools)
    required_symbols = extension_symbols()
    symbol_status = Dict(
        symbol => isdefined(BMOPF, Symbol(symbol)) for symbol in required_symbols
    )
    missing_symbols = sort!([symbol for (symbol, available) in symbol_status if !available])
    source_path = try
        pathof(BMOPF)
    catch
        package_path
    end
    source_root = package_git_root(source_path)
    type_status = Dict(
        name => isdefined(BMOPF, Symbol(name)) for name in REQUIRED_TYPES
    )
    return Dict{String,Any}(
        "schema_version" => "nlpdiagnostics-bmopf-api-contract-v1",
        "status" => isempty(missing_symbols) && all(values(type_status)) ?
            "pass" : "fail",
        "dependency" => Dict{String,Any}(
            "name" => "BMOPFTools",
            "uuid" => "5f9a3b62-8f63-4a39-b67b-af9b51e6a7c3",
            "version" => string(Base.pkgversion(BMOPF)),
            "source_path" => source_path,
            "git_root" => source_root,
            "git_revision" => isnothing(source_root) ? nothing : git_revision(source_root),
            "git_branch" => isnothing(source_root) ? nothing : git_branch(source_root),
            "git_dirty" => isnothing(source_root) ? nothing :
                !isempty(git_status_entries(source_root)),
        ),
        "contract" => Dict{String,Any}(
            "extension_source" => relpath(EXTENSION_SOURCE, ROOT),
            "required_symbol_count" => length(required_symbols),
            "required_symbols" => required_symbols,
            "symbol_status" => symbol_status,
            "missing_symbols" => missing_symbols,
            "required_types" => REQUIRED_TYPES,
            "required_type_status" => type_status,
            "schema_major_required" => 1,
            "schema_version_checked_at_runtime" => false,
            "compatibility_fallbacks" => ["opf_semantic_blocks"],
        ),
        "interpretation" => Dict{String,Any}(
            "claim" =>
                "The resolved BMOPFTools package exposes every public symbol referenced by the NLPDiagnostics JuMP extension.",
            "does_not_establish" => [
                "semantic correctness of each API result",
                "solver convergence or physical KKT acceptance",
                "compatibility with untested BMOPFTools revisions",
            ],
        ),
    )
end

function main()
    report = audit_contract()
    write_json(OUTPUT, report)
    println("wrote BMOPFTools API contract audit to $OUTPUT")
    get(report, "status", "fail") == "pass" || exit(1)
end

abspath(PROGRAM_FILE) == abspath(@__FILE__) && main()
