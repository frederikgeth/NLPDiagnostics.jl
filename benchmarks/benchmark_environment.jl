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

function _benchmark_git_state(root = normpath(joinpath(@__DIR__, "..")))
    revision = _benchmark_git_revision(root)
    try
        status = readchomp(`git -C $root status --porcelain=v1 --untracked-files=all`)
        untracked = filter(!isempty, split(readchomp(
            `git -C $root ls-files --others --exclude-standard`,
        ), '\n'))
        payload = IOBuffer()
        write(payload, read(`git -C $root diff --no-ext-diff --binary HEAD`))
        for relative in sort!(String.(untracked))
            path = joinpath(root, relative)
            isfile(path) || continue
            write(payload, "\nuntracked:", relative, '\n')
            write(payload, read(path))
        end
        bytes = take!(payload)
        dirty = !isempty(status)
        return Dict{String,Any}(
            "revision" => revision,
            "dirty" => dirty,
            "diff_fingerprint" => dirty ? bytes2hex(SHA.sha256(bytes)) : nothing,
            "changed_path_count" => isempty(status) ? 0 : length(split(status, '\n')),
            "untracked_path_count" => length(untracked),
        )
    catch error
        return Dict{String,Any}(
            "revision" => revision,
            "dirty" => nothing,
            "diff_fingerprint" => nothing,
            "changed_path_count" => nothing,
            "untracked_path_count" => nothing,
            "error_type" => string(typeof(error)),
            "error" => sprint(showerror, error),
        )
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
    git = _benchmark_git_state()
    return Dict{String,Any}(
        "julia_version" => string(VERSION),
        "julia_executable" => string(Base.julia_cmd()),
        "machine" => string(Sys.MACHINE),
        "cpu_name" => string(Sys.CPU_NAME),
        "word_size" => Sys.WORD_SIZE,
        "threads" => Threads.nthreads(),
        "packages" => packages,
        "git_revision" => git["revision"],
        "git_dirty" => git["dirty"],
        "git_diff_fingerprint" => git["diff_fingerprint"],
        "git_changed_path_count" => git["changed_path_count"],
        "git_untracked_path_count" => git["untracked_path_count"],
    )
end

function _benchmark_environment_fingerprint(environment = _benchmark_environment())
    packages = get(environment, "packages", Dict{String,Any}())
    stable = Dict(
        "julia_version" => get(environment, "julia_version", "unknown"),
        "packages" => Dict(key => packages[key] for key in sort!(collect(keys(packages)))),
        "git_revision" => get(environment, "git_revision", "unknown"),
        "git_dirty" => get(environment, "git_dirty", nothing),
        "git_diff_fingerprint" => get(environment, "git_diff_fingerprint", nothing),
    )
    return bytes2hex(SHA.sha256(codeunits(JSON.json(stable))))
end
