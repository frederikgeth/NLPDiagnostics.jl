#!/usr/bin/env julia

"""Audit the proposed stable BMOPFTools voltage-start transfer seam.

The full-case transfer benchmark currently reaches into `ctx.vars`.  This
report makes that dependency explicit and records the smallest public API that
would remove it; it does not modify BMOPFTools or claim that the proposal has
already been accepted upstream.
"""

using JSON

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "bmopf_voltage_start_api_summary.json") : ARGS[1])
const TRANSFER_SOURCE = joinpath(ROOT, "benchmarks", "bmopf_combined_mv_lv_feasibility_start_transfer.jl")

const REQUIRED_EXISTING_SYMBOLS = [
    "build_opf_model",
    "enforce_kcl!",
    "opf_model",
    "opf_bases",
    "set_opf_start_values!",
]
const PROPOSED_SYMBOLS = [
    "opf_voltage_start_values",
    "set_opf_voltage_start_values!",
]

function package_git_root(source_path::AbstractString)
    current = abspath(dirname(source_path))
    while true
        (isdir(joinpath(current, ".git")) || isfile(joinpath(current, ".git"))) && return current
        parent = dirname(current)
        parent == current && return nothing
        current = parent
    end
end

function main()
    package_path = Base.find_package("BMOPFTools")
    package_path === nothing && error("BMOPFTools is not discoverable in the active environment")
    BMOPF = Base.require(Main, :BMOPFTools)
    source_path = try pathof(BMOPF) catch; package_path end
    source_root = package_git_root(source_path)
    source_text = isfile(TRANSFER_SOURCE) ? read(TRANSFER_SOURCE, String) : ""
    existing = Dict(symbol => isdefined(BMOPF, Symbol(symbol)) for symbol in REQUIRED_EXISTING_SYMBOLS)
    proposed = Dict(symbol => isdefined(BMOPF, Symbol(symbol)) for symbol in PROPOSED_SYMBOLS)
    proposal_missing = sort!([symbol for (symbol, present) in proposed if !present])
    report = Dict{String,Any}(
        "schema_version" => "nlpdiagnostics-bmopf-voltage-start-api-v1",
        "status" => isempty(proposal_missing) ? "proposal_symbols_available" : "proposal_required",
        "dependency" => Dict(
            "name" => "BMOPFTools",
            "version" => string(Base.pkgversion(BMOPF)),
            "source_path" => source_path,
            "git_root" => source_root,
            "git_revision" => isnothing(source_root) ? nothing : git_revision(source_root),
            "git_branch" => isnothing(source_root) ? nothing : git_branch(source_root),
            "git_dirty" => isnothing(source_root) ? nothing : !isempty(git_status_entries(source_root)),
        ),
        "existing_public_symbols" => existing,
        "proposed_symbols" => proposed,
        "proposal_missing_symbols" => proposal_missing,
        "current_workaround" => Dict(
            "transfer_benchmark" => relpath(TRANSFER_SOURCE, ROOT),
            "uses_internal_context_variable_ledger" => occursin("getfield(context, :vars)", source_text),
            "stable_api_ready" => false,
        ),
        "recommended_contract" => Dict(
            "read" => "opf_voltage_start_values(ctx; units=:SI) -> typed bus/terminal rectangular phasors and coordinate metadata",
            "write" => "set_opf_voltage_start_values!(ctx, starts; units=:SI) -> applied/skipped counts with validation errors",
            "lifecycle" => "call after build_opf_model and before enforce_kcl!/optimize!; must not mutate constraints or optimize",
            "semantics" => "accept physical SI phasors or explicit working-coordinate values, honor per-bus voltage bases, preserve grounded terminals, and reject nonfinite or unknown bus-terminal keys",
            "compatibility" => "keep set_opf_start_values!(ctx) unchanged; add the transfer overload as an additive API with a versioned return schema",
        ),
        "decision" => "Do not promote the internal ctx.vars workaround as stable API. Carry this contract to BMOPFTools for review and retain the bounded benchmark evidence until an upstream implementation is available.",
    )
    write_json(OUTPUT, report)
    println("wrote BMOPFTools voltage-start API audit to $OUTPUT")
end

abspath(PROGRAM_FILE) == abspath(@__FILE__) && main()
