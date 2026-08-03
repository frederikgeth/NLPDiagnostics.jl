# Shared reproducibility metadata for benchmark runners.

using JSON
using SHA

function _benchmark_package_version(mod)
    try
        return string(Base.pkgversion(mod))
    catch
        return "unavailable"
    end
end

function _benchmark_optional_package_version(name::AbstractString)
    binding = Symbol(name)
    isdefined(Main, binding) || return "unavailable"
    return _benchmark_package_version(getfield(Main, binding))
end

function _benchmark_git_revision(root = normpath(joinpath(@__DIR__, "..")))
    try
        return strip(readchomp(`git -C $root rev-parse HEAD`))
    catch
        return "unavailable"
    end
end

function _benchmark_environment()
    packages = Dict{String,Any}(
        "NLPDiagnostics" => _benchmark_optional_package_version("NLPDiagnostics"),
        "JuMP" => _benchmark_optional_package_version("JuMP"),
        "Ipopt" => _benchmark_optional_package_version("Ipopt"),
        "MadNLP" => _benchmark_optional_package_version("MadNLP"),
        "BMOPFTools" => _benchmark_optional_package_version("BMOPFTools"),
    )
    return Dict{String,Any}(
        "julia_version" => string(VERSION),
        "julia_executable" => string(Base.julia_cmd()),
        "machine" => string(Sys.MACHINE),
        "cpu_name" => string(Sys.CPU_NAME),
        "word_size" => Sys.WORD_SIZE,
        "threads" => Threads.nthreads(),
        "packages" => packages,
        "git_revision" => _benchmark_git_revision(),
    )
end

function _benchmark_environment_fingerprint(environment = _benchmark_environment())
    packages = get(environment, "packages", Dict{String,Any}())
    stable = Dict(
        "julia_version" => get(environment, "julia_version", "unknown"),
        "packages" => Dict(key => packages[key] for key in sort!(collect(keys(packages)))),
        "git_revision" => get(environment, "git_revision", "unknown"),
    )
    return bytes2hex(SHA.sha256(codeunits(JSON.json(stable))))
end
