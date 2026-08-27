#!/usr/bin/env julia

"""Fresh-child runner for the combined MV/LV start-transfer benchmark."""

using JSON

length(ARGS) == 1 || error("usage: run_bmopf_combined_mv_lv_feasibility_start_transfer_child.jl output.json")
output = abspath(ARGS[1])
ENV["NLPDIAGNOSTICS_COMBINED_MV_LV_TRANSFER_OUTPUT"] = output
include(joinpath(@__DIR__, "bmopf_combined_mv_lv_feasibility_start_transfer.jl"))
payload = main()
payload["child_peak_rss_bytes"] = Sys.maxrss()
payload["memory_observation"] = "fresh-child Sys.maxrss high-water after the paired solve; process-local and not allocator-level peak memory"
write_json(output, payload)
