#!/usr/bin/env julia

# Read-only preflight for the benchmark/test stack. It does not install or
# mutate packages. Exit status is nonzero when a required package cannot load.

Base.include(@__MODULE__, joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: json_text

const _REQUIRED = ["NLPDiagnostics", "JuMP", "Ipopt", "BMOPFTools"]
const _OPTIONAL = ["PowerModels", "MadNLP", "PowerIO"]
const _PINNED_BMOPF_REVISION = "b5e050dff579c9a0c3e69c1e1ad11d0b748f2482"

function _powerio_abi_record()
    override = get(ENV, "POWERIO_CAPI", nothing)
    sibling = normpath(joinpath(@__DIR__, "..", "..", "powerio", "target", "release",
                                Sys.iswindows() ? "powerio_capi.dll" :
                                Sys.isapple() ? "libpowerio_capi.dylib" :
                                "libpowerio_capi.so"))
    selected = isnothing(override) || isempty(override) ? sibling : override
    return Dict{String,Any}(
        "override" => override,
        "default_sibling_path" => sibling,
        "selected_path" => selected,
        "exists" => isfile(selected),
        "ready" => isfile(selected),
        "action" => isfile(selected) ?
            "PowerIO C ABI library is available." :
            "Build powerio-capi or set POWERIO_CAPI before from_dss smoke runs.",
    )
end

function _package_record(name; finder=Base.find_package, loader=n -> Base.require(Main, Symbol(n)))
    path = finder(name)
    available = !isnothing(path)
    loadable = false
    version = nothing
    reason = available ? nothing : "package is not installed in the active environment"
    if available
        try
            module_value = loader(name)
            version = string(Base.pkgversion(module_value))
            loadable = true
        catch exception
            exception isa InterruptException && rethrow()
            reason = sprint(showerror, exception)
        end
    end
    return Dict{String,Any}(
        "name" => name,
        "available" => available,
        "loadable" => loadable,
        "reason" => reason,
        "path" => path,
        "version" => version,
    )
end

function _pinned_source_record()
    pinned_project = normpath(joinpath(@__DIR__, "environments", "full_extensions", "Project.toml"))
    Base.active_project() == pinned_project || return Dict("required"=>false, "ready"=>true)
    checkout = normpath(joinpath(@__DIR__, "..", ".ci", "BMOPFTools"))
    try
        revision = strip(read(`git -C $checkout rev-parse HEAD`, String))
        dirty = !isempty(strip(read(`git -C $checkout status --porcelain`, String)))
        return Dict{String,Any}("required"=>true, "revision"=>revision,
            "expected_revision"=>_PINNED_BMOPF_REVISION, "dirty"=>dirty,
            "ready"=>revision == _PINNED_BMOPF_REVISION && !dirty)
    catch exception
        exception isa InterruptException && rethrow()
        return Dict{String,Any}("required"=>true, "ready"=>false,
            "reason"=>sprint(showerror, exception))
    end
end

function main()
    required = [_package_record(name) for name in _REQUIRED]
    optional = [_package_record(name) for name in _OPTIONAL]
    missing_required = [item["name"] for item in required if !item["available"]]
    unloadable_required = [item["name"] for item in required if item["available"] && !item["loadable"]]
    pinned = _pinned_source_record()
    # Every extension is required in the pinned full-extension lane.
    optional_ready = !pinned["required"] || all(item["loadable"] for item in optional)
    ready = isempty(missing_required) && isempty(unloadable_required) && pinned["ready"] && optional_ready
    result = Dict{String,Any}(
        "julia_version" => string(VERSION),
        "active_project" => Base.active_project(),
        "required" => required,
        "optional" => optional,
        "powerio_capi" => _powerio_abi_record(),
        "missing_required" => missing_required,
        "unloadable_required" => unloadable_required,
        "pinned_source" => pinned,
        "ready" => ready,
    )
    print(json_text(result))
    ready || exit(1)
end

abspath(PROGRAM_FILE) == abspath(@__FILE__) && main()
