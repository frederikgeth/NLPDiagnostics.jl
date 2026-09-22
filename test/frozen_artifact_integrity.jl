module FrozenArtifactIntegrity

using JSON
using SHA

export frozen_files_match

function frozen_files_match(root::AbstractString, freeze_path::AbstractString)
    source = JSON.parsefile(joinpath(
        root,
        "docs",
        "frozen_evaluation_source_revision.json",
    ))
    relative_freeze = relpath(freeze_path, root)
    relative_freeze in source["inventories"] || return false
    revision = source["source_revision"]
    inventory = JSON.parsefile(freeze_path)
    return all(inventory["file_sha256"]) do (path, expected)
        object = "$(revision):$(path)"
        bytes = read(Cmd(["git", "-C", root, "show", object]))
        bytes2hex(sha256(bytes)) == expected
    end
end

end
