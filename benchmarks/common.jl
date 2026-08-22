module NLPDiagnosticsBenchmarkCommon

using JSON

export repo_root
export read_text
export read_summary
export write_json
export git_revision
export git_status_entries
export recursive_files

const REPO_ROOT = normpath(joinpath(@__DIR__, ".."))

repo_root() = REPO_ROOT

read_text(path::AbstractString) = isfile(path) ? read(path, String) : ""

function read_summary(relative::AbstractString; root::AbstractString = REPO_ROOT)
    path = joinpath(root, relative)
    isfile(path) || error("required summary is missing: $relative")
    return JSON.parsefile(path)
end

function write_json(path::AbstractString, payload)
    mkpath(dirname(path))
    open(path, "w") do io
        JSON.print(io, payload, 2)
        write(io, '\n')
    end
    return path
end

function git_revision(root::AbstractString = REPO_ROOT)
    try
        return strip(read(`git -C $root rev-parse HEAD`, String))
    catch
        return nothing
    end
end

function git_status_entries(root::AbstractString = REPO_ROOT)
    try
        output = strip(read(
            `git -C $root status --porcelain --untracked-files=all`,
            String,
        ))
        isempty(output) ? String[] : split(output, '\n')
    catch
        String[]
    end
end

function recursive_files(directory::AbstractString, suffix::AbstractString)
    files = String[]
    isdir(directory) || return files
    for (root, _, names) in walkdir(directory)
        for name in names
            endswith(name, suffix) && push!(files, joinpath(root, name))
        end
    end
    sort!(files)
    return files
end

end
