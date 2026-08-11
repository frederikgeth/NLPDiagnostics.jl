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

function _benchmark_git_root(path::AbstractString)
    current = isdir(path) ? abspath(path) : dirname(abspath(path))
    while true
        isdir(joinpath(current, ".git")) && return current
        parent = dirname(current)
        parent == current && return nothing
        current = parent
    end
end

function _benchmark_package_source_state(name::AbstractString)
    binding = Symbol(name)
    isdefined(Main, binding) || return Dict{String,Any}(
        "available" => false,
        "reason" => "module_not_loaded",
    )
    mod = getfield(Main, binding)
    source_path = try
        pathof(mod)
    catch
        nothing
    end
    source_path isa AbstractString || return Dict{String,Any}(
        "available" => false,
        "reason" => "module_source_path_unavailable",
    )
    root = _benchmark_git_root(source_path)
    isnothing(root) && return Dict{String,Any}(
        "available" => false,
        "reason" => "git_root_unavailable",
        "source_path" => source_path,
    )
    state = _benchmark_git_state(root)
    return Dict{String,Any}(
        "available" => true,
        "source_path" => source_path,
        "git_root" => root,
        "git_revision" => get(state, "revision", "unavailable"),
        "git_dirty" => get(state, "dirty", nothing),
        "git_diff_fingerprint" => get(state, "diff_fingerprint", nothing),
        "git_changed_path_count" => get(state, "changed_path_count", nothing),
        "git_untracked_path_count" => get(state, "untracked_path_count", nothing),
    )
end

function _benchmark_package_source_states()
    return Dict{String,Any}(
        name => _benchmark_package_source_state(name)
        for name in ("NLPDiagnostics", "BMOPFTools")
    )
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
        "package_source_states" => _benchmark_package_source_states(),
        "git_revision" => git["revision"],
        "git_dirty" => git["dirty"],
        "git_diff_fingerprint" => git["diff_fingerprint"],
        "git_changed_path_count" => git["changed_path_count"],
        "git_untracked_path_count" => git["untracked_path_count"],
    )
end

function _benchmark_environment_fingerprint(environment = _benchmark_environment())
    packages = get(environment, "packages", Dict{String,Any}())
    source_states = get(environment, "package_source_states", Dict{String,Any}())
    stable_source_states = Dict{String,Any}()
    for name in sort!(collect(keys(source_states)))
        state = source_states[name]
        state isa AbstractDict || continue
        stable_source_states[String(name)] = Dict{String,Any}(
            "available" => get(state, "available", false),
            "git_revision" => get(state, "git_revision", "unavailable"),
            "git_dirty" => get(state, "git_dirty", nothing),
            "git_diff_fingerprint" => get(state, "git_diff_fingerprint", nothing),
        )
    end
    stable = Dict(
        "julia_version" => get(environment, "julia_version", "unknown"),
        "packages" => Dict(key => packages[key] for key in sort!(collect(keys(packages)))),
        "package_source_states" => stable_source_states,
        "git_revision" => get(environment, "git_revision", "unknown"),
        "git_dirty" => get(environment, "git_dirty", nothing),
        "git_diff_fingerprint" => get(environment, "git_diff_fingerprint", nothing),
    )
    return bytes2hex(SHA.sha256(codeunits(JSON.json(stable))))
end
