#!/usr/bin/env julia

"""Fresh-child runner for the combined MV/LV start-transfer benchmark."""

using JSON

length(ARGS) == 1 || error("usage: run_bmopf_combined_mv_lv_feasibility_start_transfer_child.jl output.json")
output = abspath(ARGS[1])
ENV["NLPDIAGNOSTICS_COMBINED_MV_LV_TRANSFER_OUTPUT"] = output
include(joinpath(@__DIR__, "bmopf_combined_mv_lv_feasibility_start_transfer.jl"))

struct _MallocStatistics
    blocks_in_use::Csize_t
    size_in_use::Csize_t
    max_size_in_use::Csize_t
    size_allocated::Csize_t
end

function _allocator_snapshot()
    Sys.isapple() || return nothing
    try
        zone = ccall(:malloc_default_zone, Ptr{Cvoid}, ())
        stats = Ref(_MallocStatistics(0, 0, 0, 0))
        ccall(:malloc_zone_statistics, Cvoid,
            (Ptr{Cvoid}, Ref{_MallocStatistics}), zone, stats)
        value = stats[]
        return Dict{String,Any}(
            "available" => true,
            "blocks_in_use" => Int(value.blocks_in_use),
            "size_in_use_bytes" => Int(value.size_in_use),
            "max_size_in_use_bytes" => Int(value.max_size_in_use),
            "size_allocated_bytes" => Int(value.size_allocated),
            "peak_field_available" => value.max_size_in_use > 0,
        )
    catch error
        return Dict{String,Any}(
            "available" => false,
            "error_type" => string(typeof(error)),
            "error" => sprint(showerror, error),
        )
    end
end

allocator_before = _allocator_snapshot()
payload = main()
allocator_after = _allocator_snapshot()
payload["child_peak_rss_bytes"] = Sys.maxrss()
payload["allocator_telemetry"] = Dict(
    "before" => allocator_before,
    "after" => allocator_after,
    "current_size_in_use_delta_bytes" =>
        allocator_before isa AbstractDict && allocator_after isa AbstractDict &&
        get(allocator_before, "available", false) && get(allocator_after, "available", false) ?
            get(allocator_after, "size_in_use_bytes", 0) - get(allocator_before, "size_in_use_bytes", 0) : nothing,
    "current_size_allocated_delta_bytes" =>
        allocator_before isa AbstractDict && allocator_after isa AbstractDict &&
        get(allocator_before, "available", false) && get(allocator_after, "available", false) ?
            get(allocator_after, "size_allocated_bytes", 0) - get(allocator_before, "size_allocated_bytes", 0) : nothing,
    "peak_available" => allocator_after isa AbstractDict && get(allocator_after, "peak_field_available", false),
)
payload["memory_observation"] = "fresh-child Sys.maxrss high-water plus Darwin malloc_zone_statistics current allocator bytes; allocator peak field is reported separately and is unavailable when zero"
write_json(output, payload)
