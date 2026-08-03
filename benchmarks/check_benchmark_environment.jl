#!/usr/bin/env julia

# Read-only preflight for the benchmark/test stack. It does not install or
# mutate packages. Exit status is nonzero when a required package is absent.

using JSON

const _REQUIRED = ["JuMP", "Ipopt", "BMOPFTools"]
const _OPTIONAL = ["PowerModels", "MadNLP", "PowerIO"]

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

function _package_record(name)
    path = Base.find_package(name)
    available = !isnothing(path)
    version = nothing
    if available
        try
            module_name = Symbol(name)
            module_value = Base.require(Main, module_name)
            version = string(Base.pkgversion(module_value))
        catch
            version = "available-but-not-loadable"
        end
    end
    return Dict{String,Any}(
        "name" => name,
        "available" => available,
        "path" => path,
        "version" => version,
    )
end

function main()
    required = [_package_record(name) for name in _REQUIRED]
    optional = [_package_record(name) for name in _OPTIONAL]
    missing_required = [item["name"] for item in required if !item["available"]]
    result = Dict{String,Any}(
        "julia_version" => string(VERSION),
        "active_project" => Base.active_project(),
        "required" => required,
        "optional" => optional,
        "powerio_capi" => _powerio_abi_record(),
        "missing_required" => missing_required,
        "ready" => isempty(missing_required),
    )
    println(JSON.json(result))
    isempty(missing_required) || exit(1)
end

main()
